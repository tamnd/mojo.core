"""Floats taken apart and put back together. Go's `bits.go` and its neighbours.

The eleven functions that treat a float as a pattern of bits rather than as a
number: the four conversions between a float and its bits, the two that build
an infinity and a not a number, the three that ask what a float is, and the two
that move a sign around.

Everything else in this package is written on top of these, so they are in
their own file and they come first. Go keeps them in `bits.go`, `nan.go`,
`abs.go`, `copysign.go` and `signbit.go`; five files of three lines each is not
a shape worth reproducing.

The layout constants are Go's, under Go's names with a leading underscore
because they are not part of the API: `_MASK` is the exponent field once it is
shifted down, `_SHIFT` is how far to shift it, `_BIAS` is what to subtract from
it. A float64 is one sign bit, eleven exponent bits and fifty two fraction
bits, and those three numbers are that sentence.
"""

from std.memory import bitcast

from .const import MAX_FLOAT64


# The four bit patterns Go names. `_UVNAN` is a quiet not a number with the
# lowest fraction bit set, which is the one Go's `NaN` hands out; any pattern
# with a full exponent and a nonzero fraction is a not a number, and picking
# one makes the answer reproducible.
comptime _UVNAN = UInt64(0x7FF8000000000001)
comptime _UVINF = UInt64(0x7FF0000000000000)
comptime _UVNEGINF = UInt64(0xFFF0000000000000)
comptime _UVONE = UInt64(0x3FF0000000000000)

comptime _MASK = UInt64(0x7FF)
"""The exponent field, after it has been shifted down. Eleven bits."""

comptime _SHIFT = 52
"""How far the exponent field sits above the bottom. 64 - 11 - 1."""

comptime _BIAS = 1023
"""What the stored exponent is offset by."""

comptime _SIGN_MASK = UInt64(1) << 63
comptime _FRAC_MASK = (UInt64(1) << _SHIFT) - 1

comptime _SMALLEST_NORMAL = 2.2250738585072014e-308
"""2**-1022, the smallest float64 with a full 53 bit fraction."""


def float32bits(f: Float32) -> UInt32:
    """The IEEE 754 binary representation of `f`.

    The sign of a not a number is kept, and so is which not a number it is.
    """
    return bitcast[DType.uint32](f)


def float32frombits(b: UInt32) -> Float32:
    """The float32 with that IEEE 754 binary representation.

    The inverse of `float32bits`, including for the not a numbers.
    """
    return bitcast[DType.float32](b)


def float64bits(f: Float64) -> UInt64:
    """The IEEE 754 binary representation of `f`.

    The sign of a not a number is kept, and so is which not a number it is.
    """
    return bitcast[DType.uint64](f)


def float64frombits(b: UInt64) -> Float64:
    """The float64 with that IEEE 754 binary representation.

    The inverse of `float64bits`, including for the not a numbers.
    """
    return bitcast[DType.float64](b)


def inf(sign: Int) -> Float64:
    """Positive infinity when `sign >= 0`, negative infinity otherwise."""
    return float64frombits(_UVINF if sign >= 0 else _UVNEGINF)


def nan() -> Float64:
    """A not a number.

    Go's `NaN`. The same pattern every time, so that a test comparing bits has
    something to compare against, though nothing about IEEE 754 promises that
    an arithmetic result will be this particular one.
    """
    return float64frombits(_UVNAN)


def is_nan(f: Float64) -> Bool:
    """Whether `f` is a not a number.

    Asked as `f != f`, which is true of the not a numbers and of nothing else,
    rather than by looking at the exponent and the fraction. Go's comment on
    this is that the compiler removes the calls to it if it is written the
    obvious way, and the same reasoning holds here.
    """
    return f != f


def is_inf(f: Float64, sign: Int) -> Bool:
    """Whether `f` is an infinity of the sign asked for.

    A positive `sign` asks about positive infinity, a negative one about
    negative infinity, and zero about either.
    """
    return (sign >= 0 and f > MAX_FLOAT64) or (sign <= 0 and f < -MAX_FLOAT64)


def signbit(x: Float64) -> Bool:
    """Whether `x` is negative or negative zero.

    Not the same question as `x < 0`, which is false for negative zero and for
    the not a numbers, both of which can have the bit set.
    """
    return float64bits(x) & _SIGN_MASK != 0


def abs(x: Float64) -> Float64:
    """The absolute value of `x`.

    The sign bit cleared, so `abs(nan())` is a not a number and
    `abs(inf(-1))` is positive infinity, with no comparison anywhere.
    """
    return float64frombits(float64bits(x) & ~_SIGN_MASK)


def copysign(f: Float64, sign: Float64) -> Float64:
    """The magnitude of `f` with the sign of `sign`."""
    return float64frombits(
        (float64bits(f) & ~_SIGN_MASK) | (float64bits(sign) & _SIGN_MASK)
    )


def _normalize(x: Float64) -> Tuple[Float64, Int]:
    """`x` scaled up out of the subnormal range, with the scale used.

    Returns `y` and `exp` with `x == y * 2**exp` and `y` normal. Go's
    unexported `normalize`, which `frexp` and `ldexp` both need so that they
    can read an exponent field that means what it says.
    """
    if abs(x) < _SMALLEST_NORMAL:
        return x * Float64(1 << 52), -52
    return x, 0
