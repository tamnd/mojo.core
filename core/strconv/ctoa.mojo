"""Complex numbers to text. Go's `ctoa.go`.

One public function, which writes `(a+bi)` with both halves formatted the way
`format_float` would. Go has an `AppendComplex` next to it that it does not
export, kept for its runtime, and this does the same: `_append_complex` is
where the work is and the public name is the one Go's callers have.
"""

from std.complex import ComplexFloat64

from core.errors import Report
from core.strconv.ftoa import append_float


comptime _PLUS = UInt8(ord("+"))
comptime _MINUS = UInt8(ord("-"))


def format_complex(
    c: ComplexFloat64, fmt: UInt8, prec: Int, bit_size: Int
) raises -> String:
    """`c` written as `(a+bi)`. Go's `FormatComplex`.

    `fmt` and `prec` mean what they mean in `format_float`, and are applied to
    each half. `bit_size` is 64 for a pair of float32 components or 128 for a
    pair of float64 components, and each half is rounded as if it had come from
    a float of half that width.

    The imaginary half always carries a sign, so a positive one gets a `+` put
    in front of it. Go panics on any other bit size and this raises, for the
    reason `format_float` gives.

    ```mojo
    from std.complex import ComplexFloat64

    from core.strconv import format_complex

    def main() raises:
        var z = ComplexFloat64(3.5, -2.0)
        print(format_complex(z, UInt8(ord("g")), -1, 128))  # (3.5-2i)
    ```
    """
    var buf = List[UInt8]()
    _append_complex(buf, c, fmt, prec, bit_size)
    return String(from_utf8_lossy=Span(buf))


def _append_complex(
    mut dst: List[UInt8],
    c: ComplexFloat64,
    fmt: UInt8,
    prec: Int,
    bit_size: Int,
) raises:
    """`format_complex` onto the end of `dst`. Go's `AppendComplex`."""
    if bit_size != 64 and bit_size != 128:
        raise Report(
            "strconv: illegal format_complex bit size " + String(bit_size)
        ).error()

    # Each component is half the pair.
    var half = bit_size >> 1

    dst.append(UInt8(ord("(")))
    _ = append_float(dst, c.re, fmt, prec, half)
    var at = len(dst)
    _ = append_float(dst, c.im, fmt, prec, half)
    if dst[at] != _PLUS and dst[at] != _MINUS:
        dst.insert(at, _PLUS)
    dst.append(UInt8(ord("i")))
    dst.append(UInt8(ord(")")))
