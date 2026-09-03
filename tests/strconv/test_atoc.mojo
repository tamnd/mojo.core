"""Text to complex numbers. Go's `atoc_test.go`.

Go's table row for row, with the expected complex written as its two halves
because there is no complex literal to write instead. Every row is read at 128
bits, and again at 64 whenever both halves survive a trip through a `Float32`,
which is the pair of runs Go's `TestParseComplex` makes.

Go compares with `sameComplex`, which calls two values equal when either one
has a NaN anywhere in it. That is looser than it needs to be, so the comparison
here is half by half, with NaN equal to NaN and nothing else.
"""

from std.math import inf, isnan, nan
from std.testing import assert_equal, assert_true

from core.errors import matches
from core.errors.codes import Code, ErrRange, ErrSyntax

from core.strconv import NumError, parse_complex


comptime OK = 0
comptime SYNTAX = 1
comptime RANGE = 2

comptime MAX64 = Float64(1.7976931348623157e308)
# Go writes these as hexadecimal float literals, which Mojo does not have.
# 0x10.3 is 16.1875, and the exponent that follows is a power of two.
comptime HEX_SMALL = Float64(0.063232421875)
"""Go's `0x10.3p-8`."""
comptime HEX_LARGE = Float64(4144.0)
"""Go's `0x10.3p+8`."""


struct Row(Copyable, Movable):
    """An input, the two halves Go reads out of it, and which failure if any."""

    var input: String
    var re: Float64
    var im: Float64
    var err: Int

    def __init__(
        out self, var input: String, re: Float64, im: Float64, err: Int
    ):
        self.input = input^
        self.re = re
        self.im = im
        self.err = err


def same(a: Float64, b: Float64) -> Bool:
    """Equal, counting NaN as equal to NaN and to nothing else."""
    return (isnan(a) and isnan(b)) or a == b


def _wanted(err: Int) -> Code:
    return ErrSyntax if err == SYNTAX else ErrRange


def check(row: Row, bit_size: Int) raises:
    """One row at one width."""
    if row.err == OK:
        var z = parse_complex(row.input, bit_size)
        assert_true(
            same(z.re, row.re) and same(z.im, row.im),
            "parse_complex(" + row.input + ") read the wrong number",
        )
        return
    var raised = False
    try:
        _ = parse_complex(row.input, bit_size)
    except e:
        raised = True
        assert_true(
            matches(e, _wanted(row.err)),
            "parse_complex(" + row.input + ") raised the wrong code",
        )
        var failure = NumError.of(e)
        assert_true(Bool(failure))
        assert_equal(failure.value().func, "parse_complex")
    assert_true(raised, "parse_complex(" + row.input + ") should have failed")


def atoc_rows() -> List[Row]:
    """Go's table inside `TestParseComplex`."""
    var INF = inf[DType.float64]()
    var NAN = nan[DType.float64]()
    var rows = List[Row]()

    # Clearly invalid.
    rows.append(Row("", 0, 0, SYNTAX))
    rows.append(Row(" ", 0, 0, SYNTAX))
    rows.append(Row("(", 0, 0, SYNTAX))
    rows.append(Row(")", 0, 0, SYNTAX))
    rows.append(Row("i", 0, 0, SYNTAX))
    rows.append(Row("+i", 0, 0, SYNTAX))
    rows.append(Row("-i", 0, 0, SYNTAX))
    rows.append(Row("1I", 0, 0, SYNTAX))
    rows.append(Row("10  + 5i", 0, 0, SYNTAX))
    rows.append(Row("3+", 0, 0, SYNTAX))
    rows.append(Row("3+5", 0, 0, SYNTAX))
    rows.append(Row("3+5+5i", 0, 0, SYNTAX))

    # Parentheses, which come off in one pair or not at all.
    rows.append(Row("()", 0, 0, SYNTAX))
    rows.append(Row("(i)", 0, 0, SYNTAX))
    rows.append(Row("(0)", 0, 0, OK))
    rows.append(Row("(1i)", 0, 1, OK))
    rows.append(Row("(3.0+5.5i)", 3.0, 5.5, OK))
    rows.append(Row("(1)+1i", 0, 0, SYNTAX))
    rows.append(Row("(3.0+5.5i", 0, 0, SYNTAX))
    rows.append(Row("3.0+5.5i)", 0, 0, SYNTAX))

    # NaNs, which take a plus and never a minus.
    rows.append(Row("NaN", NAN, 0, OK))
    rows.append(Row("NANi", 0, NAN, OK))
    rows.append(Row("nan+nAni", NAN, NAN, OK))
    rows.append(Row("+NaN", 0, 0, SYNTAX))
    rows.append(Row("-NaN", 0, 0, SYNTAX))
    rows.append(Row("NaN-NaNi", 0, 0, SYNTAX))

    # Infinities.
    rows.append(Row("Inf", INF, 0, OK))
    rows.append(Row("+inf", INF, 0, OK))
    rows.append(Row("-inf", -INF, 0, OK))
    rows.append(Row("Infinity", INF, 0, OK))
    rows.append(Row("+INFINITY", INF, 0, OK))
    rows.append(Row("-infinity", -INF, 0, OK))
    rows.append(Row("+infi", 0, INF, OK))
    rows.append(Row("0-infinityi", 0, -INF, OK))
    rows.append(Row("Inf+Infi", INF, INF, OK))
    rows.append(Row("+Inf-Infi", INF, -INF, OK))
    rows.append(Row("-Infinity+Infi", -INF, INF, OK))
    rows.append(Row("inf-inf", 0, 0, SYNTAX))

    # Zeros.
    rows.append(Row("0", 0, 0, OK))
    rows.append(Row("0i", 0, 0, OK))
    rows.append(Row("-0.0i", 0, 0, OK))
    rows.append(Row("0+0.0i", 0, 0, OK))
    rows.append(Row("0e+0i", 0, 0, OK))
    rows.append(Row("0e-0+0i", 0, 0, OK))
    rows.append(Row("-0.0-0.0i", 0, 0, OK))
    rows.append(Row("0e+012345", 0, 0, OK))
    rows.append(Row("0x0p+012345i", 0, 0, OK))
    rows.append(Row("0x0.00p-012345i", 0, 0, OK))
    rows.append(Row("+0e-0+0e-0i", 0, 0, OK))
    rows.append(Row("0e+0+0e+0i", 0, 0, OK))
    rows.append(Row("-0e+0-0e+0i", 0, 0, OK))

    # Ordinary numbers.
    rows.append(Row("0.1", 0.1, 0, OK))
    rows.append(Row("0.1i", 0, 0.1, OK))
    rows.append(Row("0.123", 0.123, 0, OK))
    rows.append(Row("0.123i", 0, 0.123, OK))
    rows.append(Row("0.123+0.123i", 0.123, 0.123, OK))
    rows.append(Row("99", 99, 0, OK))
    rows.append(Row("+99", 99, 0, OK))
    rows.append(Row("-99", -99, 0, OK))
    rows.append(Row("+1i", 0, 1, OK))
    rows.append(Row("-1i", 0, -1, OK))
    rows.append(Row("+3+1i", 3, 1, OK))
    rows.append(Row("30+3i", 30, 3, OK))
    rows.append(Row("+3e+3-3e+3i", 3e3, -3e3, OK))
    rows.append(Row("+3e+3+3e+3i", 3e3, 3e3, OK))
    rows.append(Row("+3e+3+3e+3i+", 0, 0, SYNTAX))

    # Underscores, which are legal in the same places as in a float. Go opens
    # this block by repeating the two "0.1" rows above, which are left out here.
    rows.append(Row("0.1_2_3", 0.123, 0, OK))
    rows.append(Row("+0x_3p3i", 0, 24, OK))
    rows.append(Row("0_0+0x_0p0i", 0, 0, OK))
    rows.append(Row("0x_10.3p-8+0x3p3i", HEX_SMALL, 24, OK))
    rows.append(Row("+0x_1_0.3p-8+0x_3_0p3i", HEX_SMALL, 384, OK))
    rows.append(Row("0x1_0.3p+8-0x_3p3i", HEX_LARGE, -24, OK))

    # Hexadecimal, where an exponent is not optional.
    rows.append(Row("0x10.3p-8+0x3p3i", HEX_SMALL, 24, OK))
    rows.append(Row("+0x10.3p-8+0x3p3i", HEX_SMALL, 24, OK))
    rows.append(Row("0x10.3p+8-0x3p3i", HEX_LARGE, -24, OK))
    rows.append(Row("0x1p0", 1, 0, OK))
    rows.append(Row("0x1p1", 2, 0, OK))
    rows.append(Row("0x1p-1", 0.5, 0, OK))
    rows.append(Row("0x1ep-1", 15, 0, OK))
    rows.append(Row("-0x1ep-1", -15, 0, OK))
    rows.append(Row("-0x2p3", -16, 0, OK))
    rows.append(Row("0x1e2", 0, 0, SYNTAX))
    rows.append(Row("1p2", 0, 0, SYNTAX))
    rows.append(Row("0x1e2i", 0, 0, SYNTAX))

    # Out of range, one half at a time and then both.
    rows.append(Row("+0x1p1024", INF, 0, RANGE))
    rows.append(Row("-0x1p1024", -INF, 0, RANGE))
    rows.append(Row("+0x1p1024i", 0, INF, RANGE))
    rows.append(Row("-0x1p1024i", 0, -INF, RANGE))
    rows.append(Row("+0x1p1024+0x1p1024i", INF, INF, RANGE))
    rows.append(Row("+0x1p1024-0x1p1024i", INF, -INF, RANGE))
    rows.append(Row("-0x1p1024+0x1p1024i", -INF, INF, RANGE))
    rows.append(Row("-0x1p1024-0x1p1024i", -INF, -INF, RANGE))

    # The border is at ...158079. Just under it.
    rows.append(
        Row(
            "+0x1.fffffffffffff7fffp1023+0x1.fffffffffffff7fffp1023i",
            MAX64,
            MAX64,
            OK,
        )
    )
    rows.append(
        Row(
            "+0x1.fffffffffffff7fffp1023-0x1.fffffffffffff7fffp1023i",
            MAX64,
            -MAX64,
            OK,
        )
    )
    rows.append(
        Row(
            "-0x1.fffffffffffff7fffp1023+0x1.fffffffffffff7fffp1023i",
            -MAX64,
            MAX64,
            OK,
        )
    )
    rows.append(
        Row(
            "-0x1.fffffffffffff7fffp1023-0x1.fffffffffffff7fffp1023i",
            -MAX64,
            -MAX64,
            OK,
        )
    )
    # And just over it.
    rows.append(Row("+0x1.fffffffffffff8p1023", INF, 0, RANGE))
    rows.append(Row("-0x1fffffffffffff.8p+971", -INF, 0, RANGE))
    rows.append(Row("+0x1.fffffffffffff8p1023i", 0, INF, RANGE))
    rows.append(Row("-0x1fffffffffffff.8p+971i", 0, -INF, RANGE))
    rows.append(
        Row(
            "+0x1.fffffffffffff8p1023+0x1.fffffffffffff8p1023i", INF, INF, RANGE
        )
    )
    rows.append(
        Row(
            "+0x1.fffffffffffff8p1023-0x1.fffffffffffff8p1023i",
            INF,
            -INF,
            RANGE,
        )
    )
    rows.append(
        Row(
            "-0x1fffffffffffff.8p+971+0x1fffffffffffff.8p+971i",
            -INF,
            INF,
            RANGE,
        )
    )
    rows.append(
        Row(
            "-0x1fffffffffffff8p+967-0x1fffffffffffff8p+967i",
            -INF,
            -INF,
            RANGE,
        )
    )

    # A little too large.
    rows.append(Row("1e308+1e308i", 1e308, 1e308, OK))
    rows.append(Row("2e308+2e308i", INF, INF, RANGE))
    rows.append(Row("1e309+1e309i", INF, INF, RANGE))
    rows.append(Row("0x1p1025+0x1p1025i", INF, INF, RANGE))
    rows.append(Row("2e308", INF, 0, RANGE))
    rows.append(Row("1e309", INF, 0, RANGE))
    rows.append(Row("0x1p1025", INF, 0, RANGE))
    rows.append(Row("2e308i", 0, INF, RANGE))
    rows.append(Row("1e309i", 0, INF, RANGE))
    rows.append(Row("0x1p1025i", 0, INF, RANGE))

    # Way too large.
    rows.append(Row("+1e310+1e310i", INF, INF, RANGE))
    rows.append(Row("+1e310-1e310i", INF, -INF, RANGE))
    rows.append(Row("-1e310+1e310i", -INF, INF, RANGE))
    rows.append(Row("-1e310-1e310i", -INF, -INF, RANGE))

    # An exponent that would overflow the accumulator it is read into.
    rows.append(Row("1e-4294967296", 0, 0, OK))
    rows.append(Row("1e-4294967296i", 0, 0, OK))
    rows.append(Row("1e-4294967296+1i", 0, 1, OK))
    rows.append(Row("1+1e-4294967296i", 1, 0, OK))
    rows.append(Row("1e-4294967296+1e-4294967296i", 0, 0, OK))
    rows.append(Row("1e+4294967296", INF, 0, RANGE))
    rows.append(Row("1e+4294967296i", 0, INF, RANGE))
    rows.append(Row("1e+4294967296+1e+4294967296i", INF, INF, RANGE))
    rows.append(Row("1e+4294967296-1e+4294967296i", INF, -INF, RANGE))
    return rows^


def test_parse_complex() raises:
    """Go's `TestParseComplex` at 128 bits."""
    for row in atoc_rows():
        check(row, 128)


def test_parse_complex_64() raises:
    """The same rows at 64 bits, over those whose halves are exactly `Float32`s.

    A failing row is checked at both widths: nothing that is a syntax error in
    a pair of float64 components parses as a pair of float32 ones, and a number
    too large for the first is too large for the second.
    """
    for row in atoc_rows():
        if row.err != OK:
            check(row, 64)
            continue
        if Float64(Float32(row.re)) != row.re:
            continue
        if Float64(Float32(row.im)) != row.im:
            continue
        var z = parse_complex(row.input, 64)
        assert_true(
            same(Float64(Float32(z.re)), row.re)
            and same(Float64(Float32(z.im)), row.im),
            "parse_complex(" + row.input + ", 64) read the wrong number",
        )


def test_any_bit_size_is_taken() raises:
    """Go issue 42297 again, the same allowance `parse_float` makes."""
    var sizes: List[Int] = [0, 10, 100, 256]
    for size in sizes:
        var z = parse_complex("1.5e308+1.0e307i", size)
        assert_equal(z.re, 1.5e308)
        assert_equal(z.im, 1.0e307)
