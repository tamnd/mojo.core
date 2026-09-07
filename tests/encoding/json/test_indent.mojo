"""Go's `TestCompactAndIndent`, `TestCompactSeparators` and `TestIndentErrors`.

Go's first table is one document written twice, compact and indented, and it
checks four things per row: that each form compacts to the compact one and
indents to the indented one. All four are here, which is why the runner below
is longer than the table it runs.
"""

from std.testing import assert_equal, assert_true

from core.encoding.json import SyntaxError, compact, html_escape, indent
from core.errors import matches
from core.errors.codes import ErrJSONSyntax
from core.io import Byte
from core.strings import trim_right


def _compacted(text: StringSlice) raises -> String:
    var out = List[Byte]()
    compact(out, text.as_bytes())
    return String(from_utf8_lossy=Span(out))


def _indented(
    text: StringSlice, prefix: StringSlice, step: StringSlice
) raises -> String:
    var out = List[Byte]()
    indent(out, text.as_bytes(), prefix, step)
    return String(from_utf8_lossy=Span(out))


def _escaped(text: StringSlice) -> String:
    var out = List[Byte]()
    html_escape(out, text.as_bytes())
    return String(from_utf8_lossy=Span(out))


def _rows() -> List[Tuple[String, String]]:
    """Go's table, compact form first and indented form second."""
    return [
        (String("1"), String("1")),
        (String("{}"), String("{}")),
        (String("[]"), String("[]")),
        (String('{"":2}'), String('{\n\t"": 2\n}')),
        (String("[3]"), String("[\n\t3\n]")),
        (String("[1,2,3]"), String("[\n\t1,\n\t2,\n\t3\n]")),
        (String('{"x":1}'), String('{\n\t"x": 1\n}')),
        (
            String('[true,false,null,"x",1,1.5,0,-5e+2]'),
            String(
                "[\n\ttrue,\n\tfalse,\n\tnull,\n\t"
                + '"x",\n\t1,\n\t1.5,\n\t0,\n\t-5e+2\n]'
            ),
        ),
        (
            String('{"":"<>&\u2028\u2029"}'),
            String('{\n\t"": "<>&\u2028\u2029"\n}'),
        ),
        (String("null"), String("null \n\r\t")),
    ]


def test_both_forms_compact_to_the_compact_one() raises:
    """Go's first two checks per row. Compacting something already compact has
    to leave it alone, which is the half people forget to test."""
    var rows = _rows()
    for i in range(len(rows)):
        var want = rows[i][0].copy()
        var got = _compacted(rows[i][0])
        if got != want:
            raise Error("compact of the compact form gave " + repr(got))
        got = _compacted(rows[i][1])
        if got != want:
            raise Error("compact of the indented form gave " + repr(got))


def test_both_forms_indent_to_the_indented_one() raises:
    """Go's second two checks per row. Indenting something already indented
    has to leave it alone, so the operation can be run twice safely.

    The one difference between the two directions is the trailing whitespace,
    which `indent` copies and does not invent, so the compact form indents to
    the indented one with its tail trimmed off.
    """
    var rows = _rows()
    for i in range(len(rows)):
        var want = rows[i][1].copy()
        var got = _indented(rows[i][1], "", "\t")
        if got != want:
            raise Error("indent of the indented form gave " + repr(got))
        var trimmed = String(trim_right(want, " \n\r\t"))
        got = _indented(rows[i][0], "", "\t")
        if got != trimmed:
            raise Error("indent of the compact form gave " + repr(got))


def test_the_two_separators_survive_compacting() raises:
    """Go's `TestCompactSeparators`. U+2028 and U+2029 are ordinary characters
    inside a string and `compact` is not the call that rewrites them."""
    assert_equal(_compacted('{"\u2028": 1}'), '{"\u2028":1}')
    assert_equal(_compacted('{"\u2029" :2}'), '{"\u2029":2}')


def test_a_prefix_goes_in_front_of_every_line_but_the_first() raises:
    """Which is what lets the result drop into other formatted JSON at
    whatever level that is already at."""
    assert_equal(_indented("[1,2]", "> ", "  "), "[\n>   1,\n>   2\n> ]")


def test_an_empty_object_or_array_stays_on_one_line() raises:
    """The newline after an opening brace is delayed until something arrives
    that is not the matching closing one, which is the whole trick."""
    assert_equal(
        _indented('{"a":{},"b":[]}', "", " "), '{\n "a": {},\n "b": []\n}'
    )


def test_indenting_with_nothing_still_adds_the_newlines() raises:
    """Go's `TestIndentErrors` calls it this way, and an empty indent is not
    the same as no call: the lines are still separated."""
    assert_equal(_indented("[1,2]", "", ""), "[\n1,\n2\n]")


def test_whitespace_inside_a_string_is_not_insignificant() raises:
    """The one thing that makes this a JSON operation rather than a text
    one."""
    assert_equal(_compacted('{ "a b" : " c d " }'), '{"a b":" c d "}')


def test_a_document_that_is_not_json_leaves_the_buffer_alone() raises:
    """Go truncates back to the length it started at, so a caller reusing one
    buffer for many documents never finds half of a bad one in it."""
    var out = List[Byte]()
    out.extend("keep me".as_bytes())
    var raised = False
    try:
        compact(out, '{"X": "foo", "Y"}'.as_bytes())
    except e:
        raised = True
        assert_true(matches(e, ErrJSONSyntax))
    assert_true(raised)
    assert_equal(String(from_utf8_lossy=Span(out)), "keep me")


def test_indent_leaves_the_buffer_alone_too() raises:
    var out = List[Byte]()
    out.extend("keep me".as_bytes())
    var raised = False
    try:
        indent(out, "[1,".as_bytes(), "", "\t")
    except e:
        raised = True
    assert_true(raised)
    assert_equal(String(from_utf8_lossy=Span(out)), "keep me")


def test_go_reports_the_offset_indent_reports() raises:
    """Go's `TestIndentErrors`, both rows, message and offset."""
    var raised = False
    try:
        _ = _indented('{"X": "foo", "Y"}', "", "")
    except e:
        raised = True
        var failure = SyntaxError.of(e)
        assert_true(Bool(failure))
        assert_equal(
            failure.value().msg, "invalid character '}' after object key"
        )
        assert_equal(failure.value().offset, 17)
    assert_true(raised)


def test_compact_reports_the_same_offset_indent_does() raises:
    """Go's `Compact` reports zero here, because the loop feeding its scanner
    is the one loop in that file that forgets to count the bytes it fed. This
    counts, so the two calls agree. `docs/deviations.md` has the row."""
    var raised = False
    try:
        _ = _compacted('{"X": "foo", "Y"}')
    except e:
        raised = True
        var failure = SyntaxError.of(e)
        assert_true(Bool(failure))
        assert_equal(failure.value().offset, 17)
    assert_true(raised)


def test_html_escape_spells_out_the_three_ascii_characters() raises:
    """Go's `HTMLEscape`. A browser does not honour HTML escaping inside a
    script tag, so a string holding the end of one ends the tag."""
    assert_equal(
        _escaped('{"a":"</script>"}'),
        '{"a":"\\u003c/script\\u003e"}',
    )
    assert_equal(_escaped('"a&b"'), '"a\\u0026b"')


def test_html_escape_spells_out_the_two_separators() raises:
    """A browser reads both as line terminators and JSON does not, so a
    document holding one is valid and the page holding it is broken."""
    assert_equal(_escaped('"\u2028"'), '"\\u2028"')
    assert_equal(_escaped('"\u2029"'), '"\\u2029"')


def test_html_escape_leaves_a_document_with_none_of_them_alone() raises:
    assert_equal(_escaped('{"a":[1,2]}'), '{"a":[1,2]}')


def test_html_escape_does_not_read_the_document() raises:
    """Go does not parse here and neither does this, so bytes that are not
    JSON come out with the same five characters rewritten and nothing else."""
    assert_equal(_escaped("not json <at all>"), "not json \\u003cat all\\u003e")


def test_an_e2_that_is_not_a_separator_is_left_alone() raises:
    """The check is three bytes long, so a lone E2 at the end of the input and
    an E2 that starts some other character both have to survive."""
    assert_equal(_escaped('"日本"'), '"日本"')
