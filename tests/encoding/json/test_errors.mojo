"""The two error types that are about a value rather than about the bytes.

Go's own tests for these are rows inside `TestUnmarshal` and
`TestUnsupportedValues`, where a document is read into a type and the
`*UnmarshalTypeError` that comes back is compared field by field. There is no
type to read into here without a generated codec, so the rows are put through
`ValueScanner` instead, which is the call a generated codec makes and the place
the disagreement is found. `tools/codec/testdata/driver.mojo` has the same
thing end to end, with a struct and a document.

Go's offsets are one apart from these for a literal, and the row that says so
is `test_the_offset_is_where_the_value_starts`. `docs/deviations.md` has the
reasoning.
"""

from std.testing import assert_equal, assert_true

from core.encoding.json import (
    UnmarshalTypeError,
    UnsupportedValueError,
    ValueScanner,
    append_float,
)
from core.errors import matches
from core.errors.codes import ErrJSONSyntax, ErrJSONType, ErrJSONUnsupported
from core.io import Byte

comptime _LBRACE = Byte(ord("{"))
comptime _COLON = Byte(ord(":"))


def _record(e: Error) raises -> UnmarshalTypeError:
    """The type error `e` carries, or a failure saying it carried none."""
    var failure = UnmarshalTypeError.of(e)
    assert_true(Bool(failure), String(e))
    return failure.value().copy()


def _refused_as_signed(document: String, bits: Int) raises -> Error:
    """What reading `document` as a signed number of `bits` bits raises."""
    var sc = ValueScanner(document.as_bytes())
    try:
        _ = sc.read_signed(bits)
    except e:
        return e
    raise Error("a number was read out of " + document + " rather than refused")


def _written(f: Float64) raises -> Error:
    """What writing `f` raises, which for these three is a refusal."""
    var out = List[Byte]()
    try:
        append_float(out, f, 64)
    except e:
        return e
    raise Error("a float with no JSON spelling was written rather than refused")


def test_a_value_of_the_wrong_kind_names_both_sides() raises:
    """Go's `{"X": "foo"}` into an `int` field, without the field.

    The document is well formed and the value is a string and the field is a
    number, which is a disagreement about types and not about the bytes.
    """
    var e = _refused_as_signed('"7"', 64)
    assert_true(matches(e, ErrJSONType))
    assert_true(not matches(e, ErrJSONSyntax))
    var failure = _record(e)
    assert_equal(failure.value, "string")
    assert_equal(failure.type, "Int64")
    assert_equal(failure.offset, 1)
    assert_equal(failure.struct_name, "")
    assert_equal(failure.field, "")
    assert_equal(
        String(e), "json: cannot unmarshal string into a value of type Int64"
    )


def test_the_six_names_go_gives_a_value() raises:
    """`array`, `object`, `bool`, `string`, `null` and `number`.

    Go's list is the first four and the last. `null` is here as well, because
    a null where a value belongs is an error rather than a field left at its
    zero value, for the reason `missing_key` gives.
    """
    var rows: List[Tuple[String, String]] = [
        (String("[1,2,3]"), String("array")),
        (String('{"a":1}'), String("object")),
        (String("true"), String("bool")),
        (String("false"), String("bool")),
        (String('"x"'), String("string")),
        (String("null"), String("null")),
    ]
    for row in rows:
        var e = _refused_as_signed(row[0], 64)
        assert_equal(_record(e).value, row[1], row[0])


def test_a_number_that_does_not_fit_says_which_number() raises:
    """Go's range rows, which put the digits next to the word.

    `number 256` rather than `number`, because a document with one bad number
    in it is found faster with the number in hand than with an offset alone.
    """
    var wide = ValueScanner("256".as_bytes())
    var failed = False
    try:
        _ = wide.read_unsigned(8)
    except e:
        failed = True
        var failure = _record(e)
        assert_equal(failure.value, "number 256")
        assert_equal(failure.type, "UInt8")
    assert_true(failed)

    var signed = _refused_as_signed("128", 8)
    assert_equal(_record(signed).value, "number 128")
    assert_equal(_record(signed).type, "Int8")

    var negative = ValueScanner("-1".as_bytes())
    failed = False
    try:
        _ = negative.read_unsigned(8)
    except e:
        failed = True
        assert_equal(_record(e).value, "number -1")
        assert_equal(_record(e).type, "UInt8")
    assert_true(failed)


def test_a_fraction_in_a_whole_field_is_the_same_refusal() raises:
    """Not rounded and not truncated, and not a syntax error either: `7.5` is
    a number, and the field is what it will not go into."""
    var e = _refused_as_signed("7.5", 64)
    var failure = _record(e)
    assert_equal(failure.value, "number 7.5")
    assert_equal(failure.type, "Int64")
    assert_equal(
        String(e),
        "json: cannot unmarshal number 7.5 into a value of type Int64",
    )


def test_the_field_is_named_when_the_scanner_knows_it() raises:
    """Go's `{"X": 23}` into `struct T { X string }`.

    A generated decoder calls `at_field` once per key, which is what puts the
    struct and the field on a refusal several calls below it.
    """
    var sc = ValueScanner('{"X": 23}'.as_bytes())
    sc.expect(_LBRACE)
    var key = sc.read_key()
    sc.expect(_COLON)
    sc.at_field("T", key)
    var failed = False
    try:
        _ = sc.read_string()
    except e:
        failed = True
        var failure = _record(e)
        assert_equal(failure.value, "number")
        assert_equal(failure.type, "String")
        assert_equal(failure.struct_name, "T")
        assert_equal(failure.field, "X")
        assert_equal(
            String(e),
            (
                "json: cannot unmarshal number into struct field T.X of type"
                " String"
            ),
        )
    assert_true(failed)


def test_the_offset_is_where_the_value_starts() raises:
    """Go's row says 7 for this document and so does this one.

    Go has two rules: the byte a composite value begins at, and the byte after
    a literal one ends. This has one, the byte the value begins at, counted
    from one the way every other offset in this package is. The two agree on
    `{"X": [1,2,3]}` and are one apart on `{"X": 23}`, where Go says 8 and this
    says 7. One rule is worth the difference: an offset that is always the
    start of the value is an offset a caller can slice the document with.
    """
    var sc = ValueScanner('{"X": [1,2,3], "Y": 4}'.as_bytes())
    sc.expect(_LBRACE)
    var key = sc.read_key()
    sc.expect(_COLON)
    sc.at_field("T", key)
    var failed = False
    try:
        _ = sc.read_string()
    except e:
        failed = True
        assert_equal(_record(e).offset, 7)
    assert_true(failed)


def test_a_document_that_is_not_json_is_still_a_syntax_error() raises:
    """`tru` is a broken document rather than a bool in the wrong place, so it
    comes back the way every other broken document does."""
    var sc = ValueScanner("tru}".as_bytes())
    var failed = False
    try:
        _ = sc.read_bool()
    except e:
        failed = True
        assert_true(matches(e, ErrJSONSyntax))
        assert_true(not UnmarshalTypeError.of(e))
    assert_true(failed)


def test_a_float_with_no_spelling_is_refused() raises:
    """Go's `TestUnsupportedValues`, which is these three and five cycles.

    A cycle has no counterpart here: it is what Go's encoder walks into when a
    value points at itself, and nothing walks a value here.
    """
    var infinity = Float64(1.0) / Float64(0.0)
    var rows: List[Tuple[Float64, String]] = [
        (infinity, String("+Inf")),
        (-infinity, String("-Inf")),
        (infinity - infinity, String("NaN")),
    ]
    for row in rows:
        var e = _written(row[0])
        assert_true(matches(e, ErrJSONUnsupported))
        var failure = UnsupportedValueError.of(e)
        assert_true(Bool(failure), row[1])
        assert_equal(failure.value().str, row[1])
        assert_equal(String(e), "json: unsupported value: " + row[1])


def test_either_error_read_off_the_other_is_nothing() raises:
    """`of` hands back nothing rather than a wrong answer, which is what a
    type assertion does by failing."""
    var type_error = _refused_as_signed('"7"', 64)
    var unsupported = _written(Float64(1.0) / Float64(0.0))
    assert_true(not UnsupportedValueError.of(type_error))
    assert_true(not UnmarshalTypeError.of(unsupported))
    assert_true(not UnmarshalTypeError.of(Error("something else")))
    assert_true(not UnsupportedValueError.of(Error("something else")))
