"""Logarithms. Go's `log.go`, `log1p.go`, `log10.go` and `logb.go`.

Six functions and none of them wraps `std.math`.

`log` and `log1p` are ported because Mojo's are not accurate enough. Go's tests
hold `Log` and `Log1p` to four parts in 10**16, which is about two units in the
last place, and `std.math.log` is out by two million of them on an ordinary
argument. That is a deliberate trade in a library aimed at machine learning
workloads, where an eighth of an ulp of throughput is worth more than the last
thirteen digits, and it is the wrong trade for this package. The ported version
is FDLIBM's, by way of Go, and is the same code that is inside a C library.

`log10` and `log2` are ported because Go does not call anybody's `log10`
either: it scales a natural logarithm, and scaling the same one the same way is
what makes the last bit agree.

`logb` and `ilogb` are ported because they are the exponent field and nothing
else, so there is no arithmetic in them to get wrong.
"""

from .arith import frexp
from .const import LOG2E, LOG10E, MAX_INT32, MIN_INT32, SQRT2
from .ieee import (
    _BIAS,
    _MASK,
    _SHIFT,
    _normalize,
    abs,
    float64bits,
    float64frombits,
    inf,
    is_inf,
    is_nan,
    nan,
)

# The split of ln(2) into a head with its low bits clear and a tail, so that
# `k * _LN2_HI` is exact for any `k` a float64 exponent can hold and the whole
# product carries no rounding error into the sum.
comptime _LN2_HI = 6.93147180369123816490e-01
comptime _LN2_LO = 1.90821492927058770002e-10

# The minimax polynomial for log(1+s)/s in s squared, from FDLIBM.
comptime _L1 = 6.666666666666735130e-01
comptime _L2 = 3.999999999940941908e-01
comptime _L3 = 2.857142874366239149e-01
comptime _L4 = 2.222219843214978396e-01
comptime _L5 = 1.818357216161805012e-01
comptime _L6 = 1.531383769920937332e-01
comptime _L7 = 1.479819860511658591e-01


def log(x: Float64) -> Float64:
    """The natural logarithm of `x`.

    `log(0.0)` is negative infinity and the logarithm of any negative number
    is a not a number.

    The argument is reduced to `f` in [sqrt(2)/2 - 1, sqrt(2) - 1) and a whole
    power of two, and then the series is taken in `s = f/(2+f)`, which is odd
    in `f` and so needs only half as many terms as a series in `f` would. The
    two halves of ln(2) are what keep the reconstruction exact.
    """
    if is_nan(x) or is_inf(x, 1):
        return x
    if x < 0:
        return nan()
    if x == 0:
        return inf(-1)

    var f1, ki = frexp(x)
    if f1 < SQRT2 / 2:
        f1 *= 2
        ki -= 1
    var f = f1 - 1
    var k = Float64(ki)

    var s = f / (2 + f)
    var s2 = s * s
    var s4 = s2 * s2
    var t1 = s2 * (_L1 + s4 * (_L3 + s4 * (_L5 + s4 * _L7)))
    var t2 = s4 * (_L2 + s4 * (_L4 + s4 * _L6))
    var r = t1 + t2
    var hfsq = 0.5 * f * f
    return k * _LN2_HI - ((hfsq - (s * (hfsq + r) + k * _LN2_LO)) - f)


def log10(x: Float64) -> Float64:
    """The decimal logarithm of `x`. Same special cases as `log`."""
    return log(x) * LOG10E


def log2(x: Float64) -> Float64:
    """The binary logarithm of `x`. Same special cases as `log`.

    Scaled from the natural logarithm like `log10` is, with one correction:
    `frexp` has already pulled out the power of two, so an exact power of two
    arrives here as a fraction of exactly a half, and the answer is then a
    whole number that the multiply would have missed by an ulp.
    """
    var frac, e = frexp(x)
    if frac == 0.5:
        return Float64(e - 1)
    return log(frac) * LOG2E + Float64(e)


def log1p(x: Float64) -> Float64:
    """`log(1 + x)`.

    Its own function rather than the two operations, because adding one to a
    small `x` throws away every digit of `x` past the seventeenth and then the
    logarithm of what is left is the logarithm of the rounding. Below 2**-54
    the answer is `x` itself.

    `log1p(-1.0)` is negative infinity and anything below that is a not a
    number.
    """
    # Sqrt(2)-1 and Sqrt(2)/2-1, the ends of the interval the series wants.
    comptime SQRT2_M1 = 4.142135623730950488017e-01
    comptime SQRT2_HALF_M1 = -2.928932188134524755992e-01
    comptime SMALL = 1.0 / Float64(1 << 29)
    comptime TINY = 1.0 / Float64(1 << 54)
    comptime TWO53 = Float64(1 << 53)

    if x < -1 or is_nan(x):
        return nan()
    if x == -1:
        return inf(-1)
    if is_inf(x, 1):
        return inf(1)

    var absx = abs(x)

    var f = Float64(0)
    var iu = UInt64(0)
    var k = 1
    if absx < SQRT2_M1:
        if absx < SMALL:
            if absx < TINY:
                return x
            return x - x * x * 0.5
        if x > SQRT2_HALF_M1:
            # Already inside the interval, so there is nothing to reduce and
            # no correction term to carry.
            k = 0
            f = x
            iu = 1

    var c = Float64(0)
    if k != 0:
        var u: Float64
        if absx < TWO53:
            u = 1.0 + x
            iu = float64bits(u)
            k = Int(iu >> 52) - 1023
            # What the addition of one lost, put back as a correction.
            if k > 0:
                c = 1.0 - (u - x)
            else:
                c = x - (u - 1.0)
            c /= u
        else:
            u = x
            iu = float64bits(u)
            k = Int(iu >> 52) - 1023
            c = 0
        iu &= 0x000FFFFFFFFFFFFF
        if iu < 0x0006A09E667F3BCD:  # the fraction of sqrt(2)
            u = float64frombits(iu | 0x3FF0000000000000)
        else:
            k += 1
            u = float64frombits(iu | 0x3FE0000000000000)
            iu = (0x0010000000000000 - iu) >> 2
        f = u - 1.0

    var hfsq = 0.5 * f * f
    if iu == 0:
        # |f| < 2**-20, where the series in s would divide for no gain.
        if f == 0:
            if k == 0:
                return 0
            c += Float64(k) * _LN2_LO
            return Float64(k) * _LN2_HI + c
        var r = hfsq * (1.0 - 0.66666666666666666 * f)
        if k == 0:
            return f - r
        return Float64(k) * _LN2_HI - ((r - (Float64(k) * _LN2_LO + c)) - f)

    var s = f / (2.0 + f)
    var z = s * s
    var r = z * (
        _L1
        + z * (_L2 + z * (_L3 + z * (_L4 + z * (_L5 + z * (_L6 + z * _L7)))))
    )
    if k == 0:
        return f - (hfsq - s * (hfsq + r))
    return Float64(k) * _LN2_HI - (
        (hfsq - (s * (hfsq + r) + (Float64(k) * _LN2_LO + c))) - f
    )


def logb(x: Float64) -> Float64:
    """The binary exponent of `x`, as a float.

    `logb(0.0)` is negative infinity, either infinity gives positive infinity,
    and a not a number gives itself. `ilogb` is the same question with the
    answer as an integer and different special cases.
    """
    if x == 0:
        return inf(-1)
    if is_inf(x, 0):
        return inf(1)
    if is_nan(x):
        return x
    return Float64(_ilogb(x))


def ilogb(x: Float64) -> Int:
    """The binary exponent of `x`, as an integer.

    There is no integer for an infinity to be, so the special cases are the
    ends of the int32 range rather than infinities: zero gives `MIN_INT32`, and
    an infinity or a not a number gives `MAX_INT32`.
    """
    if x == 0:
        return Int(MIN_INT32)
    if is_nan(x) or is_inf(x, 0):
        return Int(MAX_INT32)
    return _ilogb(x)


def _ilogb(x: Float64) -> Int:
    """The binary exponent of a finite nonzero `x`.

    The exponent field, less the bias, less whatever `_normalize` had to scale
    a subnormal by to make that field mean anything.
    """
    var y, e = _normalize(x)
    return Int((float64bits(y) >> _SHIFT) & _MASK) - _BIAS + e
