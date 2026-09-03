"""Go's `TestFloatSetFloat64String` through `TestFloatText`, from
`floatconv_test.go`.

Text in and text out. Reading covers every mantissa base a `Float` accepts and
every way of writing an exponent, including the underscores Go allows in a
literal and the places they are not allowed. Writing covers the eight formats,
the shortest representation, and the widths where a digit has to be rounded.

Go's `TestFloatFormat` and `TestFloatScan` are not here. They go through
`fmt.Sprintf` and `fmt.Fscanf`, which are the `Format` and `Scan` methods this
port does not have, and `tools/parity/waivers.toml` says why.

Most rows are checked twice: once against the string Go's table holds, and once
against `core.strconv`, which formats and parses machine numbers by a different
route. Where the two have to agree they do, and the rows where they cannot are
the ones `core.strconv` has no syntax for.
"""

from std.testing import assert_equal, assert_raises

from core.math import float64bits
from core.math.bits import leading_zeros64
from core.strconv import format_float, parse_float, parse_int
import core.math.big as big
from core.math.big.rounding import RoundingMode


def _mode_named(name: String) raises -> RoundingMode:
    """The rounding mode Go prints as `name`, with an empty string standing for
    the one a fresh `Float` already has.

    Go writes that default as `^RoundingMode(0)`, a value no mode ever takes,
    and leaves the mode alone when it sees it.
    """
    if name == "":
        return big.ToNearestEven
    if name == "ToNearestEven":
        return big.ToNearestEven
    if name == "ToNearestAway":
        return big.ToNearestAway
    if name == "ToZero":
        return big.ToZero
    if name == "AwayFromZero":
        return big.AwayFromZero
    if name == "ToNegativeInf":
        return big.ToNegativeInf
    if name == "ToPositiveInf":
        return big.ToPositiveInf
    raise Error("no such rounding mode: " + name)


def test_set_string() raises:
    # Go's `TestFloatSetFloat64String`, the rows that parse. The columns are
    # the text and the number it means, written the way `core.strconv` reads
    # it so that the row says what it means rather than a bit pattern.
    var rows: List[List[String]] = [
        # The plain forms.
        ["0", "0"],
        ["-0", "-0"],
        ["+0", "0"],
        ["1", "1"],
        ["-1", "-1"],
        ["+1", "1"],
        ["1.234", "1.234"],
        ["-1.234", "-1.234"],
        ["+1.234", "1.234"],
        [".1", "0.1"],
        ["1.", "1"],
        ["+1.", "1"],
        # A zero keeps its sign whatever exponent follows it.
        ["0e100", "0"],
        ["-0e+100", "-0"],
        ["+0e-100", "0"],
        ["0E100", "0"],
        ["-0E+100", "-0"],
        ["+0E-100", "0"],
        # The decimal exponent, in both cases and with either sign.
        ["1.e10", "1e10"],
        ["1e+10", "1e10"],
        ["+1e-10", "1e-10"],
        ["1E10", "1e10"],
        ["1.E+10", "1e10"],
        ["+1E-10", "1e-10"],
        # The infinities, in both cases.
        ["Inf", "+Inf"],
        ["+Inf", "+Inf"],
        ["-Inf", "-Inf"],
        ["inf", "+Inf"],
        ["+inf", "+Inf"],
        ["-inf", "-Inf"],
        # Ordinary decimals.
        ["3.14159265", "3.14159265"],
        ["-687436.79457e-245", "-687436.79457e-245"],
        ["-687436.79457E245", "-687436.79457e245"],
        [".0000000000000000000000000000000000000001", "1e-40"],
        ["+10000000000000000000000000000000000000000e-0", "1e40"],
        # A decimal mantissa with a binary exponent.
        ["0p0", "0"],
        ["-0p0", "-0"],
        ["1p10", "1024"],
        ["1p+10", "1024"],
        ["+1p-10", "0.0009765625"],
        ["1024p-12", "0.25"],
        ["-1p10", "-1024"],
        ["1.5p1", "3"],
        # A binary mantissa with a decimal exponent.
        ["0b0", "0"],
        ["-0b0", "-0"],
        ["0b0e+10", "0"],
        ["-0b0e-10", "-0"],
        ["0b1010", "10"],
        ["0B1010E2", "1000"],
        ["0b.1", "0.5"],
        ["0b.001", "0.125"],
        ["0b.001e3", "125"],
        # A binary mantissa with a binary exponent.
        ["0b0p+10", "0"],
        ["-0b0p-10", "-0"],
        ["0b.1010p4", "10"],
        ["0b1p-1", "0.5"],
        ["0b001p-3", "0.125"],
        ["0b.001p3", "1"],
        ["0b0.01p2", "1"],
        ["0b0.01P+2", "1"],
        # An octal mantissa with a decimal exponent.
        ["0o0", "0"],
        ["-0o0", "-0"],
        ["0o0e+10", "0"],
        ["-0o0e-10", "-0"],
        ["0o12", "10"],
        ["0O12E2", "1000"],
        ["0o.4", "0.5"],
        ["0o.01", "0.015625"],
        ["0o.01e3", "15.625"],
        # An octal mantissa with a binary exponent.
        ["0o0p+10", "0"],
        ["-0o0p-10", "-0"],
        ["0o.12p6", "10"],
        ["0o4p-3", "0.5"],
        ["0o0014p-6", "0.1875"],
        ["0o.001p9", "1"],
        ["0o0.01p7", "2"],
        ["0O0.01P+2", "0.0625"],
        # A hexadecimal mantissa, which only takes a binary exponent.
        ["0x0", "0"],
        ["-0x0", "-0"],
        ["0x0p+10", "0"],
        ["-0x0p-10", "-0"],
        ["0xff", "255"],
        ["0X.8p1", "1"],
        ["-0X0.00008p16", "-0.5"],
        ["-0X0.00008P+16", "-0.5"],
        ["0x0.0000000000001p-1022", "5e-324"],
        ["0x1.fffffffffffffp1023", "1.7976931348623157e308"],
        # Underscores between digits, which a Go literal allows.
        ["0_0", "0"],
        ["1_000.", "1000"],
        ["1_2_3.4_5_6", "123.456"],
        ["1.0e0_0", "1"],
        ["1p+1_0", "1024"],
        ["0b_1000", "8"],
        ["0b_1011_1101", "189"],
        ["0x_f0_0d_1eP+0_8", "4027391488"],
    ]
    for r in rows:
        var x = big.Float()
        x.set_prec(53)
        x.set_string(r[0])

        var want = big.Float()
        want.set_float64(parse_float(r[1], 64))
        assert_equal(x.cmp(want), 0, r[0])
        assert_equal(x.signbit(), want.signbit(), r[0])


def test_set_string_rejects_bad_syntax() raises:
    # The other half of Go's `TestFloatSetFloat64String`, the rows that do not
    # parse. Go's `SetString` returns a false and this raises, which in a test
    # is the same thing.
    var bad: List[String] = [
        # Not numbers at all.
        "",
        "-",
        "0x",
        "0e",
        "1.2ef",
        "2..3",
        "123..",
        "infinity",
        "foobar",
        # An underscore has to sit between two digits, so none of these are
        # allowed even though every one of them is only underscores moved.
        "_",
        "0_",
        "1__0",
        "123_.",
        "123._",
        "123._4",
        "1_2.3_4_",
        "_.123",
        "_123.456",
        "10._0",
        "10.0e_0",
        "10.0e0_",
        "0P-0__0",
    ]
    for s in bad:
        var x = big.Float()
        x.set_prec(53)
        with assert_raises():
            x.set_string(s)


def _actual_prec(x: Float64) -> Int:
    """How many mantissa bits `x` really uses. Go's `actualPrec`.

    Fifty three for a normal number, and fewer for a subnormal one, whose
    leading bits are zeros that carry no information. The shortest way of
    writing a number depends on this, so a test that asks for the shortest
    form has to set it.
    """
    var mant = float64bits(x)
    if x != 0 and (mant & (UInt64(0x7FF) << 52)) == 0:
        return 64 - leading_zeros64(mant & ((UInt64(1) << 52) - 1))
    return 53


def test_float64_text() raises:
    # Go's `TestFloat64Text`. Every format at a `Float64` width, checked
    # against Go's table and then against `core.strconv`, which produces the
    # same text by a route that never builds a `Float`. The columns are the
    # number, the format letter, how many digits and the answer.
    var rows: List[List[String]] = [
        ["0", "f", "0", "0"],
        ["-0", "f", "0", "-0"],
        ["1", "f", "0", "1"],
        ["-1", "f", "0", "-1"],
        ["0.001", "e", "0", "1e-03"],
        ["0.459", "e", "0", "5e-01"],
        ["1.459", "e", "0", "1e+00"],
        ["2.459", "e", "1", "2.5e+00"],
        ["3.459", "e", "2", "3.46e+00"],
        ["4.459", "e", "3", "4.459e+00"],
        ["5.459", "e", "4", "5.4590e+00"],
        ["0.001", "f", "0", "0"],
        ["0.459", "f", "0", "0"],
        ["1.459", "f", "0", "1"],
        ["2.459", "f", "1", "2.5"],
        ["3.459", "f", "2", "3.46"],
        ["4.459", "f", "3", "4.459"],
        ["5.459", "f", "4", "5.4590"],
        ["0", "b", "0", "0"],
        ["-0", "b", "0", "-0"],
        ["1", "b", "0", "4503599627370496p-52"],
        ["-1", "b", "0", "-4503599627370496p-52"],
        ["4503599627370496", "b", "0", "4503599627370496p+0"],
        ["0", "p", "0", "0"],
        ["-0", "p", "0", "-0"],
        ["1024", "p", "0", "0x.8p+11"],
        ["-1024", "p", "0", "-0x.8p+11"],
        # The rows below come from Go's own `strconv` tests.
        ["1", "e", "5", "1.00000e+00"],
        ["1", "f", "5", "1.00000"],
        ["1", "g", "5", "1"],
        ["1", "g", "-1", "1"],
        ["20", "g", "-1", "20"],
        ["1234567.8", "g", "-1", "1.2345678e+06"],
        ["200000", "g", "-1", "200000"],
        ["2000000", "g", "-1", "2e+06"],
        # The `g` format drops the zeros a fixed width would keep.
        ["400", "g", "2", "4e+02"],
        ["40", "g", "2", "40"],
        ["4", "g", "2", "4"],
        ["0.4", "g", "2", "0.4"],
        ["0.04", "g", "2", "0.04"],
        ["0.004", "g", "2", "0.004"],
        ["0.0004", "g", "2", "0.0004"],
        ["0.00004", "g", "2", "4e-05"],
        ["0.000004", "g", "2", "4e-06"],
        ["0", "e", "5", "0.00000e+00"],
        ["0", "f", "5", "0.00000"],
        ["0", "g", "5", "0"],
        ["0", "g", "-1", "0"],
        ["-1", "e", "5", "-1.00000e+00"],
        ["-1", "f", "5", "-1.00000"],
        ["-1", "g", "5", "-1"],
        ["-1", "g", "-1", "-1"],
        ["12", "e", "5", "1.20000e+01"],
        ["12", "f", "5", "12.00000"],
        ["12", "g", "5", "12"],
        ["12", "g", "-1", "12"],
        ["123456700", "e", "5", "1.23457e+08"],
        ["123456700", "f", "5", "123456700.00000"],
        ["123456700", "g", "5", "1.2346e+08"],
        ["123456700", "g", "-1", "1.234567e+08"],
        ["1.2345e6", "e", "5", "1.23450e+06"],
        ["1.2345e6", "f", "5", "1234500.00000"],
        ["1.2345e6", "g", "5", "1.2345e+06"],
        # A power of ten a `Float64` cannot hold, so the digits it really has
        # show through at a wide enough width.
        ["1e23", "e", "17", "9.99999999999999916e+22"],
        ["1e23", "f", "17", "99999999999999991611392.00000000000000000"],
        ["1e23", "g", "17", "9.9999999999999992e+22"],
        ["1e23", "e", "-1", "1e+23"],
        ["1e23", "f", "-1", "100000000000000000000000"],
        ["1e23", "g", "-1", "1e+23"],
        # Its two neighbours.
        ["99999999999999974834176", "e", "17", "9.99999999999999748e+22"],
        [
            "99999999999999974834176",
            "f",
            "17",
            "99999999999999974834176.00000000000000000",
        ],
        ["99999999999999974834176", "g", "17", "9.9999999999999975e+22"],
        ["99999999999999974834176", "e", "-1", "9.999999999999997e+22"],
        ["99999999999999974834176", "f", "-1", "99999999999999970000000"],
        ["99999999999999974834176", "g", "-1", "9.999999999999997e+22"],
        ["100000000000000008388608", "e", "17", "1.00000000000000008e+23"],
        [
            "100000000000000008388608",
            "f",
            "17",
            "100000000000000008388608.00000000000000000",
        ],
        ["100000000000000008388608", "g", "17", "1.0000000000000001e+23"],
        ["100000000000000008388608", "e", "-1", "1.0000000000000001e+23"],
        ["100000000000000008388608", "f", "-1", "100000000000000010000000"],
        ["100000000000000008388608", "g", "-1", "1.0000000000000001e+23"],
        # The smallest number there is, both signs.
        ["5e-324", "g", "-1", "5e-324"],
        ["-5e-324", "g", "-1", "-5e-324"],
        ["32", "g", "-1", "32"],
        ["32", "g", "0", "3e+01"],
        ["100", "x", "-1", "0x1.9p+06"],
        # A `Float` has no NaN, so Go's two NaN rows are commented out in its
        # own table and there is nothing to port.
        ["+Inf", "g", "-1", "+Inf"],
        ["-Inf", "g", "-1", "-Inf"],
        ["-1", "b", "-1", "-4503599627370496p-52"],
        # Rows Go added as bugs were found.
        ["0.9", "f", "1", "0.9"],
        ["0.09", "f", "1", "0.1"],
        ["0.0999", "f", "1", "0.1"],
        ["0.05", "f", "1", "0.1"],
        ["0.05", "f", "0", "0"],
        ["0.5", "f", "1", "0.5"],
        ["0.5", "f", "0", "0"],
        ["1.5", "f", "0", "2"],
        # The two decimals just either side of the smallest normal number,
        # which used to hang other languages' parsers.
        ["2.2250738585072012e-308", "g", "-1", "2.2250738585072014e-308"],
        ["2.2250738585072011e-308", "g", "-1", "2.225073858507201e-308"],
        ["383260575764816448", "f", "0", "383260575764816448"],
        ["383260575764816448", "g", "-1", "3.8326057576481645e+17"],
        # A negative width is the shortest form, however negative it is.
        ["1", "f", "-10", "1"],
        ["1", "f", "-11", "1"],
        ["1", "f", "-12", "1"],
    ]
    for r in rows:
        var x = parse_float(r[0], 64)
        var fmt = UInt8(ord(r[1]))
        var digits = Int(parse_int(r[2], 10, 64))

        # The shortest form depends on how many mantissa bits the number
        # really uses, which is fewer than fifty three for a subnormal one.
        var z = big.Float()
        z.set_prec(_actual_prec(x))
        z.set_float64(x)
        var got = z.text(fmt, digits)
        assert_equal(got, r[3], r[0] + " " + r[1] + " " + r[2])

        if r[1] == "b" and x == 0:
            # `core.strconv` writes a zero in the `b` format with the biased
            # exponent a `Float64` carries, which a `Float` has no notion of.
            continue
        if r[1] == "p":
            # There is no `p` format in `core.strconv`.
            continue
        assert_equal(
            got,
            format_float(x, fmt, digits, 64),
            r[0] + " " + r[1] + " " + r[2],
        )


def test_round_shortest_normal() raises:
    # Go's `TestRoundShortestNormal`, from its issue 80206. The shortest form
    # of these numbers is decided by a digit right at the trimming point, and
    # a guard that reads it wrongly rounds the last digit up when it should
    # not.
    var values: List[String] = [
        "4.3749999999999917e+17",
        "4.9999999999999917e+17",
        "4.7619047619047597e+17",
        "3.7499999999999917e+17",
        "1.9047619047619039e+18",
        # A nine at the trimmed position, which is the row the guard is for.
        "1.1138394197049199e+18",
    ]
    for s in values:
        var x = parse_float(s, 64)
        var z = big.Float()
        z.set_prec(53)
        z.set_float64(x)
        assert_equal(
            z.text(UInt8(ord("g")), -1),
            format_float(x, UInt8(ord("g")), -1, 64),
            s,
        )


def test_text() raises:
    # Go's `TestFloatText`. The same formats at precisions a `Float64` cannot
    # reach, and the exponents at the very edges of the range. The columns are
    # the number, the rounding mode with an empty string for the default, the
    # precision to parse at, the format letter, how many digits and the
    # answer.
    var rows: List[List[String]] = [
        ["0", "", "10", "f", "0", "0"],
        ["-0", "", "10", "f", "0", "-0"],
        ["1", "", "10", "f", "0", "1"],
        ["-1", "", "10", "f", "0", "-1"],
        ["1.459", "", "100", "e", "0", "1e+00"],
        ["2.459", "", "100", "e", "1", "2.5e+00"],
        ["3.459", "", "100", "e", "2", "3.46e+00"],
        ["4.459", "", "100", "e", "3", "4.459e+00"],
        ["5.459", "", "100", "e", "4", "5.4590e+00"],
        ["1.459", "", "100", "E", "0", "1E+00"],
        ["2.459", "", "100", "E", "1", "2.5E+00"],
        ["3.459", "", "100", "E", "2", "3.46E+00"],
        ["4.459", "", "100", "E", "3", "4.459E+00"],
        ["5.459", "", "100", "E", "4", "5.4590E+00"],
        ["1.459", "", "100", "f", "0", "1"],
        ["2.459", "", "100", "f", "1", "2.5"],
        ["3.459", "", "100", "f", "2", "3.46"],
        ["4.459", "", "100", "f", "3", "4.459"],
        ["5.459", "", "100", "f", "4", "5.4590"],
        ["1.459", "", "100", "g", "0", "1"],
        ["2.459", "", "100", "g", "1", "2"],
        ["3.459", "", "100", "g", "2", "3.5"],
        ["4.459", "", "100", "g", "3", "4.46"],
        ["5.459", "", "100", "g", "4", "5.459"],
        ["1459", "", "53", "g", "0", "1e+03"],
        ["2459", "", "53", "g", "1", "2e+03"],
        ["3459", "", "53", "g", "2", "3.5e+03"],
        ["4459", "", "53", "g", "3", "4.46e+03"],
        ["5459", "", "53", "g", "4", "5459"],
        ["1459", "", "53", "G", "0", "1E+03"],
        ["2459", "", "53", "G", "1", "2E+03"],
        ["3459", "", "53", "G", "2", "3.5E+03"],
        ["4459", "", "53", "G", "3", "4.46E+03"],
        ["5459", "", "53", "G", "4", "5459"],
        # More digits asked for than the number has.
        [
            "3",
            "",
            "10",
            "e",
            "40",
            "3.0000000000000000000000000000000000000000e+00",
        ],
        [
            "3",
            "",
            "10",
            "f",
            "40",
            "3.0000000000000000000000000000000000000000",
        ],
        ["3", "", "10", "g", "40", "3"],
        [
            "3e40",
            "",
            "100",
            "e",
            "40",
            "3.0000000000000000000000000000000000000000e+40",
        ],
        [
            "3e40",
            "",
            "100",
            "f",
            "4",
            "30000000000000000000000000000000000000000.0000",
        ],
        ["3e40", "", "100", "g", "40", "3e+40"],
        # An exponent big enough to be silly still comes out in a moment.
        ["1e1000000", "", "64", "p", "0", "0x.88b3a28a05eade3ap+3321929"],
        ["1e646456992", "", "64", "p", "0", "0x.e883a0c5c8c7c42ap+2147483644"],
        ["1e646456993", "", "64", "p", "0", "+Inf"],
        ["1e1000000000", "", "64", "p", "0", "+Inf"],
        ["1e-1000000", "", "64", "p", "0", "0x.efb4542cc8ca418ap-3321928"],
        [
            "1e-646456993",
            "",
            "64",
            "p",
            "0",
            "0x.e17c8956983d9d59p-2147483647",
        ],
        ["1e-646456994", "", "64", "p", "0", "0"],
        ["1e-1000000000", "", "64", "p", "0", "0"],
        # The two ends of the exponent range.
        ["1p2147483646", "", "64", "p", "0", "0x.8p+2147483647"],
        ["0x.8p2147483647", "", "64", "p", "0", "0x.8p+2147483647"],
        ["0x.8p-2147483647", "", "64", "p", "0", "0x.8p-2147483647"],
        ["1p-2147483649", "", "64", "p", "0", "0x.8p-2147483648"],
        ["0", "", "53", "b", "0", "0"],
        ["-0", "", "53", "b", "0", "-0"],
        ["1.0", "", "53", "b", "0", "4503599627370496p-52"],
        ["-1.0", "", "53", "b", "0", "-4503599627370496p-52"],
        ["4503599627370496", "", "53", "b", "0", "4503599627370496p+0"],
        # Go's issue 9939: a three written six ways is the same three, and at
        # three hundred and fifty bits it is a very long mantissa.
        ["3", "", "350", "b", "0", _three_at_350()],
        ["03", "", "350", "b", "0", _three_at_350()],
        ["3.", "", "350", "b", "0", _three_at_350()],
        ["3.0", "", "350", "b", "0", _three_at_350()],
        ["3.00", "", "350", "b", "0", _three_at_350()],
        ["3.000", "", "350", "b", "0", _three_at_350()],
        ["3", "", "350", "p", "0", "0x.cp+2"],
        ["03", "", "350", "p", "0", "0x.cp+2"],
        ["3.", "", "350", "p", "0", "0x.cp+2"],
        ["3.0", "", "350", "p", "0", "0x.cp+2"],
        ["3.00", "", "350", "p", "0", "0x.cp+2"],
        ["3.000", "", "350", "p", "0", "0x.cp+2"],
        ["0", "", "64", "p", "0", "0"],
        ["-0", "", "64", "p", "0", "-0"],
        ["1024.0", "", "64", "p", "0", "0x.8p+11"],
        ["-1024.0", "", "64", "p", "0", "-0x.8p+11"],
        # The hexadecimal format, where the digits asked for are hexadecimal
        # ones after the point.
        ["0", "", "64", "x", "-1", "0x0p+00"],
        ["0", "", "64", "x", "0", "0x0p+00"],
        ["0", "", "64", "x", "1", "0x0.0p+00"],
        ["0", "", "64", "x", "5", "0x0.00000p+00"],
        ["3.25", "", "64", "x", "0", "0x1p+02"],
        ["-3.25", "", "64", "x", "0", "-0x1p+02"],
        ["3.25", "", "64", "x", "1", "0x1.ap+01"],
        ["-3.25", "", "64", "x", "1", "-0x1.ap+01"],
        ["3.25", "", "64", "x", "-1", "0x1.ap+01"],
        ["-3.25", "", "64", "x", "-1", "-0x1.ap+01"],
        ["1024.0", "", "64", "x", "0", "0x1p+10"],
        ["-1024.0", "", "64", "x", "0", "-0x1p+10"],
        ["1024.0", "", "64", "x", "5", "0x1.00000p+10"],
        ["8191.0", "", "53", "x", "-1", "0x1.fffp+12"],
        ["8191.5", "", "53", "x", "-1", "0x1.fff8p+12"],
        ["8191.53125", "", "53", "x", "-1", "0x1.fff88p+12"],
        ["8191.53125", "", "53", "x", "4", "0x1.fff8p+12"],
        ["8191.53125", "", "53", "x", "3", "0x1.000p+13"],
        ["8191.53125", "", "53", "x", "0", "0x1p+13"],
        ["8191.533203125", "", "53", "x", "-1", "0x1.fff888p+12"],
        ["8191.533203125", "", "53", "x", "5", "0x1.fff88p+12"],
        ["8191.533203125", "", "53", "x", "4", "0x1.fff9p+12"],
        # A width that loses nothing rounds the same way whatever the mode.
        ["8191.53125", "", "53", "x", "-1", "0x1.fff88p+12"],
        ["8191.53125", "ToNearestEven", "53", "x", "5", "0x1.fff88p+12"],
        ["8191.53125", "ToNearestAway", "53", "x", "5", "0x1.fff88p+12"],
        ["8191.53125", "ToZero", "53", "x", "5", "0x1.fff88p+12"],
        ["8191.53125", "AwayFromZero", "53", "x", "5", "0x1.fff88p+12"],
        ["8191.53125", "ToNegativeInf", "53", "x", "5", "0x1.fff88p+12"],
        ["8191.53125", "ToPositiveInf", "53", "x", "5", "0x1.fff88p+12"],
        ["8191.53125", "", "53", "x", "4", "0x1.fff8p+12"],
        ["8191.53125", "", "53", "x", "3", "0x1.000p+13"],
        ["8191.53125", "", "53", "x", "0", "0x1p+13"],
        ["8191.533203125", "", "53", "x", "-1", "0x1.fff888p+12"],
        ["8191.533203125", "", "53", "x", "6", "0x1.fff888p+12"],
        ["8191.533203125", "", "53", "x", "5", "0x1.fff88p+12"],
        ["8191.533203125", "", "53", "x", "4", "0x1.fff9p+12"],
        # A width that lands exactly between two digits, where the mode
        # decides and the sign decides with it.
        ["8191.53125", "ToNearestEven", "53", "x", "4", "0x1.fff8p+12"],
        ["8191.53125", "ToNearestAway", "53", "x", "4", "0x1.fff9p+12"],
        ["8191.53125", "ToZero", "53", "x", "4", "0x1.fff8p+12"],
        ["8191.53125", "ToZero", "53", "x", "2", "0x1.ffp+12"],
        ["8191.53125", "AwayFromZero", "53", "x", "4", "0x1.fff9p+12"],
        ["8191.53125", "ToNegativeInf", "53", "x", "4", "0x1.fff8p+12"],
        ["-8191.53125", "ToNegativeInf", "53", "x", "4", "-0x1.fff9p+12"],
        ["8191.53125", "ToPositiveInf", "53", "x", "4", "0x1.fff9p+12"],
        ["-8191.53125", "ToPositiveInf", "53", "x", "4", "-0x1.fff8p+12"],
        # Go's issue 34343, at the very bottom of the exponent range, where
        # the `x` format has to move the point and the exponent with it.
        [
            "0x.8p-2147483648",
            "ToNearestEven",
            "4",
            "p",
            "-1",
            "0x.8p-2147483648",
        ],
        [
            "0x.8p-2147483648",
            "ToNearestEven",
            "4",
            "x",
            "-1",
            "0x1p-2147483649",
        ],
    ]
    for r in rows:
        var prec = Int(parse_int(r[2], 10, 64))
        var mode = _mode_named(r[1])
        var x = big.parse_float(r[0], 0, prec, big.ToNearestEven)
        x.set_mode(mode)

        var fmt = UInt8(ord(r[3]))
        var digits = Int(parse_int(r[4], 10, 64))
        var label = r[0] + " " + r[3] + " " + r[4] + " " + r[1]
        var got = x.text(fmt, digits)
        assert_equal(got, r[5], label)

        # At a `Float64` width, rounding to nearest, `core.strconv` has to
        # write the same thing. The `p` format is not one it has, and a zero
        # is written there with the biased exponent a `Float64` carries.
        if prec != 53 or r[3] == "p" or x.sign() == 0:
            continue
        if r[1] != "" and r[1] != "ToNearestEven":
            continue
        var f64, acc = x.float64()
        assert_equal(acc, big.Exact, label)
        assert_equal(format_float(f64, fmt, digits, 64), r[5], label)


def _three_at_350() -> String:
    """A three at three hundred and fifty bits, written in the `b` format.

    Go's issue 9939 was that trailing zeros in the text moved the exponent, so
    every way of writing a three has to give this same line back.
    """
    return String(
        "17201239619925536337081156714765652055974237418762108428031916295"
        "40192157066363606052513914832594264915968p-348"
    )
