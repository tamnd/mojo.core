"""What a generated codec is made of, on its own.

Go has no tests for this because Go has nothing like it: its `Unmarshal` reads
a document by inspecting a type while the program runs, and there is no scanner
underneath that a generated decoder would call. So these are written rather
than borrowed, and they are about the two things a generated codec cannot check
for itself. That the grammar this walks is the grammar `valid` and `parse`
accept, since a codec that read documents the rest of the package refused would
be a second dialect nobody asked for. And that the writers put out what Go's
encoder puts out, since the two are going to be compared byte for byte.

`tools/codec` has its own test as well, which generates a codec for a package
of fixtures, builds it outside this repository and runs it. That one is about
the code the generator writes. This one is about the code it calls.
"""

from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from core.encoding.json import (
    MAX_NESTING_DEPTH,
    SyntaxError,
    ValueScanner,
    append_bool,
    append_float,
    append_signed,
    append_string,
    append_unsigned,
    missing_key,
    valid,
)
from core.errors import matches
from core.errors.codes import ErrJSONSyntax, ErrJSONText
from core.io import Byte

comptime _LBRACE = Byte(ord("{"))
comptime _RBRACE = Byte(ord("}"))
comptime _LBRACKET = Byte(ord("["))
comptime _RBRACKET = Byte(ord("]"))
comptime _COLON = Byte(ord(":"))
comptime _COMMA = Byte(ord(","))


def _written(text: StringSlice) raises -> String:
    """`text` as the quoted JSON string a generated encoder would write."""
    var out = List[Byte]()
    append_string(out, text)
    return String(from_utf8_lossy=Span(out))


def _float(f: Float64, bits: Int) raises -> String:
    """One number as a generated encoder would write it."""
    var out = List[Byte]()
    append_float(out, f, bits)
    return String(from_utf8_lossy=Span(out))


def test_a_scanner_walks_an_object() raises:
    """The six calls a generated decoder makes, in the order it makes them."""
    var sc = ValueScanner('{"a": 1, "b": "two"}'.as_bytes())
    sc.enter()
    sc.expect(_LBRACE)
    assert_equal(sc.read_string(), "a")
    sc.expect(_COLON)
    assert_equal(sc.read_signed(64), 1)
    assert_true(sc.accept(_COMMA))
    assert_equal(sc.read_string(), "b")
    sc.expect(_COLON)
    assert_equal(sc.read_string(), "two")
    assert_true(not sc.accept(_COMMA))
    sc.expect(_RBRACE)
    sc.leave()
    sc.end()


def test_the_three_widths_read_back() raises:
    """Signed, unsigned and floating, each at the end of its range."""
    var signed = ValueScanner("-9223372036854775808".as_bytes())
    assert_equal(signed.read_signed(64), Int64.MIN)

    var unsigned = ValueScanner("18446744073709551615".as_bytes())
    assert_equal(unsigned.read_unsigned(64), UInt64.MAX)

    var narrow = ValueScanner("255".as_bytes())
    assert_equal(narrow.read_unsigned(8), 255)

    var floating = ValueScanner("1.5e300".as_bytes())
    assert_equal(floating.read_float(64), 1.5e300)


def test_a_number_too_wide_for_its_field_is_refused() raises:
    """The check Go's reflection makes on the field it is assigning into."""
    var wide = ValueScanner("256".as_bytes())
    with assert_raises():
        _ = wide.read_unsigned(8)

    var negative = ValueScanner("-1".as_bytes())
    with assert_raises():
        _ = negative.read_unsigned(64)


def test_a_fraction_where_a_whole_number_goes_is_refused() raises:
    """Not rounded, not truncated. Go refuses the same document."""
    var sc = ValueScanner("7.5".as_bytes())
    with assert_raises(contains="expected a whole number"):
        _ = sc.read_signed(64)


def test_the_number_grammar_is_the_format_and_not_the_parser() raises:
    """`01`, `.5`, `1.`, `+1` and `1e` are JSON that no reader accepts.

    `core.strconv` would read three of these, which is why the shape is checked
    here rather than left to the conversion: a document is refused for being
    the wrong document, not for being an unlucky one.
    """
    var rows = ["01", ".5", "1.", "+1", "1e", "1e+", "-", ""]
    for row in rows:
        var sc = ValueScanner(row.as_bytes())
        var refused = False
        try:
            _ = sc.read_number(False)
        except:
            refused = True
        assert_true(refused, row)
        assert_true(not valid(row.as_bytes()), row)


def test_a_string_gives_up_its_escapes() raises:
    """The eight one letter escapes and a `\\u` that is a whole character."""
    var sc = ValueScanner('"\\"\\\\\\/\\b\\f\\n\\r\\t\\u00e9"'.as_bytes())
    var text = sc.read_string()
    assert_equal(
        text,
        '"\\/' + chr(8) + chr(12) + chr(10) + chr(13) + chr(9) + "é",
    )


def test_a_surrogate_pair_is_one_character() raises:
    """Two escapes that name the halves of one character above the BMP."""
    var sc = ValueScanner('"\\ud83d\\ude00"'.as_bytes())
    assert_equal(sc.read_string(), "😀")


def test_half_of_a_surrogate_pair_is_refused() raises:
    """Where this differs from Go, and agrees with `parse`.

    Go writes U+FFFD and carries on, because a Go `string` is arbitrary bytes.
    A Mojo `String` says it is UTF-8, so the substitution would be a silent
    edit of somebody's data rather than a representation of it.
    """
    var sc = ValueScanner('"\\ud800"'.as_bytes())
    try:
        _ = sc.read_string()
        raise Error("a lone surrogate was read rather than refused")
    except e:
        assert_true(matches(e, ErrJSONText))


def test_bytes_that_are_not_utf8_are_refused() raises:
    """The other half of the same rule, for text that was never escaped."""
    var raw: List[Byte] = [
        Byte(ord('"')),
        Byte(0xFF),
        Byte(ord('"')),
    ]
    var sc = ValueScanner(Span(raw))
    try:
        _ = sc.read_string()
        raise Error("bytes that are not UTF-8 were read rather than refused")
    except e:
        assert_true(matches(e, ErrJSONText))


def test_an_escape_that_is_not_one_is_refused() raises:
    """Checked while the literal is walked, before anything is resolved."""
    var sc = ValueScanner('"\\x"'.as_bytes())
    with assert_raises(contains="in string escape"):
        _ = sc.read_string()

    var short = ValueScanner('"\\u00g0"'.as_bytes())
    with assert_raises(contains="in \\u escape"):
        _ = short.read_string()


def test_a_control_character_inside_a_string_is_refused() raises:
    """JSON says a literal holds nothing below a space unescaped."""
    var sc = ValueScanner(('"a' + chr(10) + 'b"').as_bytes())
    with assert_raises(contains="in string literal"):
        _ = sc.read_string()


def test_a_document_that_ends_in_the_middle_is_refused() raises:
    """Every one of these is a truncation rather than a mistake."""
    var rows = ['"abc', '"\\', '"\\u00', "{"]
    for row in rows:
        var sc = ValueScanner(row.as_bytes())
        var refused = False
        try:
            sc.skip_value()
        except:
            refused = True
        assert_true(refused, row)


def test_skipping_a_value_steps_over_all_of_it() raises:
    """What a key no field matches costs: the value is walked and dropped."""
    var sc = ValueScanner('[{"a":[1,2,{"b":null}],"c":"}"}, true]'.as_bytes())
    sc.expect(_LBRACKET)
    sc.skip_value()
    assert_true(sc.accept(_COMMA))
    assert_true(sc.read_bool())
    sc.expect(_RBRACKET)
    sc.end()


def test_nesting_is_capped_where_the_rest_of_the_package_caps_it() raises:
    """A document of nothing but brackets is a refusal, not a crash."""
    var deep = String("[") * (MAX_NESTING_DEPTH + 1)
    var sc = ValueScanner(deep.as_bytes())
    with assert_raises(contains="exceeded max depth"):
        sc.skip_value()


def test_anything_after_the_value_is_refused() raises:
    """`end` is what makes a decoder read one document rather than a prefix."""
    var sc = ValueScanner("1 2".as_bytes())
    assert_equal(sc.read_signed(64), 1)
    with assert_raises(contains="after top-level value"):
        sc.end()


def test_a_refusal_is_a_syntax_error_with_an_offset() raises:
    """A generated decoder's failure reads like every other failure here.

    Go's is a `*json.SyntaxError` from a type assertion, and it is the same
    record from `SyntaxError.of` whether the bytes came through `valid` or
    through a codec.
    """
    var sc = ValueScanner('{"a": tru}'.as_bytes())
    sc.expect(_LBRACE)
    _ = sc.read_string()
    sc.expect(_COLON)
    try:
        _ = sc.read_bool()
        raise Error("a broken literal was read rather than refused")
    except e:
        assert_true(matches(e, ErrJSONSyntax))
        var failure = SyntaxError.of(e)
        assert_true(failure.__bool__())
        assert_equal(failure.value().offset, 7)


def test_the_writers_put_out_what_go_puts_out() raises:
    """Booleans and whole numbers, which have one spelling each."""
    var out = List[Byte]()
    append_bool(out, True)
    append_bool(out, False)
    append_signed(out, -9223372036854775808)
    append_unsigned(out, 18446744073709551615)
    assert_equal(
        String(from_utf8_lossy=Span(out)),
        "truefalse-922337203685477580818446744073709551615",
    )


def test_a_string_goes_out_with_gos_escapes() raises:
    """Go's set, which is wider than the grammar's minimum.

    The three HTML characters and the two JavaScript line terminators are
    escaped so that the result can be dropped into a script tag, which is what
    Go's encoder does and is why `html_escape` exists separately for documents
    that did not come from one.
    """
    assert_equal(_written("plain"), '"plain"')
    assert_equal(_written('a"b\\c'), '"a\\"b\\\\c"')
    assert_equal(_written("a" + chr(10) + chr(13) + chr(9)), '"a\\n\\r\\t"')
    assert_equal(_written("a" + chr(1)), '"a\\u0001"')
    assert_equal(_written("<b>&"), '"\\u003cb\\u003e\\u0026"')
    assert_equal(_written("é😀"), '"é😀"')
    assert_equal(_written(chr(0x2028) + chr(0x2029)), '"\\u2028\\u2029"')


def test_what_a_writer_writes_reads_back() raises:
    """Every escape above through the scanner again, which is the point."""
    var rows = [
        String("plain"),
        String('a"b\\c'),
        "a" + chr(10) + chr(13) + chr(9),
        "a" + chr(1),
        String("<b>&"),
        String("é😀"),
        chr(0x2028) + chr(0x2029),
    ]
    for row in rows:
        var written = _written(row)
        var sc = ValueScanner(written.as_bytes())
        assert_equal(sc.read_string(), row)


def test_a_float_is_written_the_way_go_writes_one() raises:
    """Shortest round trip, with the exponent form only outside the readable
    range and the exponent itself written without a leading zero."""
    assert_equal(_float(0.0, 64), "0")
    assert_equal(_float(1.5, 64), "1.5")
    assert_equal(_float(-1.5, 64), "-1.5")
    assert_equal(_float(1e21, 64), "1e+21")
    assert_equal(_float(1e-7, 64), "1e-7")
    assert_equal(_float(1e20, 64), "100000000000000000000")
    assert_equal(_float(0.1, 32), "0.1")


def test_a_number_json_cannot_hold_is_refused() raises:
    """Neither infinity nor a not a number has a JSON spelling.

    Go refuses both from `Marshal` as an `UnsupportedValueError`, and writing
    the bare word either of them formats as would produce a document nothing
    can read back.
    """
    var infinity = Float64(1.0) / Float64(0.0)
    with assert_raises(contains="no JSON representation"):
        _ = _float(infinity, 64)
    with assert_raises(contains="no JSON representation"):
        _ = _float(infinity - infinity, 64)


def test_a_missing_key_says_which_one() raises:
    """A field that is not `Optional` and not in the document.

    Go leaves it at the zero value. There is no zero value here to leave it
    at, so the decoder raises and the message names the struct and the key
    rather than the field, since the key is what the document is missing.
    """
    var e = missing_key("Item", "name")
    assert_equal(String(e), 'json: Item: the document has no "name" key')


def test_a_scanner_hands_back_a_value_as_its_bytes() raises:
    """What a `RawMessage` field is read with, and it reads nothing.

    The bytes are walked far enough to find the end of the value and no
    further, so whatever is inside comes back as it was written.
    """
    var whole = ValueScanner(' { "a" : [ 1 , 2 ] } '.as_bytes())
    assert_equal(String(whole.read_raw()), '{ "a" : [ 1 , 2 ] }')
    whole.end()

    var wide = ValueScanner("1e400".as_bytes())
    assert_equal(String(wide.read_raw()), "1e400")

    var empty = ValueScanner('""'.as_bytes())
    assert_equal(String(empty.read_raw()), '""')


def test_a_raw_value_in_the_middle_of_an_object_stops_where_it_should() raises:
    """The scanner carries on from the byte after the value, which is what
    makes a field of them read at all."""
    var sc = ValueScanner(
        '{"kind":"x","payload":[1,{"b":null}],"n":1}'.as_bytes()
    )
    sc.enter()
    sc.expect(_LBRACE)
    assert_equal(sc.read_string(), "kind")
    sc.expect(_COLON)
    assert_equal(sc.read_string(), "x")
    assert_true(sc.accept(_COMMA))
    assert_equal(sc.read_string(), "payload")
    sc.expect(_COLON)
    assert_equal(String(sc.read_raw()), '[1,{"b":null}]')
    assert_true(sc.accept(_COMMA))
    assert_equal(sc.read_string(), "n")
    sc.expect(_COLON)
    assert_equal(sc.read_signed(64), 1)
    sc.expect(_RBRACE)
    sc.leave()
    sc.end()


def test_a_raw_value_that_is_not_a_value_is_still_refused() raises:
    """Not read is not the same as not checked. The walk is the scanner's own,
    so a payload that is not one JSON value stops here rather than at whoever
    reads it later."""
    var cut = ValueScanner("[1,".as_bytes())
    with assert_raises():
        _ = cut.read_raw()
    var bad = ValueScanner("[,]".as_bytes())
    with assert_raises():
        _ = bad.read_raw()


def test_an_unknown_key_is_stepped_over_by_default() raises:
    """Which is how a document written by a newer program still reads."""
    var sc = ValueScanner('{"a":{"deep":[1,2]},"b":1}'.as_bytes())
    sc.enter()
    sc.expect(_LBRACE)
    assert_equal(sc.read_string(), "a")
    sc.expect(_COLON)
    sc.unknown_key("a")
    assert_true(sc.accept(_COMMA))
    assert_equal(sc.read_string(), "b")
    sc.expect(_COLON)
    assert_equal(sc.read_signed(64), 1)
    sc.expect(_RBRACE)
    sc.leave()
    sc.end()


def test_an_unknown_key_is_refused_when_the_caller_asked() raises:
    """Go's `DisallowUnknownFields`, and Go's message word for word.

    It is not a syntax error and does not carry `ErrJSONSyntax`, because the
    document is well formed and the disagreement is about what the reader
    expected. The offset names the value the key introduced, which Go's
    failure has no room for.
    """
    var sc = ValueScanner('{"a":{"deep":[1,2]},"b":1}'.as_bytes(), True)
    sc.enter()
    sc.expect(_LBRACE)
    assert_equal(sc.read_string(), "a")
    sc.expect(_COLON)
    var said = Error()
    try:
        sc.unknown_key("a")
    except e:
        said = e.copy()
    assert_equal(String(said), 'json: unknown field "a"')
    assert_true(not matches(said, ErrJSONSyntax))
    assert_true(not Bool(SyntaxError.of(said)))


def test_the_strict_flag_is_off_unless_it_is_asked_for() raises:
    """A generated decoder takes it as a defaulted argument, so a caller who
    never heard of it gets Go's default."""
    var loose = ValueScanner("{}".as_bytes())
    assert_false(loose.disallow_unknown)
    var strict = ValueScanner("{}".as_bytes(), True)
    assert_true(strict.disallow_unknown)
