"""`marshal`, `unmarshal` and `Encoder`, over Go's own stream tables.

Go's `streamTest` is eight values, one of each JSON kind, and `streamEncoded`
and `streamEncodedIndent` are what an `Encoder` writes for them plain and laid
out. Both tables are here in full. Go's values are an `any` each and here each
one is a `RawMessage` holding the text, which is the same eight values arriving
through the interface Go's encoder would have found on them.

After the tables comes `TestEncoderSetEscapeHTML`, whose interesting rows are
the ones that go through a `MarshalJSON`, since that is the path every value
takes here. Then one behaviour at a time: what `marshal` does to whitespace and
to bytes that are not JSON, where the newline lands, and what a value that
refuses to be written does to the stream it was going into.
"""

from std.testing import assert_equal, assert_raises

from core.bytes import new_buffer
from core.encoding.json import (
    Marshaler,
    RawMessage,
    marshal,
    marshal_indent,
    new_encoder,
    unmarshal,
)
from core.errors import new as new_error
from core.io import Byte

comptime _STREAM_ENCODED = """0.1
"hello"
null
true
false
["a","b","c"]
{"ß":"long s","K":"Kelvin"}
3.14
"""
"""Go's `streamEncoded`, byte for byte."""

comptime _STREAM_ENCODED_INDENT = """0.1
"hello"
null
true
false
[
>."a",
>."b",
>."c"
>]
{
>."ß": "long s",
>."K": "Kelvin"
>}
3.14
"""
"""Go's `streamEncodedIndent`, with its prefix `>` and its indent `.`."""

comptime _SEPARATOR = '"a b"'
"""One string holding U+2028, the character Go escapes for JavaScript's sake
rather than for JSON's."""


struct _Written(Copyable, Marshaler, Movable):
    """Go's `strMarshaler`: whatever text it holds, handed back as the value.

    The type Go's escaping test is built on, and the reason it is built on one:
    a value that writes its own JSON is the only value whose bytes reach the
    encoder without having been through the escaping already.
    """

    var text: String

    def __init__(out self, text: StringSlice):
        self.text = String(text)

    def marshal_json(self) raises -> List[Byte]:
        return List[Byte](self.text.as_bytes())


struct _Refuses(Copyable, Marshaler, Movable):
    """A value that cannot be written, which is what a float that is not a
    number is."""

    var why: String

    def __init__(out self, why: StringSlice):
        self.why = String(why)

    def marshal_json(self) raises -> List[Byte]:
        raise new_error(self.why)


def _text(var data: List[Byte]) raises -> String:
    """A list of bytes as the text it holds."""
    return String(from_utf8=Span(data))


def _stream() raises -> List[RawMessage]:
    """Go's `streamTest`, each value as the text it was written with."""
    var texts: List[String] = [
        "0.1",
        '"hello"',
        "null",
        "true",
        "false",
        '["a","b","c"]',
        '{"ß":"long s","K":"Kelvin"}',
        "3.14",
    ]
    var out = List[RawMessage]()
    for i in range(len(texts)):
        var held = RawMessage()
        held.unmarshal_json(texts[i].as_bytes())
        out.append(held^)
    return out^


def test_gos_stream_table() raises:
    """Go's `TestEncoder`: the eight values, written one after another.

    `set_indent` is called with a shape and then with nothing, which is Go's
    own check that two empty strings turn the laying out off again rather than
    leaving the last shape in place.
    """
    var enc = new_encoder(new_buffer(List[Byte]()))
    enc.set_indent(">", ".")
    enc.set_indent("", "")
    var values = _stream()
    for i in range(len(values)):
        enc.encode(values[i])
    assert_equal(enc.w.string(), String(_STREAM_ENCODED))


def test_gos_indented_stream_table() raises:
    """Go's `TestEncoderIndent`, with the same eight values and Go's odd prefix
    and indent, which are chosen so that a stray space would show."""
    var enc = new_encoder(new_buffer(List[Byte]()))
    enc.set_indent(">", ".")
    var values = _stream()
    for i in range(len(values)):
        enc.encode(values[i])
    assert_equal(enc.w.string(), String(_STREAM_ENCODED_INDENT))


def test_a_shorter_stream_is_the_front_of_the_table() raises:
    """Go runs its table at every length from nothing to all of it.

    The point is that a value carries no state into the next one, so writing
    three values gives exactly what the first three lines say and not the first
    three lines with something extra between them.
    """
    var values = _stream()
    var enc = new_encoder(new_buffer(List[Byte]()))
    for i in range(3):
        enc.encode(values[i])
    assert_equal(enc.w.string(), '0.1\n"hello"\nnull\n')


def test_gos_escape_html_rows() raises:
    """The rows of Go's `TestEncoderSetEscapeHTML` that go through a
    `MarshalJSON`.

    Go's `strMarshaler` hands back `"<str>"` unescaped and the encoder escapes
    it on the way past, which is what makes this the row worth porting: it is
    the one place in Go's own test where the escaping is applied to bytes the
    encoder did not write.
    """
    var enc = new_encoder(new_buffer(List[Byte]()))
    enc.encode(_Written('"<str>"'))
    assert_equal(enc.w.string(), '"\\u003cstr\\u003e"\n')

    var off = new_encoder(new_buffer(List[Byte]()))
    off.set_escape_html(False)
    off.encode(_Written('"<str>"'))
    assert_equal(off.w.string(), '"<str>"\n')


def test_gos_ampersand_row() raises:
    """Go's `c` row, whose `MarshalJSON` hands back `"<&>"`."""
    var enc = new_encoder(new_buffer(List[Byte]()))
    enc.encode(_Written('"<&>"'))
    assert_equal(enc.w.string(), '"\\u003c\\u0026\\u003e"\n')


def test_the_two_separators_go_with_the_three() raises:
    """U+2028 and U+2029 follow the switch rather than ignoring it.

    Go's compacting pass escapes them alongside the three HTML characters and
    leaves them alone when the switch is off. That is not the rule Go's
    reflection path follows, which escapes them whatever the switch says, and
    the compacting one is right here because a value that writes its own JSON
    takes the compacting path in Go too.
    """
    var enc = new_encoder(new_buffer(List[Byte]()))
    enc.encode(_Written(_SEPARATOR))
    assert_equal(enc.w.string(), '"a\\u2028b"\n')

    var off = new_encoder(new_buffer(List[Byte]()))
    off.set_escape_html(False)
    off.encode(_Written(_SEPARATOR))
    assert_equal(off.w.string(), String(_SEPARATOR) + "\n")


def test_marshal_takes_the_whitespace_out() raises:
    """What comes back from `marshal_json` is compacted, which is what Go does
    with the result of a `MarshalJSON`."""
    var held = RawMessage()
    held.unmarshal_json('{ "a" : [ 1, 2 ] }'.as_bytes())
    assert_equal(_text(marshal(held)), '{"a":[1,2]}')


def test_marshal_escapes_without_being_asked() raises:
    """Go's `Marshal` escapes the three HTML characters and has no switch to
    turn that off. Only `Encoder` has one."""
    assert_equal(_text(marshal(_Written('"<&>"'))), '"\\u003c\\u0026\\u003e"')


def test_marshal_refuses_bytes_that_are_not_a_value() raises:
    """A type whose `marshal_json` is wrong is caught at the call that made the
    bytes rather than at the far end of a wire."""
    with assert_raises():
        _ = marshal(_Written("{"))
    with assert_raises():
        _ = marshal(_Written("[1,]"))
    with assert_raises():
        _ = marshal(_Written("1 2"))


def test_a_refusal_from_the_value_comes_back() raises:
    """`marshal_json` raising is `marshal` raising, unchanged."""
    with assert_raises(contains="unsupported value"):
        _ = marshal(_Refuses("json: unsupported value: NaN"))


def test_nothing_is_written_when_the_value_is_refused() raises:
    """A value the encoder will not write leaves the stream where it was, so
    the next value that is fine still lands at the start of a line."""
    var enc = new_encoder(new_buffer(List[Byte]()))
    with assert_raises():
        enc.encode(_Written("[1,]"))
    assert_equal(enc.w.string(), "")

    enc.encode(_Written("[1]"))
    assert_equal(enc.w.string(), "[1]\n")


def test_marshal_indent_lays_a_value_out() raises:
    """`marshal` and then `indent`, which is how Go builds `MarshalIndent`."""
    var held = RawMessage()
    held.unmarshal_json("[1,2]".as_bytes())
    assert_equal(_text(marshal_indent(held, "", "  ")), "[\n  1,\n  2\n]")


def test_marshal_indent_leaves_the_first_line_alone() raises:
    """The first line gets neither the prefix nor an indent, so the result
    drops into other formatted JSON at whatever level it is already at."""
    var held = RawMessage()
    held.unmarshal_json('{"a":1}'.as_bytes())
    assert_equal(_text(marshal_indent(held, ">", ".")), '{\n>."a": 1\n>}')


def test_unmarshal_reads_a_value_back() raises:
    """The other half of the pair, over the one type in the package that
    implements both."""
    var held = RawMessage()
    unmarshal('{"a":1}'.as_bytes(), held)
    assert_equal(String(held), '{"a":1}')


def test_unmarshal_checks_the_whole_document_first() raises:
    """Go checks before it reads and so does this, so a document with a second
    value after the first is refused rather than half read."""
    var held = RawMessage()
    held.unmarshal_json("[1]".as_bytes())
    with assert_raises():
        unmarshal("[1] [2]".as_bytes(), held)
    assert_equal(String(held), "[1]")


def test_unmarshal_leaves_the_value_alone_when_it_refuses() raises:
    """The rule the rest of the library follows: a value handed to a call that
    refuses its input comes back the value it was."""
    var held = RawMessage()
    held.unmarshal_json('"before"'.as_bytes())
    with assert_raises():
        unmarshal("{".as_bytes(), held)
    assert_equal(String(held), '"before"')


def test_a_value_writes_and_reads_back_the_same() raises:
    """The round trip over each of the six kinds a document can hold."""
    var texts: List[String] = [
        "null",
        "true",
        "0.1",
        '"hello"',
        "[1,2,3]",
        '{"a":{"b":[]}}',
    ]
    for i in range(len(texts)):
        var held = RawMessage()
        unmarshal(texts[i].as_bytes(), held)
        assert_equal(_text(marshal(held)), texts[i])


def test_an_empty_value_writes_as_null() raises:
    """Go's nil `RawMessage` writes as `null` and so does the empty one here,
    which is what keeps a field that carried nothing readable at the far
    end."""
    assert_equal(_text(marshal(RawMessage())), "null")


def test_the_newline_comes_before_the_laying_out() raises:
    """Go puts the newline on and then indents, which matters because `indent`
    copies trailing whitespace.

    A value that already ended in a line ending would otherwise pick up a
    second one, and a stream of laid out values would grow a blank line between
    every pair.
    """
    var enc = new_encoder(new_buffer(List[Byte]()))
    enc.set_indent("", " ")
    enc.encode(_Written("[1]\n"))
    assert_equal(enc.w.string(), "[\n 1\n]\n")
