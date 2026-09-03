"""Roots, scaling and the exponent field. Go's `sqrt.go`, `cbrt.go`,
`hypot.go`, `fma.go`, `remainder.go`, `frexp.go`, `ldexp.go` and
`nextafter.go`.

Nine functions. `sqrt`, `cbrt`, `fma` and `remainder` come from `std.math`,
which agrees with Go on every value in Go's tables: they are either a machine
instruction or a correctly rounded routine with nothing left to disagree
about. `hypot` was in that list and is not, because the system routine is not
correctly rounded and the two lines Go writes instead are; the docstring has
the value that settled it.

`frexp`, `ldexp`, `nextafter` and `nextafter32` are ported. They only move bits
around, so they are exact and Go's version is the definition; and
`std.math.frexp` returns the exponent as a float64, which is not a value
anybody wants to index or shift with.
"""

from std.math import cbrt as _std_cbrt
from std.math import fma as _std_fma
from std.math import remainder as _std_remainder
from std.math import sqrt as _std_sqrt

from .ieee import (
    _BIAS,
    _MASK,
    _SHIFT,
    _normalize,
    abs,
    copysign,
    float32bits,
    float32frombits,
    float64bits,
    float64frombits,
    inf,
    is_inf,
    is_nan,
    nan,
)


def sqrt(x: Float64) -> Float64:
    """The square root of `x`.

    An instruction on every architecture this builds for, and correctly
    rounded by the standard. `sqrt(-0.0)` is negative zero and the square root
    of any other negative number is a not a number.
    """
    return _std_sqrt(x)


def cbrt(x: Float64) -> Float64:
    """The cube root of `x`.

    Defined for negative numbers, unlike `sqrt`, and `cbrt(-8.0)` is -2.
    """
    return _std_cbrt(x)


def hypot(p: Float64, q: Float64) -> Float64:
    """`sqrt(p*p + q*q)`, without the overflow that squaring would cause.

    An infinity in either argument gives positive infinity even when the other
    is a not a number, which is the one place this disagrees with computing it
    the written way.

    Ported rather than taken from `std.math`, which is the system routine and
    is not correctly rounded. On macOS it returns 29.348203997243527 for
    `hypot(-16.688001947990161, -24.14182405800559)` where the answer is
    29.348203997243523, and the platform is free to answer either. Go's own
    two lines are reproducible, which is what everything that divides by this
    number needs: `core.math.cmplx.sqrt` at that point is a difference of two
    nearly equal numbers, and one bit here becomes fifty there.
    """
    var a = abs(p)
    var b = abs(q)
    if is_inf(a, 1) or is_inf(b, 1):
        return inf(1)
    if is_nan(a) or is_nan(b):
        return nan()
    if a < b:
        a, b = b, a
    if a == 0:
        return 0
    b = b / a
    return a * _std_sqrt(1 + b * b)


def fma(x: Float64, y: Float64, z: Float64) -> Float64:
    """`x*y + z`, rounded once.

    The product is kept at full width and only the sum is rounded, so this is
    not the same number as `x*y + z` written out, and that is the point of it.
    """
    return _std_fma(x, y, z)


def remainder(x: Float64, y: Float64) -> Float64:
    """The IEEE 754 remainder of `x / y`.

    The quotient is rounded to the nearest rather than toward zero, so the
    answer is at most half of `y` in magnitude and its sign need not be `x`'s.
    That is the difference from `mod`, which is the other convention.
    """
    return _std_remainder(x, y)


def frexp(f: Float64) -> Tuple[Float64, Int]:
    """`f` as a fraction in [1/2, 1) and a power of two that multiply back to
    it.

    A zero gives itself and a zero exponent, keeping its sign; so do the
    infinities and the not a numbers, which have no fraction to name.
    """
    if f == 0:
        return f, 0
    if is_inf(f, 0) or is_nan(f):
        return f, 0
    var y, e = _normalize(f)
    var x = float64bits(y)
    var exp = e + Int((x >> _SHIFT) & _MASK) - _BIAS + 1
    x &= ~(_MASK << _SHIFT)
    x |= UInt64(_BIAS - 1) << _SHIFT
    return float64frombits(x), exp


def ldexp(frac: Float64, exp: Int) -> Float64:
    """`frac * 2**exp`. The inverse of `frexp`.

    A zero, an infinity or a not a number comes back unchanged whatever `exp`
    is. Otherwise the exponent is added to the exponent field, which overflows
    to an infinity and underflows to a zero of the right sign. The subnormal
    range is reached by biasing the exponent up by 53 and scaling the answer
    back down, since the field cannot hold what a subnormal needs.
    """
    if frac == 0:
        return frac
    if is_inf(frac, 0) or is_nan(frac):
        return frac
    var f, e = _normalize(frac)
    var n = exp + e
    var x = float64bits(f)
    n += Int((x >> _SHIFT) & _MASK) - _BIAS
    if n < -1075:
        return copysign(0, f)
    if n > 1023:
        return inf(-1) if f < 0 else inf(1)
    var m = Float64(1)
    if n < -1022:
        n += 53
        m = 1.0 / Float64(UInt64(1) << 53)
    x &= ~(_MASK << _SHIFT)
    x |= UInt64(n + _BIAS) << _SHIFT
    return m * float64frombits(x)


def nextafter(x: Float64, y: Float64) -> Float64:
    """The float64 next to `x` in the direction of `y`.

    `nextafter(x, x)` is `x`, and a not a number in either argument gives one.
    Adding one to the bit pattern is what steps to the next float, which works
    across the boundary between the subnormals and the normals and across the
    one into the infinities, because IEEE 754 laid the patterns out in order
    on purpose.
    """
    if is_nan(x) or is_nan(y):
        return nan()
    if x == y:
        return x
    if x == 0:
        return copysign(float64frombits(1), y)
    if (y > x) == (x > 0):
        return float64frombits(float64bits(x) + 1)
    return float64frombits(float64bits(x) - 1)


def nextafter32(x: Float32, y: Float32) -> Float32:
    """The float32 next to `x` in the direction of `y`.

    `nextafter` at the narrower width, and the same reasoning.
    """
    if x != x or y != y:
        return Float32(nan())
    if x == y:
        return x
    if x == 0:
        return Float32(copysign(Float64(float32frombits(1)), Float64(y)))
    if (y > x) == (x > 0):
        return float32frombits(float32bits(x) + 1)
    return float32frombits(float32bits(x) - 1)
