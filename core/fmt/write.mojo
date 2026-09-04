"""Writing one value out, the way Go's `fmt/format.go` does it.

This is the run time half and it is a port rather than an interpretation. Every
routine here has a counterpart in Go with the same name and the same order of
operations, because the output is compared against Go's byte for byte and the
places where the two could differ are all in the details: whether a zero pad
goes before or after the sign, whether `%#.0f` keeps its decimal point, whether
a width counts bytes or runes.

Nothing in this file looks at the format string. It is handed a verb, the flag
bits, a width and a precision, all of which were worked out when the program
was compiled, and a value that has already been narrowed to one of five shapes
by `kind.mojo`.
"""

from core.strconv import (
    can_backquote,
    format_float,
    is_print,
    quote,
    quote_rune,
    quote_rune_to_ascii,
    quote_to_ascii,
)
from core.unicode.utf8 import MAX_RUNE, RUNE_ERROR, append_rune
from core.unicode.utf8 import rune_count_in_string

from .plan import MINUS, PLUS, SHARP, SPACE, ZERO, rune_at

comptime _LOWER = "0123456789abcdefx"
comptime _UPPER = "0123456789ABCDEFX"

comptime _ZERO_BYTE = Byte(ord("0"))


def _text(buf: List[Byte]) -> String:
    """A buffer this file built, as a string.

    Lossy because the constructor that is not lossy raises, and every caller
    here has either written ASCII or written UTF-8 through `append_rune`. A
    check that cannot fail is not worth a `raises` on nine functions.
    """
    return String(from_utf8_lossy=Span(buf))


def padding(mut out: String, n: Int, flags: Int):
    """`n` bytes of padding, spaces or zeros. Go's `writePadding`."""
    if n <= 0:
        return
    var fill = "0" if (flags & ZERO) != 0 and (flags & MINUS) == 0 else " "
    for _ in range(n):
        out += fill


def pad(mut out: String, text: String, flags: Int, width: Int):
    """`text`, padded to `width`. Go's `pad` and `padString`.

    The width is in runes rather than bytes, so `%5s` of `héllo` is five
    characters and not four characters and a wasted column.
    """
    if width <= 0:
        out += text
        return
    var room = width - rune_count_in_string(text)
    if (flags & MINUS) == 0:
        padding(out, room, flags)
        out += text
    else:
        out += text
        padding(out, room, flags)


def boolean(mut out: String, value: Bool, flags: Int, width: Int):
    """`%t` and `%v` of a boolean. Go's `fmtBoolean`."""
    pad(out, "true" if value else "false", flags, width)


def integer(
    mut out: String,
    bits: UInt64,
    base: Int,
    signed: Bool,
    verb: Int,
    upper: Bool,
    flags: Int,
    width: Int,
    given: Int,
):
    """An integer in any of the four bases Go prints. Go's `fmtInteger`.

    Built least significant digit first and reversed at the end, where Go fills
    a buffer from the back. The two produce the same bytes and this way there
    is no arithmetic on an index to get wrong.

    `%03d` and `%.3d` both ask for leading zeros and Go resolves the collision
    by turning the width into a precision when only the flag was given, which
    is what puts the zeros after the sign instead of before it.
    """
    var u = bits
    var negative = signed and u.cast[DType.int64]() < 0
    if negative:
        u = ~u + 1

    var prec = 0
    if given >= 0:
        prec = given
        # A precision of zero and a value of zero print nothing at all, which
        # is not the same as printing nothing and skipping the padding.
        if prec == 0 and u == 0:
            padding(out, width, flags & ~ZERO)
            return
    elif (flags & ZERO) != 0 and (flags & MINUS) == 0 and width > 0:
        prec = width
        if negative or (flags & PLUS) != 0 or (flags & SPACE) != 0:
            prec -= 1

    var digits = (_UPPER if upper else _LOWER).as_bytes()
    var buf = List[Byte]()
    var divisor = UInt64(base)
    while u >= divisor:
        buf.append(digits[Int(u % divisor)])
        u //= divisor
    buf.append(digits[Int(u)])
    while len(buf) < prec:
        buf.append(_ZERO_BYTE)

    if (flags & SHARP) != 0:
        if base == 2:
            buf.append(Byte(ord("b")))
            buf.append(_ZERO_BYTE)
        elif base == 8:
            if buf[len(buf) - 1] != _ZERO_BYTE:
                buf.append(_ZERO_BYTE)
        elif base == 16:
            buf.append(digits[16])
            buf.append(_ZERO_BYTE)
    if verb == ord("O"):
        buf.append(Byte(ord("o")))
        buf.append(_ZERO_BYTE)

    if negative:
        buf.append(Byte(ord("-")))
    elif (flags & PLUS) != 0:
        buf.append(Byte(ord("+")))
    elif (flags & SPACE) != 0:
        buf.append(Byte(ord(" ")))

    buf.reverse()
    # The zeros are in the number already, so what is left is a space pad even
    # when the zero flag was given.
    pad(out, _text(buf), flags & ~ZERO, width)


def character(mut out: String, bits: UInt64, flags: Int, width: Int):
    """`%c`. Go's `fmtC`.

    Anything that is not a code point is the replacement character, which is
    the same answer Go gives and the reason the conversion goes through the
    unsigned value: `int32(-1)` is not minus one here, it is far above the
    largest rune.
    """
    var r = Int32(RUNE_ERROR) if bits > UInt64(MAX_RUNE) else Int32(
        bits.cast[DType.int32]()
    )
    var buf = List[Byte]()
    _ = append_rune(buf, r)
    pad(out, _text(buf), flags, width)


def quoted_rune(mut out: String, bits: UInt64, flags: Int, width: Int):
    """`%q` of an integer, a single quoted character literal. Go's `fmtQc`."""
    var r = Int32(RUNE_ERROR) if bits > UInt64(MAX_RUNE) else Int32(
        bits.cast[DType.int32]()
    )
    var text = quote_rune_to_ascii(r) if (flags & PLUS) != 0 else quote_rune(r)
    pad(out, text, flags, width)


def unicode(mut out: String, bits: UInt64, flags: Int, width: Int, given: Int):
    """`%U`, as `U+0078`, and with the sharp flag as `U+0078 'x'`. Go's
    `fmtUnicode`."""
    var prec = 4
    if given > 4:
        prec = given

    var buf = List[Byte]()
    # Built backwards like `integer`, so the quoted character that goes on the
    # end is the first thing in.
    if (
        (flags & SHARP) != 0
        and bits <= UInt64(MAX_RUNE)
        and is_print(Int32(bits.cast[DType.int32]()))
    ):
        buf.append(Byte(ord("'")))
        var encoded = List[Byte]()
        _ = append_rune(encoded, Int32(bits.cast[DType.int32]()))
        for i in reversed(range(len(encoded))):
            buf.append(encoded[i])
        buf.append(Byte(ord("'")))
        buf.append(Byte(ord(" ")))

    var digits = _UPPER.as_bytes()
    var u = bits
    var written = 0
    while u >= 16:
        buf.append(digits[Int(u & 0xF)])
        u >>= 4
        written += 1
    buf.append(digits[Int(u)])
    written += 1
    while written < prec:
        buf.append(_ZERO_BYTE)
        written += 1
    buf.append(Byte(ord("+")))
    buf.append(Byte(ord("U")))

    buf.reverse()
    pad(out, _text(buf), flags & ~ZERO, width)


def truncate(s: String, prec: Int) -> String:
    """The first `prec` runes of `s`. Go's `truncateString`.

    Runes rather than bytes, so `%.3s` of a Japanese word is three characters.
    Go measures the same thing the same way, and it is the one place a
    precision is not a count of digits.
    """
    if prec < 0:
        return s
    var b = s.as_bytes()
    var i = 0
    var left = prec
    while i < len(b):
        if left == 0:
            return String(s[byte=0:i])
        i += rune_at(b, i)[1]
        left -= 1
    return s


def text(mut out: String, s: String, flags: Int, width: Int, prec: Int):
    """`%s` and `%v` of a string. Go's `fmtS`."""
    pad(out, truncate(s, prec), flags, width)


def quoted(mut out: String, s: String, flags: Int, width: Int, prec: Int):
    """`%q` of a string. Go's `fmtQ`.

    The sharp flag asks for a backquoted literal and gets one only when the
    string can be written that way, which is `can_backquote`'s whole job. The
    plus flag asks for nothing outside ASCII.
    """
    var cut = truncate(s, prec)
    if (flags & SHARP) != 0 and can_backquote(cut):
        pad(out, "`" + cut + "`", flags, width)
        return
    var text = quote_to_ascii(cut) if (flags & PLUS) != 0 else quote(cut)
    pad(out, text, flags, width)


def hexadecimal(
    mut out: String, s: String, upper: Bool, flags: Int, width: Int, prec: Int
):
    """`%x` and `%X` of a string, two hexadecimal digits a byte. Go's `fmtSbx`.

    The space flag separates the bytes and the sharp flag adds `0x`, and
    together they add `0x` to every byte rather than to the string, which is
    Go's rule and reads like a hexdump.

    Bytes rather than runes throughout, including for the precision. This is
    the one verb where Go says so explicitly, because the point of it is the
    encoding rather than the text.
    """
    var b = s.as_bytes()
    var length = len(b)
    if prec >= 0 and prec < length:
        length = prec

    if length == 0:
        padding(out, width, flags)
        return

    var size = 2 * length
    if (flags & SPACE) != 0:
        if (flags & SHARP) != 0:
            size *= 2
        size += length - 1
    elif (flags & SHARP) != 0:
        size += 2

    if width > size and (flags & MINUS) == 0:
        padding(out, width - size, flags)

    var digits = (_UPPER if upper else _LOWER).as_bytes()
    var buf = List[Byte]()
    if (flags & SHARP) != 0:
        buf.append(_ZERO_BYTE)
        buf.append(digits[16])
    for i in range(length):
        if (flags & SPACE) != 0 and i > 0:
            buf.append(Byte(ord(" ")))
            if (flags & SHARP) != 0:
                buf.append(_ZERO_BYTE)
                buf.append(digits[16])
        buf.append(digits[Int(b[i] >> 4)])
        buf.append(digits[Int(b[i] & 0xF)])
    out += _text(buf)

    if width > size and (flags & MINUS) != 0:
        padding(out, width - size, flags)


def _restore_zeros(body: String, verb: Int, prec: Int) -> String:
    """What the sharp flag adds back to a float. Go's inner loop in `fmtFloat`.

    `%g` drops trailing zeros and the decimal point when they say nothing, and
    `%#g` is how a caller asks for them back, because a table of numbers reads
    better when the columns line up. The count is significant digits, so it
    starts at the first digit that is not a zero.
    """
    var digits = 0
    if (
        verb == ord("v")
        or verb == ord("g")
        or verb == ord("G")
        or verb == ord("x")
    ):
        digits = 6 if prec == -1 else prec

    var b = body.as_bytes()
    var tail = String()
    var cut = len(b)
    var point = False
    var nonzero = False
    for i in range(len(b)):
        var c = b[i]
        if c == Byte(ord(".")):
            point = True
        elif c == Byte(ord("p")) or c == Byte(ord("P")):
            tail = String(body[byte = i : len(b)])
            cut = i
            break
        elif (
            (c == Byte(ord("e")) or c == Byte(ord("E")))
            and verb != ord("x")
            and verb != ord("X")
        ):
            tail = String(body[byte = i : len(b)])
            cut = i
            break
        else:
            if c != _ZERO_BYTE:
                nonzero = True
            if nonzero:
                digits -= 1

    var kept = String(body[byte=0:cut])
    if not point:
        # A lone zero has contributed a digit already; anything else has not.
        if kept == "0":
            digits -= 1
        kept += "."
    while digits > 0:
        kept += "0"
        digits -= 1
    return kept + tail


def floating(
    mut out: String,
    value: Float64,
    bits: Int,
    verb: Int,
    default: Int,
    flags: Int,
    width: Int,
    given: Int,
) raises:
    """A float in any of Go's seven float verbs. Go's `fmtFloat`.

    The sign is worked out here rather than left to `strconv`, because zero
    padding has to go between the sign and the first digit and the sign has to
    be a space when the space flag asked for one.
    """
    var prec = given if given >= 0 else default
    var written = format_float(value, UInt8(verb), prec, bits)

    var sign = "+"
    var body = written
    if written.byte_length() > 0 and written.as_bytes()[0] == Byte(ord("-")):
        sign = "-"
        body = String(written[byte = 1 : written.byte_length()])
    if (flags & SPACE) != 0 and sign == "+" and (flags & PLUS) == 0:
        sign = " "

    var first = body.as_bytes()[0]
    if first == Byte(ord("I")) or first == Byte(ord("N")):
        # An infinity is never zero padded and a not a number carries no sign
        # unless one was asked for.
        if (
            first == Byte(ord("N"))
            and (flags & SPACE) == 0
            and (flags & PLUS) == 0
        ):
            pad(out, body, flags & ~ZERO, width)
        else:
            pad(out, sign + body, flags & ~ZERO, width)
        return

    if (flags & SHARP) != 0 and verb != ord("b"):
        body = _restore_zeros(body, verb, prec)

    if (flags & PLUS) != 0 or sign != "+":
        var whole = 1 + body.byte_length()
        if (flags & ZERO) != 0 and (flags & MINUS) == 0 and width > whole:
            out += sign
            padding(out, width - whole, flags)
            out += body
            return
        pad(out, sign + body, flags, width)
        return
    pad(out, body, flags, width)
