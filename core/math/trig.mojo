"""The circular and hyperbolic functions. Go's `sin.go`, `cos` in the same
file, `tan.go`, `sincos.go`, `asin.go`, `atan.go`, `atan2.go`, `sinh.go`,
`tanh.go` and `asinh.go`, `acosh.go`, `atanh.go`.

Fifteen functions. The circular ones and the inverses are the system
library's: Go carries its own Payne-Hanek argument reduction and its own
minimax polynomials for these because it does not link libm; the reduction is
the hard part, it is the reason `sin(1e15)` has any correct digits at all, and
it is already in the library Mojo links.

The three hyperbolic ones are ported. `std.math.sinh` is a not a number at
negative infinity where it should be negative infinity, `std.math.tanh` is one
at a not a number where it should be a not a number, and `std.math.cosh` is
`std.math.exp` and carries its error. None of the three is a big function, and
the versions here are Cephes by way of Go, on top of this package's `exp`.

`sincos` is written here as a pair rather than ported. Go fuses the two so
that the argument reduction and the octant decision happen once instead of
twice, which is a speed argument and not a correctness one, and the fused
version returns the same two numbers the separate calls do.
"""

from std.math import acos as _std_acos
from std.math import acosh as _std_acosh
from std.math import asin as _std_asin
from std.math import asinh as _std_asinh
from std.math import atan as _std_atan
from std.math import atan2 as _std_atan2
from std.math import atanh as _std_atanh
from std.math import cos as _std_cos
from std.math import sin as _std_sin
from std.math import tan as _std_tan

from .exp import exp
from .ieee import abs


# Hart & Cheney's #2029 (20.36D), which Go uses for the hyperbolic sine below
# a half, where `(exp(x) - exp(-x)) / 2` is two nearly equal numbers being
# subtracted and most of the digits go with them.
comptime _SINH_P0 = -0.6307673640497716991184787251e6
comptime _SINH_P1 = -0.8991272022039509355398013511e5
comptime _SINH_P2 = -0.2894211355989563807284660366e4
comptime _SINH_P3 = -0.2630563213397497062819489e2
comptime _SINH_Q0 = -0.6307673640497716991212077277e6
comptime _SINH_Q1 = 0.1521517378790019070696485176e5
comptime _SINH_Q2 = -0.173678953558233699533450911e3

# Cephes, for the hyperbolic tangent below 0.625, in Cody and Waite's
# `x + x**3 * P(x)/Q(x)` form.
comptime _TANH_P0 = -9.64399179425052238628e-1
comptime _TANH_P1 = -9.92877231001918586564e1
comptime _TANH_P2 = -1.61468768441708447952e3
comptime _TANH_Q0 = 1.12811678491632931402e2
comptime _TANH_Q1 = 2.23548839060100448583e3
comptime _TANH_Q2 = 4.84406305325125486048e3

comptime _MAXLOG = 8.8029691931113054295988e01
"""`log(2**127)`, past half of which the hyperbolic tangent is one."""


def sin(x: Float64) -> Float64:
    """The sine of `x`, in radians.

    `sin(-0.0)` is negative zero, and either infinity is a not a number since
    there is no angle to speak of.
    """
    return _std_sin(x)


def cos(x: Float64) -> Float64:
    """The cosine of `x`, in radians.

    Either infinity is a not a number, for the reason `sin` gives.
    """
    return _std_cos(x)


def tan(x: Float64) -> Float64:
    """The tangent of `x`, in radians. Same special cases as `sin`."""
    return _std_tan(x)


def sincos(x: Float64) -> Tuple[Float64, Float64]:
    """The sine and the cosine of `x` together.

    Go computes both at once off one argument reduction. Here it is the two
    calls, which give the same two numbers, because the reduction is inside
    the system library and there is no way to ask it for both halves.
    """
    return _std_sin(x), _std_cos(x)


def asin(x: Float64) -> Float64:
    """The arcsine of `x`, in radians.

    `asin` of anything outside [-1, 1] is a not a number, and `asin(-0.0)` is
    negative zero.
    """
    return _std_asin(x)


def acos(x: Float64) -> Float64:
    """The arccosine of `x`, in radians.

    A not a number outside [-1, 1], like `asin`.
    """
    return _std_acos(x)


def atan(x: Float64) -> Float64:
    """The arctangent of `x`, in radians, in [-pi/2, pi/2].

    `atan(-0.0)` is negative zero and the infinities give plus and minus a
    quarter turn.
    """
    return _std_atan(x)


def atan2(y: Float64, x: Float64) -> Float64:
    """The arctangent of `y/x`, in radians, using the signs of both to pick a
    quadrant, so the answer covers the whole circle rather than half of it.

    The special cases are the long list IEEE 754 gives, including the four
    combinations of infinities, which land on the four diagonals.
    """
    return _std_atan2(y, x)


def sinh(x: Float64) -> Float64:
    """The hyperbolic sine of `x`. `sinh(-0.0)` is negative zero.

    Ported rather than wrapped, because `std.math.sinh` is a not a number at
    negative infinity. Three ranges: past 21 the second term has fallen below
    the last bit of the first, above a half it is the definition, and below
    that it is a rational approximation, because the definition there is a
    subtraction of two numbers that agree to almost every digit.
    """
    var v = x
    var sign = False
    if v < 0:
        v = -v
        sign = True

    var temp: Float64
    if v > 21:
        temp = exp(v) * 0.5
    elif v > 0.5:
        var ex = exp(v)
        temp = (ex - 1 / ex) * 0.5
    else:
        var sq = v * v
        temp = (
            ((_SINH_P3 * sq + _SINH_P2) * sq + _SINH_P1) * sq + _SINH_P0
        ) * v
        temp = temp / (((sq + _SINH_Q2) * sq + _SINH_Q1) * sq + _SINH_Q0)

    return -temp if sign else temp


def cosh(x: Float64) -> Float64:
    """The hyperbolic cosine of `x`. `cosh(-0.0)` is one, not zero.

    Built on `exp` rather than taken from `std.math`, because `std.math.cosh`
    is `std.math.exp` and inherits its accuracy. Past 21 the second term is
    below the last bit of the first and is left out, which also keeps the
    reciprocal from underflowing.
    """
    var a = abs(x)
    if a > 21:
        return exp(a) * 0.5
    var ex = exp(a)
    return (ex + 1 / ex) * 0.5


def tanh(x: Float64) -> Float64:
    """The hyperbolic tangent of `x`.

    The infinities give plus and minus one rather than a not a number, which
    is the difference from `tan`. A not a number gives a not a number, which
    is where `std.math.tanh` returns one instead and is the reason this is
    ported.
    """
    var z = abs(x)
    if z > 0.5 * _MAXLOG:
        # Far enough out that the answer is one to every bit there is.
        return -1.0 if x < 0 else 1.0
    if z >= 0.625:
        var s = exp(2 * z)
        var t = 1 - 2 / (s + 1)
        return -t if x < 0 else t
    if x == 0:
        return x
    var s = x * x
    return x + x * s * ((_TANH_P0 * s + _TANH_P1) * s + _TANH_P2) / (
        ((s + _TANH_Q0) * s + _TANH_Q1) * s + _TANH_Q2
    )


def asinh(x: Float64) -> Float64:
    """The inverse hyperbolic sine of `x`. Defined everywhere."""
    return _std_asinh(x)


def acosh(x: Float64) -> Float64:
    """The inverse hyperbolic cosine of `x`.

    A not a number below one, since the hyperbolic cosine never goes there.
    """
    return _std_acosh(x)


def atanh(x: Float64) -> Float64:
    """The inverse hyperbolic tangent of `x`.

    Plus or minus infinity at plus or minus one, and a not a number outside
    them.
    """
    return _std_atanh(x)
