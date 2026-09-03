"""Integers to text. Go's `itoa.go`.

Three shapes of the same conversion: `format_uint` and `format_int` build a
`String`, the `append_` pair write into a list a caller already has, and `itoa`
is the one everybody actually calls.

Go panics on a base outside 2 through 36. This raises, for the reason
`strings.Builder.grow` raises on a negative count: the base is usually a
literal and a wrong one is a bug, but the caller is the only one who can say
what to do about it, and an abort takes the whole process with it.

`itoa` cannot fail, because base 10 is always legal, so it is the one function
here without `raises` on it and the one that reads cleanly inside an expression.

Go's `formatBase10` splits the number into nine digit chunks so that a 32 bit
host does 32 bit division. That is not ported: there is no 32 bit host in this
library's set, and on a 64 bit one the chunking costs a division to save a
division. The two digit table below is the part of Go's fast path that pays for
itself anywhere.
"""

from core.errors import Report


comptime _DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
"""Digit values 0 through 35, which is why the base ceiling is 36."""

comptime _SMALLS = String(
    "00010203040506070809",
    "10111213141516171819",
    "20212223242526272829",
    "30313233343536373839",
    "40414243444546474849",
    "50515253545556575859",
    "60616263646566676869",
    "70717273747576777879",
    "80818283848586878889",
    "90919293949596979899",
)
"""Every two digit number, so base 10 emits two bytes per division."""

comptime INT_SIZE = 64
"""The width of `Int` in bits. Go's `IntSize`.

Go computes it from `^uint(0) >> 63` because it supports 32 bit platforms.
Every platform this library builds for is 64 bit, and `docs/platforms.md` is
the list. It is here so that a bit size of zero means the same thing it does in
Go: whatever an `Int` holds.
"""

# The buffer is one byte per digit of a 64 bit number in base 2, plus a sign.
comptime _MAX_DIGITS = 65


def _check_base(base: Int) raises:
    """Go's panic, as a raise. The message is Go's."""
    if base < 2 or base > 36:
        raise Report(
            "strconv: illegal append_int/format_int base " + String(base)
        ).error()


def _shift_for(base: Int) -> UInt64:
    """How far to shift for a power of two base, which is its trailing zeros.

    A loop rather than an intrinsic, because it runs once per call on five
    possible inputs and the intrinsic would be a dependency.
    """
    var shift = UInt64(0)
    var b = base
    while b > 1:
        b >>= 1
        shift += 1
    return shift


def _append_digits(
    mut dst: List[UInt8], u: UInt64, base: Int, neg: Bool
) -> Int:
    """`u` in `base`, with a minus in front if `neg`, appended to `dst`.

    Go's `formatBits`. The digits come out least significant first, so they are
    written backwards into a fixed buffer and copied once. `base` has to be
    between 2 and 36; the public entry points are what check that.
    """
    var a = InlineArray[UInt8, _MAX_DIGITS](fill=0)
    var i = _MAX_DIGITS
    var v = u

    if base == 10:
        var pairs = _SMALLS.as_bytes()
        while v >= 100:
            var q = v // 100
            var d = Int(v - q * 100) * 2
            i -= 2
            a[i] = pairs[d]
            a[i + 1] = pairs[d + 1]
            v = q
        var d = Int(v) * 2
        i -= 1
        a[i] = pairs[d + 1]
        if v >= 10:
            i -= 1
            a[i] = pairs[d]
    elif base & (base - 1) == 0:
        # A power of two, so the division is a shift and the remainder a mask.
        var shift = _shift_for(base)
        var mask = UInt64(base) - 1
        var digits = _DIGITS.as_bytes()
        while v >= UInt64(base):
            i -= 1
            a[i] = digits[Int(v & mask)]
            v >>= shift
        i -= 1
        a[i] = digits[Int(v)]
    else:
        var b = UInt64(base)
        var digits = _DIGITS.as_bytes()
        while v >= b:
            var q = v // b
            i -= 1
            a[i] = digits[Int(v - q * b)]
            v = q
        i -= 1
        a[i] = digits[Int(v)]

    if neg:
        i -= 1
        a[i] = UInt8(ord("-"))

    for k in range(i, _MAX_DIGITS):
        dst.append(a[k])
    return _MAX_DIGITS - i


def _magnitude(i: Int64) -> UInt64:
    """`i` without its sign, which for the smallest `Int64` needs the unsigned
    side of the arithmetic: negating it as a signed value wraps back to itself.
    """
    var u = UInt64(i.cast[DType.uint64]())
    if i < 0:
        return ~u + 1
    return u


def _to_string(var buf: List[UInt8]) -> String:
    """Digits are ASCII, so this never substitutes anything."""
    return String(from_utf8_lossy=Span(buf))


def format_uint(i: UInt64, base: Int) raises -> String:
    """`i` written in `base`, using lower case letters. Go's `FormatUint`.

    ```mojo
    from core.strconv import format_uint

    def main():
        print(format_uint(UInt64(255), 16))  # ff
    ```
    """
    _check_base(base)
    var buf = List[UInt8]()
    _ = _append_digits(buf, i, base, False)
    return _to_string(buf^)


def format_int(i: Int64, base: Int) raises -> String:
    """`i` written in `base`, using lower case letters. Go's `FormatInt`.

    A negative number gets a minus in front, so the digits after it are the
    magnitude and base 2 of the smallest `Int64` is a minus and 63 zeros after
    a one, not the two's complement bits.
    """
    _check_base(base)
    var buf = List[UInt8]()
    _ = _append_digits(buf, _magnitude(i), base, i < 0)
    return _to_string(buf^)


def itoa(i: Int) -> String:
    """`i` in base 10. Go's `Itoa`, and the one that cannot fail.

    ```mojo
    from core.strconv import itoa

    def main():
        print("there are " + itoa(3) + " of them")
    ```
    """
    var buf = List[UInt8]()
    _ = _append_digits(buf, _magnitude(Int64(i)), 10, i < 0)
    return _to_string(buf^)


def append_int(mut dst: List[UInt8], i: Int64, base: Int) raises -> Int:
    """`format_int(i, base)` onto the end of `dst`, and how many bytes that
    took. Go's `AppendInt`, which hands back the grown slice instead.

    The count rather than the list, the same as `utf8.append_rune` and the
    `append_quote` family: the list is already the caller's and a second name
    for it is the thing that goes stale.
    """
    _check_base(base)
    return _append_digits(dst, _magnitude(i), base, i < 0)


def append_uint(mut dst: List[UInt8], i: UInt64, base: Int) raises -> Int:
    """`format_uint(i, base)` onto the end of `dst`, and how many bytes that
    took. Go's `AppendUint`."""
    _check_base(base)
    return _append_digits(dst, i, base, False)
