"""Complex numbers to text. Go's `ctoa_test.go`.

Nine rows, which is all Go has: a few signs, a check that the format byte and
the precision reach both halves, and a check that a bit size of 64 rounds each
half as a float32. Everything else about the two halves is settled by the
`format_float` tests next door, which is the note Go leaves at the end of its
table.
"""

from std.complex import ComplexFloat64
from std.testing import assert_equal, assert_raises

from core.strconv import format_complex


struct Row(Copyable, Movable):
    """A number, how to write it, and what Go writes."""

    var re: Float64
    var im: Float64
    var fmt: UInt8
    var prec: Int
    var bit_size: Int
    var out: String

    def __init__(
        out self,
        re: Float64,
        im: Float64,
        fmt: String,
        prec: Int,
        bit_size: Int,
        var out: String,
    ):
        self.re = re
        self.im = im
        self.fmt = UInt8(ord(fmt))
        self.prec = prec
        self.bit_size = bit_size
        self.out = out^


def ctoa_rows() -> List[Row]:
    """Go's table inside `TestFormatComplex`."""
    var rows = List[Row]()

    # A variety of signs.
    rows.append(Row(1, 2, "g", -1, 128, "(1+2i)"))
    rows.append(Row(3, -4, "g", -1, 128, "(3-4i)"))
    rows.append(Row(-5, 6, "g", -1, 128, "(-5+6i)"))
    rows.append(Row(-7, -8, "g", -1, 128, "(-7-8i)"))

    # The format byte and the precision reach both halves.
    rows.append(Row(3.14159, 0.00123, "e", 3, 128, "(3.142e+00+1.230e-03i)"))
    rows.append(Row(3.14159, 0.00123, "f", 3, 128, "(3.142+0.001i)"))
    rows.append(Row(3.14159, 0.00123, "g", 3, 128, "(3.14+0.00123i)"))

    # The bit size rounds each half.
    rows.append(
        Row(
            1.2345678901234567,
            9.876543210987654,
            "f",
            -1,
            128,
            "(1.2345678901234567+9.876543210987654i)",
        )
    )
    rows.append(
        Row(
            1.2345678901234567,
            9.876543210987654,
            "f",
            -1,
            64,
            "(1.2345679+9.876543i)",
        )
    )
    return rows^


def test_format_complex() raises:
    """Go's `TestFormatComplex`."""
    for row in ctoa_rows():
        var z = ComplexFloat64(row.re, row.im)
        assert_equal(
            format_complex(z, row.fmt, row.prec, row.bit_size), row.out
        )


def test_an_illegal_bit_size_is_refused() raises:
    """Go's `TestFormatComplexInvalidBitSize`, which expects a panic.

    A bit size that is neither 64 nor 128 is a mistake in the calling program
    rather than in its input, and Go panics on it. Here it raises, for the
    reason `format_float` gives.
    """
    var z = ComplexFloat64(1.0, 2.0)
    with assert_raises():
        _ = format_complex(z, UInt8(ord("g")), -1, 100)
    with assert_raises():
        _ = format_complex(z, UInt8(ord("g")), -1, 32)
