"""Go's `encodeTokenTests`, and the encoder's own rules around it.

The table is Go's, row for row, because it is where the name space prefix
invention is pinned down and that is the part of the encoder nobody would guess
right from the specification alone. The rest of the file covers what Go tests
separately: the xml declaration only being allowed first, a document surviving
a trip through the decoder and back, and what `close` says about a document
that was left open.
"""

from core.bytes import new_buffer
from core.encoding.xml import (
    Attr,
    CharData,
    Comment,
    Directive,
    Encoder,
    HEADER,
    Name,
    ProcInst,
    START_ELEMENT,
    StartElement,
    Token,
    new_decoder,
    new_encoder,
)
from core.errors import matches
from core.errors.codes import ErrXMLEncode
from core.io import Byte

from ._fixtures import attr, chars, end, start

comptime _XML_URL = "http://www.w3.org/XML/1998/namespace"
"""The one name space with a prefix that is fixed by the specification."""


struct EncodeCase(Copyable, Movable):
    """One row of Go's `encodeTokenTests`."""

    var desc: String
    """What the row is for, used in the failure message."""

    var toks: List[Token]
    """The tokens to encode, in order."""

    var want: String
    """What should have been written, including when the last token failed."""

    var err: String
    """The message the last token should fail with, or empty for none."""

    def __init__(
        out self,
        desc: StringSlice,
        var toks: List[Token],
        want: StringSlice = "",
        err: StringSlice = "",
    ):
        """A row."""
        self.desc = String(desc)
        self.toks = toks^
        self.want = String(want)
        self.err = String(err)


def _cases() -> List[EncodeCase]:
    """Go's `encodeTokenTests`."""
    var out = List[EncodeCase]()
    out.append(
        EncodeCase(
            "start element with name space",
            [start("space", "local", List[Attr]())],
            '<local xmlns="space">',
        )
    )
    out.append(
        EncodeCase(
            "start element with no name",
            [start("space", "", List[Attr]())],
            err="xml: start tag with no name",
        )
    )
    out.append(
        EncodeCase(
            "end element with no name",
            [end("space", "")],
            err="xml: end tag with no name",
        )
    )
    out.append(EncodeCase("char data", [chars("foo")], "foo"))
    out.append(
        EncodeCase("char data with escaped chars", [chars(" \t\n")], " &#x9;\n")
    )
    out.append(EncodeCase("comment", [Token(Comment("foo"))], "<!--foo-->"))
    out.append(
        EncodeCase(
            "comment with invalid content",
            [Token(Comment("foo-->"))],
            err="xml: EncodeToken of Comment containing --> marker",
        )
    )
    out.append(
        EncodeCase(
            "proc instruction",
            [Token(ProcInst("Target", "Instruction"))],
            "<?Target Instruction?>",
        )
    )
    out.append(
        EncodeCase(
            "proc instruction with empty target",
            [Token(ProcInst("", "Instruction"))],
            err="xml: EncodeToken of ProcInst with invalid Target",
        )
    )
    out.append(
        EncodeCase(
            "proc instruction with bad content",
            [Token(ProcInst("", "Instruction?>"))],
            err="xml: EncodeToken of ProcInst with invalid Target",
        )
    )
    out.append(EncodeCase("directive", [Token(Directive("foo"))], "<!foo>"))
    out.append(
        EncodeCase(
            "more complex directive",
            [
                Token(
                    Directive(
                        "DOCTYPE doc [ <!ELEMENT doc '>'> <!-- com>ment --> ]"
                    )
                )
            ],
            "<!DOCTYPE doc [ <!ELEMENT doc '>'> <!-- com>ment --> ]>",
        )
    )
    out.append(
        EncodeCase(
            "directive instruction with bad name",
            [Token(Directive("foo>"))],
            err="xml: EncodeToken of Directive containing wrong < or > markers",
        )
    )
    out.append(
        EncodeCase(
            "end tag without start tag",
            [end("foo", "bar")],
            err="xml: end tag </bar> without start tag",
        )
    )
    out.append(
        EncodeCase(
            "mismatching end tag local name",
            [start("", "foo", List[Attr]()), end("", "bar")],
            "<foo>",
            "xml: end tag </bar> does not match start tag <foo>",
        )
    )
    out.append(
        EncodeCase(
            "mismatching end tag namespace",
            [start("space", "foo", List[Attr]()), end("another", "foo")],
            '<foo xmlns="space">',
            (
                "xml: end tag </foo> in namespace another does not match start"
                " tag <foo> in namespace space"
            ),
        )
    )
    out.append(
        EncodeCase(
            "start element with explicit namespace",
            [
                start(
                    "space",
                    "local",
                    [
                        attr("xmlns", "x", "space"),
                        attr("space", "foo", "value"),
                    ],
                )
            ],
            (
                '<local xmlns="space" xmlns:_xmlns="xmlns" _xmlns:x="space"'
                ' xmlns:space="space" space:foo="value">'
            ),
        )
    )
    out.append(
        EncodeCase(
            "start element with explicit namespace and colliding prefix",
            [
                start(
                    "space",
                    "local",
                    [
                        attr("xmlns", "x", "space"),
                        attr("space", "foo", "value"),
                        attr("x", "bar", "other"),
                    ],
                )
            ],
            (
                '<local xmlns="space" xmlns:_xmlns="xmlns" _xmlns:x="space"'
                ' xmlns:space="space" space:foo="value" xmlns:x="x"'
                ' x:bar="other">'
            ),
        )
    )
    out.append(
        EncodeCase(
            "start element using previously defined namespace",
            [
                start("", "local", [attr("xmlns", "x", "space")]),
                start("space", "foo", [attr("space", "x", "y")]),
            ],
            (
                '<local xmlns:_xmlns="xmlns" _xmlns:x="space"><foo'
                ' xmlns="space" xmlns:space="space" space:x="y">'
            ),
        )
    )
    out.append(
        EncodeCase(
            "nested name space with same prefix",
            [
                start("", "foo", [attr("xmlns", "x", "space1")]),
                start("", "foo", [attr("xmlns", "x", "space2")]),
                start(
                    "",
                    "foo",
                    [
                        attr("space1", "a", "space1 value"),
                        attr("space2", "b", "space2 value"),
                    ],
                ),
                end("", "foo"),
                end("", "foo"),
                start(
                    "",
                    "foo",
                    [
                        attr("space1", "a", "space1 value"),
                        attr("space2", "b", "space2 value"),
                    ],
                ),
            ],
            (
                '<foo xmlns:_xmlns="xmlns" _xmlns:x="space1"><foo'
                ' _xmlns:x="space2"><foo xmlns:space1="space1"'
                ' space1:a="space1 value" xmlns:space2="space2"'
                ' space2:b="space2 value"></foo></foo><foo'
                ' xmlns:space1="space1" space1:a="space1 value"'
                ' xmlns:space2="space2" space2:b="space2 value">'
            ),
        )
    )
    out.append(
        EncodeCase(
            "start element defining several prefixes for the same name space",
            [
                start(
                    "space",
                    "foo",
                    [
                        attr("xmlns", "a", "space"),
                        attr("xmlns", "b", "space"),
                        attr("space", "x", "value"),
                    ],
                )
            ],
            (
                '<foo xmlns="space" xmlns:_xmlns="xmlns" _xmlns:a="space"'
                ' _xmlns:b="space" xmlns:space="space" space:x="value">'
            ),
        )
    )
    out.append(
        EncodeCase(
            "nested element redefines name space",
            [
                start("", "foo", [attr("xmlns", "x", "space")]),
                start(
                    "space",
                    "foo",
                    [
                        attr("xmlns", "y", "space"),
                        attr("space", "a", "value"),
                    ],
                ),
            ],
            (
                '<foo xmlns:_xmlns="xmlns" _xmlns:x="space"><foo'
                ' xmlns="space" _xmlns:y="space" xmlns:space="space"'
                ' space:a="value">'
            ),
        )
    )
    out.append(
        EncodeCase(
            "nested element creates alias for default name space",
            [
                start("space", "foo", [attr("", "xmlns", "space")]),
                start(
                    "space",
                    "foo",
                    [
                        attr("xmlns", "y", "space"),
                        attr("space", "a", "value"),
                    ],
                ),
            ],
            (
                '<foo xmlns="space" xmlns="space"><foo xmlns="space"'
                ' xmlns:_xmlns="xmlns" _xmlns:y="space" xmlns:space="space"'
                ' space:a="value">'
            ),
        )
    )
    out.append(
        EncodeCase(
            "nested element defines default name space with existing prefix",
            [
                start("", "foo", [attr("xmlns", "x", "space")]),
                start(
                    "space",
                    "foo",
                    [
                        attr("", "xmlns", "space"),
                        attr("space", "a", "value"),
                    ],
                ),
            ],
            (
                '<foo xmlns:_xmlns="xmlns" _xmlns:x="space"><foo'
                ' xmlns="space" xmlns="space" xmlns:space="space"'
                ' space:a="value">'
            ),
        )
    )
    out.append(
        EncodeCase(
            (
                "nested element uses empty attribute name space when default ns"
                " defined"
            ),
            [
                start("space", "foo", [attr("", "xmlns", "space")]),
                start("space", "foo", [attr("", "attr", "value")]),
            ],
            '<foo xmlns="space" xmlns="space"><foo xmlns="space" attr="value">',
        )
    )
    out.append(
        EncodeCase(
            "redefine xmlns",
            [start("", "foo", [attr("foo", "xmlns", "space")])],
            '<foo xmlns:foo="foo" foo:xmlns="space">',
        )
    )
    out.append(
        EncodeCase(
            "xmlns with explicit name space #1",
            [start("space", "foo", [attr("xml", "xmlns", "space")])],
            '<foo xmlns="space" xmlns:_xml="xml" _xml:xmlns="space">',
        )
    )
    out.append(
        EncodeCase(
            "xmlns with explicit name space #2",
            [start("space", "foo", [attr(_XML_URL, "xmlns", "space")])],
            '<foo xmlns="space" xml:xmlns="space">',
        )
    )
    out.append(
        EncodeCase(
            "empty name space declaration is ignored",
            [start("", "foo", [attr("xmlns", "foo", "")])],
            '<foo xmlns:_xmlns="xmlns" _xmlns:foo="">',
        )
    )
    out.append(
        EncodeCase(
            "attribute with no name is ignored",
            [start("", "foo", [attr("", "", "value")])],
            "<foo>",
        )
    )
    out.append(
        EncodeCase(
            "namespace URL with non-valid name",
            [start("/34", "foo", [attr("/34", "x", "value")])],
            '<foo xmlns="/34" xmlns:_="/34" _:x="value">',
        )
    )
    out.append(
        EncodeCase(
            "nested element resets default namespace to empty",
            [
                start("space", "foo", [attr("", "xmlns", "space")]),
                start(
                    "",
                    "foo",
                    [
                        attr("", "xmlns", ""),
                        attr("", "x", "value"),
                        attr("space", "x", "value"),
                    ],
                ),
            ],
            (
                '<foo xmlns="space" xmlns="space"><foo xmlns="" x="value"'
                ' xmlns:space="space" space:x="value">'
            ),
        )
    )
    out.append(
        EncodeCase(
            "nested element requires empty default name space",
            [
                start("space", "foo", [attr("", "xmlns", "space")]),
                start("", "foo", List[Attr]()),
            ],
            '<foo xmlns="space" xmlns="space"><foo>',
        )
    )
    out.append(
        EncodeCase(
            "attribute uses name space from xmlns",
            [
                start(
                    "some/space",
                    "foo",
                    [
                        attr("", "attr", "value"),
                        attr("some/space", "other", "other value"),
                    ],
                )
            ],
            (
                '<foo xmlns="some/space" attr="value" xmlns:space="some/space"'
                ' space:other="other value">'
            ),
        )
    )
    out.append(
        EncodeCase(
            "default name space should not be used by attributes",
            [
                start(
                    "space",
                    "foo",
                    [
                        attr("", "xmlns", "space"),
                        attr("xmlns", "bar", "space"),
                        attr("space", "baz", "foo"),
                    ],
                ),
                start("space", "baz", List[Attr]()),
                end("space", "baz"),
                end("space", "foo"),
            ],
            (
                '<foo xmlns="space" xmlns="space" xmlns:_xmlns="xmlns"'
                ' _xmlns:bar="space" xmlns:space="space" space:baz="foo"><baz'
                ' xmlns="space"></baz></foo>'
            ),
        )
    )
    out.append(
        EncodeCase(
            "default name space not used by attributes, not explicitly defined",
            [
                start(
                    "space",
                    "foo",
                    [
                        attr("", "xmlns", "space"),
                        attr("space", "baz", "foo"),
                    ],
                ),
                start("space", "baz", List[Attr]()),
                end("space", "baz"),
                end("space", "foo"),
            ],
            (
                '<foo xmlns="space" xmlns="space" xmlns:space="space"'
                ' space:baz="foo"><baz xmlns="space"></baz></foo>'
            ),
        )
    )
    out.append(
        EncodeCase(
            "impossible xmlns declaration",
            [
                start("", "foo", [attr("", "xmlns", "space")]),
                start("space", "bar", [attr("space", "attr", "value")]),
            ],
            (
                '<foo xmlns="space"><bar xmlns="space" xmlns:space="space"'
                ' space:attr="value">'
            ),
        )
    )
    out.append(
        EncodeCase(
            "reserved namespace prefix, all lower case",
            [
                start(
                    "",
                    "foo",
                    [
                        attr(
                            "http://www.w3.org/2001/xmlSchema-instance",
                            "nil",
                            "true",
                        )
                    ],
                )
            ],
            (
                '<foo xmlns:_xmlSchema-instance="http://www.w3.org/2001/'
                'xmlSchema-instance" _xmlSchema-instance:nil="true">'
            ),
        )
    )
    out.append(
        EncodeCase(
            "reserved namespace prefix, all upper case",
            [
                start(
                    "",
                    "foo",
                    [
                        attr(
                            "http://www.w3.org/2001/XMLSchema-instance",
                            "nil",
                            "true",
                        )
                    ],
                )
            ],
            (
                '<foo xmlns:_XMLSchema-instance="http://www.w3.org/2001/'
                'XMLSchema-instance" _XMLSchema-instance:nil="true">'
            ),
        )
    )
    out.append(
        EncodeCase(
            "reserved namespace prefix, all mixed case",
            [
                start(
                    "",
                    "foo",
                    [
                        attr(
                            "http://www.w3.org/2001/XmLSchema-instance",
                            "nil",
                            "true",
                        )
                    ],
                )
            ],
            (
                '<foo xmlns:_XmLSchema-instance="http://www.w3.org/2001/'
                'XmLSchema-instance" _XmLSchema-instance:nil="true">'
            ),
        )
    )
    return out^


def test_every_token_is_written_the_way_go_writes_it() raises:
    """Go's `TestEncodeToken`, row for row.

    A row that expects a failure still says what should have reached the
    writer before it, because a failing token has to leave the bytes it had
    already written alone rather than truncating them.
    """
    var cases = _cases()
    for i in range(len(cases)):
        var row = cases[i].copy()
        var e = new_encoder(new_buffer(List[Byte]()))
        var raised = Optional[Error](None)
        for j in range(len(row.toks)):
            try:
                e.encode_token(row.toks[j])
            except err:
                raised = err
                if j < len(row.toks) - 1:
                    raise Error(
                        row.desc
                        + ": token "
                        + String(j)
                        + " raised "
                        + String(raised.value())
                    )
                break
        if row.err:
            if not raised:
                raise Error(
                    row.desc + ": expected " + row.err + ", nothing raised"
                )
            var got_err = String(raised.value())
            if got_err != row.err:
                raise Error(
                    row.desc
                    + ": raised "
                    + repr(got_err)
                    + ", want "
                    + repr(row.err)
                )
            if not matches(raised.value(), ErrXMLEncode):
                raise Error(row.desc + ": raise is not tagged ErrXMLEncode")
        elif raised:
            raise Error(row.desc + ": raised " + String(raised.value()))
        e.flush()
        var got = e.w.w.string()
        if got != row.want:
            raise Error(
                row.desc + ": wrote " + repr(got) + ", want " + repr(row.want)
            )


def test_the_declaration_only_goes_first() raises:
    """Go's `TestProcInstEncodeToken`.

    An `xml` processing instruction is the declaration and there is exactly one
    place it may go. Any other target may appear anywhere.
    """
    var e = new_encoder(new_buffer(List[Byte]()))
    e.encode_token(Token(ProcInst("xml", "Instruction")))
    e.encode_token(Token(ProcInst("Target", "Instruction")))
    var raised = False
    try:
        e.encode_token(Token(ProcInst("xml", "Instruction")))
    except err:
        raised = True
        if not matches(err, ErrXMLEncode):
            raise Error("raise is not tagged ErrXMLEncode")
    if not raised:
        raise Error("a second xml declaration was accepted")


def test_flushing_first_does_not_buy_a_second_declaration() raises:
    """A flush must not make the encoder think it is still at the start.

    Go asks its buffered writer whether it holds anything, which is the same
    question only until the first flush. This is the one place the two differ
    and it is a deviation on purpose, so it is pinned here rather than left to
    be discovered.
    """
    var e = new_encoder(new_buffer(List[Byte]()))
    e.encode_token(chars("text"))
    e.flush()
    var raised = False
    try:
        e.encode_token(Token(ProcInst("xml", 'version="1.0"')))
    except err:
        raised = True
    if not raised:
        raise Error("a declaration was accepted after a flush")


def test_a_document_survives_a_trip_through_both_halves() raises:
    """Go's `TestDecodeEncode`. Every token a decoder produces is one an
    encoder accepts."""
    var doc = String(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        "<?Target Instruction?>\n"
        "<root>\n"
        "</root>\n"
    )
    var d = new_decoder(new_buffer(List[Byte](doc.as_bytes())))
    var e = new_encoder(new_buffer(List[Byte]()))
    var tokens = d.tokens()
    while tokens.has_next():
        e.encode_token(tokens.next())
    e.close()
    var got = e.w.w.string()
    if got != doc:
        raise Error("round trip wrote " + repr(got) + ", want " + repr(doc))


def test_the_header_is_the_declaration_go_writes() raises:
    """`HEADER` is a constant because everybody writes the same two
    attributes in the same order."""
    if HEADER != '<?xml version="1.0" encoding="UTF-8"?>\n':
        raise Error("HEADER is " + repr(HEADER))


def test_indenting_puts_every_element_on_its_own_line() raises:
    """`indent` writes a newline and one copy of the indent per level.

    An element with nothing between its tags stays on one line, which is the
    whole job of the flag Go calls `indentedIn`.
    """
    var e = new_encoder(new_buffer(List[Byte]()))
    e.indent("", "  ")
    e.encode_token(start("", "a", List[Attr]()))
    e.encode_token(start("", "b", List[Attr]()))
    e.encode_token(end("", "b"))
    e.encode_token(start("", "c", List[Attr]()))
    e.encode_token(chars("text"))
    e.encode_token(end("", "c"))
    e.encode_token(end("", "a"))
    e.close()
    var want = String("<a>\n  <b></b>\n  <c>text</c>\n</a>")
    var got = e.w.w.string()
    if got != want:
        raise Error("wrote " + repr(got) + ", want " + repr(want))


def test_a_prefix_goes_in_front_of_every_line() raises:
    """The prefix of `indent` leads each line, before the indentation."""
    var e = new_encoder(new_buffer(List[Byte]()))
    e.indent("| ", "..")
    e.encode_token(start("", "a", List[Attr]()))
    e.encode_token(start("", "b", List[Attr]()))
    e.encode_token(chars("x"))
    e.encode_token(end("", "b"))
    e.encode_token(end("", "a"))
    e.close()
    var want = String("| <a>\n| ..<b>x</b>\n| </a>")
    var got = e.w.w.string()
    if got != want:
        raise Error("wrote " + repr(got) + ", want " + repr(want))


def test_nothing_reaches_the_writer_until_it_is_flushed() raises:
    """Everything is buffered, which is why `close` exists."""
    var e = new_encoder(new_buffer(List[Byte]()))
    e.encode_token(start("", "a", List[Attr]()))
    e.encode_token(end("", "a"))
    if e.w.w.string() != "":
        raise Error("bytes reached the writer before a flush")
    e.close()
    if e.w.w.string() != "<a></a>":
        raise Error("close did not flush")


def test_closing_with_an_element_still_open_raises() raises:
    """A document that stops in the middle is the failure `close` is for."""
    var e = new_encoder(new_buffer(List[Byte]()))
    e.encode_token(start("", "a", List[Attr]()))
    var raised = Optional[Error](None)
    try:
        e.close()
    except err:
        raised = err
    if not raised:
        raise Error("close accepted an unclosed document")
    if String(raised.value()) != "unclosed tag <a>":
        raise Error("close raised " + repr(String(raised.value())))
    if e.w.w.string() != "<a>":
        raise Error("close did not flush what had been written")


def test_closing_twice_is_not_a_failure() raises:
    """The second call does nothing, which is Go's behaviour."""
    var e = new_encoder(new_buffer(List[Byte]()))
    e.encode_token(start("", "a", List[Attr]()))
    e.encode_token(end("", "a"))
    e.close()
    e.close()
    if e.w.w.string() != "<a></a>":
        raise Error("the second close wrote something")


def test_writing_after_close_raises() raises:
    """A closed encoder cannot quietly append to a finished document."""
    var e = new_encoder(new_buffer(List[Byte]()))
    e.encode_token(start("", "a", List[Attr]()))
    e.encode_token(end("", "a"))
    e.close()
    var raised = False
    try:
        e.encode_token(chars("more"))
    except err:
        raised = True
        if String(err) != "xml: use of closed Encoder":
            raise Error("raised " + repr(String(err)))
    if not raised:
        raise Error("a closed encoder accepted a token")


def test_a_comment_holding_the_end_marker_is_refused() raises:
    """Writing it would end the comment early and the rest would be markup."""
    var e = new_encoder(new_buffer(List[Byte]()))
    var raised = False
    try:
        e.encode_token(Token(Comment("a --> b")))
    except err:
        raised = True
    if not raised:
        raise Error("a comment containing --> was written")


def test_a_directive_with_unbalanced_brackets_is_refused() raises:
    """Angle brackets have to balance outside comments and quotes.

    The quoted and commented ones do not count, which is what lets a real
    doctype through: it is full of both.
    """
    var ok = String('DOCTYPE a [ <!ENTITY b "c > d"> <!-- e > f --> ]')
    var e = new_encoder(new_buffer(List[Byte]()))
    e.encode_token(Token(Directive(ok)))
    e.close()
    if e.w.w.string() != "<!" + ok + ">":
        raise Error("wrote " + repr(e.w.w.string()))

    var bad = new_encoder(new_buffer(List[Byte]()))
    var raised = False
    try:
        bad.encode_token(Token(Directive("DOCTYPE a <")))
    except err:
        raised = True
    if not raised:
        raise Error("an unbalanced directive was written")


def test_an_attribute_value_has_its_newlines_escaped() raises:
    """A raw newline inside quotes is turned into a space by any parser, so a
    value that held one would not read back as it was written."""
    var e = new_encoder(new_buffer(List[Byte]()))
    e.encode_token(start("", "a", [attr("", "x", "one\ntwo")]))
    e.encode_token(end("", "a"))
    e.close()
    var want = String('<a x="one&#xA;two"></a>')
    var got = e.w.w.string()
    if got != want:
        raise Error("wrote " + repr(got) + ", want " + repr(want))


def test_character_data_keeps_its_newlines() raises:
    """Outside an attribute a newline is whitespace and survives as itself."""
    var e = new_encoder(new_buffer(List[Byte]()))
    e.encode_token(start("", "a", List[Attr]()))
    e.encode_token(chars("one\ntwo"))
    e.encode_token(end("", "a"))
    e.close()
    var want = String("<a>one\ntwo</a>")
    var got = e.w.w.string()
    if got != want:
        raise Error("wrote " + repr(got) + ", want " + repr(want))
