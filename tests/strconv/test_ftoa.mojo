"""Floats to text. Go's `ftoa_test.go`.

Go's `ftoatests`, row for row, checked at 64 bits, checked again at 32 bits for
the rows whose value survives a trip through a `Float32`, and checked once more
through the append form, which is the shape Go's `TestFtoa` has.

`TestFtoaPowersOfTwo` is here too. `TestFtoaRandom` is not: it compares the fast
path against the slow one through a test only hook Go's package exports, and the
same ground is covered by the differential run against Go recorded in the pull
request.

The rows are written as a struct rather than a tuple because a tuple holding a
`String` cannot be destructured, which is the same reason every table in this
suite looks like this.
"""

from std.math import inf, nan
from std.memory import bitcast
from std.testing import assert_equal, assert_raises

from core.strconv import append_float, format_float, parse_float


struct Row(Copyable, Movable):
    var f: Float64
    var fmt: UInt8
    var prec: Int
    var out: String

    def __init__(out self, f: Float64, fmt: String, prec: Int, var out: String):
        self.f = f
        self.fmt = UInt8(ord(fmt))
        self.prec = prec
        self.out = out^


def fdiv(a: Float64, b: Float64) -> Float64:
    """Go's `fdiv`, kept for the same reason.

    A division written out where the compiler can see both sides is folded at
    more precision than a float has, and these rows are about what the float
    does.
    """
    return a / b


def power_of_two(exp: Int) -> Float64:
    """`2^exp`, zero below the smallest subnormal.

    Mojo's `ldexp` has the exponent field written straight into it, so it gives
    a wrong answer as soon as the result is subnormal. The bits are written out
    here instead.
    """
    if exp > 1023:
        return inf[DType.float64]()
    if exp >= -1022:
        return bitcast[DType.float64](UInt64(exp + 1023) << 52)
    if exp >= -1074:
        return bitcast[DType.float64](UInt64(1) << UInt64(exp + 1074))
    return 0.0


def ftoa_rows() -> List[Row]:
    """Go's `ftoatests`."""
    # Go writes these two as integer constants, which is the only way to say
    # exactly which side of 1e23 is meant.
    var below1e23 = Float64(99999999999999974834176)
    var above1e23 = Float64(100000000000000008388608)

    var rows = List[Row]()
    rows.append(Row(1, "e", 5, "1.00000e+00"))
    rows.append(Row(1, "f", 5, "1.00000"))
    rows.append(Row(1, "g", 5, "1"))
    rows.append(Row(1, "g", -1, "1"))
    rows.append(Row(1, "x", -1, "0x1p+00"))
    rows.append(Row(1, "x", 5, "0x1.00000p+00"))
    rows.append(Row(20, "g", -1, "20"))
    rows.append(Row(20, "x", -1, "0x1.4p+04"))
    rows.append(Row(1234567.8, "g", -1, "1.2345678e+06"))
    rows.append(Row(1234567.8, "x", -1, "0x1.2d687cccccccdp+20"))
    rows.append(Row(200000, "g", -1, "200000"))
    rows.append(Row(200000, "x", -1, "0x1.86ap+17"))
    rows.append(Row(200000, "X", -1, "0X1.86AP+17"))
    rows.append(Row(2000000, "g", -1, "2e+06"))
    rows.append(Row(1e10, "g", -1, "1e+10"))

    # f conversion basic cases
    rows.append(Row(12345, "f", 2, "12345.00"))
    rows.append(Row(1234.5, "f", 2, "1234.50"))
    rows.append(Row(123.45, "f", 2, "123.45"))
    rows.append(Row(12.345, "f", 2, "12.35"))
    rows.append(Row(1.2345, "f", 2, "1.23"))
    rows.append(Row(0.12345, "f", 2, "0.12"))
    rows.append(Row(0.12945, "f", 2, "0.13"))
    rows.append(Row(0.012345, "f", 2, "0.01"))
    rows.append(Row(0.015, "f", 2, "0.01"))
    rows.append(Row(0.016, "f", 2, "0.02"))
    rows.append(Row(0.0052345, "f", 2, "0.01"))
    rows.append(Row(0.0012345, "f", 2, "0.00"))
    rows.append(Row(0.00012345, "f", 2, "0.00"))
    rows.append(Row(0.000012345, "f", 2, "0.00"))

    rows.append(Row(0.996644984, "f", 6, "0.996645"))
    rows.append(Row(0.996644984, "f", 5, "0.99664"))
    rows.append(Row(0.996644984, "f", 4, "0.9966"))
    rows.append(Row(0.996644984, "f", 3, "0.997"))
    rows.append(Row(0.996644984, "f", 2, "1.00"))
    rows.append(Row(0.996644984, "f", 1, "1.0"))

    # g conversion and zero suppression
    rows.append(Row(400, "g", 2, "4e+02"))
    rows.append(Row(40, "g", 2, "40"))
    rows.append(Row(4, "g", 2, "4"))
    rows.append(Row(0.4, "g", 2, "0.4"))
    rows.append(Row(0.04, "g", 2, "0.04"))
    rows.append(Row(0.004, "g", 2, "0.004"))
    rows.append(Row(0.0004, "g", 2, "0.0004"))
    rows.append(Row(0.00004, "g", 2, "4e-05"))
    rows.append(Row(0.000004, "g", 2, "4e-06"))

    rows.append(Row(0, "e", 5, "0.00000e+00"))
    rows.append(Row(0, "f", 5, "0.00000"))
    rows.append(Row(0, "g", 5, "0"))
    rows.append(Row(0, "g", -1, "0"))
    rows.append(Row(0, "x", 5, "0x0.00000p+00"))

    rows.append(Row(-1, "e", 5, "-1.00000e+00"))
    rows.append(Row(-1, "f", 5, "-1.00000"))
    rows.append(Row(-1, "g", 5, "-1"))
    rows.append(Row(-1, "g", -1, "-1"))

    rows.append(Row(12, "e", 5, "1.20000e+01"))
    rows.append(Row(12, "f", 5, "12.00000"))
    rows.append(Row(12, "g", 5, "12"))
    rows.append(Row(12, "g", -1, "12"))

    rows.append(Row(123456700, "e", 5, "1.23457e+08"))
    rows.append(Row(123456700, "f", 5, "123456700.00000"))
    rows.append(Row(123456700, "g", 5, "1.2346e+08"))
    rows.append(Row(123456700, "g", -1, "1.234567e+08"))

    rows.append(Row(1.2345e6, "e", 5, "1.23450e+06"))
    rows.append(Row(1.2345e6, "f", 5, "1234500.00000"))
    rows.append(Row(1.2345e6, "g", 5, "1.2345e+06"))

    # Round to even
    rows.append(Row(1.2345e6, "e", 3, "1.234e+06"))
    rows.append(Row(1.2355e6, "e", 3, "1.236e+06"))
    rows.append(Row(1.2345, "f", 3, "1.234"))
    rows.append(Row(1.2355, "f", 3, "1.236"))
    rows.append(Row(1234567890123456.5, "e", 15, "1.234567890123456e+15"))
    rows.append(Row(1234567890123457.5, "e", 15, "1.234567890123458e+15"))
    rows.append(Row(108678236358137.625, "g", -1, "1.0867823635813762e+14"))

    rows.append(Row(1e23, "e", 17, "9.99999999999999916e+22"))
    rows.append(Row(1e23, "f", 17, "99999999999999991611392.00000000000000000"))
    rows.append(Row(1e23, "g", 17, "9.9999999999999992e+22"))

    rows.append(Row(1e23, "e", -1, "1e+23"))
    rows.append(Row(1e23, "f", -1, "100000000000000000000000"))
    rows.append(Row(1e23, "g", -1, "1e+23"))

    rows.append(Row(below1e23, "e", 17, "9.99999999999999748e+22"))
    rows.append(
        Row(below1e23, "f", 17, "99999999999999974834176.00000000000000000")
    )
    rows.append(Row(below1e23, "g", 17, "9.9999999999999975e+22"))

    rows.append(Row(below1e23, "e", -1, "9.999999999999997e+22"))
    rows.append(Row(below1e23, "f", -1, "99999999999999970000000"))
    rows.append(Row(below1e23, "g", -1, "9.999999999999997e+22"))

    rows.append(Row(above1e23, "e", 17, "1.00000000000000008e+23"))
    rows.append(
        Row(above1e23, "f", 17, "100000000000000008388608.00000000000000000")
    )
    rows.append(Row(above1e23, "g", 17, "1.0000000000000001e+23"))

    rows.append(Row(above1e23, "e", -1, "1.0000000000000001e+23"))
    rows.append(Row(above1e23, "f", -1, "100000000000000010000000"))
    rows.append(Row(above1e23, "g", -1, "1.0000000000000001e+23"))

    rows.append(Row(fdiv(5e-304, 1e20), "g", -1, "5e-324"))
    rows.append(Row(fdiv(-5e-304, 1e20), "g", -1, "-5e-324"))

    rows.append(Row(32, "g", -1, "32"))
    rows.append(Row(32, "g", 0, "3e+01"))

    rows.append(Row(100, "x", -1, "0x1.9p+06"))
    rows.append(Row(100, "y", -1, "%y"))

    rows.append(Row(nan[DType.float64](), "g", -1, "NaN"))
    rows.append(Row(-nan[DType.float64](), "g", -1, "NaN"))
    rows.append(Row(inf[DType.float64](), "g", -1, "+Inf"))
    rows.append(Row(-inf[DType.float64](), "g", -1, "-Inf"))

    rows.append(Row(-1, "b", -1, "-4503599627370496p-52"))

    # fixed bugs
    rows.append(Row(0.9, "f", 1, "0.9"))
    rows.append(Row(0.09, "f", 1, "0.1"))
    rows.append(Row(0.0999, "f", 1, "0.1"))
    rows.append(Row(0.05, "f", 1, "0.1"))
    rows.append(Row(0.05, "f", 0, "0"))
    rows.append(Row(0.5, "f", 1, "0.5"))
    rows.append(Row(0.5, "f", 0, "0"))
    rows.append(Row(1.5, "f", 0, "2"))

    # The value that once hung Java.
    # https://www.exploringbinary.com/java-hangs-when-converting-2-2250738585072012e-308/
    rows.append(
        Row(2.2250738585072012e-308, "g", -1, "2.2250738585072014e-308")
    )
    # And the one that once hung PHP.
    # https://www.exploringbinary.com/php-hangs-on-numeric-value-2-2250738585072011e-308/
    rows.append(Row(2.2250738585072011e-308, "g", -1, "2.225073858507201e-308"))

    # Go issue 2625.
    rows.append(Row(383260575764816448, "f", 0, "383260575764816448"))
    rows.append(Row(383260575764816448, "g", -1, "3.8326057576481645e+17"))

    # Go issue 29491.
    rows.append(Row(498484681984085570, "f", -1, "498484681984085570"))
    rows.append(Row(-5.8339553793802237e23, "g", -1, "-5.8339553793802237e+23"))

    # Go issue 52187, an unknown format character.
    rows.append(Row(123.45, "?", 0, "%?"))
    rows.append(Row(123.45, "?", 1, "%?"))
    rows.append(Row(123.45, "?", -1, "%?"))

    # rounding
    rows.append(Row(2.275555555555555, "x", -1, "0x1.23456789abcdep+01"))
    rows.append(Row(2.275555555555555, "x", 0, "0x1p+01"))
    rows.append(Row(2.275555555555555, "x", 2, "0x1.23p+01"))
    rows.append(Row(2.275555555555555, "x", 16, "0x1.23456789abcde000p+01"))
    rows.append(
        Row(2.275555555555555, "x", 21, "0x1.23456789abcde00000000p+01")
    )
    rows.append(Row(2.2755555510520935, "x", -1, "0x1.2345678p+01"))
    rows.append(Row(2.2755555510520935, "x", 6, "0x1.234568p+01"))
    rows.append(Row(2.275555431842804, "x", -1, "0x1.2345668p+01"))
    rows.append(Row(2.275555431842804, "x", 6, "0x1.234566p+01"))
    rows.append(Row(3.999969482421875, "x", -1, "0x1.ffffp+01"))
    rows.append(Row(3.999969482421875, "x", 4, "0x1.ffffp+01"))
    rows.append(Row(3.999969482421875, "x", 3, "0x1.000p+02"))
    rows.append(Row(3.999969482421875, "x", 2, "0x1.00p+02"))
    rows.append(Row(3.999969482421875, "x", 1, "0x1.0p+02"))
    rows.append(Row(3.999969482421875, "x", 0, "0x1p+02"))

    # Cases that Java once mishandled, from David Chase.
    rows.append(Row(1.801439850948199e16, "g", -1, "1.801439850948199e+16"))
    rows.append(Row(5.960464477539063e-08, "g", -1, "5.960464477539063e-08"))
    rows.append(Row(1.012e-320, "g", -1, "1.012e-320"))

    # Cases from Go's `TestFtoaRandom` that caught bugs in its fixed formatter.
    rows.append(Row(8177880169308380.0 * 2, "e", 14, "1.63557603386168e+16"))
    rows.append(Row(8393378656576888.0 * 2, "e", 15, "1.678675731315378e+16"))
    rows.append(Row(8738676561280626.0 * 16, "e", 16, "1.3981882498049002e+17"))
    rows.append(Row(8291032395191335.0 / (1 << 30), "e", 5, "7.72163e+06"))
    rows.append(
        Row(
            8880392441509914.0 / Float64(1 << 80),
            "e",
            16,
            "7.3456884594794477e-09",
        )
    )

    # The exact division inside the fixed formatter, Go's `divisiblePow5`.
    rows.append(Row(2384185791015625.0 * (1 << 12), "e", 5, "9.76562e+18"))
    rows.append(Row(2384185791015625.0 * (1 << 13), "e", 5, "1.95312e+19"))

    # Mistakes Go found in its fixed formatter by making them on purpose. The
    # first is Go's 0x1.000000000005p+71, which has no hexadecimal spelling
    # here.
    rows.append(
        Row(
            Float64((1 << 71) + (5 << 23)),
            "e",
            16,
            "2.3611832414348645e+21",
        )
    )
    rows.append(Row(power_of_two(-27), "e", 17, "7.45058059692382812e-09"))
    rows.append(Row(power_of_two(-41), "e", 17, "4.54747350886464119e-13"))
    return rows^


def test_format_float() raises:
    """Go's `TestFtoa` at 64 bits."""
    for row in ftoa_rows():
        assert_equal(format_float(row.f, row.fmt, row.prec, 64), row.out)


def test_append_float() raises:
    """The same rows through the append form, onto a list that already holds
    something, which is where an off by one shows up.

    Go hands back the grown slice and this hands back a count, so both the
    count and the bytes are checked.
    """
    for row in ftoa_rows():
        var dst = List[UInt8]()
        dst.extend("abc".as_bytes())
        var n = append_float(dst, row.f, row.fmt, row.prec, 64)
        assert_equal(n, row.out.byte_length())
        assert_equal(String(from_utf8_lossy=Span(dst)), "abc" + row.out)


def test_format_float_32() raises:
    """Go's `TestFtoa` at 32 bits, over the rows whose value is exactly a
    `Float32`.

    The `b` format is left out because it spells the mantissa of the float it
    was handed, which is a different number at the two widths. Go also skips
    `5.960464477539063e-08`, which is exact as a `Float32` but asks for more
    digits than one carries.
    """
    for row in ftoa_rows():
        if row.fmt == UInt8(ord("b")):
            continue
        if Float64(Float32(row.f)) != row.f:
            continue
        if row.f == 5.960464477539063e-08:
            continue
        assert_equal(format_float(row.f, row.fmt, row.prec, 32), row.out)


def test_powers_of_two_round_trip() raises:
    """Go's `TestFtoaPowersOfTwo`, over every power of two either format holds.

    Go walks a wider range and skips the infinities. The extra exponents are
    zero at one end and infinite at the other, and neither says anything about
    the formatter.
    """
    var e = UInt8(ord("e"))
    for exp in range(-1074, 1024):
        var f = power_of_two(exp)
        assert_equal(parse_float(format_float(f, e, -1, 64), 64), f)

    for exp in range(-149, 128):
        var f = Float64(Float32(power_of_two(exp)))
        assert_equal(
            Float32(parse_float(format_float(f, e, -1, 32), 32)), Float32(f)
        )


def test_an_illegal_bit_size_is_refused() raises:
    """Go panics on a bit size that is neither 32 nor 64. This raises, because
    the caller can pass one through from data and a raise is the thing they can
    handle.
    """
    with assert_raises():
        _ = format_float(3.14, UInt8(ord("g")), -1, 100)

    var dst = List[UInt8]()
    with assert_raises():
        _ = append_float(dst, 3.14, UInt8(ord("g")), -1, 0)
