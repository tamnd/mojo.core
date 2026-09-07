"""Turning text into something that can go inside a document.

Five characters have a meaning in XML and three more have a meaning that
depends on where they are, and all eight are written as references here rather
than as themselves. Go escapes the same eight in the same way, including the
two it spells numerically to save a byte, so text escaped here and text escaped
by Go are the same bytes.

There is no unescaping half. Expanding a reference is the decoder's work and it
happens while the document is being read, because whether `&x;` is a reference
at all depends on the entity table the decoder was given. Go has no
`Unescape` either, and for the same reason.
"""

from core.io import Byte, Writer as IoWriter
from core.unicode.utf8 import decode_rune

comptime _ESC_QUOT = "&#34;"
"""A double quote. Shorter than `&quot;` by two bytes, which is Go's reason."""

comptime _ESC_APOS = "&#39;"
"""A single quote. Shorter than `&apos;`, again Go's reason."""

comptime _ESC_AMP = "&amp;"
"""An ampersand."""

comptime _ESC_LT = "&lt;"
"""A less than sign."""

comptime _ESC_GT = "&gt;"
"""A greater than sign. Only `]]>` really needs it, and Go escapes every one."""

comptime _ESC_TAB = "&#x9;"
"""A tab. Inside an attribute value a raw tab is turned into a space by any
conforming parser, so writing it raw would lose it."""

comptime _ESC_NL = "&#xA;"
"""A newline, for the reason the tab has."""

comptime _ESC_CR = "&#xD;"
"""A carriage return. This one has to be escaped everywhere: the specification
tells a parser to turn a raw one into a newline before anything else sees it,
so a raw carriage return does not survive a round trip."""

comptime _ESC_FFFD = "�"
"""The replacement character, which is what a byte that is not text becomes."""


def is_in_character_range(r: Int32) -> Bool:
    """Whether `r` may appear in a document at all. Go's `isInCharacterRange`.

    The `Char` production of the specification, section 2.2. Tab, newline and
    carriage return, then everything from a space up, less the surrogates and
    the two non characters at the end of the basic plane. Notably every other
    control character is excluded, so a document cannot carry a NUL or a bell
    even as an escape.
    """
    return (
        r == 0x09
        or r == 0x0A
        or r == 0x0D
        or (r >= 0x20 and r <= 0xD7FF)
        or (r >= 0xE000 and r <= 0xFFFD)
        or (r >= 0x10000 and r <= 0x10FFFF)
    )


def _escape_for(
    r: Int32, width: Int, escape_newline: Bool
) -> StringSlice[ImmStaticOrigin]:
    """What `r` has to be written as, or empty when it can be written as itself.

    Split out of the two loops below because they escape the same eight
    characters and differ only in where the bytes come from, and two copies of a
    table like this is how the two halves of an encoder come to disagree.
    """
    if r == Int32(ord('"')):
        return _ESC_QUOT
    if r == Int32(ord("'")):
        return _ESC_APOS
    if r == Int32(ord("&")):
        return _ESC_AMP
    if r == Int32(ord("<")):
        return _ESC_LT
    if r == Int32(ord(">")):
        return _ESC_GT
    if r == Int32(ord("\t")):
        return _ESC_TAB
    if r == Int32(ord("\n")):
        return _ESC_NL if escape_newline else ""
    if r == Int32(ord("\r")):
        return _ESC_CR
    # A rune the document may not hold, and a real U+FFFD is left alone while a
    # byte that merely decoded to one is not. That is the `width == 1` test:
    # the replacement character is three bytes when it was written on purpose
    # and one byte when it is standing in for something that was not UTF-8.
    if not is_in_character_range(r) or (r == 0xFFFD and width == 1):
        return _ESC_FFFD
    return ""


def _escape[
    W: IoWriter, //, o: Origin
](mut w: W, s: Span[Byte, o], escape_newline: Bool) raises:
    """The whole of the escaping, for both of the exported entry points.

    Runs of bytes that need nothing go out in one write, which is what makes
    this worth doing a rune at a time rather than a byte at a time: the common
    case for a document is a long stretch with nothing to escape in it.
    """
    var last = 0
    var i = 0
    while i < len(s):
        var decoded = decode_rune(s[i : len(s)])
        var r = decoded[0]
        var width = decoded[1]
        i += width
        var esc = _escape_for(r, width, escape_newline)
        if not esc:
            continue
        if i - width > last:
            _ = w.write(s[last : i - width])
        _ = w.write(esc.as_bytes())
        last = i
    if last < len(s):
        _ = w.write(s[last : len(s)])


def escape_text[W: IoWriter, //, o: Origin](mut w: W, s: Span[Byte, o]) raises:
    """Write `s` to `w` with the eight special characters spelled out.
    Go's `EscapeText`.

    ```mojo
    from core.bytes import new_buffer
    from core.encoding.xml import escape_text
    from core.io import Byte

    def main() raises:
        var out = new_buffer(List[Byte]())
        escape_text(out, "a < b & c".as_bytes())
        print(out.string())  # a &lt; b &amp; c
    ```

    Bytes that are not UTF-8 come out as replacement characters rather than
    raising, which is Go's behaviour and is the only one that makes sense for a
    function whose job is to produce something that parses.

    Go returns the write failure and this raises it, which is what every writer
    in this library does.
    """
    _escape(w, s, True)


def escape[W: IoWriter, //, o: Origin](mut w: W, s: Span[Byte, o]) raises:
    """`escape_text` under Go's older name. Go's `Escape`.

    Go's takes no error return because it predates `EscapeText`, and its own
    documentation says to use the other one. This is here so a port compiles
    and it does the same thing.
    """
    escape_text(w, s)
