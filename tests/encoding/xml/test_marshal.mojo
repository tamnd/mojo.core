"""Whole values out and whole values back, through the four codec traits.

Go's own tests for this half are `TestMarshal` and `TestUnmarshal`, hundreds of
rows over structs with tags on them, and almost every row is a statement about
what reflection makes of a tag rather than about XML. There is no reflection
here, so what is left to test is the part Go's `Marshaler` path does: that a
value writing itself gets a whole element out, that a value reading itself back
gets the same value, and that a value cannot damage the document around it.
"""

from std.testing import assert_equal, assert_true

from core.bytes import new_buffer, new_buffer_string
from core.encoding.xml import (
    Attr,
    CHAR_DATA,
    CharData,
    Decoder,
    END_ELEMENT,
    Encoder,
    EndElement,
    Marshaler,
    MarshalerAttr,
    Name,
    START_ELEMENT,
    StartElement,
    Token,
    UnmarshalError,
    Unmarshaler,
    UnmarshalerAttr,
    marshal,
    marshal_indent,
    new_decoder,
    new_encoder,
    unmarshal,
    unmarshal_error,
)
from core.errors import matches
from core.errors.codes import EOF
from core.io import Byte, Reader as IoReader, Writer as IoWriter
from core.strings import contains


struct Person(Copyable, Marshaler, Movable, Unmarshaler):
    """A value that writes itself and reads itself back.

    The shape Go's `Marshaler` documentation suggests: a name in the text of an
    element and an age in an attribute on it, so that both halves of a start
    element are exercised.
    """

    var name: String
    var age: String

    def __init__(out self, name: StringSlice = "", age: StringSlice = ""):
        self.name = String(name)
        self.age = String(age)

    def marshal_xml[
        W: IoWriter & Deinitable & Movable
    ](self, mut e: Encoder[W], start: StartElement) raises:
        var open = start.copy()
        if not open.name.local:
            open.name = Name("", "person")
        open.attr.append(Attr(Name("", "age"), self.age))
        e.encode_token(Token(open.copy()))
        e.encode_token(Token(CharData(self.name)))
        e.encode_token(Token(open.end()))

    def unmarshal_xml[
        R: IoReader & Deinitable & Movable
    ](mut self, mut d: Decoder[R], start: StartElement) raises:
        if start.name.local != "person":
            raise unmarshal_error(
                "expected element type <person> but have <"
                + start.name.local
                + ">"
            )
        var age = String()
        for i in range(len(start.attr)):
            if start.attr[i].name.local == "age":
                age = start.attr[i].value.copy()
        var text = String()
        while True:
            var t = d.token()
            if t.kind == CHAR_DATA:
                text += t.text()
            elif t.kind == END_ELEMENT:
                break
        self.name = text^
        self.age = age^


struct Unclosed(Marshaler):
    """A value that opens an element and walks away from it."""

    def __init__(out self):
        pass

    def marshal_xml[
        W: IoWriter & Deinitable & Movable
    ](self, mut e: Encoder[W], start: StartElement) raises:
        e.encode_token(Token(StartElement(Name("", "left"), List[Attr]())))


struct Greedy(Marshaler):
    """A value that closes an element somebody else opened."""

    def __init__(out self):
        pass

    def marshal_xml[
        W: IoWriter & Deinitable & Movable
    ](self, mut e: Encoder[W], start: StartElement) raises:
        e.encode_token(Token(EndElement(Name("", "outer"))))


struct Celsius(Copyable, MarshalerAttr, Movable, UnmarshalerAttr):
    """A value that is one attribute rather than one element."""

    var degrees: String

    def __init__(out self, degrees: StringSlice = ""):
        self.degrees = String(degrees)

    def marshal_xml_attr(self, name: Name) raises -> Attr:
        if not self.degrees:
            return Attr(Name("", ""), "")
        return Attr(name, self.degrees + "C")

    def unmarshal_xml_attr(mut self, attr: Attr) raises:
        var value = attr.value
        if not value.endswith("C"):
            raise unmarshal_error("expected a temperature, have " + value)
        self.degrees = String(value[byte = 0 : value.byte_length() - 1])


def _text[o: ImmOrigin](b: Span[Byte, o]) -> String:
    """What was written, as something a comparison can print."""
    return String(from_utf8_lossy=b)


def test_a_value_writes_itself_as_one_element() raises:
    """Go's walk would name this element after the Go type and this value names
    it, which is the whole difference between the two halves."""
    assert_equal(
        _text(Span(marshal(Person("Ada", "36")))),
        '<person age="36">Ada</person>',
    )


def test_no_declaration_goes_out_in_front_of_it() raises:
    """Go writes none either, and `HEADER` is the constant for a caller who
    wants one."""
    var written = _text(Span(marshal(Person("Ada", "36"))))
    assert_true(not contains(written, "<?xml"), "a declaration appeared")


def test_the_caller_can_name_the_element_instead() raises:
    """`encode_element` is the call with a name in it, and the value here uses
    the one it was given rather than the one it would have picked."""
    var e = new_encoder(new_buffer(List[Byte]()))
    e.encode_element(
        Person("Ada", "36"), StartElement(Name("", "author"), List[Attr]())
    )
    e.close()
    assert_equal(_text(Span(e.w.w.bytes())), '<author age="36">Ada</author>')


def test_marshal_indent_puts_each_element_on_its_own_line() raises:
    """One element with text in it stays on one line, which is what
    `_indented_in` is for and is Go's layout as well."""
    assert_equal(
        _text(Span(marshal_indent(Person("Ada", "36"), "", "  "))),
        '<person age="36">Ada</person>',
    )


def test_a_value_that_leaves_an_element_open_is_refused() raises:
    """Go's `marshalInterface` check, which is the reason it pushes a marker at
    all. Without it the caller's document would be one tag short and nothing
    would say so until it was parsed by somebody else.
    """
    var raised = Optional[Error](None)
    try:
        _ = marshal(Unclosed())
    except err:
        raised = err
    assert_true(Bool(raised), "an element was left open and nothing said so")
    assert_true(
        contains(String(raised.value()), "<left> not closed"),
        "the message does not name the element: " + String(raised.value()),
    )


def test_a_value_cannot_close_an_element_it_did_not_open() raises:
    """The other half of the marker. The element being closed here is real and
    is open, and it still cannot be closed from inside the call, because the
    marker sits between it and the value writing itself.
    """
    var e = new_encoder(new_buffer(List[Byte]()))
    e.encode_token(Token(StartElement(Name("", "outer"), List[Attr]())))
    var raised = Optional[Error](None)
    try:
        e.encode_element(Greedy(), StartElement(Name("", "x"), List[Attr]()))
    except err:
        raised = err
    assert_true(Bool(raised), "a value closed the element around it")
    assert_true(
        contains(String(raised.value()), "without start tag"),
        "the message is not the one about a stray end tag: "
        + String(raised.value()),
    )


def test_a_value_reads_itself_back_out_of_a_document() raises:
    """The round trip, which is the only thing both halves have to agree on."""
    var read = Person()
    unmarshal('<person age="36">Ada</person>'.as_bytes(), read)
    assert_equal(read.name, "Ada")
    assert_equal(read.age, "36")
    assert_equal(_text(Span(marshal(read))), '<person age="36">Ada</person>')


def test_anything_in_front_of_the_element_is_skipped() raises:
    """A declaration, a comment and some whitespace, which is what a document
    off a wire looks like. Go's `Decode` skips them and so does this."""
    var read = Person()
    unmarshal(
        (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            "<!-- who -->\n"
            '<person age="36">Ada</person>'
        ).as_bytes(),
        read,
    )
    assert_equal(read.name, "Ada")


def test_a_document_with_no_element_is_the_end_of_the_input() raises:
    """Nothing to read into, and nothing here invents a value, so the raise is
    the one the reader underneath produced."""
    var read = Person()
    var raised = Optional[Error](None)
    try:
        unmarshal("<!-- nothing but a comment -->".as_bytes(), read)
    except err:
        raised = err
    assert_true(Bool(raised), "a document with no element read into a value")
    assert_true(
        matches(raised.value(), EOF),
        "the raise is not the end of the input: " + String(raised.value()),
    )


def test_the_wrong_element_is_an_unmarshal_error() raises:
    """The one thing Go's own walk raises on this path, and the reason the type
    is here. The document is well formed, so it is not a syntax error."""
    var read = Person()
    var raised = Optional[Error](None)
    try:
        unmarshal("<animal>Ada</animal>".as_bytes(), read)
    except err:
        raised = err
    assert_true(Bool(raised), "the wrong element was read into a person")
    var failure = UnmarshalError.of(raised.value())
    assert_true(Bool(failure), "the raise did not read back as UnmarshalError")
    assert_equal(
        failure.value().error(),
        "expected element type <person> but have <animal>",
    )


def test_a_refusal_leaves_the_value_it_was_handed_alone() raises:
    """The library's rule, stricter than Go's. Go writes fields into the
    destination as it goes and stops where it failed."""
    var read = Person("Ada", "36")
    try:
        unmarshal("<animal>Bob</animal>".as_bytes(), read)
    except:
        pass
    assert_equal(read.name, "Ada")
    assert_equal(read.age, "36")


def test_decode_element_takes_over_from_a_caller_reading_tokens() raises:
    """Go's stated reason for having two calls: read the tokens yourself until
    you know what the element is, then hand the rest over."""
    var d = new_decoder(
        new_buffer_string('<file><person age="36">Ada</person></file>')
    )
    _ = d.token()
    var start = d.token().start_element()
    var read = Person()
    d.decode_element(read, start)
    assert_equal(read.name, "Ada")
    assert_equal(d.token().kind, END_ELEMENT)


def test_an_attribute_writes_and_reads_itself() raises:
    """The attribute pair, which Go reaches for a field tagged `attr` and this
    reaches from the `marshal_xml` that wants one."""
    var written = Celsius("21").marshal_xml_attr(Name("", "temperature"))
    assert_equal(written.name.local, "temperature")
    assert_equal(written.value, "21C")

    var read = Celsius()
    read.unmarshal_xml_attr(written)
    assert_equal(read.degrees, "21")


def test_an_attribute_with_no_name_is_left_out_of_the_element() raises:
    """Go's rule, and how a value says it has nothing to write this time. The
    encoder skips it rather than writing an attribute with an empty name, which
    is not something XML can spell.
    """
    var e = new_encoder(new_buffer(List[Byte]()))
    var start = StartElement(Name("", "reading"), List[Attr]())
    start.attr.append(Celsius().marshal_xml_attr(Name("", "temperature")))
    e.encode_token(Token(start.copy()))
    e.encode_token(Token(start.end()))
    e.close()
    assert_equal(_text(Span(e.w.w.bytes())), "<reading></reading>")


def test_an_unmarshal_error_read_off_something_else_is_nothing() raises:
    """`of` says no rather than guessing, the same as `SyntaxError.of`."""
    var raised = Optional[Error](None)
    try:
        var read = Person()
        unmarshal("<person>Ada".as_bytes(), read)
    except err:
        raised = err
    assert_true(Bool(raised), "an unclosed element was accepted")
    assert_true(
        not UnmarshalError.of(raised.value()),
        "a syntax error read back as an UnmarshalError",
    )
