"""The gamma function and its logarithm. Go's `gamma.go` and `lgamma.go`.

`gamma` is ported. Go's is Cephes, by way of `tgamma.c`, and the system library
here is a different implementation with a different error curve: at -170.5 it
is about two hundred parts in the last place away from Go's answer, which is
outside even the loosest tolerance Go's own tests accept. Everywhere the two
agree it does not matter which is used, and where they disagree Go's answer is
the one this package promises, so Go's is the one that is here.

`lgamma`'s value comes from the system library, which is within Go's tolerance
for it across the whole test range. Its sign does not: that is the second half
of Go's `Lgamma`, which C puts in a global called `signgam` set as a side
effect of the call, a design from before threads and not a thing to reach for
from Mojo. Go returns it, and so does this, computed rather than read.

The two tables `_GAM_P` and `_GAM_Q` are the rational approximation on the
interval from two to three, which is where every argument under thirty three
gets moved to by the recurrence. Above thirty three it is Stirling's formula,
and below zero it is the reflection formula, which is why `gamma` calls `sin`.
"""

from std.math import lgamma as _std_lgamma

from .const import PI
from .exp import exp, pow
from .floor import floor
from .ieee import abs, inf, is_inf, is_nan, nan, signbit
from .trig import sin


comptime _GAM_P: InlineArray[Float64, 7] = [
    1.60119522476751861407e-04,
    1.19135147006586384913e-03,
    1.04213797561761569935e-02,
    4.76367800457137231464e-02,
    2.07448227648435975150e-01,
    4.94214826801497100753e-01,
    9.99999999999999996796e-01,
]

comptime _GAM_Q: InlineArray[Float64, 8] = [
    -2.31581873324120129819e-05,
    5.39605580493303397842e-04,
    -4.45641913851797240494e-03,
    1.18139785222060435552e-02,
    3.58236398605498653373e-02,
    -2.34591795718243348568e-01,
    7.14304917030273074085e-02,
    1.00000000000000000320e00,
]

comptime _GAM_S: InlineArray[Float64, 5] = [
    7.87311395793093628397e-04,
    -2.29549961613378126380e-04,
    -2.68132617805781232825e-03,
    3.47222221605458667310e-03,
    8.33333333333482257126e-02,
]

comptime _SQRT_TWO_PI = 2.506628274631000502417
comptime _MAX_STIRLING = 143.01608
"""Above this, `pow(x, x - 0.5)` would overflow and the work is split in two."""

comptime _EULER = 0.57721566490153286060651209008240243104215933593992
"""The Euler-Mascheroni constant, for the first two terms of the series at
zero."""


def _stirling(x: Float64) -> Tuple[Float64, Float64]:
    """The gamma function of `x` by Stirling's formula, as two factors.

    The caller multiplies them. Go leaves the multiplication out so that a
    caller who is about to divide by the answer can avoid an infinity in the
    middle for arguments between 172 and 180, where the product overflows and
    the reciprocal would not have.

    The polynomial is good from 33 to 172. Larger arguments only ever reach
    here on their way into a division, and the answer there is subnormal, so
    there are no digits left for the polynomial to get wrong.
    """
    if x > 200:
        return inf(1), 1.0

    var s = materialize[_GAM_S]()
    var w = 1 / x
    w = 1 + w * ((((s[0] * w + s[1]) * w + s[2]) * w + s[3]) * w + s[4])

    var ex = exp(x)
    var y1: Float64
    var y2 = 1.0
    if x > _MAX_STIRLING:
        var v = pow(x, 0.5 * x - 0.25)
        y1 = v
        y2 = v / ex
    else:
        y1 = pow(x, x - 0.5) / ex
    return y1, _SQRT_TWO_PI * w * y2


def _is_neg_int(x: Float64) -> Bool:
    """Whether `x` is a negative integer, where gamma has a pole.

    Go asks `Modf` for the fractional part and compares it to zero. This asks
    whether the value is its own floor, which is the same question.
    """
    return x < 0 and floor(x) == x


def _gamma_small(x: Float64, z: Float64) -> Float64:
    """Gamma near zero, where the recurrence would divide by almost nothing.

    Two terms of the series: `gamma(x)` is `1/x - Euler` as `x` goes to zero,
    written as a single division so that the subtraction happens in the
    denominator where it cannot cancel.
    """
    if x == 0:
        return inf(1)
    return z / ((1 + _EULER * x) * x)


def gamma(x: Float64) -> Float64:
    """The gamma function of `x`.

    `gamma(+0.0)` is positive infinity and `gamma(-0.0)` is negative infinity,
    which is the limit approached from each side. At a negative integer there
    is no limit to take, one side running to each infinity, so the answer is a
    not a number rather than either, and so is `gamma(-inf)`.
    """
    if _is_neg_int(x) or is_inf(x, -1) or is_nan(x):
        return nan()
    if is_inf(x, 1):
        return inf(1)
    if x == 0:
        return inf(-1) if signbit(x) else inf(1)

    var q = abs(x)
    var p = floor(q)
    if q > 33:
        if x >= 0:
            var y1, y2 = _stirling(x)
            return y1 * y2

        # Below minus thirty three, by reflection:
        # gamma(x) * gamma(1-x) = pi / sin(pi*x). `x` is negative and, having
        # been checked above, not an integer, so it is small enough to convert:
        # anything at or past 2**63 in magnitude is an integer already.
        var sign = 1
        if Int(p) & 1 == 0:
            sign = -1
        var z = q - p
        if z > 0.5:
            p = p + 1
            z = q - p
        z = q * sin(PI * z)
        if z == 0:
            return inf(sign)

        var sq1, sq2 = _stirling(q)
        var absz = abs(z)
        var d = absz * sq1 * sq2
        # Split the division up when the product would overflow, since the
        # answer itself is small and only the intermediate is out of range.
        if is_inf(d, 0):
            z = PI / absz / sq1 / sq2
        else:
            z = PI / d
        return Float64(sign) * z

    # Everything from here down is moved into [2, 3) by the recurrence
    # gamma(x+1) = x * gamma(x), with the factors picked up along the way
    # collected in `z`.
    var v = x
    var z = 1.0
    while v >= 3:
        v = v - 1
        z = z * v
    while v < 0:
        if v > -1e-09:
            return _gamma_small(v, z)
        z = z / v
        v = v + 1
    while v < 2:
        if v < 1e-09:
            return _gamma_small(v, z)
        z = z / v
        v = v + 1

    if v == 2:
        return z

    v = v - 2
    var gp = materialize[_GAM_P]()
    var gq = materialize[_GAM_Q]()
    var num = (
        ((((v * gp[0] + gp[1]) * v + gp[2]) * v + gp[3]) * v + gp[4]) * v
        + gp[5]
    ) * v + gp[6]
    var den = (
        (
            ((((v * gq[0] + gq[1]) * v + gq[2]) * v + gq[3]) * v + gq[4]) * v
            + gq[5]
        )
        * v
        + gq[6]
    ) * v + gq[7]
    return z * num / den


def lgamma(x: Float64) -> Tuple[Float64, Int]:
    """The natural logarithm of the absolute value of `gamma(x)`, and the sign
    of `gamma(x)`.

    The logarithm is what `gamma` overflows past: `gamma(172.0)` is an infinity
    and `lgamma(172.0)` is about 713. Since a logarithm cannot carry the sign,
    the sign comes back beside it, as 1 or -1.

    The sign is 1 everywhere gamma is positive, and 1 as well at the places
    where the first return is an infinity and there is no sign to have: zero,
    the negative integers, and the not a numbers.
    """
    # Both infinities come back as themselves, which is Go, and is not what
    # the system library does with the negative one.
    if is_nan(x) or is_inf(x, 0):
        return x, 1
    return _std_lgamma(x), _lgamma_sign(x)


def _lgamma_sign(x: Float64) -> Int:
    """The sign of `gamma(x)`, as Go's `Lgamma` reports it.

    Positive everywhere from zero up, and alternating below it once per unit
    interval, starting negative just under zero. Go asks this question of
    `sinPi(|x|)`, which is the same alternation computed the long way round;
    the parity of the integer part answers it without evaluating a sine, and
    without the accuracy worry that a sine of a large argument brings.

    Go's answer at a negative integer is 1, and so is this one: the logarithm
    there is an infinity and the sign is not describing anything. That case is
    also what keeps the conversion below in range, since every float64 large
    enough to overflow an `Int` is an integer and has already returned.
    """
    if is_nan(x) or is_inf(x, 0) or x >= 0:
        return 1
    var a = -x
    var whole = floor(a)
    if whole == a:
        return 1
    return -1 if Int(whole) % 2 == 0 else 1
