"""Wide arithmetic. Go's `Add`, `Sub`, `Mul`, `Div` and `Rem`.

The five operations a multiple precision integer is built out of: a sum that
tells you whether it carried, a difference that tells you whether it borrowed,
a product that keeps both halves, and a division of a double width dividend by
a single width divisor. `core.math.big` is the caller they exist for.

Go writes all of them in terms of the width below, because Go has no 128 bit
integer: `Add64` reconstructs its carry from the sign bits of the operands and
the sum, and `Div64` is Knuth's algorithm D on 32 bit halves. Mojo has
`UInt128`, so every 64 bit function here is the obvious arithmetic done one
width up and split, which is the same answer with the reasoning left visible.
The 32 bit ones go up to `UInt64` for the same reason.

Go panics on a zero divisor and on a quotient that does not fit. Both raise
here, `ErrDivideByZero` and `ErrOverflow`, which makes `div` and `rem` the only
functions in the package that can fail.
"""

from core.errors import Report
from core.errors.codes import ErrDivideByZero, ErrOverflow


def _lo64(x: UInt128) -> UInt64:
    """The bottom 64 bits of `x`."""
    return UInt64(x.cast[DType.uint64]())


def _hi64(x: UInt128) -> UInt64:
    """The top 64 bits of `x`."""
    return UInt64((x >> UInt128(64)).cast[DType.uint64]())


def _wide(hi: UInt64, lo: UInt64) -> UInt128:
    """The 128 bit number whose halves are `hi` and `lo`."""
    return (UInt128(hi) << UInt128(64)) | UInt128(lo)


def _divide_by_zero() -> Error:
    """Go's `divideError`, which is the runtime's own panic value."""
    return (
        Report("bits: integer divide by zero")
        .with_code(ErrDivideByZero)
        .error()
    )


def _overflow() -> Error:
    """Go's `overflowError`, raised when a quotient needs more bits than it has.
    """
    return Report("bits: integer overflow").with_code(ErrOverflow).error()


def add(x: UInt, y: UInt, carry: UInt) -> Tuple[UInt, UInt]:
    """`x + y + carry`, as the sum and the carry out of the top.

    `carry` has to be 0 or 1. Go says the behaviour is undefined otherwise and
    this inherits that, because the caller is a limb loop that has just been
    handed the carry out of the limb below.
    """
    var sum, carry_out = add64(UInt64(x), UInt64(y), UInt64(carry))
    return (UInt(sum), UInt(carry_out))


def add32(x: UInt32, y: UInt32, carry: UInt32) -> Tuple[UInt32, UInt32]:
    """`x + y + carry`, as the sum and the carry out of the top."""
    var wide = UInt64(x) + UInt64(y) + UInt64(carry)
    return (UInt32(wide & 0xFFFFFFFF), UInt32(wide >> 32))


def add64(x: UInt64, y: UInt64, carry: UInt64) -> Tuple[UInt64, UInt64]:
    """`x + y + carry`, as the sum and the carry out of the top.

    ```mojo
    from core.math.bits import add64

    var sum, carry = add64(UInt64.MAX, UInt64(1), UInt64(0))
    print(sum, carry)  # 0 1
    ```

    Go recovers the carry from the sign bits of the two operands and the sum,
    which is the only way to see it without a wider type. The sum is done in
    128 bits here and the carry is the top half, which cannot be off by one in
    the way a hand written version can.
    """
    var wide = UInt128(x) + UInt128(y) + UInt128(carry)
    return (_lo64(wide), _hi64(wide))


def sub(x: UInt, y: UInt, borrow: UInt) -> Tuple[UInt, UInt]:
    """`x - y - borrow`, as the difference and the borrow out of the top.

    `borrow` has to be 0 or 1, on the same terms as `add`'s carry.
    """
    var diff, borrow_out = sub64(UInt64(x), UInt64(y), UInt64(borrow))
    return (UInt(diff), UInt(borrow_out))


def sub32(x: UInt32, y: UInt32, borrow: UInt32) -> Tuple[UInt32, UInt32]:
    """`x - y - borrow`, as the difference and the borrow out of the top."""
    var wide = UInt64(x) - UInt64(y) - UInt64(borrow)
    return (UInt32(wide & 0xFFFFFFFF), UInt32((wide >> 32) & 1))


def sub64(x: UInt64, y: UInt64, borrow: UInt64) -> Tuple[UInt64, UInt64]:
    """`x - y - borrow`, as the difference and the borrow out of the top.

    ```mojo
    from core.math.bits import sub64

    var diff, borrow = sub64(UInt64(0), UInt64(1), UInt64(0))
    print(diff, borrow)  # 18446744073709551615 1
    ```

    The subtraction is done in 128 bits and wraps when it goes below zero, so
    the top half comes back as all ones rather than as one. The borrow is its
    lowest bit, which is 1 exactly when the difference underflowed.
    """
    var wide = UInt128(x) - UInt128(y) - UInt128(borrow)
    return (_lo64(wide), _hi64(wide) & 1)


def mul(x: UInt, y: UInt) -> Tuple[UInt, UInt]:
    """The whole product of `x` and `y`, as its top half and its bottom half.

    The halves are in Go's order, high first, which is the order they are
    written in and the opposite of the order they are added in.
    """
    var hi, lo = mul64(UInt64(x), UInt64(y))
    return (UInt(hi), UInt(lo))


def mul32(x: UInt32, y: UInt32) -> Tuple[UInt32, UInt32]:
    """The whole 64 bit product of `x` and `y`, high half first."""
    var wide = UInt64(x) * UInt64(y)
    return (UInt32(wide >> 32), UInt32(wide & 0xFFFFFFFF))


def mul64(x: UInt64, y: UInt64) -> Tuple[UInt64, UInt64]:
    """The whole 128 bit product of `x` and `y`, high half first.

    ```mojo
    from core.math.bits import mul64

    var hi, lo = mul64(UInt64(1) << 63, UInt64(2))
    print(hi, lo)  # 1 0
    ```

    Go splits both operands into 32 bit halves and assembles the product from
    four narrower multiplies. This is the multiply itself, one width up.
    """
    var wide = UInt128(x) * UInt128(y)
    return (_hi64(wide), _lo64(wide))


def div(hi: UInt, lo: UInt, y: UInt) raises -> Tuple[UInt, UInt]:
    """`(hi, lo) / y` and `(hi, lo) % y`, for a dividend twice as wide as `y`.

    Raises `ErrDivideByZero` when `y` is zero and `ErrOverflow` when `y <= hi`,
    which is the case where the quotient needs more than 64 bits and so has
    nowhere to go. Both are panics in Go. `rem` answers the second case
    without raising, because a remainder always fits.
    """
    var quo, rem_ = div64(UInt64(hi), UInt64(lo), UInt64(y))
    return (UInt(quo), UInt(rem_))


def div32(hi: UInt32, lo: UInt32, y: UInt32) raises -> Tuple[UInt32, UInt32]:
    """`(hi, lo) / y` and `(hi, lo) % y`, with the dividend 64 bits wide."""
    if y == 0:
        raise _divide_by_zero()
    if y <= hi:
        raise _overflow()
    var wide = (UInt64(hi) << 32) | UInt64(lo)
    return (UInt32(wide // UInt64(y)), UInt32(wide % UInt64(y)))


def div64(hi: UInt64, lo: UInt64, y: UInt64) raises -> Tuple[UInt64, UInt64]:
    """`(hi, lo) / y` and `(hi, lo) % y`, with the dividend 128 bits wide.

    ```mojo
    from core.math.bits import div64

    var quo, rem = div64(UInt64(1), UInt64(0), UInt64(3))
    print(quo, rem)  # 6148914691236517205 1
    ```

    Go runs Knuth's algorithm D over 32 bit halves here, seventy lines of
    normalisation, two trial quotients and their corrections. `UInt128` divides
    in one operator and the guard above it is what keeps the result in range,
    so the correction loops have nothing to correct.
    """
    if y == 0:
        raise _divide_by_zero()
    if y <= hi:
        raise _overflow()
    var wide = _wide(hi, lo)
    var divisor = UInt128(y)
    return (_lo64(wide // divisor), _lo64(wide % divisor))


def rem(hi: UInt, lo: UInt, y: UInt) raises -> UInt:
    """`(hi, lo) % y`, for a dividend twice as wide as `y`.

    Raises `ErrDivideByZero` when `y` is zero and never raises `ErrOverflow`,
    which is the whole difference between this and `div`: the quotient can be
    too wide to return but the remainder is always smaller than `y`.
    """
    return UInt(rem64(UInt64(hi), UInt64(lo), UInt64(y)))


def rem32(hi: UInt32, lo: UInt32, y: UInt32) raises -> UInt32:
    """`(hi, lo) % y`, with the dividend 64 bits wide."""
    if y == 0:
        raise _divide_by_zero()
    return UInt32(((UInt64(hi) << 32) | UInt64(lo)) % UInt64(y))


def rem64(hi: UInt64, lo: UInt64, y: UInt64) raises -> UInt64:
    """`(hi, lo) % y`, with the dividend 128 bits wide.

    Go reduces `hi` modulo `y` first so that its own `Div64` cannot hit the
    overflow panic on the way past. Dividing 128 bits by 64 has no such
    restriction, so the reduction is not needed here.
    """
    if y == 0:
        raise _divide_by_zero()
    return _lo64(_wide(hi, lo) % UInt128(y))
