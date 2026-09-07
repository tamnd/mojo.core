"""`Decoder`, against the documents Go's own tests read.

The two big cases are Go's `TestRawToken` and `TestToken`: the same document
parsed twice, once with the prefixes left alone and once with them resolved.
Everything after them is one behaviour at a time.
"""

from std.testing import assert_equal, assert_true

from core.bytes import new_buffer_string
from core.encoding.xml import (
    CHAR_DATA,
    COMMENT,
    DIRECTIVE,
    Directive,
    END_ELEMENT,
    PROC_INST,
    START_ELEMENT,
    SyntaxError,
    Token,
    html_auto_close,
    html_entity,
    new_decoder,
)
from core.encoding.xml.decode import _proc_inst
from core.errors import matches
from core.errors.codes import EOF, ErrXMLCharset, ErrXMLDepth, ErrXMLVersion

from ._fixtures import (
    NON_STRICT_INPUT,
    TEST_INPUT,
    chars,
    cooked_tokens,
    non_strict_tokens,
    raw_tokens,
    test_entity,
    xml_input,
)


def _read_all(text: String) raises -> List[Token]:
    """Every token of `text`, through `token`."""
    var d = new_decoder(new_buffer_string(text))
    var out = List[Token]()
    var tokens = d.tokens()
    while tokens.has_next():
        out.append(tokens.next())
    return out^


def _read_all_raw(text: String) raises -> List[Token]:
    """Every token of `text`, through `raw_token`."""
    var d = new_decoder(new_buffer_string(text))
    var out = List[Token]()
    while True:
        try:
            out.append(d.raw_token())
        except e:
            if matches(e, EOF):
                break
            raise e
    return out^


def _same(got: List[Token], want: List[Token], what: StringSlice) raises:
    """Compare two token lists and say which one differs when they do."""
    for i in range(min(len(got), len(want))):
        if got[i] != want[i]:
            raise Error(
                String(what)
                + ": token "
                + String(i)
                + " is "
                + String(got[i])
                + ", want "
                + String(want[i])
            )
    assert_equal(len(got), len(want))


def test_raw_token_reads_gos_document() raises:
    """Go's `TestRawToken`, token for token."""
    var d = new_decoder(new_buffer_string(TEST_INPUT))
    d.entity = test_entity()
    var got = List[Token]()
    while True:
        try:
            got.append(d.raw_token())
        except e:
            if matches(e, EOF):
                break
            raise e
    _same(got, raw_tokens(), "raw_token")


def test_token_reads_gos_document() raises:
    """Go's `TestToken`. The same bytes, with the prefixes resolved."""
    var d = new_decoder(new_buffer_string(TEST_INPUT))
    d.entity = test_entity()
    var got = List[Token]()
    var tokens = d.tokens()
    while tokens.has_next():
        got.append(tokens.next())
    _same(got, cooked_tokens(), "token")


def test_every_malformed_document_is_refused() raises:
    """Go's `TestSyntax`, over the whole of `xmlInput`.

    A document that ends early and a document that is nonsense are both
    failures of the same kind, and the point of the table is that none of them
    is quietly accepted.
    """
    var cases = xml_input()
    for i in range(len(cases)):
        var raised = False
        try:
            _ = _read_all(cases[i])
        except e:
            raised = True
            if not SyntaxError.of(e):
                raise Error(
                    "case " + cases[i] + ": not a syntax error: " + String(e)
                )
        if not raised:
            raise Error("case " + cases[i] + ": parsed, want a syntax error")


def test_a_forgiving_decoder_keeps_a_bad_entity() raises:
    """Go's `TestNonStrictRawToken`, all eight rows."""
    var d = new_decoder(new_buffer_string(NON_STRICT_INPUT))
    d.strict = False
    var got = List[Token]()
    while True:
        try:
            got.append(d.raw_token())
        except e:
            if matches(e, EOF):
                break
            raise e
    _same(got, non_strict_tokens(), "non strict")


def test_auto_close_invents_the_missing_end_tag() raises:
    """`<br>` written without its end half still arrives as two tokens.

    The names in `html_auto_close` are the thirteen HTML elements that are
    empty by definition, and each is closed on the very next token whatever
    that token is, which is what Go's own documentation says: closed
    immediately after they are opened. It is not a list of elements that close
    when the next one of the same name arrives, so `<p>` is not on it.
    """
    var d = new_decoder(new_buffer_string("<div>a<br>b</div>"))
    d.strict = False
    d.auto_close = html_auto_close()
    var shape = String()
    var tokens = d.tokens()
    while tokens.has_next():
        var t = tokens.next()
        if t.kind == START_ELEMENT:
            shape += "<" + t.name.local + ">"
        elif t.kind == END_ELEMENT:
            shape += "</" + t.name.local + ">"
        else:
            shape += t.text()
    assert_equal(shape, "<div>a<br></br>b</div>")


def test_the_html_entity_table_reads_html() raises:
    """The three lines Go's documentation gives, doing what it says they do."""
    var d = new_decoder(new_buffer_string("<p>caf&eacute; &amp; cr&egrave;me"))
    d.strict = False
    d.auto_close = html_auto_close()
    d.entity = html_entity()
    _ = d.token()
    assert_equal(d.token().text(), "café & crème")


def test_a_bare_attribute_is_its_own_value() raises:
    """`<input disabled>`, which HTML allows and XML does not."""
    var d = new_decoder(new_buffer_string("<input disabled>"))
    d.strict = False
    var t = d.token()
    assert_equal(t.attr[0].name.local, "disabled")
    assert_equal(t.attr[0].value, "disabled")


def test_an_unquoted_value_is_read_when_not_strict() raises:
    var d = new_decoder(new_buffer_string("<a href=x-1>"))
    d.strict = False
    assert_equal(d.token().attr[0].value, "x-1")


def test_a_declared_entity_expands_once() raises:
    """An entity's text is not read back, so `&e;` cannot expand twice.

    This is the whole of why there is no expansion budget to configure: the
    result of an expansion is never scanned for further references.
    """
    var d = new_decoder(new_buffer_string("<a>&e;</a>"))
    d.entity["e"] = String("&e;&e;")
    _ = d.token()
    assert_equal(d.token().text(), "&e;&e;")


def test_an_undeclared_entity_raises() raises:
    """The billion laughs document, which arrives here as an unknown name.

    The entity is declared in the doctype, and the doctype is not parsed, so
    there is nothing for `&lol;` to expand to and nothing to expand.
    """
    var d = new_decoder(
        new_buffer_string("<!DOCTYPE a [<!ENTITY lol 'ha'>]><a>&lol;</a>")
    )
    var raised = False
    try:
        while True:
            _ = d.token()
    except e:
        raised = True
        var failure = SyntaxError.of(e)
        assert_true(Bool(failure))
        assert_equal(failure.value().msg, "invalid character entity &lol;")
    assert_true(raised)


def test_the_doctype_is_a_directive_and_nothing_more() raises:
    var got = _read_all("<!DOCTYPE a [<!ENTITY lol 'ha'>]><a/>")
    assert_equal(got[0].kind, DIRECTIVE)
    assert_equal(got[0].text(), "DOCTYPE a [<!ENTITY lol 'ha'>]")


def test_a_comment_inside_a_directive_becomes_a_space() raises:
    """So that a `<` and a `!` the comment kept apart are not joined up."""
    var got = _read_all("<!DOCTYPE a [<!-- note -->]><a/>")
    assert_equal(got[0].text(), "DOCTYPE a [ ]")


def test_cdata_is_character_data() raises:
    var got = _read_all("<a><![CDATA[x < y & z]]></a>")
    assert_equal(got[1].kind, CHAR_DATA)
    assert_equal(got[1].text(), "x < y & z")


def test_a_comment_arrives_without_its_markers() raises:
    var got = _read_all("<a><!-- hi --></a>")
    assert_equal(got[1].kind, COMMENT)
    assert_equal(got[1].text(), " hi ")


def test_two_dashes_inside_a_comment_are_refused() raises:
    """A rule of the specification that surprises everybody."""
    var raised = False
    try:
        _ = _read_all("<a><!-- a -- b --></a>")
    except e:
        raised = True
        assert_equal(
            SyntaxError.of(e).value().msg,
            'invalid sequence "--" not allowed in comments',
        )
    assert_true(raised)


def test_a_processing_instruction_keeps_its_target() raises:
    var got = _read_all('<?target it="1"?><a/>')
    assert_equal(got[0].kind, PROC_INST)
    assert_equal(got[0].target, "target")
    assert_equal(got[0].text(), 'it="1"')


def test_an_empty_element_is_two_tokens() raises:
    """`<br/>` opens and closes, so a caller counting depth never has to know
    which spelling the document used."""
    var got = _read_all("<a><br/></a>")
    assert_equal(len(got), 4)
    assert_equal(got[1].kind, START_ELEMENT)
    assert_equal(got[2].kind, END_ELEMENT)
    assert_equal(got[2].name.local, "br")


def test_a_mismatched_end_tag_raises() raises:
    var raised = False
    try:
        _ = _read_all("<a>\n<b></a>")
    except e:
        raised = True
        var failure = SyntaxError.of(e)
        assert_true(Bool(failure))
        assert_equal(failure.value().line, 2)
        assert_equal(failure.value().msg, "element <b> closed by </a>")
    assert_true(raised)


def test_an_end_tag_in_the_wrong_space_raises() raises:
    var raised = False
    try:
        _ = _read_all('<x:a xmlns:x="u" xmlns:y="v"></y:a>')
    except e:
        raised = True
        assert_true(Bool(SyntaxError.of(e)))
    assert_true(raised)


def test_an_unclosed_element_is_a_truncated_document() raises:
    """Not the orderly end of the input, which is the difference between
    `token` and `raw_token` here."""
    var raised = False
    try:
        _ = _read_all("<a><b>")
    except e:
        raised = True
        assert_equal(SyntaxError.of(e).value().msg, "unexpected EOF")
    assert_true(raised)


def test_raw_token_ends_clean_on_the_same_document() raises:
    """`raw_token` keeps no stack, so it has nothing to be unhappy about."""
    assert_equal(len(_read_all_raw("<a><b>")), 2)


def test_a_character_the_document_may_not_hold_is_refused() raises:
    var raised = False
    try:
        _ = _read_all("<a>&#1;</a>")
    except e:
        raised = True
        assert_equal(
            SyntaxError.of(e).value().msg, "illegal character code U+0001"
        )
    assert_true(raised)


def test_a_surrogate_becomes_the_replacement_character() raises:
    """Go writes `string(rune(n))`, which turns a lone surrogate into U+FFFD,
    and this agrees with it."""
    var got = _read_all("<a>&#xD800;</a>")
    assert_equal(got[1].text(), "�")


def test_a_carriage_return_becomes_a_newline() raises:
    """Required of every parser, so a document written on Windows reads the
    same as one written anywhere else."""
    var got = _read_all("<a>x\r\ny\rz</a>")
    assert_equal(got[1].text(), "x\ny\nz")


def test_a_bad_version_is_refused() raises:
    """1.1 changed the line ending rules and the name rules, and neither of
    those changes is implemented here."""
    var raised = False
    try:
        _ = _read_all('<?xml version="1.1"?><a/>')
    except e:
        raised = True
        assert_true(matches(e, ErrXMLVersion))
    assert_true(raised)


def test_a_non_utf8_encoding_is_refused() raises:
    """Go refuses this too whenever its `CharsetReader` is nil, which is its
    default."""
    var raised = False
    try:
        _ = _read_all('<?xml version="1.0" encoding="latin-1"?><a/>')
    except e:
        raised = True
        assert_true(matches(e, ErrXMLCharset))
    assert_true(raised)


def test_utf_8_is_accepted_however_it_is_spelled() raises:
    var got = _read_all('<?xml version="1.0" encoding="utf-8"?><a/>')
    assert_equal(got[1].kind, START_ELEMENT)


def test_nesting_deeper_than_the_cap_is_refused() raises:
    """The one thing added to Go's token path, and the reason a document of
    nothing but open tags cannot allocate a stack the size of itself."""
    var text = String()
    for _ in range(50):
        text += "<a>"
    var d = new_decoder(new_buffer_string(text))
    d.max_depth = 10
    var raised = False
    try:
        while True:
            _ = d.token()
    except e:
        raised = True
        assert_true(matches(e, ErrXMLDepth))
    assert_true(raised)


def test_the_cap_can_be_raised() raises:
    var text = String()
    for _ in range(50):
        text += "<a>"
    for _ in range(50):
        text += "</a>"
    var d = new_decoder(new_buffer_string(text))
    d.max_depth = 100
    var seen = 0
    while True:
        try:
            _ = d.token()
            seen += 1
        except e:
            if matches(e, EOF):
                break
            raise e
    assert_equal(seen, 100)


def test_raw_token_ignores_the_cap() raises:
    """It keeps no stack, so there is nothing for a cap to protect."""
    var text = String()
    for _ in range(50):
        text += "<a>"
    var d = new_decoder(new_buffer_string(text))
    d.max_depth = 10
    assert_equal(len(_read_all_raw(text)), 50)


def test_the_failure_is_sticky() raises:
    """One malformed document, the same complaint every time after."""
    var d = new_decoder(new_buffer_string("<a></b>"))
    var first = String()
    try:
        while True:
            _ = d.token()
    except e:
        first = String(e)
    var second = String()
    try:
        _ = d.token()
    except e:
        second = String(e)
    assert_true(Bool(first))
    assert_equal(first, second)


def test_default_space_names_the_unprefixed() raises:
    """As if the whole document sat inside an element carrying `xmlns`."""
    var d = new_decoder(new_buffer_string("<a><b/></a>"))
    d.default_space = String("urn:x")
    assert_equal(d.token().name.space, "urn:x")
    assert_equal(d.token().name.space, "urn:x")


def test_the_default_space_does_not_reach_attributes() raises:
    """A rule of the name spaces recommendation, and the only reason
    `translate` takes a flag."""
    var d = new_decoder(new_buffer_string('<a k="v"/>'))
    d.default_space = String("urn:x")
    assert_equal(d.token().attr[0].name.space, "")


def test_the_xml_prefix_needs_no_declaration() raises:
    var got = _read_all('<a xml:lang="en"/>')
    assert_equal(
        got[0].attr[0].name.space, "http://www.w3.org/XML/1998/namespace"
    )


def test_input_offset_and_input_pos_follow_the_reader() raises:
    var d = new_decoder(new_buffer_string("<a>\n<b/></a>"))
    _ = d.token()
    assert_equal(d.input_offset(), 3)
    var pos = d.input_pos()
    assert_equal(pos[0], 1)
    assert_equal(pos[1], 4)
    _ = d.token()
    assert_equal(d.input_pos()[0], 2)


def test_skip_reads_to_the_end_of_the_element() raises:
    var d = new_decoder(new_buffer_string("<a><b><c/></b>after</a>"))
    _ = d.token()
    _ = d.token()
    d.skip()
    assert_equal(d.token().text(), "after")


def test_skip_past_the_end_raises() raises:
    var d = new_decoder(new_buffer_string("<a><b/></a>"))
    _ = d.token()
    var raised = False
    try:
        d.skip()
        d.skip()
    except e:
        raised = True
    assert_true(raised)


def test_a_nested_directive_keeps_all_of_itself() raises:
    """Go's `TestNestedDirectives`.

    A directive ends at the `>` that matches its `<!`, and the ones inside a
    nested declaration or inside quotes do not close it. Get that wrong and a
    doctype with an entity declaration in it is cut in half.
    """
    var doc = String(
        "\n<!DOCTYPE [<!ENTITY rdf"
        ' "http://www.w3.org/1999/02/22-rdf-syntax-ns#">]>\n<!DOCTYPE [<!ENTITY'
        ' xlt ">">]>\n<!DOCTYPE [<!ENTITY xlt "<">]>\n<!DOCTYPE [<!ENTITY xlt'
        " '>'>]>\n<!DOCTYPE [<!ENTITY xlt '<'>]>\n<!DOCTYPE [<!ENTITY xlt"
        " '\">'>]>\n<!DOCTYPE [<!ENTITY xlt \"'<\">]>\n"
    )
    var want = List[Token]()
    var bodies = [
        String('[<!ENTITY rdf "http://www.w3.org/1999/02/22-rdf-syntax-ns#">]'),
        String('[<!ENTITY xlt ">">]'),
        String('[<!ENTITY xlt "<">]'),
        String("[<!ENTITY xlt '>'>]"),
        String("[<!ENTITY xlt '<'>]"),
        String("[<!ENTITY xlt '\">'>]"),
        String('[<!ENTITY xlt "\'<">]'),
    ]
    for i in range(len(bodies)):
        want.append(chars("\n"))
        want.append(Token(Directive("DOCTYPE " + bodies[i])))
    want.append(chars("\n"))
    _same(_read_all(doc), want, "nested directives")


def test_a_directive_keeps_the_declarations_around_its_comments() raises:
    """Go's `TestDirectivesWithComments`.

    A comment inside a directive is dropped and leaves one space behind, and
    everything either side of it stays. Go's third line is the awkward one: a
    run of things that look like comments but are not.
    """
    var doc = String(
        "\n<!DOCTYPE [<!-- a comment --><!ENTITY rdf"
        ' "http://www.w3.org/1999/02/22-rdf-syntax-ns#">]>\n<!DOCTYPE [<!ENTITY'
        ' go "Golang"><!-- a comment-->]>\n<!DOCTYPE <!-> <!> <!----> <!-->-->'
        ' <!--->--> [<!ENTITY go "Golang"><!-- a comment-->]>\n'
    )
    var want = List[Token]()
    want.append(chars("\n"))
    want.append(
        Token(
            Directive(
                "DOCTYPE [ <!ENTITY rdf"
                ' "http://www.w3.org/1999/02/22-rdf-syntax-ns#">]'
            )
        )
    )
    want.append(chars("\n"))
    want.append(Token(Directive('DOCTYPE [<!ENTITY go "Golang"> ]')))
    want.append(chars("\n"))
    want.append(
        Token(Directive('DOCTYPE <!-> <!>       [<!ENTITY go "Golang"> ]'))
    )
    want.append(chars("\n"))
    _same(_read_all(doc), want, "directives with comments")


def test_the_declaration_is_read_the_way_go_reads_it() raises:
    """Go's `TestProcInstEncoding`, over the private `_proc_inst`.

    The declaration is not parsed as XML, it is scanned for `name="value"`,
    and the last one wins. The two rows Go marks as open questions are here
    with Go's answers, because the point of the table is that this behaves the
    way Go behaves rather than the way anybody would design it.
    """
    var rows = [
        (
            String('version="1.0" encoding="utf-8"'),
            String("1.0"),
            String("utf-8"),
        ),
        (
            String("version=\"1.0\" encoding='utf-8'"),
            String("1.0"),
            String("utf-8"),
        ),
        (
            String("version=\"1.0\" encoding='utf-8' "),
            String("1.0"),
            String("utf-8"),
        ),
        (String('version="1.0" encoding=utf-8'), String("1.0"), String("")),
        (String('encoding="FOO" '), String(""), String("FOO")),
        (
            String(
                "version=2.0 version=\"1.0\" encoding=utf-7 encoding='utf-8'"
            ),
            String("1.0"),
            String("utf-8"),
        ),
        (String("version= encoding="), String(""), String("")),
        (String('encoding="version=1.0"'), String(""), String("version=1.0")),
        (String(""), String(""), String("")),
        (
            String("encoding=\"version='1.0'\""),
            String("1.0"),
            String("version='1.0'"),
        ),
        (
            String("version=\"encoding='utf-8'\""),
            String("encoding='utf-8'"),
            String("utf-8"),
        ),
    ]
    for i in range(len(rows)):
        var got_version = _proc_inst("version", rows[i][0])
        if got_version != rows[i][1]:
            raise Error(
                "version of "
                + repr(rows[i][0])
                + " is "
                + repr(got_version)
                + ", want "
                + repr(rows[i][1])
            )
        var got_encoding = _proc_inst("encoding", rows[i][0])
        if got_encoding != rows[i][2]:
            raise Error(
                "encoding of "
                + repr(rows[i][0])
                + " is "
                + repr(got_encoding)
                + ", want "
                + repr(rows[i][2])
            )
