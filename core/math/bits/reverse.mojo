"""Moving bits around. Go's `Reverse`, `ReverseBytes` and `RotateLeft`.

Reversing bits and reversing bytes are both single instructions on the
architectures this library builds for, and `std.bit` names them, so those ten
functions are calls. Rotation is not, because Go's takes the distance at run
time, so the five rotations are the shift pair written out.

Go builds its reversals out of the mask and shift ladder from Hacker's Delight
for the same reason it carries tables in `count.mojo`'s Go counterpart: the
compiler intrinsifies some widths on some architectures and the ladder is what
the rest run on. The answers are identical, and `tests/math/bits` takes Go's
own table to say so.
"""

from std.bit import bit_reverse, byte_swap

from core.math.bits.count import UINT_SIZE


def reverse(x: UInt) -> UInt:
    """`x` with its bits in the opposite order.

    ```mojo
    from core.math.bits import reverse

    print(reverse(UInt(1)))  # 9223372036854775808
    ```
    """
    return bit_reverse(x)


def reverse8(x: UInt8) -> UInt8:
    """`x` with its bits in the opposite order."""
    return bit_reverse(x)


def reverse16(x: UInt16) -> UInt16:
    """`x` with its bits in the opposite order."""
    return bit_reverse(x)


def reverse32(x: UInt32) -> UInt32:
    """`x` with its bits in the opposite order."""
    return bit_reverse(x)


def reverse64(x: UInt64) -> UInt64:
    """`x` with its bits in the opposite order."""
    return bit_reverse(x)


def reverse_bytes(x: UInt) -> UInt:
    """`x` with its bytes in the opposite order.

    The bits within each byte stay where they are, which is what makes this the
    swap between one endianness and the other rather than `reverse`.
    """
    return byte_swap(x)


def reverse_bytes16(x: UInt16) -> UInt16:
    """`x` with its two bytes swapped.

    ```mojo
    from core.math.bits import reverse_bytes16

    print(reverse_bytes16(UInt16(0x1234)))  # 13330, which is 0x3412
    ```
    """
    return byte_swap(x)


def reverse_bytes32(x: UInt32) -> UInt32:
    """`x` with its four bytes in the opposite order."""
    return byte_swap(x)


def reverse_bytes64(x: UInt64) -> UInt64:
    """`x` with its eight bytes in the opposite order."""
    return byte_swap(x)


def rotate_left(x: UInt, k: Int) -> UInt:
    """`x` rotated `k` places towards the top, wrapping at the width.

    ```mojo
    from core.math.bits import rotate_left8

    print(rotate_left8(UInt8(0b1000_0001), 1))  # 3
    ```

    A negative `k` rotates the other way, which is how Go spells rotate right
    and why there is no second function for it. The distance is taken modulo
    the width, so no distance is out of range.

    `std.bit.rotate_bits_left` wants the distance at compile time. Go's takes
    it at run time and callers pass one they computed, so this is the shift
    pair written out instead. The second shift is masked as well as the first,
    because a shift by the full width is undefined below Mojo and a rotation by
    zero would otherwise land on it.
    """
    var s = UInt(k & (UINT_SIZE - 1))
    return (x << s) | (x >> ((UINT_SIZE - s) & (UINT_SIZE - 1)))


def rotate_left8(x: UInt8, k: Int) -> UInt8:
    """`x` rotated `k` places towards the top, wrapping at 8 bits."""
    var s = UInt8(k & 7)
    return (x << s) | (x >> ((8 - s) & 7))


def rotate_left16(x: UInt16, k: Int) -> UInt16:
    """`x` rotated `k` places towards the top, wrapping at 16 bits."""
    var s = UInt16(k & 15)
    return (x << s) | (x >> ((16 - s) & 15))


def rotate_left32(x: UInt32, k: Int) -> UInt32:
    """`x` rotated `k` places towards the top, wrapping at 32 bits."""
    var s = UInt32(k & 31)
    return (x << s) | (x >> ((32 - s) & 31))


def rotate_left64(x: UInt64, k: Int) -> UInt64:
    """`x` rotated `k` places towards the top, wrapping at 64 bits."""
    var s = UInt64(k & 63)
    return (x << s) | (x >> ((64 - s) & 63))
