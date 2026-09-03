"""Text to integers. Go's `atoi_test.go`.

Go's five tables, row for row: `parseUint64Tests`, `parseUint64BaseTests`,
`parseInt64Tests`, `parseInt64BaseTests`, and the 32 bit pair.

Go records the expected error as a value and compares it. Here the failure is a
raise carrying a code, so a row says which code it wants and `check_uint` and
`check_int` assert on that rather than only on the fact that something failed.
Every one of Go's `ErrRange` rows also carries a clamped value, which a raise
cannot, and the rows keep the value anyway so that the table still reads as
Go's does.
"""

from std.testing import assert_equal, assert_true

from core.errors import matches
from core.errors.codes import Code, ErrBase, ErrBitSize, ErrRange, ErrSyntax

from core.strconv import NumError, atoi, parse_int, parse_uint


comptime OK = 0
comptime SYNTAX = 1
comptime RANGE = 2


struct URow(Copyable, Movable):
    """An input, a base, the answer Go gives, and which failure if any."""

    var input: String
    var base: Int
    var want: UInt64
    var err: Int

    def __init__(
        out self, var input: String, base: Int, want: UInt64, err: Int
    ):
        self.input = input^
        self.base = base
        self.want = want
        self.err = err


struct IRow(Copyable, Movable):
    var input: String
    var base: Int
    var want: Int64
    var err: Int

    def __init__(out self, var input: String, base: Int, want: Int64, err: Int):
        self.input = input^
        self.base = base
        self.want = want
        self.err = err


def _wanted(err: Int) -> Code:
    return ErrSyntax if err == SYNTAX else ErrRange


def check_uint(row: URow, bit_size: Int) raises:
    """One `parse_uint` row, value or code."""
    if row.err == OK:
        assert_equal(parse_uint(row.input, row.base, bit_size), row.want)
        return
    var raised = False
    try:
        _ = parse_uint(row.input, row.base, bit_size)
    except e:
        raised = True
        assert_true(
            matches(e, _wanted(row.err)),
            "parse_uint(" + row.input + ") raised the wrong code",
        )
    assert_true(raised, "parse_uint(" + row.input + ") should have failed")


def check_int(row: IRow, bit_size: Int) raises:
    """One `parse_int` row, value or code."""
    if row.err == OK:
        assert_equal(parse_int(row.input, row.base, bit_size), row.want)
        return
    var raised = False
    try:
        _ = parse_int(row.input, row.base, bit_size)
    except e:
        raised = True
        assert_true(
            matches(e, _wanted(row.err)),
            "parse_int(" + row.input + ") raised the wrong code",
        )
    assert_true(raised, "parse_int(" + row.input + ") should have failed")


def test_parse_uint64() raises:
    """Go's `parseUint64Tests`, all at base 10, where no underscore is legal."""
    var rows = List[URow]()
    rows.append(URow("", 10, 0, SYNTAX))
    rows.append(URow("0", 10, 0, OK))
    rows.append(URow("1", 10, 1, OK))
    rows.append(URow("12345", 10, 12345, OK))
    rows.append(URow("012345", 10, 12345, OK))
    rows.append(URow("12345x", 10, 0, SYNTAX))
    rows.append(URow("98765432100", 10, 98765432100, OK))
    rows.append(URow("18446744073709551615", 10, UInt64.MAX, OK))
    rows.append(URow("18446744073709551616", 10, UInt64.MAX, RANGE))
    rows.append(URow("18446744073709551620", 10, UInt64.MAX, RANGE))
    rows.append(URow("1_2_3_4_5", 10, 0, SYNTAX))
    rows.append(URow("_12345", 10, 0, SYNTAX))
    rows.append(URow("1__2345", 10, 0, SYNTAX))
    rows.append(URow("12345_", 10, 0, SYNTAX))
    # A sign is not allowed here, not even the one that changes nothing.
    rows.append(URow("-0", 10, 0, SYNTAX))
    rows.append(URow("-1", 10, 0, SYNTAX))
    rows.append(URow("+1", 10, 0, SYNTAX))
    for row in rows:
        check_uint(row, 64)


def test_parse_uint64_base() raises:
    """Go's `parseUint64BaseTests`: every prefix and every underscore rule."""
    var rows = List[URow]()
    rows.append(URow("", 0, 0, SYNTAX))
    rows.append(URow("0", 0, 0, OK))
    rows.append(URow("0x", 0, 0, SYNTAX))
    rows.append(URow("0X", 0, 0, SYNTAX))
    rows.append(URow("1", 0, 1, OK))
    rows.append(URow("12345", 0, 12345, OK))
    rows.append(URow("012345", 0, 0o12345, OK))
    rows.append(URow("0x12345", 0, 0x12345, OK))
    rows.append(URow("0X12345", 0, 0x12345, OK))
    rows.append(URow("12345x", 0, 0, SYNTAX))
    rows.append(URow("0xabcdefg123", 0, 0, SYNTAX))
    rows.append(URow("123456789abc", 0, 0, SYNTAX))
    rows.append(URow("98765432100", 0, 98765432100, OK))
    rows.append(URow("18446744073709551615", 0, UInt64.MAX, OK))
    rows.append(URow("18446744073709551616", 0, UInt64.MAX, RANGE))
    rows.append(URow("18446744073709551620", 0, UInt64.MAX, RANGE))
    rows.append(URow("0xFFFFFFFFFFFFFFFF", 0, UInt64.MAX, OK))
    rows.append(URow("0x10000000000000000", 0, UInt64.MAX, RANGE))
    rows.append(URow("01777777777777777777777", 0, UInt64.MAX, OK))
    rows.append(URow("01777777777777777777778", 0, 0, SYNTAX))
    rows.append(URow("02000000000000000000000", 0, UInt64.MAX, RANGE))
    rows.append(URow("0200000000000000000000", 0, UInt64(1) << 61, OK))
    rows.append(URow("0b", 0, 0, SYNTAX))
    rows.append(URow("0B", 0, 0, SYNTAX))
    rows.append(URow("0b101", 0, 5, OK))
    rows.append(URow("0B101", 0, 5, OK))
    rows.append(URow("0o", 0, 0, SYNTAX))
    rows.append(URow("0O", 0, 0, SYNTAX))
    rows.append(URow("0o377", 0, 255, OK))
    rows.append(URow("0O377", 0, 255, OK))

    # Underscores, which base 0 allows between digits and nowhere else.
    rows.append(URow("1_2_3_4_5", 0, 12345, OK))
    rows.append(URow("_12345", 0, 0, SYNTAX))
    rows.append(URow("1__2345", 0, 0, SYNTAX))
    rows.append(URow("12345_", 0, 0, SYNTAX))

    rows.append(URow("1_2_3_4_5", 10, 0, SYNTAX))
    rows.append(URow("_12345", 10, 0, SYNTAX))
    rows.append(URow("1__2345", 10, 0, SYNTAX))
    rows.append(URow("12345_", 10, 0, SYNTAX))

    rows.append(URow("0x_1_2_3_4_5", 0, 0x12345, OK))
    rows.append(URow("_0x12345", 0, 0, SYNTAX))
    rows.append(URow("0x__12345", 0, 0, SYNTAX))
    rows.append(URow("0x1__2345", 0, 0, SYNTAX))
    rows.append(URow("0x1234__5", 0, 0, SYNTAX))
    rows.append(URow("0x12345_", 0, 0, SYNTAX))

    rows.append(URow("1_2_3_4_5", 16, 0, SYNTAX))
    rows.append(URow("_12345", 16, 0, SYNTAX))
    rows.append(URow("1__2345", 16, 0, SYNTAX))
    rows.append(URow("1234__5", 16, 0, SYNTAX))
    rows.append(URow("12345_", 16, 0, SYNTAX))

    rows.append(URow("0_1_2_3_4_5", 0, 0o12345, OK))
    rows.append(URow("_012345", 0, 0, SYNTAX))
    rows.append(URow("0__12345", 0, 0, SYNTAX))
    rows.append(URow("01234__5", 0, 0, SYNTAX))
    rows.append(URow("012345_", 0, 0, SYNTAX))

    rows.append(URow("0o_1_2_3_4_5", 0, 0o12345, OK))
    rows.append(URow("_0o12345", 0, 0, SYNTAX))
    rows.append(URow("0o__12345", 0, 0, SYNTAX))
    rows.append(URow("0o1234__5", 0, 0, SYNTAX))
    rows.append(URow("0o12345_", 0, 0, SYNTAX))

    rows.append(URow("0_1_2_3_4_5", 8, 0, SYNTAX))
    rows.append(URow("_012345", 8, 0, SYNTAX))
    rows.append(URow("0__12345", 8, 0, SYNTAX))
    rows.append(URow("01234__5", 8, 0, SYNTAX))
    rows.append(URow("012345_", 8, 0, SYNTAX))

    rows.append(URow("0b_1_0_1", 0, 5, OK))
    rows.append(URow("_0b101", 0, 0, SYNTAX))
    rows.append(URow("0b__101", 0, 0, SYNTAX))
    rows.append(URow("0b1__01", 0, 0, SYNTAX))
    rows.append(URow("0b10__1", 0, 0, SYNTAX))
    rows.append(URow("0b101_", 0, 0, SYNTAX))

    rows.append(URow("1_0_1", 2, 0, SYNTAX))
    rows.append(URow("_101", 2, 0, SYNTAX))
    rows.append(URow("1_01", 2, 0, SYNTAX))
    rows.append(URow("10_1", 2, 0, SYNTAX))
    rows.append(URow("101_", 2, 0, SYNTAX))

    for row in rows:
        check_uint(row, 64)


def test_parse_int64() raises:
    """Go's `parseInt64Tests`, base 10."""
    var rows = List[IRow]()
    rows.append(IRow("", 10, 0, SYNTAX))
    rows.append(IRow("0", 10, 0, OK))
    rows.append(IRow("-0", 10, 0, OK))
    rows.append(IRow("+0", 10, 0, OK))
    rows.append(IRow("1", 10, 1, OK))
    rows.append(IRow("-1", 10, -1, OK))
    rows.append(IRow("+1", 10, 1, OK))
    rows.append(IRow("12345", 10, 12345, OK))
    rows.append(IRow("-12345", 10, -12345, OK))
    rows.append(IRow("012345", 10, 12345, OK))
    rows.append(IRow("-012345", 10, -12345, OK))
    rows.append(IRow("98765432100", 10, 98765432100, OK))
    rows.append(IRow("-98765432100", 10, -98765432100, OK))
    rows.append(IRow("9223372036854775807", 10, Int64.MAX, OK))
    rows.append(IRow("-9223372036854775807", 10, -Int64.MAX, OK))
    rows.append(IRow("9223372036854775808", 10, Int64.MAX, RANGE))
    # The one value whose text is only legal with the sign in front of it.
    rows.append(IRow("-9223372036854775808", 10, Int64.MIN, OK))
    rows.append(IRow("9223372036854775809", 10, Int64.MAX, RANGE))
    rows.append(IRow("-9223372036854775809", 10, Int64.MIN, RANGE))
    rows.append(IRow("-1_2_3_4_5", 10, 0, SYNTAX))
    rows.append(IRow("-_12345", 10, 0, SYNTAX))
    rows.append(IRow("_12345", 10, 0, SYNTAX))
    rows.append(IRow("1__2345", 10, 0, SYNTAX))
    rows.append(IRow("12345_", 10, 0, SYNTAX))
    rows.append(IRow("123%45", 10, 0, SYNTAX))
    for row in rows:
        check_int(row, 64)


def test_parse_int64_base() raises:
    """Go's `parseInt64BaseTests`, which is where the odd bases live."""
    var rows = List[IRow]()
    rows.append(IRow("", 0, 0, SYNTAX))
    rows.append(IRow("0", 0, 0, OK))
    rows.append(IRow("-0", 0, 0, OK))
    rows.append(IRow("1", 0, 1, OK))
    rows.append(IRow("-1", 0, -1, OK))
    rows.append(IRow("12345", 0, 12345, OK))
    rows.append(IRow("-12345", 0, -12345, OK))
    rows.append(IRow("012345", 0, 0o12345, OK))
    rows.append(IRow("-012345", 0, -0o12345, OK))
    rows.append(IRow("0x12345", 0, 0x12345, OK))
    rows.append(IRow("-0X12345", 0, -0x12345, OK))
    rows.append(IRow("12345x", 0, 0, SYNTAX))
    rows.append(IRow("-12345x", 0, 0, SYNTAX))
    rows.append(IRow("98765432100", 0, 98765432100, OK))
    rows.append(IRow("-98765432100", 0, -98765432100, OK))
    rows.append(IRow("9223372036854775807", 0, Int64.MAX, OK))
    rows.append(IRow("-9223372036854775807", 0, -Int64.MAX, OK))
    rows.append(IRow("9223372036854775808", 0, Int64.MAX, RANGE))
    rows.append(IRow("-9223372036854775808", 0, Int64.MIN, OK))
    rows.append(IRow("9223372036854775809", 0, Int64.MAX, RANGE))
    rows.append(IRow("-9223372036854775809", 0, Int64.MIN, RANGE))

    rows.append(IRow("g", 17, 16, OK))
    rows.append(IRow("10", 25, 25, OK))
    rows.append(
        IRow(
            "holycow",
            35,
            (((((17 * 35 + 24) * 35 + 21) * 35 + 34) * 35 + 12) * 35 + 24) * 35
            + 32,
            OK,
        )
    )
    rows.append(
        IRow(
            "holycow",
            36,
            (((((17 * 36 + 24) * 36 + 21) * 36 + 34) * 36 + 12) * 36 + 24) * 36
            + 32,
            OK,
        )
    )

    rows.append(IRow("0", 2, 0, OK))
    rows.append(IRow("-1", 2, -1, OK))
    rows.append(IRow("1010", 2, 10, OK))
    rows.append(IRow("1000000000000000", 2, 1 << 15, OK))
    rows.append(
        IRow(
            "111111111111111111111111111111111111111111111111111111111111111",
            2,
            Int64.MAX,
            OK,
        )
    )
    rows.append(
        IRow(
            "1000000000000000000000000000000000000000000000000000000000000000",
            2,
            Int64.MAX,
            RANGE,
        )
    )
    rows.append(
        IRow(
            "-1000000000000000000000000000000000000000000000000000000000000000",
            2,
            Int64.MIN,
            OK,
        )
    )
    rows.append(
        IRow(
            "-1000000000000000000000000000000000000000000000000000000000000001",
            2,
            Int64.MIN,
            RANGE,
        )
    )

    rows.append(IRow("-10", 8, -8, OK))
    rows.append(IRow("57635436545", 8, 0o57635436545, OK))
    rows.append(IRow("100000000", 8, 1 << 24, OK))

    rows.append(IRow("10", 16, 16, OK))
    rows.append(IRow("-123456789abcdef", 16, -0x123456789ABCDEF, OK))
    rows.append(IRow("7fffffffffffffff", 16, Int64.MAX, OK))

    rows.append(IRow("-0x_1_2_3_4_5", 0, -0x12345, OK))
    rows.append(IRow("0x_1_2_3_4_5", 0, 0x12345, OK))
    rows.append(IRow("-_0x12345", 0, 0, SYNTAX))
    rows.append(IRow("_-0x12345", 0, 0, SYNTAX))
    rows.append(IRow("_0x12345", 0, 0, SYNTAX))
    rows.append(IRow("0x__12345", 0, 0, SYNTAX))
    rows.append(IRow("0x1__2345", 0, 0, SYNTAX))
    rows.append(IRow("0x1234__5", 0, 0, SYNTAX))
    rows.append(IRow("0x12345_", 0, 0, SYNTAX))

    rows.append(IRow("-0_1_2_3_4_5", 0, -0o12345, OK))
    rows.append(IRow("0_1_2_3_4_5", 0, 0o12345, OK))
    rows.append(IRow("-_012345", 0, 0, SYNTAX))
    rows.append(IRow("_-012345", 0, 0, SYNTAX))
    rows.append(IRow("_012345", 0, 0, SYNTAX))
    rows.append(IRow("0__12345", 0, 0, SYNTAX))
    rows.append(IRow("01234__5", 0, 0, SYNTAX))
    rows.append(IRow("012345_", 0, 0, SYNTAX))

    rows.append(IRow("+0xf", 0, 0xF, OK))
    rows.append(IRow("-0xf", 0, -0xF, OK))
    rows.append(IRow("0x+f", 0, 0, SYNTAX))
    rows.append(IRow("0x-f", 0, 0, SYNTAX))

    for row in rows:
        check_int(row, 64)


def test_parse_uint32() raises:
    """Go's `parseUint32Tests`, which is the bit size argument doing its job."""
    var rows = List[URow]()
    rows.append(URow("", 10, 0, SYNTAX))
    rows.append(URow("0", 10, 0, OK))
    rows.append(URow("1", 10, 1, OK))
    rows.append(URow("12345", 10, 12345, OK))
    rows.append(URow("012345", 10, 12345, OK))
    rows.append(URow("12345x", 10, 0, SYNTAX))
    rows.append(URow("987654321", 10, 987654321, OK))
    rows.append(URow("4294967295", 10, (UInt64(1) << 32) - 1, OK))
    rows.append(URow("4294967296", 10, (UInt64(1) << 32) - 1, RANGE))
    rows.append(URow("1_2_3_4_5", 10, 0, SYNTAX))
    rows.append(URow("_12345", 10, 0, SYNTAX))
    rows.append(URow("1__2345", 10, 0, SYNTAX))
    rows.append(URow("12345_", 10, 0, SYNTAX))
    for row in rows:
        check_uint(row, 32)


def test_parse_int32() raises:
    """Go's `parseInt32Tests`."""
    var rows = List[IRow]()
    rows.append(IRow("", 10, 0, SYNTAX))
    rows.append(IRow("0", 10, 0, OK))
    rows.append(IRow("-0", 10, 0, OK))
    rows.append(IRow("1", 10, 1, OK))
    rows.append(IRow("-1", 10, -1, OK))
    rows.append(IRow("12345", 10, 12345, OK))
    rows.append(IRow("-12345", 10, -12345, OK))
    rows.append(IRow("012345", 10, 12345, OK))
    rows.append(IRow("-012345", 10, -12345, OK))
    rows.append(IRow("12345x", 10, 0, SYNTAX))
    rows.append(IRow("-12345x", 10, 0, SYNTAX))
    rows.append(IRow("987654321", 10, 987654321, OK))
    rows.append(IRow("-987654321", 10, -987654321, OK))
    rows.append(IRow("2147483647", 10, (1 << 31) - 1, OK))
    rows.append(IRow("-2147483647", 10, -((1 << 31) - 1), OK))
    rows.append(IRow("2147483648", 10, (1 << 31) - 1, RANGE))
    rows.append(IRow("-2147483648", 10, -(1 << 31), OK))
    rows.append(IRow("2147483649", 10, (1 << 31) - 1, RANGE))
    rows.append(IRow("-2147483649", 10, -(1 << 31), RANGE))
    rows.append(IRow("-1_2_3_4_5", 10, 0, SYNTAX))
    rows.append(IRow("-_12345", 10, 0, SYNTAX))
    rows.append(IRow("_12345", 10, 0, SYNTAX))
    rows.append(IRow("1__2345", 10, 0, SYNTAX))
    rows.append(IRow("12345_", 10, 0, SYNTAX))
    rows.append(IRow("123%45", 10, 0, SYNTAX))
    for row in rows:
        check_int(row, 32)


def test_every_bit_size_holds_its_own_boundary() raises:
    """The largest value of each width parses and one more does not.

    Go covers 32 and 64 and leaves the rest to the shared code path. The
    smaller widths are where an off by one in the mask would hide, so they get
    a row each.
    """
    var widths = [1, 8, 16, 32, 64]
    for bits in widths:
        var top = UInt64.MAX >> UInt64(64 - bits)
        var text = String(top)
        assert_equal(parse_uint(text, 10, bits), top)
        var over = String(top + 1) if bits < 64 else "18446744073709551616"
        var raised = False
        try:
            _ = parse_uint(over, 10, bits)
        except e:
            raised = True
            assert_true(matches(e, ErrRange))
        assert_true(raised, "parse_uint should have overflowed at " + over)


def test_signed_boundaries_are_not_symmetric() raises:
    """One further down than up, at every width, which is two's complement."""
    var widths = [8, 16, 32, 64]
    for bits in widths:
        var top = Int64((UInt64(1) << UInt64(bits - 1)).cast[DType.int64]()) - 1
        assert_equal(parse_int(String(top), 10, bits), top)
        assert_equal(parse_int(String(-top - 1), 10, bits), -top - 1)
        # One past the top, which at 64 bits has to be written out because an
        # `Int64` cannot hold it to be printed.
        var over = String("9223372036854775808") if bits == 64 else String(
            top + 1
        )
        var raised = False
        try:
            _ = parse_int(over, 10, bits)
        except e:
            raised = True
            assert_true(matches(e, ErrRange))
        assert_true(raised, "parse_int should have overflowed")


def test_atoi() raises:
    """`atoi` is `parse_int(s, 10, 0)`, and it blames itself when it fails."""
    assert_equal(atoi("0"), 0)
    assert_equal(atoi("-42"), -42)
    assert_equal(atoi("+42"), 42)
    assert_equal(atoi("9223372036854775807"), Int(Int64.MAX))
    var raised = False
    try:
        _ = atoi("hello")
    except e:
        raised = True
        assert_true(matches(e, ErrSyntax))
        var failure = NumError.of(e)
        assert_true(Bool(failure))
        assert_equal(failure.value().func, "atoi")
        assert_equal(failure.value().num, "hello")
    assert_true(raised)


def test_an_illegal_base_and_bit_size_are_their_own_failures() raises:
    """Go collapses both into a message. Here each has a code of its own.

    This is the one place the library says more than Go does, so it is worth a
    test that says which code came out rather than only that something did.
    """
    var raised = False
    try:
        _ = parse_uint("123", 37, 64)
    except e:
        raised = True
        assert_true(matches(e, ErrBase))
    assert_true(raised)

    raised = False
    try:
        _ = parse_uint("123", 10, 65)
    except e:
        raised = True
        assert_true(matches(e, ErrBitSize))
    assert_true(raised)

    raised = False
    try:
        _ = parse_int("123", 10, -1)
    except e:
        raised = True
        assert_true(matches(e, ErrBitSize))
    assert_true(raised)


def test_the_failure_carries_the_input_back() raises:
    """`NumError.of` reads the whole shape, and `parse_int` blames the sign it
    stripped as part of the input rather than reporting the tail it parsed.
    """
    var raised = False
    try:
        _ = parse_int("-12345x", 0, 64)
    except e:
        raised = True
        var failure = NumError.of(e)
        assert_true(Bool(failure))
        assert_equal(failure.value().func, "parse_int")
        assert_equal(failure.value().num, "-12345x")
        assert_equal(
            failure.value().error(),
            'strconv.parse_int: parsing "-12345x": invalid syntax',
        )
    assert_true(raised)


def test_of_declines_an_error_from_somewhere_else() raises:
    """Go's type assertion fails on someone else's error and so does this."""
    var raised = False
    try:
        raise Error("not from here")
    except e:
        raised = True
        assert_true(not NumError.of(e))
    assert_true(raised)
