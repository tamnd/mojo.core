"""Tests for reading a whole document into an arena.

Go has no table to start from here, because Go's answer is `Unmarshal` into an
`any` and its tests are about reflection rather than about the tree that comes
out. What this checks instead is the four things issue 32 asks a document to
decide: that a number keeps what was written, that an unpaired surrogate and
bytes that are not UTF-8 are refused rather than repaired, that nesting is
capped, and that duplicate keys have one answer and it is written down.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.encoding.json import (
    ARRAY,
    BOOL,
    MAX_NESTING_DEPTH,
    NULL,
    NUMBER,
    OBJECT,
    STRING,
    SyntaxError,
    new_document,
    parse,
    valid,
)
from core.errors import matches
from core.errors.codes import ErrJSONStale, ErrJSONText
from core.io import Byte


def _out(text: StringSlice) raises -> String:
    """`text` parsed and written straight back out again."""
    var doc = parse(text.as_bytes())
    return String(doc.root())


def test_the_six_kinds_all_arrive() raises:
    var nothing = parse("null".as_bytes())
    assert_equal(nothing.root().kind(), NULL)
    assert_true(nothing.root().is_null())

    var yes = parse("true".as_bytes())
    assert_equal(yes.root().kind(), BOOL)
    assert_true(yes.root().as_bool())

    var no = parse("false".as_bytes())
    assert_false(no.root().as_bool())

    var n = parse("12".as_bytes())
    assert_equal(n.root().kind(), NUMBER)
    assert_equal(n.root().as_number().string(), "12")

    var s = parse('"hi"'.as_bytes())
    assert_equal(s.root().kind(), STRING)
    assert_equal(s.root().as_string(), "hi")

    var a = parse("[]".as_bytes())
    assert_equal(a.root().kind(), ARRAY)

    var o = parse("{}".as_bytes())
    assert_equal(o.root().kind(), OBJECT)


def test_a_scalar_answers_only_its_own_question() raises:
    var doc = parse('"hi"'.as_bytes())
    var root = doc.root()
    with assert_raises(contains="json: value is a string, not a number"):
        _ = root.as_number()
    with assert_raises(contains="json: value is a string, not a boolean"):
        _ = root.as_bool()
    with assert_raises(contains="json: value is a string, not an array"):
        _ = root.at(0)
    with assert_raises(contains="json: value is a string, not an object"):
        _ = root.key(0)
    assert_false(root.is_null())


def test_an_array_is_read_by_position() raises:
    var doc = parse('[1, "two", null]'.as_bytes())
    var root = doc.root()
    assert_equal(len(root), 3)
    assert_equal(root.at(0).as_number().string(), "1")
    assert_equal(root.at(1).as_string(), "two")
    assert_true(root.at(2).is_null())


def test_an_index_outside_an_array_raises() raises:
    var doc = parse("[1]".as_bytes())
    var root = doc.root()
    with assert_raises(
        contains="json: index 1 out of range, the container holds 1"
    ):
        _ = root.at(1)
    with assert_raises(contains="json: index -1 out of range"):
        _ = root.at(-1)


def test_an_empty_container_holds_nothing() raises:
    var a = parse("[]".as_bytes())
    assert_equal(len(a.root()), 0)
    var o = parse("{}".as_bytes())
    assert_equal(len(o.root()), 0)


def test_a_scalar_has_no_children() raises:
    # `__len__` cannot raise, so a scalar answers zero rather than failing, and
    # `kind` is what tells the two apart.
    var doc = parse("7".as_bytes())
    assert_equal(len(doc.root()), 0)


def test_an_object_is_read_by_name_or_by_position() raises:
    var doc = parse('{"b": 1, "a": 2}'.as_bytes())
    var root = doc.root()
    assert_equal(len(root), 2)
    assert_equal(root.key(0), "b")
    assert_equal(root.key(1), "a")
    assert_equal(root.member(0).as_number().string(), "1")
    assert_equal(root.field("a").as_number().string(), "2")
    assert_true(root.has("b"))
    assert_false(root.has("c"))


def test_a_name_that_is_not_there_raises() raises:
    var doc = parse('{"a": 1}'.as_bytes())
    var root = doc.root()
    with assert_raises(contains="json: no member named 'c'"):
        _ = root.field("c")


def test_the_members_keep_the_order_the_document_wrote() raises:
    var doc = parse('{"z": 1, "m": 2, "a": 3}'.as_bytes())
    var root = doc.root()
    var names = String()
    for i in range(len(root)):
        names += root.key(i)
    assert_equal(names, "zma")


def test_a_duplicate_key_keeps_both_and_the_last_one_wins() raises:
    # RFC 8259 section 4 says names SHOULD be unique and does not say what to do
    # when they are not. Go's map ends up with the last one because each
    # assignment overwrites the one before, and `field` matches that. Both are
    # still here in order for a caller who would rather see the document.
    var doc = parse('{"a": 1, "a": 2}'.as_bytes())
    var root = doc.root()
    assert_equal(len(root), 2)
    assert_equal(root.key(0), "a")
    assert_equal(root.key(1), "a")
    assert_equal(root.member(0).as_number().string(), "1")
    assert_equal(root.member(1).as_number().string(), "2")
    assert_equal(root.field("a").as_number().string(), "2")


def test_nesting_is_walked_from_the_root() raises:
    var doc = parse('{"a": [{"b": [1, 2]}, 3]}'.as_bytes())
    var root = doc.root()
    assert_equal(
        root.field("a").at(0).field("b").at(1).as_number().string(), "2"
    )
    assert_equal(root.field("a").at(1).as_number().string(), "3")


def test_containers_side_by_side_keep_their_own_children() raises:
    # The children of a nested container land on the pending stack in between
    # its parent's, so a run in the arena is only contiguous once the bracket
    # closes. This is the shape that catches getting that wrong.
    var doc = parse("[[1], [2], [3, [4]]]".as_bytes())
    var root = doc.root()
    assert_equal(len(root), 3)
    assert_equal(root.at(0).at(0).as_number().string(), "1")
    assert_equal(root.at(1).at(0).as_number().string(), "2")
    assert_equal(root.at(2).at(0).as_number().string(), "3")
    assert_equal(root.at(2).at(1).at(0).as_number().string(), "4")


def test_objects_side_by_side_keep_their_own_members() raises:
    var doc = parse(
        '{"x": {"p": 1}, "y": {"q": 2}, "z": {"r": {"s": 3}}}'.as_bytes()
    )
    var root = doc.root()
    assert_equal(root.field("x").field("p").as_number().string(), "1")
    assert_equal(root.field("y").field("q").as_number().string(), "2")
    assert_equal(
        root.field("z").field("r").field("s").as_number().string(), "3"
    )


def test_a_number_keeps_what_the_document_wrote() raises:
    # Nothing is converted on the way in, so a number a float cannot hold is a
    # number this document holds. Go's `Unmarshal` into an `any` gives a
    # `float64` here and loses all five of these.
    var text = "[1, 1.0, 1e400, -0, 123456789012345678901234567890]"
    var doc = parse(text.as_bytes())
    var root = doc.root()
    assert_equal(root.at(0).as_number().string(), "1")
    assert_equal(root.at(1).as_number().string(), "1.0")
    assert_equal(root.at(2).as_number().string(), "1e400")
    assert_equal(root.at(3).as_number().string(), "-0")
    assert_equal(
        root.at(4).as_number().string(), "123456789012345678901234567890"
    )


def test_a_number_converts_when_it_is_asked_to() raises:
    var doc = parse("[42, 1.5]".as_bytes())
    var root = doc.root()
    assert_equal(root.at(0).as_number().int64(), 42)
    assert_equal(root.at(1).as_number().float64(), 1.5)


def test_escapes_come_back_as_characters() raises:
    var doc = parse('"a\\tb\\nc\\"d\\\\e\\/f"'.as_bytes())
    assert_equal(doc.root().as_string(), 'a\tb\nc"d\\e/f')


def test_a_hex_escape_comes_back_as_its_code_point() raises:
    var doc = parse('"\\u00e9"'.as_bytes())
    assert_equal(doc.root().as_string(), "é")


def test_a_surrogate_pair_comes_back_as_one_character() raises:
    var doc = parse('"\\ud83d\\ude00"'.as_bytes())
    assert_equal(doc.root().as_string(), chr(0x1F600))


def test_a_surrogate_on_its_own_is_refused() raises:
    # The one place a document is refused that `valid` accepts. Go turns this
    # into U+FFFD and carries on; a Mojo `String` says it is UTF-8, so the
    # substitution would be a silent edit of somebody's data.
    var texts: List[String] = [
        '"\\ud800"',
        '"\\udc00"',
        '"\\ud800\\ud800"',
        '"a\\udfffb"',
    ]
    for text in texts:
        assert_true(parse_is_text_error(text), text)


def test_bytes_that_are_not_utf8_are_refused() raises:
    var quote = Byte(34)
    var lone: List[Byte] = [quote, Byte(0x80), quote]
    var bad: List[Byte] = [quote, Byte(0xC3), Byte(0x28), quote]
    assert_true(bytes_are_text_error(lone))
    assert_true(bytes_are_text_error(bad))


def test_a_refused_string_is_still_valid_json() raises:
    # `valid` and the token decoder both take these documents, which is Go's
    # behaviour, and only the document path refuses them. The deviation is about
    # what a string holds rather than about what a document is.
    var quote = Byte(34)
    var lone: List[Byte] = [quote, Byte(0x80), quote]
    assert_true(valid(Span(lone)))
    assert_true(valid('"\\ud800"'.as_bytes()))


def test_a_refusal_names_the_byte_it_happened_at() raises:
    var doc = new_document()
    try:
        doc.parse_into('["ok", "\\ud800"]'.as_bytes())
        raise Error("accepted an unpaired surrogate")
    except e:
        assert_true(matches(e, ErrJSONText))
        assert_true(String(e).find("unpaired surrogate") >= 0, String(e))


def test_a_key_is_unquoted_the_same_way_as_a_value() raises:
    var doc = parse('{"a\\tb": 1}'.as_bytes())
    var root = doc.root()
    assert_equal(root.key(0), "a\tb")
    assert_equal(root.field("a\tb").as_number().string(), "1")
    assert_true(root.has("a\tb"))


def test_a_key_that_is_not_text_is_refused() raises:
    var text = '{"\\ud800": 1}'
    assert_true(parse_is_text_error(text))


def test_an_empty_string_parses_to_nothing() raises:
    var doc = parse('[""]'.as_bytes())
    assert_equal(doc.root().at(0).as_string(), "")


def test_bytes_that_are_not_json_raise_a_syntax_error() raises:
    var texts: List[String] = [
        "",
        "  ",
        "{",
        "[1,]",
        "tru",
        "01",
        "{'a':1}",
        '{"a" 1}',
        "[1] [2]",
        '"abc',
    ]
    for text in texts:
        var doc = new_document()
        try:
            doc.parse_into(text.as_bytes())
            raise Error("accepted " + repr(text))
        except e:
            assert_true(Bool(SyntaxError.of(e)), text + ": " + String(e))


def test_nesting_deeper_than_the_cap_is_refused() raises:
    var text = String("[") * (MAX_NESTING_DEPTH + 1)
    var doc = new_document()
    try:
        doc.parse_into(text.as_bytes())
        raise Error("accepted a document nested past the cap")
    except e:
        assert_true(Bool(SyntaxError.of(e)), String(e))


def test_nesting_up_to_the_cap_is_read_without_a_stack() raises:
    # The builder and the writer both use an explicit stack, so this is a list
    # that grows rather than ten thousand call frames.
    var depth = MAX_NESTING_DEPTH
    var text = String("[") * depth + "7" + String("]") * depth
    var doc = parse(text.as_bytes())
    var here = doc.root()
    for _ in range(depth):
        assert_equal(here.kind(), ARRAY)
        here = here.at(0)
    assert_equal(here.as_number().string(), "7")
    assert_equal(String(doc.root()).byte_length(), text.byte_length())


def test_a_document_can_be_parsed_into_again() raises:
    var doc = new_document()
    doc.parse_into('{"a": 1}'.as_bytes())
    assert_equal(doc.root().field("a").as_number().string(), "1")
    doc.parse_into("[2]".as_bytes())
    assert_equal(doc.root().at(0).as_number().string(), "2")
    doc.parse_into("null".as_bytes())
    assert_true(doc.root().is_null())


def test_a_document_that_has_not_been_parsed_into_is_empty() raises:
    var doc = new_document()
    var root = doc.root()
    with assert_raises(contains="json: the document is empty"):
        _ = root.kind()
    assert_equal(String(root), "null")


def test_reset_empties_a_document() raises:
    var doc = parse('{"a": 1}'.as_bytes())
    doc.reset()
    var root = doc.root()
    with assert_raises(contains="json: the document is empty"):
        _ = root.kind()


def test_a_failed_parse_leaves_the_document_readable() raises:
    var doc = new_document()
    doc.parse_into('{"a": 1}'.as_bytes())
    try:
        doc.parse_into("{".as_bytes())
    except:
        pass
    # The bytes were refused before `reset` ran, so what was here is still here.
    assert_equal(doc.root().field("a").as_number().string(), "1")


def test_a_value_writes_itself_back_out_as_json() raises:
    assert_equal(_out("null"), "null")
    assert_equal(_out("true"), "true")
    assert_equal(_out("  [ 1 , 2 ]  "), "[1,2]")
    assert_equal(
        _out('{ "a" : [ 1 , { "b" : null } ] }'), '{"a":[1,{"b":null}]}'
    )
    assert_equal(_out("[]"), "[]")
    assert_equal(_out("{}"), "{}")
    assert_equal(_out("[[],{},[{}]]"), "[[],{},[{}]]")


def test_writing_out_keeps_the_number_the_document_wrote() raises:
    assert_equal(_out("[1.50, 1e400, -0]"), "[1.50,1e400,-0]")


def test_writing_out_escapes_what_json_requires_and_nothing_more() raises:
    var doc = parse('"a\\tb\\u0000c\\"d\\\\e"'.as_bytes())
    assert_equal(String(doc.root()), '"a\\tb\\u0000c\\"d\\\\e"')


def test_writing_out_leaves_text_as_text() raises:
    # A document that arrived in UTF-8 leaves in UTF-8. Go escapes `<`, `>` and
    # `&` here by default and `html_escape` is the call for that.
    var doc = parse('["héllo <b>", "\\u00e9"]'.as_bytes())
    assert_equal(String(doc.root()), '["héllo <b>","é"]')


def test_writing_out_round_trips_through_parse() raises:
    var text = '{"a":[1,2,{"b":"x\\ny"}],"c":null,"d":[true,false]}'
    assert_equal(_out(_out(text)), _out(text))
    assert_equal(_out(text), text)


def test_a_nested_value_writes_only_itself() raises:
    var doc = parse('{"a": [1, 2], "b": 3}'.as_bytes())
    assert_equal(String(doc.root().field("a")), "[1,2]")
    assert_equal(String(doc.root().field("b")), "3")


def test_a_handle_from_an_earlier_parse_raises() raises:
    # Mojo's origins already refuse most of the ways this could be reached, so
    # the generation counter is what is left for the rest of them.
    var doc = new_document()
    doc.parse_into('["one"]'.as_bytes())
    var stale = doc.root()
    doc.parse_into('["two"]'.as_bytes())
    try:
        _ = stale.kind()
        raise Error("a handle from an earlier parse still read")
    except e:
        assert_true(matches(e, ErrJSONStale), String(e))
    assert_equal(doc.root().at(0).as_string(), "two")


def test_a_handle_is_two_integers_and_a_borrow() raises:
    # Copying one costs nothing and every copy reads the same node.
    var doc = parse("[1]".as_bytes())
    var one = doc.root()
    var two = one
    assert_equal(two.at(0).as_number().string(), "1")
    assert_equal(one.at(0).as_number().string(), "1")


def parse_is_text_error(text: String) raises -> Bool:
    """Whether parsing `text` raises `ErrJSONText`."""
    var doc = new_document()
    try:
        doc.parse_into(text.as_bytes())
        return False
    except e:
        return matches(e, ErrJSONText)


def bytes_are_text_error(b: List[Byte]) raises -> Bool:
    """Whether parsing `b` raises `ErrJSONText`."""
    var doc = new_document()
    try:
        doc.parse_into(Span(b))
        return False
    except e:
        return matches(e, ErrJSONText)
