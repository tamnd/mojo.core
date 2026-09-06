"""`ParseError`, the three message shapes, and the two additions Go has not.

Go checks its messages by comparing whole `*ParseError` values in `TestRead`,
so there is no separate test of the wording there. The wording is a promise a
caller can read, so it is checked here against Go's three `Sprintf` formats.

`last_record` and the raise from `field_pos` are the two places this package
does not match Go, and both are checked here rather than left to the table.
"""

from std.testing import assert_equal, assert_true

from core.bytes import new_buffer_string
from core.encoding.csv import ParseError, new_reader
from core.errors import field, matches
from core.errors.codes import EOF, ErrFieldCount, ErrQuote


def test_message_field_count() raises:
    """A count failure names one line and no column, same as Go."""
    var r = new_reader(new_buffer_string("a,b,c\nd,e\n"))
    r.fields_per_record = 0
    _ = r.read()
    try:
        _ = r.read()
        raise Error("the short record did not raise")
    except e:
        var got = ParseError.of(e)
        assert_true(Bool(got))
        assert_equal(
            got.value().error(), "record on line 2: wrong number of fields"
        )
        assert_equal(got.value().line, 2)
        assert_equal(got.value().start_line, 2)


def test_message_one_line() raises:
    """A record that started and failed on the same line names it once."""
    var r = new_reader(new_buffer_string('a "word",b'))
    try:
        _ = r.read()
        raise Error("the bare quote did not raise")
    except e:
        var got = ParseError.of(e)
        assert_true(Bool(got))
        assert_equal(
            got.value().error(),
            String(
                'parse error on line 1, column 3: bare " in non-quoted-field'
            ),
        )


def test_message_two_lines() raises:
    """A quoted field spanning lines names the line the record began on."""
    var r = new_reader(new_buffer_string('a,"b\nc"d,e'))
    try:
        _ = r.read()
        raise Error("the stray quote did not raise")
    except e:
        var got = ParseError.of(e)
        assert_true(Bool(got))
        assert_equal(got.value().start_line, 1)
        assert_equal(got.value().line, 2)
        assert_equal(got.value().column, 2)
        assert_equal(
            got.value().error(),
            String(
                "record on line 1; parse error on line 2, column 2:"
                ' extraneous or missing " in quoted-field'
            ),
        )


def test_unwrap_and_fields() raises:
    """The code is on the error itself, and so are the three numbers."""
    var r = new_reader(new_buffer_string('a,"b\nc"d,e'))
    try:
        _ = r.read()
        raise Error("the stray quote did not raise")
    except e:
        assert_true(matches(e, ErrQuote))
        assert_equal(field(e, "start_line").or_else(""), "1")
        assert_equal(field(e, "line").or_else(""), "2")
        assert_equal(field(e, "column").or_else(""), "2")
        var got = ParseError.of(e)
        assert_true(got.value().unwrap() == ErrQuote)


def test_of_ignores_other_errors() raises:
    """The end of the input is not a parse failure and has no `ParseError`."""
    var r = new_reader(new_buffer_string(""))
    try:
        _ = r.read()
        raise Error("the empty input did not raise")
    except e:
        assert_true(matches(e, EOF))
        assert_true(not ParseError.of(e))


def test_last_record_holds_the_short_record() raises:
    """The addition Go does not have, and the case it exists for.

    Go's `Read` hands back the record and `ErrFieldCount` together. A raise
    carries the failure alone, so the record waits here.
    """
    var r = new_reader(new_buffer_string("a,b,c\nd,e\nf,g,h\n"))
    r.fields_per_record = 0
    _ = r.read()
    assert_equal(len(r.last_record()), 0)
    try:
        _ = r.read()
        raise Error("the short record did not raise")
    except e:
        assert_true(matches(e, ErrFieldCount))
    var kept = r.last_record()
    assert_equal(len(kept), 2)
    assert_equal(kept[0], "d")
    assert_equal(kept[1], "e")
    # Reading carries on, because a count failure is not fatal.
    var third = r.read()
    assert_equal(len(third), 3)
    assert_equal(len(r.last_record()), 0)


def test_field_pos_out_of_range_raises() raises:
    """Go panics on an index out of range and this raises, as design.md says."""
    var r = new_reader(new_buffer_string("a,b\n"))
    _ = r.read()
    var spot = r.field_pos(1)
    assert_equal(spot[0], 1)
    assert_equal(spot[1], 3)
    var raised = False
    try:
        _ = r.field_pos(2)
    except:
        raised = True
    assert_true(raised)


def test_input_offset_walks_the_input() raises:
    """`input_offset` is where the next record starts, not where it ended."""
    var r = new_reader(new_buffer_string("a,b\nc,d\n"))
    assert_equal(r.input_offset(), Int64(0))
    _ = r.read()
    assert_equal(r.input_offset(), Int64(4))
    _ = r.read()
    assert_equal(r.input_offset(), Int64(8))
