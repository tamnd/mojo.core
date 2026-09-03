"""Text to complex numbers. Go's `atoc.go`.

One public function. It reads `N`, `Ni` or `N+Ni`, with an optional pair of
parentheses around the whole thing and no spaces anywhere, where each `N` is
what `parse_float` reads.

Go's complex128 is a language type; here the pair is Mojo's `ComplexFloat64`,
which is what `core.math.cmplx` will take when it arrives. A `bit_size` of 64
asks for a pair of float32 components and anything else for a pair of float64
components, and either way the result is the wider pair, exactly as Go returns
a complex128 in both cases.
"""

from std.complex import ComplexFloat64

from core.strconv.atof import _parse_float_prefix
from core.strconv.num_error import _range_error, _syntax_error


comptime _PLUS = UInt8(ord("+"))
comptime _MINUS = UInt8(ord("-"))
comptime _OPEN = UInt8(ord("("))
comptime _CLOSE = UInt8(ord(")"))
comptime _I = UInt8(ord("i"))


def parse_complex[
    o: ImmOrigin
](s: StringSlice[o], bit_size: Int) raises -> ComplexFloat64:
    """`s` as a complex number of `bit_size` bits. Go's `ParseComplex`.

    `bit_size` is 64 for a pair of float32 components or 128 for a pair of
    float64 components, and anything else is read as 128. The result holds
    float64 components either way, and at 64 they are values a float32 can
    represent exactly.

    The forms are `N`, `Ni` and `N±Ni`, where `N` is anything `parse_float`
    reads, including `inf` and `nan`. A second component with no sign of its
    own needs the `+`, which is why `1+2i` parses and `1 2i` does not, and a
    `nan` imaginary part takes only `+`. The whole may be wrapped in one pair
    of parentheses.

    Raises with `ErrSyntax` when the text is not of that shape and with
    `ErrRange` when a component is a number too large to hold. Go returns the
    infinity it clamped to alongside that second failure, and a raise carries
    no value, so a caller who wants it formats an infinity with the sign of the
    component that overflowed.

    ```mojo
    from core.strconv import parse_complex

    def main() raises:
        var z = parse_complex("(3.5-2i)", 128)
        print(z.re, z.im)  # 3.5 -2.0
    ```
    """
    # Go names this `size`: the width of each component, not of the pair.
    var size = 32 if bit_size == 64 else 64

    var text = s
    var outer = text.as_bytes()
    if (
        len(outer) >= 2
        and outer[0] == _OPEN
        and outer[len(outer) - 1] == _CLOSE
    ):
        text = text[byte = 1 : text.byte_length() - 1]

    # A component out of range is held rather than raised, because a syntax
    # error further along is the more useful thing to report and Go keeps the
    # same order.
    var out_of_range = False

    # The real part, or the imaginary one if an `i` follows it.
    var re = _parse_float_prefix(text, size)
    if not re.ok:
        raise _syntax_error("parse_complex", s)
    out_of_range = out_of_range or re.out_of_range
    text = text[byte = re.n : text.byte_length()]

    if text.byte_length() == 0:
        if out_of_range:
            raise _range_error("parse_complex", s)
        return ComplexFloat64(re.f, 0.0)

    var rest = text.as_bytes()
    var c = rest[0]
    if c == _PLUS:
        # Take the sign, so that `+NaNi` reads. Not on a `++`, which would hide
        # an error rather than fix one.
        if len(rest) > 1 and rest[1] != _PLUS:
            text = text[byte = 1 : text.byte_length()]
    elif c == _I and len(rest) == 1:
        # An imaginary part on its own, so what was read is the imaginary one.
        if out_of_range:
            raise _range_error("parse_complex", s)
        return ComplexFloat64(0.0, re.f)
    elif c != _MINUS:
        raise _syntax_error("parse_complex", s)

    var im = _parse_float_prefix(text, size)
    if not im.ok:
        raise _syntax_error("parse_complex", s)
    out_of_range = out_of_range or im.out_of_range
    text = text[byte = im.n : text.byte_length()]
    var tail = text.as_bytes()
    if len(tail) != 1 or tail[0] != _I:
        raise _syntax_error("parse_complex", s)
    if out_of_range:
        raise _range_error("parse_complex", s)
    return ComplexFloat64(re.f, im.f)
