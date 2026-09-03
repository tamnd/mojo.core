"""Rounding, and the arithmetic that goes with it. Go's `floor.go`, `modf.go`,
`mod.go` and `dim.go`.

Ten functions. Three of them cut a float to an integer in a fixed direction,
two round it to the nearest with different tie rules, one splits it into the
two halves, and four are the arithmetic Go puts here for want of a better home.

`floor`, `ceil` and `trunc` are the machine's own instructions, reached through
`std.math`. Go writes all three by hand out of `modf` and sign flips, because
the Go compiler turns them into instructions on some architectures and the
written version is what the others fall back to. That is the same trade
`core.math.bits` makes and it is made the same way here.

`round` and `round_to_even` are ported, because neither is an instruction and
the two tie rules are the whole difference between them. Go's versions work on
the bit pattern rather than by comparing against a half, and so do these: the
comment in Go's source gives the obvious implementation of each and then does
not use it.
"""

from std.math import ceil as _std_ceil
from std.math import floor as _std_floor
from std.math import trunc as _std_trunc

from .ieee import (
    _BIAS,
    _FRAC_MASK,
    _MASK,
    _SHIFT,
    _SIGN_MASK,
    _UVONE,
    abs,
    copysign,
    float64bits,
    float64frombits,
    inf,
    is_inf,
    is_nan,
    nan,
    signbit,
)
from .arith import frexp, ldexp


def floor(x: Float64) -> Float64:
    """The greatest integer value less than or equal to `x`.

    `floor(-0.0)` is negative zero, the infinities come back unchanged, and so
    does a not a number.
    """
    return _std_floor(x)


def ceil(x: Float64) -> Float64:
    """The least integer value greater than or equal to `x`.

    Same special cases as `floor`.
    """
    return _std_ceil(x)


def trunc(x: Float64) -> Float64:
    """`x` with its fractional part removed, rounding toward zero.

    Same special cases as `floor`.
    """
    return _std_trunc(x)


def round(x: Float64) -> Float64:
    """The nearest integer to `x`, rounding a half away from zero.

    So `round(2.5)` is 3 and `round(-2.5)` is -3, which is the schoolbook rule
    and not the one the hardware uses. `round_to_even` is the hardware's.

    Done on the bits. Below one the answer is a zero or a one with `x`'s sign,
    which is what the first branch builds. From one up to 2**52 there is a
    fractional part to deal with, and adding a half at the right place and then
    clearing what is below it rounds and truncates in one go. Above 2**52 every
    float is already an integer, and so are the infinities and the not a
    numbers, so those fall out of both branches unchanged.
    """
    var bits = float64bits(x)
    var e = Int((bits >> _SHIFT) & _MASK)
    if e < _BIAS:
        bits &= _SIGN_MASK
        if e == _BIAS - 1:
            bits |= _UVONE
    elif e < _BIAS + _SHIFT:
        var d = UInt64(e - _BIAS)
        bits += (UInt64(1) << (_SHIFT - 1)) >> d
        bits &= ~(_FRAC_MASK >> d)
    return float64frombits(bits)


def round_to_even(x: Float64) -> Float64:
    """The nearest integer to `x`, rounding a half to the even neighbour.

    So `round_to_even(2.5)` is 2 and `round_to_even(3.5)` is 4. This is IEEE
    754's default rule and the one every arithmetic operation in this library
    already uses.

    Done on the bits like `round` is, and the trick is the same one with a
    smaller constant: add a half minus one unit in the last place when the
    truncated number would be even, and a full half when it would be odd. The
    bit that says which is the lowest bit of the integer part, which is where
    `bits >> (_SHIFT - d)` lands.
    """
    var bits = float64bits(x)
    var e = Int((bits >> _SHIFT) & _MASK)
    if e >= _BIAS + _SHIFT:
        # Already an integer, or an infinity, or a not a number. Go reaches
        # this case through a shift wider than the word, which is a value the
        # Go specification defines and LLVM does not, so it is a branch here.
        return x
    if e >= _BIAS:
        var d = UInt64(e - _BIAS)
        var half_minus_ulp = (UInt64(1) << (_SHIFT - 1)) - 1
        bits += (half_minus_ulp + ((bits >> (_SHIFT - d)) & 1)) >> d
        bits &= ~(_FRAC_MASK >> d)
    elif e == _BIAS - 1 and bits & _FRAC_MASK != 0:
        bits = (bits & _SIGN_MASK) | _UVONE
    else:
        bits &= _SIGN_MASK
    return float64frombits(bits)


def modf(f: Float64) -> Tuple[Float64, Float64]:
    """The integer and fractional parts of `f`, which sum back to it.

    Both have the sign of `f`. An infinity gives itself and a not a number,
    since there is no fraction to name; a not a number gives two of them.
    """
    var integer = trunc(f)
    return integer, copysign(f - integer, f)


def dim(x: Float64, y: Float64) -> Float64:
    """The larger of `x - y` and zero.

    Every special case falls out of the subtraction: two like infinities
    subtract to a not a number, and a not a number anywhere stays one. The
    comparison is written so that a not a number, which answers false to
    everything, takes the second branch.
    """
    var v = x - y
    if v <= 0:
        return 0
    return v


def max(x: Float64, y: Float64) -> Float64:
    """The larger of `x` or `y`.

    Not the same as the language's `max`. Positive infinity wins over a not a
    number here, a not a number beats everything else, and `max(+0.0, -0.0)`
    is positive zero rather than whichever argument came first.
    """
    if is_inf(x, 1) or is_inf(y, 1):
        return inf(1)
    if is_nan(x) or is_nan(y):
        return nan()
    if x == 0 and x == y:
        return y if signbit(x) else x
    return x if x > y else y


def min(x: Float64, y: Float64) -> Float64:
    """The smaller of `x` or `y`.

    The mirror of `max`: negative infinity wins over a not a number, a not a
    number beats everything else, and `min(+0.0, -0.0)` is negative zero.
    """
    if is_inf(x, -1) or is_inf(y, -1):
        return inf(-1)
    if is_nan(x) or is_nan(y):
        return nan()
    if x == 0 and x == y:
        return x if signbit(x) else y
    return x if x < y else y


def mod(x: Float64, y: Float64) -> Float64:
    """The floating point remainder of `x / y`.

    The result is smaller than `y` in magnitude and carries `x`'s sign, so
    `mod(-5.0, 3.0)` is -2 and not 1. `remainder` is the other convention, the
    one that rounds the quotient to the nearest rather than toward zero.

    Subtracting scaled copies of `y` until nothing is left is exact at every
    step, because each subtraction is between two numbers of the same
    magnitude, so the answer has no rounding error in it at all.
    """
    if y == 0 or is_inf(x, 0) or is_nan(x) or is_nan(y):
        return nan()
    var d = abs(y)

    var yfr, yexp = frexp(d)
    var r = -x if x < 0 else x

    while r >= d:
        var rfr, rexp = frexp(r)
        if rfr < yfr:
            rexp -= 1
        r -= ldexp(d, rexp - yexp)

    return -r if x < 0 else r
