"""Integers to text. Go's `itoa_test.go`.

Go's `itob64tests` and `uitob64tests`, row for row, with the append form
checked against the same expectation the way Go's `TestItoa` does.

The rows are written as a struct rather than a tuple because a tuple holding a
`String` cannot be destructured, which is the same reason every table in this
suite looks like this.
"""

from std.testing import assert_equal, assert_raises

from core.strconv import (
    INT_SIZE,
    append_int,
    append_uint,
    format_int,
    format_uint,
    itoa,
)


struct SignedRow(Copyable, Movable):
    var input: Int64
    var base: Int
    var out: String

    def __init__(out self, input: Int64, base: Int, var out: String):
        self.input = input
        self.base = base
        self.out = out^


struct UnsignedRow(Copyable, Movable):
    var input: UInt64
    var base: Int
    var out: String

    def __init__(out self, input: UInt64, base: Int, var out: String):
        self.input = input
        self.base = base
        self.out = out^


def signed_rows() -> List[SignedRow]:
    """Go's `itob64tests`."""
    var rows = List[SignedRow]()
    rows.append(SignedRow(0, 10, "0"))
    rows.append(SignedRow(1, 10, "1"))
    rows.append(SignedRow(-1, 10, "-1"))
    rows.append(SignedRow(12345678, 10, "12345678"))
    rows.append(SignedRow(-987654321, 10, "-987654321"))
    # The powers of two either side of 32 bits, where a sloppy conversion shows.
    rows.append(SignedRow((1 << 31) - 1, 10, "2147483647"))
    rows.append(SignedRow(-(1 << 31) + 1, 10, "-2147483647"))
    rows.append(SignedRow(1 << 31, 10, "2147483648"))
    rows.append(SignedRow(-(1 << 31), 10, "-2147483648"))
    rows.append(SignedRow((1 << 31) + 1, 10, "2147483649"))
    rows.append(SignedRow(-(1 << 31) - 1, 10, "-2147483649"))
    rows.append(SignedRow((1 << 32) - 1, 10, "4294967295"))
    rows.append(SignedRow(-(1 << 32) + 1, 10, "-4294967295"))
    rows.append(SignedRow(1 << 32, 10, "4294967296"))
    rows.append(SignedRow(-(1 << 32), 10, "-4294967296"))
    rows.append(SignedRow((1 << 32) + 1, 10, "4294967297"))
    rows.append(SignedRow(-(1 << 32) - 1, 10, "-4294967297"))
    rows.append(SignedRow(1 << 50, 10, "1125899906842624"))
    rows.append(SignedRow((1 << 63) - 1, 10, "9223372036854775807"))
    rows.append(SignedRow(-((1 << 63) - 1), 10, "-9223372036854775807"))
    rows.append(SignedRow(Int64.MIN, 10, "-9223372036854775808"))

    rows.append(SignedRow(0, 2, "0"))
    rows.append(SignedRow(10, 2, "1010"))
    rows.append(SignedRow(-1, 2, "-1"))
    rows.append(SignedRow(1 << 15, 2, "1000000000000000"))

    rows.append(SignedRow(-8, 8, "-10"))
    rows.append(SignedRow(0o57635436545, 8, "57635436545"))
    rows.append(SignedRow(1 << 24, 8, "100000000"))

    rows.append(SignedRow(16, 16, "10"))
    rows.append(SignedRow(-0x123456789ABCDEF, 16, "-123456789abcdef"))
    rows.append(SignedRow((1 << 63) - 1, 16, "7fffffffffffffff"))
    rows.append(
        SignedRow(
            (1 << 63) - 1,
            2,
            "111111111111111111111111111111111111111111111111111111111111111",
        )
    )
    rows.append(
        SignedRow(
            Int64.MIN,
            2,
            "-1000000000000000000000000000000000000000000000000000000000000000",
        )
    )

    # The bases nobody uses, which is why they are worth a row.
    rows.append(SignedRow(16, 17, "g"))
    rows.append(SignedRow(25, 25, "10"))
    rows.append(
        SignedRow(
            (((((17 * 35 + 24) * 35 + 21) * 35 + 34) * 35 + 12) * 35 + 24) * 35
            + 32,
            35,
            "holycow",
        )
    )
    rows.append(
        SignedRow(
            (((((17 * 36 + 24) * 36 + 21) * 36 + 34) * 36 + 12) * 36 + 24) * 36
            + 32,
            36,
            "holycow",
        )
    )
    return rows^


def unsigned_rows() -> List[UnsignedRow]:
    """Go's `uitob64tests`, which is where the top half of `UInt64` lives."""
    var rows = List[UnsignedRow]()
    rows.append(UnsignedRow((UInt64(1) << 63) - 1, 10, "9223372036854775807"))
    rows.append(UnsignedRow(UInt64(1) << 63, 10, "9223372036854775808"))
    rows.append(UnsignedRow((UInt64(1) << 63) + 1, 10, "9223372036854775809"))
    rows.append(UnsignedRow(UInt64.MAX - 1, 10, "18446744073709551614"))
    rows.append(UnsignedRow(UInt64.MAX, 10, "18446744073709551615"))
    rows.append(
        UnsignedRow(
            UInt64.MAX,
            2,
            "1111111111111111111111111111111111111111111111111111111111111111",
        )
    )
    return rows^


def test_format_int() raises:
    """Go's `TestItoa`, the `FormatInt` and `AppendInt` halves."""
    for row in signed_rows():
        assert_equal(format_int(row.input, row.base), row.out)
        var dst = List[UInt8]()
        for byte in "abc".as_bytes():
            dst.append(byte)
        var n = append_int(dst, row.input, row.base)
        assert_equal(n, row.out.byte_length())
        assert_equal(String(from_utf8_lossy=Span(dst)), "abc" + row.out)


def test_format_uint_on_the_non_negative_rows() raises:
    """Go runs the same table through the unsigned pair where it can."""
    for row in signed_rows():
        if row.input < 0:
            continue
        var u = UInt64(row.input.cast[DType.uint64]())
        assert_equal(format_uint(u, row.base), row.out)
        var dst = List[UInt8]()
        assert_equal(append_uint(dst, u, row.base), row.out.byte_length())
        assert_equal(String(from_utf8_lossy=Span(dst)), row.out)


def test_format_uint_above_the_signed_range() raises:
    """Go's `uitob64tests`. Everything here is wrong if the sign leaks in."""
    for row in unsigned_rows():
        assert_equal(format_uint(row.input, row.base), row.out)
        var dst = List[UInt8]()
        assert_equal(
            append_uint(dst, row.input, row.base), row.out.byte_length()
        )
        assert_equal(String(from_utf8_lossy=Span(dst)), row.out)


def test_itoa() raises:
    """The base 10 rows again through the function without a base."""
    for row in signed_rows():
        if row.base != 10:
            continue
        assert_equal(itoa(Int(row.input)), row.out)


def test_an_illegal_base_raises() raises:
    """Go panics here and this raises, which is the deviation.

    Every base outside 2 through 36, on all four entry points, so that none of
    them is the one that quietly formats in base 10 instead.
    """
    var bases = [-1, 0, 1, 37, 100]
    for base in bases:
        with assert_raises():
            _ = format_uint(UInt64(12345678), base)
        with assert_raises():
            _ = format_int(Int64(12345678), base)
        var dst = List[UInt8]()
        with assert_raises():
            _ = append_uint(dst, UInt64(12345678), base)
        with assert_raises():
            _ = append_int(dst, Int64(12345678), base)
        # And it raised before writing anything, which is what makes a failed
        # append safe to ignore rather than something to unwind.
        assert_equal(len(dst), 0)


def test_int_size() raises:
    """Go's `IntSize`, which is the default bit size for the parsers."""
    assert_equal(INT_SIZE, 64)
