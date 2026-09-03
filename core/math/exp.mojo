"""Exponentials. Go's `exp.go`, `expm1.go`, `pow.go` and `pow10.go`.

Five functions, and only `expm1` wraps `std.math`.

`exp` and `exp2` are ported for the reason `log` is: Go holds `Exp` to four
parts in 10**16 and `std.math.exp` is out by thirty thousand units in the last
place on an ordinary argument. Both are FDLIBM's, by way of Go, and both end in
the same three lines, so the shared tail is `_expmulti` here as it is in Go.

`pow` is ported because there is a page of special cases before any arithmetic
happens and Go's answers to them are the contract, and because the arithmetic
itself is Go's own: the fractional part of the exponent through `exp` and
`log`, and the integer part by squaring, with the powers of two pulled out into
a separate accumulator so that an intermediate cannot overflow when the answer
would not.

`pow10` is ported because it is a table lookup, and Go's tables are what it
returns.
"""

from std.math import expm1 as _std_expm1
from std.math import trunc as _trunc

from .arith import frexp, ldexp, sqrt
from .ieee import (
    abs,
    float64frombits,
    inf,
    is_inf,
    is_nan,
    nan,
    signbit,
)
from .log import log

# ln(2) split into a head and a tail, as in `log`, and the reciprocal of ln(2)
# to the precision the reduction needs rather than to the last bit.
comptime _LN2_HI = 6.93147180369123816490e-01
comptime _LN2_LO = 1.90821492927058770002e-10
comptime _LOG2E = 1.44269504088896338700e00

# Where `exp` stops trying. Above the first the answer is an infinity and
# below the second it is a zero, in both cases before any polynomial would
# have had anything to say.
comptime _EXP_OVERFLOW = 7.09782712893383973096e02
comptime _EXP_UNDERFLOW = -7.45133219101941108420e02
comptime _EXP_NEAR_ZERO = 1.0 / Float64(1 << 28)

# The same two limits for `exp2`, in powers of two rather than of e.
comptime _EXP2_OVERFLOW = 1.0239999999999999e03
comptime _EXP2_UNDERFLOW = -1.0740e03

# The Remez polynomial for r*(exp(r)+1)/(exp(r)-1) on [0, 0.34658], in r
# squared. Degree five, and good to within 2**-59 across the interval.
comptime _P1 = 1.66666666666666657415e-01
comptime _P2 = -2.77777777770155933842e-03
comptime _P3 = 6.61375632143793436117e-05
comptime _P4 = -1.65339022054652515390e-06
comptime _P5 = 4.13813679705723846039e-08


def exp(x: Float64) -> Float64:
    """`e**x`.

    A large enough argument gives positive infinity and a small enough one
    gives zero, rather than raising anything.

    Reduced to `x = k*ln(2) + r` with `|r|` at most half of ln(2), where the
    polynomial converges quickly, and then scaled back by `2**k`. The reduction
    is carried as a head and a tail so that the subtraction that produces `r`
    keeps its low bits.
    """
    if is_nan(x):
        return x
    if x > _EXP_OVERFLOW:
        return inf(1)
    if x < _EXP_UNDERFLOW:
        return 0
    if -_EXP_NEAR_ZERO < x and x < _EXP_NEAR_ZERO:
        return 1 + x

    var k = 0
    if x < 0:
        k = Int(_LOG2E * x - 0.5)
    elif x > 0:
        k = Int(_LOG2E * x + 0.5)
    var hi = x - Float64(k) * _LN2_HI
    var lo = Float64(k) * _LN2_LO
    return _expmulti(hi, lo, k)


def exp2(x: Float64) -> Float64:
    """`2**x`. Same special cases as `exp`.

    The same reduction with the roles swapped: `k` is the nearest whole number
    to `x` outright, and what is left over is turned into a natural exponent by
    multiplying by ln(2), again as a head and a tail.
    """
    if is_nan(x):
        return x
    if x > _EXP2_OVERFLOW:
        return inf(1)
    if x < _EXP2_UNDERFLOW:
        return 0

    var k = 0
    if x > 0:
        k = Int(x + 0.5)
    elif x < 0:
        k = Int(x - 0.5)
    var t = x - Float64(k)
    return _expmulti(t * _LN2_HI, -t * _LN2_LO, k)


def _expmulti(hi: Float64, lo: Float64, k: Int) -> Float64:
    """`e**(hi - lo) * 2**k`, for `|hi - lo|` at most half of ln(2).

    The tail of both `exp` and `exp2`. The polynomial approximates
    `r - (exp(r) - 1 - r) / (something)` in a form that keeps the leading 1 out
    of the rounding, which is why the answer is assembled as `1 - (...)` rather
    than as a sum of terms.
    """
    var r = hi - lo
    var t = r * r
    var c = r - t * (_P1 + t * (_P2 + t * (_P3 + t * (_P4 + t * _P5))))
    var y = 1 - ((lo - (r * c) / (2 - c)) - hi)
    return ldexp(y, k)


def expm1(x: Float64) -> Float64:
    """`e**x - 1`.

    Its own function rather than the two operations, because `exp(x)` for a
    small `x` is one plus a rounding and subtracting the one leaves the
    rounding. This is `std.math`'s, which agrees with Go's everywhere Go
    checks.
    """
    return _std_expm1(x)


def pow(x: Float64, y: Float64) -> Float64:
    """`x**y`.

    The special cases are IEEE 754's, and there are a lot of them. The two
    worth remembering are that anything to the power of zero is one, including
    a not a number, and one to any power is one, including to the power of a
    not a number. A negative base with a fractional exponent is a not a
    number, since there is no real answer to give.

    The exponent is split into a whole part and a fraction. The fraction goes
    through `exp` and `log`, which is one rounding each. The whole part is done
    by squaring `x` and multiplying in the squares the bits of the exponent
    call for, with the power of two kept in a separate integer so that an
    intermediate cannot overflow while the answer is still in range.
    """
    if y == 0 or x == 1:
        return 1
    if y == 1:
        return x
    if is_nan(x) or is_nan(y):
        return nan()
    if x == 0:
        if y < 0:
            if signbit(x) and _is_odd_int(y):
                return inf(-1)
            return inf(1)
        if signbit(x) and _is_odd_int(y):
            return x
        return 0
    if is_inf(y, 0):
        if x == -1:
            return 1
        if (abs(x) < 1) == is_inf(y, 1):
            return 0
        return inf(1)
    if is_inf(x, 0):
        if is_inf(x, -1):
            return pow(1 / x, -y)
        if y < 0:
            return 0
        return inf(1)
    if y == 0.5:
        return sqrt(x)
    if y == -0.5:
        return 1 / sqrt(x)

    var whole = _trunc(abs(y))
    var frac = abs(y) - whole
    if frac != 0 and x < 0:
        return nan()
    if whole >= Float64(1 << 63):
        # A whole exponent this large is even, so the sign of the base does
        # not survive, and the answer is a zero or an infinity for every base
        # except -1 and 1. The 1 was handled at the top.
        if x == -1:
            return 1
        if (abs(x) < 1) == (y > 0):
            return 0
        return inf(1)

    # The answer, kept as `a1 * 2**ae`.
    var a1 = 1.0
    var ae = 0

    if frac != 0:
        if frac > 0.5:
            frac -= 1
            whole += 1
        a1 = exp(frac * log(x))

    var x1, xe = frexp(x)
    var i = Int(whole)
    while i != 0:
        if xe < -(1 << 12) or (1 << 12) < xe:
            # `xe` is about to overflow the doubling below. There is at least
            # one bit left in `i`, so `ae` would pick up `xe` at least once
            # more, and a lower bound on it already puts the final scaling
            # outside what a float64 exponent holds.
            ae += xe
            break
        if i & 1 == 1:
            a1 *= x1
            ae += xe
        x1 *= x1
        xe <<= 1
        if x1 < 0.5:
            x1 += x1
            xe -= 1
        i >>= 1

    # A negative exponent inverts the answer, done on the two halves
    # separately so that neither of them has to survive the round trip.
    if y < 0:
        a1 = 1 / a1
        ae = -ae
    return ldexp(a1, ae)


def _is_odd_int(x: Float64) -> Bool:
    """Whether `x` is a whole number and an odd one.

    Anything from 2**53 up is answered no without looking. Every float that
    large is even, and converting one to an integer to ask about its low bit
    is undefined once it no longer fits.
    """
    if abs(x) >= Float64(1 << 53):
        return False
    var whole = _trunc(x)
    return x - whole == 0 and Int(whole) & 1 == 1


def pow10(n: Int) -> Float64:
    """`10**n`.

    Zero below -323 and positive infinity above 308, which are the last powers
    of ten a float64 has any digits of. In between it is a product or a
    quotient of two table entries, so that no power is more than one rounding
    away from exact.
    """
    var small = materialize[_POW10TAB]()
    if 0 <= n and n <= 308:
        return materialize[_POW10POSTAB32]()[n // 32] * small[n % 32]
    if -323 <= n and n <= 0:
        return materialize[_POW10NEGTAB32]()[-n // 32] / small[-n % 32]
    if n > 0:
        return inf(1)
    return 0


# The three tables `pow10` reads. Go's, unchanged, except that `1e-320` is
# written as its bits: it is subnormal, and a subnormal written as a float
# literal is zero by the time it is a `Float64`. That is the same language
# deviation `SMALLEST_NONZERO_FLOAT64` runs into.
comptime _POW10TAB: InlineArray[Float64, 32] = [
    1e00,
    1e01,
    1e02,
    1e03,
    1e04,
    1e05,
    1e06,
    1e07,
    1e08,
    1e09,
    1e10,
    1e11,
    1e12,
    1e13,
    1e14,
    1e15,
    1e16,
    1e17,
    1e18,
    1e19,
    1e20,
    1e21,
    1e22,
    1e23,
    1e24,
    1e25,
    1e26,
    1e27,
    1e28,
    1e29,
    1e30,
    1e31,
]

comptime _POW10POSTAB32: InlineArray[Float64, 10] = [
    1e00,
    1e32,
    1e64,
    1e96,
    1e128,
    1e160,
    1e192,
    1e224,
    1e256,
    1e288,
]

comptime _POW10NEGTAB32: InlineArray[Float64, 11] = [
    1e-00,
    1e-32,
    1e-64,
    1e-96,
    1e-128,
    1e-160,
    1e-192,
    1e-224,
    1e-256,
    1e-288,
    float64frombits(0x7E8),  # 1e-320, subnormal
]
