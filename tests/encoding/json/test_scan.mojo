"""What the scanner accepts and what it refuses.

Go's `TestValid` is six rows and does not go anywhere near the edges, so most
of this is the edges: the shapes RFC 8259 names, the shapes it excludes, and
the four places a document can end in the middle of something.
"""

from std.testing import assert_equal, assert_true

from core.encoding.json import SyntaxError, valid, valid_or_raise
from core.errors import matches
from core.errors.codes import ErrJSONSyntax


def _accepts(text: StringSlice) raises:
    """Fail naming `text` if it is not accepted."""
    if not valid(text.as_bytes()):
        var why = String()
        try:
            valid_or_raise(text.as_bytes())
        except e:
            why = String(e)
        raise Error("refused " + repr(String(text)) + ": " + why)


def _refuses(text: StringSlice) raises:
    """Fail naming `text` if it is accepted."""
    if valid(text.as_bytes()):
        raise Error("accepted " + repr(String(text)))


def test_gos_own_six_rows() raises:
    """Go's `TestValid`."""
    _refuses("foo")
    _refuses("}{")
    _refuses("{]")
    _accepts("{}")
    _accepts('{"foo":"bar"}')
    _accepts('{"foo":"bar","bar":{"baz":["qux"]}}')


def test_every_kind_of_value_on_its_own() raises:
    """A document may be any value, not only an object or an array, which is
    RFC 8259 and was not true of RFC 4627."""
    _accepts("null")
    _accepts("true")
    _accepts("false")
    _accepts("0")
    _accepts('""')
    _accepts("[]")
    _accepts("{}")


def test_the_numbers_the_grammar_allows() raises:
    _accepts("0")
    _accepts("-0")
    _accepts("1")
    _accepts("-1")
    _accepts("1.5")
    _accepts("-1.5")
    _accepts("1e5")
    _accepts("1E5")
    _accepts("1e+5")
    _accepts("1e-5")
    _accepts("1.5e-5")
    _accepts("0.0000000000000000001")
    _accepts("123456789012345678901234567890")


def test_the_numbers_the_grammar_does_not() raises:
    """Every one of these is a number in some other language and none of them
    is one here, which is the point of the list."""
    _refuses("01")
    _refuses("-01")
    _refuses("+1")
    _refuses(".5")
    _refuses("1.")
    _refuses("1.e5")
    _refuses("1e")
    _refuses("1e+")
    _refuses("1e5.5")
    _refuses("0x10")
    _refuses("Infinity")
    _refuses("-Infinity")
    _refuses("NaN")
    _refuses("--1")


def test_gos_valid_number_table() raises:
    """Go's `TestNumberIsValid`, the accepting half.

    Go runs this against its `isValidNumber`, which is unexported, and against
    `Unmarshal` into a float. A number on its own is a whole document, so the
    scanner is asked the same question here and has to give the same answer.
    """
    var rows = [
        "0",
        "-0",
        "1",
        "-1",
        "0.1",
        "-0.1",
        "1234",
        "-1234",
        "12.34",
        "-12.34",
        "12E0",
        "12E1",
        "12e34",
        "12E-0",
        "12e+1",
        "12e-34",
        "-12E0",
        "-12E1",
        "-12e34",
        "-12E-0",
        "-12e+1",
        "-12e-34",
        "1.2E0",
        "1.2E1",
        "1.2e34",
        "1.2E-0",
        "1.2e+1",
        "1.2e-34",
        "-1.2E0",
        "-1.2E1",
        "-1.2e34",
        "-1.2E-0",
        "-1.2e+1",
        "-1.2e-34",
        "0E0",
        "0E1",
        "0e34",
        "0E-0",
        "0e+1",
        "0e-34",
        "-0E0",
        "-0E1",
        "-0e34",
        "-0E-0",
        "-0e+1",
        "-0e-34",
    ]
    for i in range(len(rows)):
        _accepts(rows[i])


def test_gos_invalid_number_table() raises:
    """Go's `TestNumberIsValid`, the refusing half."""
    var rows = [
        "",
        "invalid",
        "1.0.1",
        "1..1",
        "-1-2",
        "012a42",
        "01.2",
        "012",
        "12E12.12",
        "1e2e3",
        "1e+-2",
        "1e--23",
        "1e",
        "e1",
        "1e+",
        "1ea",
        "1a",
        "1.a",
        "1.",
        "01",
        "1.e1",
    ]
    for i in range(len(rows)):
        _refuses(rows[i])


def test_the_escapes_a_string_may_hold() raises:
    _accepts('"\\""')
    _accepts('"\\\\"')
    _accepts('"\\/"')
    _accepts('"\\b"')
    _accepts('"\\f"')
    _accepts('"\\n"')
    _accepts('"\\r"')
    _accepts('"\\t"')
    _accepts('"\\u0000"')
    _accepts('"\\uFFFF"')
    _accepts('"\\uD83D\\uDE00"')


def test_the_escapes_it_may_not() raises:
    """An unpaired surrogate escape is accepted by the scanner and refused
    later by whatever decodes the string, which is Go's split too: the state
    machine only counts hex digits."""
    _refuses('"\\x"')
    _refuses('"\\u"')
    _refuses('"\\u00"')
    _refuses('"\\u00G0"')
    _refuses('"\\\'"')
    _accepts('"\\uD800"')


def test_a_control_character_in_a_string_is_refused() raises:
    """Everything below a space has to be written as an escape, which is the
    one rule that catches a document with a raw newline in a string."""
    _refuses('"a\nb"')
    _refuses('"a\tb"')
    _accepts('"a\\nb"')


def test_the_four_bytes_of_whitespace_and_no_others() raises:
    _accepts(" \t\r\n1 \t\r\n")
    _refuses("\x0c1")
    _refuses("\x0b1")


def test_a_document_holding_two_values_is_refused() raises:
    """The whole input has to be one value, which is what separates this from
    a decoder reading a stream."""
    _refuses("{} {}")
    _refuses("1 2")
    _refuses("[][]")
    _refuses("nulll")


def test_a_document_that_stops_in_the_middle() raises:
    """Four places to run out of input, and each of them is a failure rather
    than a value that happens to be short."""
    _refuses("")
    _refuses("[")
    _refuses("[1")
    _refuses("[1,")
    _refuses("{")
    _refuses('{"a"')
    _refuses('{"a":')
    _refuses('{"a":1')
    _refuses('"unclosed')
    _refuses("tru")


def test_the_shapes_a_trailing_comma_makes() raises:
    _refuses("[1,]")
    _refuses('{"a":1,}')
    _refuses("[,]")
    _refuses("[1,,2]")
    _refuses("{,}")


def test_an_object_key_has_to_be_a_string() raises:
    _refuses("{a:1}")
    _refuses("{1:2}")
    _refuses("{'a':1}")
    _accepts('{"":1}')


def test_nesting_is_capped_at_ten_thousand() raises:
    """Go's `maxNestingDepth`. A few kilobytes of brackets is otherwise a
    stack the size of the input, which is the whole reason there is a cap."""
    var ok = String()
    for _ in range(10000):
        ok += "["
    for _ in range(10000):
        ok += "]"
    _accepts(ok)
    var too_deep = String()
    for _ in range(10001):
        too_deep += "["
    for _ in range(10001):
        too_deep += "]"
    _refuses(too_deep)


def test_the_failure_carries_gos_message_and_offset() raises:
    """Go's `TestIndentErrors` pins these two, message and offset both."""
    var raised = False
    try:
        valid_or_raise('{"X": "foo", "Y"}'.as_bytes())
    except e:
        raised = True
        assert_true(matches(e, ErrJSONSyntax))
        var failure = SyntaxError.of(e)
        assert_true(Bool(failure))
        assert_equal(
            failure.value().msg, "invalid character '}' after object key"
        )
        assert_equal(failure.value().offset, 17)
    assert_true(raised)


def test_the_second_of_gos_two_messages() raises:
    var raised = False
    try:
        valid_or_raise('{"X": "foo" "Y": "bar"}'.as_bytes())
    except e:
        raised = True
        var failure = SyntaxError.of(e)
        assert_true(Bool(failure))
        assert_equal(
            failure.value().msg,
            "invalid character '\"' after object key:value pair",
        )
        assert_equal(failure.value().offset, 13)
    assert_true(raised)


def test_an_empty_document_says_it_ended_early() raises:
    """The one message that names no character, because there was none."""
    var raised = False
    try:
        valid_or_raise("".as_bytes())
    except e:
        raised = True
        var failure = SyntaxError.of(e)
        assert_true(Bool(failure))
        assert_equal(failure.value().msg, "unexpected end of JSON input")
        assert_equal(failure.value().offset, 0)
    assert_true(raised)


def test_the_message_quotes_the_character_the_way_go_does() raises:
    """Go's `quoteChar`, which writes both quotes out itself because the
    quoting it borrows would get one of them wrong."""
    var got = String()
    try:
        valid_or_raise("'".as_bytes())
    except e:
        got = String(e)
    assert_equal(got, "invalid character '\\'' looking for beginning of value")


def test_a_syntax_error_from_somewhere_else_is_not_one() raises:
    """`of` hands back nothing rather than a wrong answer, which is what a
    type assertion does by failing."""
    assert_true(not SyntaxError.of(Error("something else")))


def test_the_depth_cap_names_itself() raises:
    var deep = String()
    for _ in range(10001):
        deep += "["
    var got = String()
    try:
        valid_or_raise(deep.as_bytes())
    except e:
        got = String(e)
    assert_equal(got, "invalid character '[' exceeded max depth")
