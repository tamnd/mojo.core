"""Text to floats. Go's `atof_test.go`.

Go's `atoftests` and `atof32tests`, row for row, each read back through
`format_float` the way Go's `testAtof` does, so a row is a pair of strings and
the float in the middle never has to be spelled out.

Go records the expected error as a value and compares it. Here the failure is a
raise carrying a code, so a row says which code it wants. Go's `ErrRange` rows
also carry the clamped value, an infinity or a zero, which a raise cannot, and
the rows keep the string anyway so that the table still reads as Go's does.

`TestAtofSlow` and `TestAtofRandom` are not here. The first flips a test only
switch Go's package exports to force the slow path, and the second compares
against Go's own formatter. The differential run against Go recorded in the
pull request covers both.
"""

from std.memory import bitcast
from std.testing import assert_equal, assert_true

from core.errors import matches
from core.errors.codes import Code, ErrRange, ErrSyntax

from core.strconv import NumError, format_float, parse_float


comptime OK = 0
comptime SYNTAX = 1
comptime RANGE = 2

comptime G = UInt8(ord("g"))


struct Row(Copyable, Movable):
    """An input, what Go prints it back as, and which failure if any."""

    var input: String
    var out: String
    var err: Int

    def __init__(out self, var input: String, var out: String, err: Int):
        self.input = input^
        self.out = out^
        self.err = err


def repeat(s: String, n: Int) -> String:
    """`s` written `n` times, standing in for Go's `strings.Repeat`.

    `core.strings` is not a dependency of this package's tests and the three
    rows that want it are long inputs rather than interesting strings.
    """
    var text = String()
    for _ in range(n):
        text += s
    return text^


def _wanted(err: Int) -> Code:
    return ErrSyntax if err == SYNTAX else ErrRange


def check(row: Row, bit_size: Int) raises:
    """One row at one width, printed back at the same width."""
    if row.err == OK:
        var f = parse_float(row.input, bit_size)
        assert_equal(format_float(f, G, -1, bit_size), row.out)
        return
    var raised = False
    try:
        _ = parse_float(row.input, bit_size)
    except e:
        raised = True
        assert_true(
            matches(e, _wanted(row.err)),
            "parse_float(" + row.input + ") raised the wrong code",
        )
        var failure = NumError.of(e)
        assert_true(Bool(failure))
        assert_equal(failure.value().func, "parse_float")
    assert_true(raised, "parse_float(" + row.input + ") should have failed")


def atof_rows() -> List[Row]:
    """Go's `atoftests`."""
    var rows = List[Row]()
    rows.append(Row("", "0", SYNTAX))
    rows.append(Row("1", "1", OK))
    rows.append(Row("+1", "1", OK))
    rows.append(Row("1x", "0", SYNTAX))
    rows.append(Row("1.1.", "0", SYNTAX))
    rows.append(Row("1e23", "1e+23", OK))
    rows.append(Row("1E23", "1e+23", OK))
    rows.append(Row("100000000000000000000000", "1e+23", OK))
    rows.append(Row("1e-100", "1e-100", OK))
    rows.append(Row("123456700", "1.234567e+08", OK))
    rows.append(Row("99999999999999974834176", "9.999999999999997e+22", OK))
    rows.append(Row("100000000000000000000001", "1.0000000000000001e+23", OK))
    rows.append(Row("100000000000000008388608", "1.0000000000000001e+23", OK))
    rows.append(Row("100000000000000016777215", "1.0000000000000001e+23", OK))
    rows.append(Row("100000000000000016777216", "1.0000000000000003e+23", OK))
    rows.append(Row("-1", "-1", OK))
    rows.append(Row("-0.1", "-0.1", OK))
    rows.append(Row("-0", "-0", OK))
    rows.append(Row("1e-20", "1e-20", OK))
    rows.append(Row("625e-3", "0.625", OK))

    # Hexadecimal floating point.
    rows.append(Row("0x1p0", "1", OK))
    rows.append(Row("0x1p1", "2", OK))
    rows.append(Row("0x1p-1", "0.5", OK))
    rows.append(Row("0x1ep-1", "15", OK))
    rows.append(Row("-0x1ep-1", "-15", OK))
    rows.append(Row("-0x1_ep-1", "-15", OK))
    rows.append(Row("0x1p-200", "6.223015277861142e-61", OK))
    rows.append(Row("0x1p200", "1.6069380442589903e+60", OK))
    rows.append(Row("0x1fFe2.p0", "131042", OK))
    rows.append(Row("0x1fFe2.P0", "131042", OK))
    rows.append(Row("-0x2p3", "-16", OK))
    rows.append(Row("0x0.fp4", "15", OK))
    rows.append(Row("0x0.fp0", "0.9375", OK))
    rows.append(Row("0x1e2", "0", SYNTAX))
    rows.append(Row("1p2", "0", SYNTAX))

    # zeros
    rows.append(Row("0", "0", OK))
    rows.append(Row("0e0", "0", OK))
    rows.append(Row("-0e0", "-0", OK))
    rows.append(Row("+0e0", "0", OK))
    rows.append(Row("0e-0", "0", OK))
    rows.append(Row("-0e-0", "-0", OK))
    rows.append(Row("+0e-0", "0", OK))
    rows.append(Row("0e+0", "0", OK))
    rows.append(Row("-0e+0", "-0", OK))
    rows.append(Row("+0e+0", "0", OK))
    rows.append(Row("0e+01234567890123456789", "0", OK))
    rows.append(Row("0.00e-01234567890123456789", "0", OK))
    rows.append(Row("-0e+01234567890123456789", "-0", OK))
    rows.append(Row("-0.00e-01234567890123456789", "-0", OK))
    rows.append(Row("0x0p+01234567890123456789", "0", OK))
    rows.append(Row("0x0.00p-01234567890123456789", "0", OK))
    rows.append(Row("-0x0p+01234567890123456789", "-0", OK))
    rows.append(Row("-0x0.00p-01234567890123456789", "-0", OK))

    # A zero with an exponent near the edge of the table, Go issue 15364.
    rows.append(Row("0e291", "0", OK))
    rows.append(Row("0e292", "0", OK))
    rows.append(Row("0e347", "0", OK))
    rows.append(Row("0e348", "0", OK))
    rows.append(Row("-0e291", "-0", OK))
    rows.append(Row("-0e292", "-0", OK))
    rows.append(Row("-0e347", "-0", OK))
    rows.append(Row("-0e348", "-0", OK))
    rows.append(Row("0x0p126", "0", OK))
    rows.append(Row("0x0p127", "0", OK))
    rows.append(Row("0x0p128", "0", OK))
    rows.append(Row("0x0p129", "0", OK))
    rows.append(Row("0x0p130", "0", OK))
    rows.append(Row("0x0p1022", "0", OK))
    rows.append(Row("0x0p1023", "0", OK))
    rows.append(Row("0x0p1024", "0", OK))
    rows.append(Row("0x0p1025", "0", OK))
    rows.append(Row("0x0p1026", "0", OK))
    rows.append(Row("-0x0p126", "-0", OK))
    rows.append(Row("-0x0p127", "-0", OK))
    rows.append(Row("-0x0p128", "-0", OK))
    rows.append(Row("-0x0p129", "-0", OK))
    rows.append(Row("-0x0p130", "-0", OK))
    rows.append(Row("-0x0p1022", "-0", OK))
    rows.append(Row("-0x0p1023", "-0", OK))
    rows.append(Row("-0x0p1024", "-0", OK))
    rows.append(Row("-0x0p1025", "-0", OK))
    rows.append(Row("-0x0p1026", "-0", OK))

    # NaNs
    rows.append(Row("nan", "NaN", OK))
    rows.append(Row("NaN", "NaN", OK))
    rows.append(Row("NAN", "NaN", OK))

    # Infinities
    rows.append(Row("inf", "+Inf", OK))
    rows.append(Row("-Inf", "-Inf", OK))
    rows.append(Row("+INF", "+Inf", OK))
    rows.append(Row("-Infinity", "-Inf", OK))
    rows.append(Row("+INFINITY", "+Inf", OK))
    rows.append(Row("Infinity", "+Inf", OK))

    # The largest float64.
    rows.append(Row("1.7976931348623157e308", "1.7976931348623157e+308", OK))
    rows.append(Row("-1.7976931348623157e308", "-1.7976931348623157e+308", OK))
    rows.append(Row("0x1.fffffffffffffp1023", "1.7976931348623157e+308", OK))
    rows.append(Row("-0x1.fffffffffffffp1023", "-1.7976931348623157e+308", OK))
    rows.append(Row("0x1fffffffffffffp+971", "1.7976931348623157e+308", OK))
    rows.append(Row("-0x1fffffffffffffp+971", "-1.7976931348623157e+308", OK))
    rows.append(Row("0x.1fffffffffffffp1027", "1.7976931348623157e+308", OK))
    rows.append(Row("-0x.1fffffffffffffp1027", "-1.7976931348623157e+308", OK))

    # The next one up, which does not fit.
    rows.append(Row("1.7976931348623159e308", "+Inf", RANGE))
    rows.append(Row("-1.7976931348623159e308", "-Inf", RANGE))
    rows.append(Row("0x1p1024", "+Inf", RANGE))
    rows.append(Row("-0x1p1024", "-Inf", RANGE))
    rows.append(Row("0x2p1023", "+Inf", RANGE))
    rows.append(Row("-0x2p1023", "-Inf", RANGE))
    rows.append(Row("0x.1p1028", "+Inf", RANGE))
    rows.append(Row("-0x.1p1028", "-Inf", RANGE))
    rows.append(Row("0x.2p1027", "+Inf", RANGE))
    rows.append(Row("-0x.2p1027", "-Inf", RANGE))

    # The border is at ...158079. Just under it.
    rows.append(Row("1.7976931348623158e308", "1.7976931348623157e+308", OK))
    rows.append(Row("-1.7976931348623158e308", "-1.7976931348623157e+308", OK))
    rows.append(
        Row("0x1.fffffffffffff7fffp1023", "1.7976931348623157e+308", OK)
    )
    rows.append(
        Row("-0x1.fffffffffffff7fffp1023", "-1.7976931348623157e+308", OK)
    )
    # And just over it.
    rows.append(Row("1.797693134862315808e308", "+Inf", RANGE))
    rows.append(Row("-1.797693134862315808e308", "-Inf", RANGE))
    rows.append(Row("0x1.fffffffffffff8p1023", "+Inf", RANGE))
    rows.append(Row("-0x1.fffffffffffff8p1023", "-Inf", RANGE))
    rows.append(Row("0x1fffffffffffff.8p+971", "+Inf", RANGE))
    rows.append(Row("-0x1fffffffffffff8p+967", "-Inf", RANGE))
    rows.append(Row("0x.1fffffffffffff8p1027", "+Inf", RANGE))
    rows.append(Row("-0x.1fffffffffffff9p1027", "-Inf", RANGE))

    # A little too large.
    rows.append(Row("1e308", "1e+308", OK))
    rows.append(Row("2e308", "+Inf", RANGE))
    rows.append(Row("1e309", "+Inf", RANGE))
    rows.append(Row("0x1p1025", "+Inf", RANGE))

    # Way too large.
    rows.append(Row("1e310", "+Inf", RANGE))
    rows.append(Row("-1e310", "-Inf", RANGE))
    rows.append(Row("1e400", "+Inf", RANGE))
    rows.append(Row("-1e400", "-Inf", RANGE))
    rows.append(Row("1e400000", "+Inf", RANGE))
    rows.append(Row("-1e400000", "-Inf", RANGE))
    rows.append(Row("0x1p1030", "+Inf", RANGE))
    rows.append(Row("0x1p2000", "+Inf", RANGE))
    rows.append(Row("0x1p2000000000", "+Inf", RANGE))
    rows.append(Row("-0x1p1030", "-Inf", RANGE))
    rows.append(Row("-0x1p2000", "-Inf", RANGE))
    rows.append(Row("-0x1p2000000000", "-Inf", RANGE))

    # Subnormal.
    rows.append(Row("1e-305", "1e-305", OK))
    rows.append(Row("1e-306", "1e-306", OK))
    rows.append(Row("1e-307", "1e-307", OK))
    rows.append(Row("1e-308", "1e-308", OK))
    rows.append(Row("1e-309", "1e-309", OK))
    rows.append(Row("1e-310", "1e-310", OK))
    rows.append(Row("1e-322", "1e-322", OK))
    # The smallest subnormal.
    rows.append(Row("5e-324", "5e-324", OK))
    rows.append(Row("4e-324", "5e-324", OK))
    rows.append(Row("3e-324", "5e-324", OK))
    # Too small, which is a zero and not a failure.
    rows.append(Row("2e-324", "0", OK))
    # Way too small.
    rows.append(Row("1e-350", "0", OK))
    rows.append(Row("1e-400000", "0", OK))

    # Near the bottom of the normal range and into the subnormals. The comment
    # on each is the float it lands on.
    rows.append(Row("0x2.00000000000000p-1010", "1.8227805048890994e-304", OK))
    rows.append(Row("0x1.fffffffffffff0p-1010", "1.8227805048890992e-304", OK))
    rows.append(Row("0x1.fffffffffffff7p-1010", "1.8227805048890992e-304", OK))
    rows.append(Row("0x1.fffffffffffff8p-1010", "1.8227805048890994e-304", OK))
    rows.append(Row("0x1.fffffffffffff9p-1010", "1.8227805048890994e-304", OK))

    rows.append(Row("0x2.00000000000000p-1022", "4.450147717014403e-308", OK))
    rows.append(Row("0x1.fffffffffffff0p-1022", "4.4501477170144023e-308", OK))
    rows.append(Row("0x1.fffffffffffff7p-1022", "4.4501477170144023e-308", OK))
    rows.append(Row("0x1.fffffffffffff8p-1022", "4.450147717014403e-308", OK))
    rows.append(Row("0x1.fffffffffffff9p-1022", "4.450147717014403e-308", OK))

    rows.append(Row("0x1.00000000000000p-1022", "2.2250738585072014e-308", OK))
    rows.append(Row("0x0.fffffffffffff0p-1022", "2.225073858507201e-308", OK))
    rows.append(Row("0x0.ffffffffffffe0p-1022", "2.2250738585072004e-308", OK))
    rows.append(Row("0x0.ffffffffffffe7p-1022", "2.2250738585072004e-308", OK))
    rows.append(Row("0x1.ffffffffffffe8p-1023", "2.225073858507201e-308", OK))
    rows.append(Row("0x1.ffffffffffffe9p-1023", "2.225073858507201e-308", OK))

    rows.append(Row("0x0.00000003fffff0p-1022", "2.072261e-317", OK))
    rows.append(Row("0x0.00000003456780p-1022", "1.694649e-317", OK))
    rows.append(Row("0x0.00000003456787p-1022", "1.694649e-317", OK))
    # Exactly half, so it goes to the even one.
    rows.append(Row("0x0.00000003456788p-1022", "1.694649e-317", OK))
    rows.append(Row("0x0.00000003456790p-1022", "1.6946496e-317", OK))
    rows.append(Row("0x0.00000003456789p-1022", "1.6946496e-317", OK))
    # Half, and then one more digit a long way down.
    rows.append(
        Row(
            "0x0.0000000345678800000000000000000000000001p-1022",
            "1.6946496e-317",
            OK,
        )
    )

    rows.append(Row("0x0.000000000000f0p-1022", "7.4e-323", OK))
    rows.append(Row("0x0.00000000000060p-1022", "3e-323", OK))
    rows.append(Row("0x0.00000000000058p-1022", "3e-323", OK))
    rows.append(Row("0x0.00000000000057p-1022", "2.5e-323", OK))
    rows.append(Row("0x0.00000000000050p-1022", "2.5e-323", OK))

    rows.append(Row("0x0.00000000000010p-1022", "5e-324", OK))
    rows.append(Row("0x0.000000000000081p-1022", "5e-324", OK))
    rows.append(Row("0x0.00000000000008p-1022", "0", OK))
    rows.append(Row("0x0.00000000000007fp-1022", "0", OK))

    # An exponent that would overflow the accumulator it is read into.
    rows.append(Row("1e-4294967296", "0", OK))
    rows.append(Row("1e+4294967296", "+Inf", RANGE))
    rows.append(Row("1e-18446744073709551616", "0", OK))
    rows.append(Row("1e+18446744073709551616", "+Inf", RANGE))
    rows.append(Row("0x1p-4294967296", "0", OK))
    rows.append(Row("0x1p+4294967296", "+Inf", RANGE))
    rows.append(Row("0x1p-18446744073709551616", "0", OK))
    rows.append(Row("0x1p+18446744073709551616", "+Inf", RANGE))

    # Not a number at all.
    rows.append(Row("1e", "0", SYNTAX))
    rows.append(Row("1e-", "0", SYNTAX))
    rows.append(Row(".e-1", "0", SYNTAX))
    rows.append(Row("1\x00.2", "0", SYNTAX))
    rows.append(Row("0x", "0", SYNTAX))
    rows.append(Row("0x.", "0", SYNTAX))
    rows.append(Row("0x1", "0", SYNTAX))
    rows.append(Row("0x.1", "0", SYNTAX))
    rows.append(Row("0x1p", "0", SYNTAX))
    rows.append(Row("0x.1p", "0", SYNTAX))
    rows.append(Row("0x1p+", "0", SYNTAX))
    rows.append(Row("0x.1p+", "0", SYNTAX))
    rows.append(Row("0x1p-", "0", SYNTAX))
    rows.append(Row("0x.1p-", "0", SYNTAX))
    rows.append(Row("0x1p+2", "4", OK))
    rows.append(Row("0x.1p+2", "0.25", OK))
    rows.append(Row("0x1p-2", "0.25", OK))
    rows.append(Row("0x.1p-2", "0.015625", OK))

    # The value that once hung Java.
    # https://www.exploringbinary.com/java-hangs-when-converting-2-2250738585072012e-308/
    rows.append(Row("2.2250738585072012e-308", "2.2250738585072014e-308", OK))
    # And the one that once hung PHP.
    # https://www.exploringbinary.com/php-hangs-on-numeric-value-2-2250738585072011e-308/
    rows.append(Row("2.2250738585072011e-308", "2.225073858507201e-308", OK))

    # A very large number, which Go's fast path once got wrong.
    rows.append(Row("4.630813248087435e+307", "4.630813248087435e+307", OK))

    # A different kind of very large number: more digits than any float needs.
    rows.append(Row("22.222222222222222", "22.22222222222222", OK))
    rows.append(Row("2." + repeat("2", 4000) + "e+1", "22.22222222222222", OK))
    rows.append(Row("0x1.1111111111111p222", "7.18931911124017e+66", OK))
    rows.append(Row("0x2.2222222222222p221", "7.18931911124017e+66", OK))
    rows.append(
        Row("0x2." + repeat("2", 4000) + "p221", "7.18931911124017e+66", OK)
    )

    # Exactly half way between 1 and the float above it, so it goes down to the
    # even one.
    rows.append(
        Row("1.00000000000000011102230246251565404236316680908203125", "1", OK)
    )
    rows.append(Row("0x1.00000000000008p0", "1", OK))
    # A shade lower, still down.
    rows.append(
        Row("1.00000000000000011102230246251565404236316680908203124", "1", OK)
    )
    rows.append(Row("0x1.00000000000007Fp0", "1", OK))
    # A shade higher, up.
    rows.append(
        Row(
            "1.00000000000000011102230246251565404236316680908203126",
            "1.0000000000000002",
            OK,
        )
    )
    rows.append(Row("0x1.000000000000081p0", "1.0000000000000002", OK))
    rows.append(Row("0x1.00000000000009p0", "1.0000000000000002", OK))
    # Higher, but only if the last digit of ten thousand is read.
    var zeros = repeat("0", 10000)
    rows.append(
        Row(
            "1.00000000000000011102230246251565404236316680908203125"
            + zeros
            + "1",
            "1.0000000000000002",
            OK,
        )
    )
    rows.append(
        Row("0x1.00000000000008" + zeros + "1p0", "1.0000000000000002", OK)
    )

    # Half way between the float above 1 and the one above that, so it goes up
    # to the even one this time.
    rows.append(
        Row(
            "1.00000000000000033306690738754696212708950042724609375",
            "1.0000000000000004",
            OK,
        )
    )
    rows.append(Row("0x1.00000000000018p0", "1.0000000000000004", OK))

    # Half way between two floats a long way up, Go issue 36657.
    rows.append(
        Row("1090544144181609348671888949248", "1.0905441441816093e+30", OK)
    )
    # A shade above, which rounds up.
    rows.append(
        Row("1090544144181609348835077142190", "1.0905441441816094e+30", OK)
    )

    # Underscores, legal only between digits of the same part.
    rows.append(Row("1_23.50_0_0e+1_2", "1.235e+14", OK))
    rows.append(Row("-_123.5e+12", "0", SYNTAX))
    rows.append(Row("+_123.5e+12", "0", SYNTAX))
    rows.append(Row("_123.5e+12", "0", SYNTAX))
    rows.append(Row("1__23.5e+12", "0", SYNTAX))
    rows.append(Row("123_.5e+12", "0", SYNTAX))
    rows.append(Row("123._5e+12", "0", SYNTAX))
    rows.append(Row("123.5_e+12", "0", SYNTAX))
    rows.append(Row("123.5__0e+12", "0", SYNTAX))
    rows.append(Row("123.5e_+12", "0", SYNTAX))
    rows.append(Row("123.5e+_12", "0", SYNTAX))
    rows.append(Row("123.5e_-12", "0", SYNTAX))
    rows.append(Row("123.5e-_12", "0", SYNTAX))
    rows.append(Row("123.5e+1__2", "0", SYNTAX))
    rows.append(Row("123.5e+12_", "0", SYNTAX))

    rows.append(Row("0x_1_2.3_4_5p+1_2", "74565", OK))
    rows.append(Row("-_0x12.345p+12", "0", SYNTAX))
    rows.append(Row("+_0x12.345p+12", "0", SYNTAX))
    rows.append(Row("_0x12.345p+12", "0", SYNTAX))
    rows.append(Row("0x__12.345p+12", "0", SYNTAX))
    rows.append(Row("0x1__2.345p+12", "0", SYNTAX))
    rows.append(Row("0x12_.345p+12", "0", SYNTAX))
    rows.append(Row("0x12._345p+12", "0", SYNTAX))
    rows.append(Row("0x12.3__45p+12", "0", SYNTAX))
    rows.append(Row("0x12.345_p+12", "0", SYNTAX))
    rows.append(Row("0x12.345p_+12", "0", SYNTAX))
    rows.append(Row("0x12.345p+_12", "0", SYNTAX))
    rows.append(Row("0x12.345p_-12", "0", SYNTAX))
    rows.append(Row("0x12.345p-_12", "0", SYNTAX))
    rows.append(Row("0x12.345p+1__2", "0", SYNTAX))
    rows.append(Row("0x12.345p+12_", "0", SYNTAX))

    rows.append(Row("1e100x", "0", SYNTAX))
    rows.append(Row("1e1000x", "0", SYNTAX))
    return rows^


def atof32_rows() -> List[Row]:
    """Go's `atof32tests`, which are read and printed at 32 bits."""
    var rows = List[Row]()
    # Hexadecimal.
    rows.append(Row("0x1p-100", "7.888609e-31", OK))
    rows.append(Row("0x1p100", "1.2676506e+30", OK))

    # Exactly half way between 1 and the float above it, so it goes down to the
    # even one.
    rows.append(Row("1.000000059604644775390625", "1", OK))
    rows.append(Row("0x1.000001p0", "1", OK))
    # A shade lower.
    rows.append(Row("1.000000059604644775390624", "1", OK))
    rows.append(Row("0x1.0000008p0", "1", OK))
    rows.append(Row("0x1.000000fp0", "1", OK))
    # A shade higher.
    rows.append(Row("1.000000059604644775390626", "1.0000001", OK))
    rows.append(Row("0x1.000002p0", "1.0000001", OK))
    rows.append(Row("0x1.0000018p0", "1.0000001", OK))
    rows.append(Row("0x1.0000011p0", "1.0000001", OK))
    # Higher, but only if the last digit of ten thousand is read.
    var zeros = repeat("0", 10000)
    rows.append(
        Row("1.000000059604644775390625" + zeros + "1", "1.0000001", OK)
    )
    rows.append(Row("0x1.000001" + zeros + "1p0", "1.0000001", OK))

    # The largest float32, which is (1<<128) * (1 - 2^-24).
    rows.append(
        Row("340282346638528859811704183484516925440", "3.4028235e+38", OK)
    )
    rows.append(
        Row("-340282346638528859811704183484516925440", "-3.4028235e+38", OK)
    )
    rows.append(Row("0x.ffffffp128", "3.4028235e+38", OK))
    rows.append(Row("-0x.ffffffp128", "-3.4028235e+38", OK))
    # The next one up, which does not fit.
    rows.append(Row("3.4028236e38", "+Inf", RANGE))
    rows.append(Row("-3.4028236e38", "-Inf", RANGE))
    rows.append(Row("0x1.0p128", "+Inf", RANGE))
    rows.append(Row("-0x1.0p128", "-Inf", RANGE))
    # The border is at 3.40282356779...e+38. Just under it.
    rows.append(Row("3.402823567e38", "3.4028235e+38", OK))
    rows.append(Row("-3.402823567e38", "-3.4028235e+38", OK))
    rows.append(Row("0x.ffffff7fp128", "3.4028235e+38", OK))
    rows.append(Row("-0x.ffffff7fp128", "-3.4028235e+38", OK))
    # And just over it.
    rows.append(Row("3.4028235678e38", "+Inf", RANGE))
    rows.append(Row("-3.4028235678e38", "-Inf", RANGE))
    rows.append(Row("0x.ffffff8p128", "+Inf", RANGE))
    rows.append(Row("-0x.ffffff8p128", "-Inf", RANGE))

    # Subnormal, which for a float32 starts below 2^-126.
    rows.append(Row("1e-38", "1e-38", OK))
    rows.append(Row("1e-39", "1e-39", OK))
    rows.append(Row("1e-40", "1e-40", OK))
    rows.append(Row("1e-41", "1e-41", OK))
    rows.append(Row("1e-42", "1e-42", OK))
    rows.append(Row("1e-43", "1e-43", OK))
    rows.append(Row("1e-44", "1e-44", OK))
    # 4p-149 is 5.6e-45.
    rows.append(Row("6e-45", "6e-45", OK))
    rows.append(Row("5e-45", "6e-45", OK))

    # The smallest subnormal, 1p-149, which is 1.4e-45.
    rows.append(Row("1e-45", "1e-45", OK))
    rows.append(Row("2e-45", "1e-45", OK))
    rows.append(Row("3e-45", "3e-45", OK))

    # Near the bottom of the normal range and into the subnormals.
    rows.append(Row("0x0.89aBcDp-125", "1.2643093e-38", OK))
    rows.append(Row("0x0.8000000p-125", "1.1754944e-38", OK))
    rows.append(Row("0x0.1234560p-125", "1.671814e-39", OK))
    rows.append(Row("0x0.1234567p-125", "1.671814e-39", OK))
    rows.append(Row("0x0.1234568p-125", "1.671814e-39", OK))
    rows.append(Row("0x0.1234569p-125", "1.671815e-39", OK))
    rows.append(Row("0x0.1234570p-125", "1.671815e-39", OK))
    rows.append(Row("0x0.0000010p-125", "1e-45", OK))
    rows.append(Row("0x0.00000081p-125", "1e-45", OK))
    rows.append(Row("0x0.0000008p-125", "0", OK))
    rows.append(Row("0x0.0000007p-125", "0", OK))

    # 2^92 is 8388608p+69, an exact power of two that needs eight decimal
    # digits to come back. The float32 below it is 16777215p+68, which is
    # 4.95175986e+27, so the half way point is 4.951760009 and a formatter that
    # thinks the one below is 8388607p+69 shortens this to 4.95176e+27.
    rows.append(Row("4951760157141521099596496896", "4.9517602e+27", OK))
    return rows^


def test_parse_float() raises:
    """Go's `atoftests` at 64 bits."""
    for row in atof_rows():
        check(row, 64)


def test_parse_float_32_of_the_64_bit_table() raises:
    """Go's `testAtof` again at 32 bits, over the rows whose value is exactly a
    `Float32`.

    Go reads the value out of the failing rows as well, because a failure there
    still hands back an infinity. A raise carries no value, so the failing rows
    are checked for the same code instead: a number too big for a `Float64` is
    too big for a `Float32` too, and nothing that is a syntax error at one width
    parses at the other.
    """
    for row in atof_rows():
        if row.err != OK:
            check(row, 32)
            continue
        var f = parse_float(row.input, 64)
        if Float64(Float32(f)) != f:
            continue
        var narrow = parse_float(row.input, 32)
        assert_equal(Float64(Float32(narrow)), narrow)
        assert_equal(format_float(narrow, G, -1, 32), row.out)


def test_parse_float_32() raises:
    """Go's `atof32tests`, read and printed at 32 bits."""
    for row in atof32_rows():
        check(row, 32)
        if row.err == OK:
            var f = parse_float(row.input, 32)
            assert_equal(
                Float64(Float32(f)),
                f,
                "parse_float(" + row.input + ", 32) is not a Float32",
            )


def test_round_trip() raises:
    """Go's `TestRoundTrip`, two values that come out wrong on a machine whose
    floating point unit is left in eighty bit mode.
    """
    var f = Float64(8865794286000691 << 39)
    assert_equal(format_float(f, G, -1, 64), "4.87402195346389e+27")
    assert_equal(parse_float("4.87402195346389e+27", 64), f)

    var g = Float64(8865794286000692 << 39)
    assert_equal(format_float(g, G, -1, 64), "4.8740219534638903e+27")
    assert_equal(parse_float("4.8740219534638903e+27", 64), g)


# slow: two million float32 values, which is a job for CI rather than for a
# local run
def test_round_trip_32() raises:
    """Go's `TestRoundTrip32`: the same stride through every finite `Float32`,
    negating every other one, formatted and read back.
    """
    var step = UInt32(997)
    var limit = UInt32(0xFF) << 23
    var i = UInt32(0)
    while i < limit:
        var f = bitcast[DType.float32](i)
        if (i & 1) == 1:
            f = -f
        var text = format_float(Float64(f), G, -1, 32)
        var parsed = parse_float(text, 32)
        assert_equal(Float64(Float32(parsed)), parsed)
        assert_equal(Float32(parsed), f)
        i += step


def test_any_bit_size_is_taken() raises:
    """Go issue 42297: enough code in the wild calls this with the base it meant
    for `parse_int` that anything other than 32 is read as 64 rather than
    refused, and this does the same.
    """
    var sizes: List[Int] = [0, 10, 100, 128]
    for size in sizes:
        assert_equal(parse_float("1.5e308", size), 1.5e308)
