"""What `escape_text` writes, and what `is_in_character_range` allows.

The eight characters that get spelled out are the whole of the escaping half,
so most of this is one table of them. The rest is Go's own two tests: bytes
that are not text becoming the replacement character, and the four runes a
document may never hold.
"""

from core.bytes import new_buffer
from core.encoding.xml import escape, escape_text, is_in_character_range
from core.io import Byte


def _escaped(s: StringSlice) raises -> String:
    """`s` through `escape_text`."""
    var out = new_buffer(List[Byte]())
    escape_text(out, s.as_bytes())
    return out.string()


def test_the_eight_special_characters_are_spelled_out() raises:
    """Five have a meaning in XML and three are turned into something else by
    a parser if they are written raw."""
    var pairs = [
        ('"', "&#34;"),
        ("'", "&#39;"),
        ("&", "&amp;"),
        ("<", "&lt;"),
        (">", "&gt;"),
        ("\t", "&#x9;"),
        ("\n", "&#xA;"),
        ("\r", "&#xD;"),
    ]
    for i in range(len(pairs)):
        var got = _escaped(pairs[i][0])
        if got != pairs[i][1]:
            raise Error(
                repr(pairs[i][0])
                + " escaped to "
                + repr(got)
                + ", want "
                + repr(String(pairs[i][1]))
            )


def test_the_two_quotes_are_written_the_short_way() raises:
    """Go writes the numeric form because it is two bytes shorter than the
    named one, and a document full of attributes is full of these."""
    if _escaped('a"b') != "a&#34;b":
        raise Error("a double quote is not written numerically")
    if _escaped("a'b") != "a&#39;b":
        raise Error("a single quote is not written numerically")


def test_text_with_nothing_to_escape_goes_out_as_it_came_in() raises:
    """The common case, and the reason the escaping walks runs rather than
    bytes."""
    var plain = String("a long stretch of perfectly ordinary text 白鵬翔")
    if _escaped(plain) != plain:
        raise Error("plain text was changed")


def test_a_run_between_two_escapes_survives() raises:
    """The bytes either side of something escaped have to come out in order."""
    if _escaped("a<b>c") != "a&lt;b&gt;c":
        raise Error("wrote " + repr(_escaped("a<b>c")))


def test_a_byte_that_is_not_text_becomes_the_replacement_character() raises:
    """Go's `TestEscapeTextInvalidChar`.

    A NUL is outside the character range whatever encoding it arrived in, so
    it goes out as U+FFFD rather than raising. Escaping produces something
    that parses or it is not doing its job.
    """
    var input = List[Byte]()
    input.extend("A ".as_bytes())
    input.append(0)
    input.extend(" terminated string.".as_bytes())
    var out = new_buffer(List[Byte]())
    escape_text(out, Span(input))
    var want = String("A � terminated string.")
    var got = out.string()
    if got != want:
        raise Error("wrote " + repr(got) + ", want " + repr(want))


def test_a_real_replacement_character_is_left_alone() raises:
    """A U+FFFD somebody wrote on purpose is three bytes and is text.

    Only the one byte version, which is what a decoder produces for something
    that was not UTF-8, gets rewritten. Both come out as the same character
    here; the distinction is that the three byte one is not touched at all.
    """
    if _escaped("�") != "�":
        raise Error("a written replacement character was rewritten")


def test_escape_is_escape_text_under_the_older_name() raises:
    """Go keeps both and its own documentation says to use the newer one."""
    var out = new_buffer(List[Byte]())
    escape(out, "a < b".as_bytes())
    if out.string() != "a &lt; b":
        raise Error("escape wrote " + repr(out.string()))


def test_the_character_range_is_the_one_the_specification_gives() raises:
    """Tab, newline and carriage return, then everything from a space up, less
    the surrogates and the two non characters at the end of the basic plane.
    """
    var allowed = [
        Int32(0x09),
        0x0A,
        0x0D,
        0x20,
        0xD7FF,
        0xE000,
        0xFFFD,
        0x10000,
        0x10FFFF,
    ]
    for i in range(len(allowed)):
        if not is_in_character_range(allowed[i]):
            raise Error(String(allowed[i]) + " should be allowed")
    var refused = [
        Int32(0x00),
        0x08,
        0x0B,
        0x0C,
        0x1F,
        0xD800,
        0xDFFF,
        0xFFFE,
        0xFFFF,
        0x110000,
        -1,
    ]
    for i in range(len(refused)):
        if is_in_character_range(refused[i]):
            raise Error(String(refused[i]) + " should be refused")


def test_every_control_character_but_three_is_outside_the_range() raises:
    """A document cannot carry a NUL or a bell even as a numeric reference,
    which is the part of the rule that surprises people."""
    for c in range(0x20):
        var allowed = c == 0x09 or c == 0x0A or c == 0x0D
        if is_in_character_range(Int32(c)) != allowed:
            raise Error("control character " + String(c) + " is wrong")
