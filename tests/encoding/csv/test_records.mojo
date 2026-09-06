"""`Reader.records()`, the cursor Go has no counterpart for.

The point of it is the case Go's loop gets wrong when the comparison against
`io.EOF` is left out, so the test that matters here is the malformed row in the
middle of a file: it has to raise rather than end the loop quietly.
"""

from std.testing import assert_equal, assert_true

from core.bytes import new_buffer_string
from core.encoding.csv import new_reader
from core.errors import matches
from core.errors.codes import EOF, ErrFieldCount, ErrQuote


def test_records_walks_a_file() raises:
    var r = new_reader(new_buffer_string("a,b\nc,d\ne,f\n"))
    var records = r.records()
    var seen = List[String]()
    while records.has_next():
        var record = records.next()
        seen.append(record[0])
    assert_equal(len(seen), 3)
    assert_equal(seen[0], "a")
    assert_equal(seen[2], "e")


def test_records_ends_clean_and_stays_ended() raises:
    """The first of the trait's three rules, checked twice over."""
    var r = new_reader(new_buffer_string("a,b\n"))
    var records = r.records()
    assert_true(records.has_next())
    _ = records.next()
    assert_true(not records.has_next())
    assert_true(not records.has_next())


def test_records_next_past_the_end_raises() raises:
    """The second rule. There is no zero record to hand back instead."""
    var r = new_reader(new_buffer_string("a,b\n"))
    var records = r.records()
    _ = records.next()
    var raised = False
    try:
        _ = records.next()
    except e:
        raised = True
        assert_true(matches(e, EOF))
    assert_true(raised)


def test_records_reports_a_malformed_row() raises:
    """The whole reason this exists, and the case Go's loop can get wrong."""
    var r = new_reader(new_buffer_string('a,b\nc,"d"e\nf,g\n'))
    var records = r.records()
    var seen = 0
    var raised = False
    try:
        while records.has_next():
            _ = records.next()
            seen += 1
    except e:
        raised = True
        assert_true(matches(e, ErrQuote))
    assert_true(raised)
    assert_equal(seen, 1)


def test_records_reports_a_short_row() raises:
    """A count failure raises here too, with the record on `last_record`."""
    var r = new_reader(new_buffer_string("a,b,c\nd,e\n"))
    r.fields_per_record = 0
    var records = r.records()
    _ = records.next()
    var raised = False
    try:
        _ = records.next()
    except e:
        raised = True
        assert_true(matches(e, ErrFieldCount))
    assert_true(raised)
    var kept = r.last_record()
    assert_equal(len(kept), 2)
    assert_equal(kept[1], "e")


def test_reader_is_usable_after_the_cursor() raises:
    """The cursor points at the reader, so the reader keeps its place."""
    var r = new_reader(new_buffer_string("a,b\nc,d\ne,f\n"))
    var first = List[String]()
    var records = r.records()
    if records.has_next():
        first = records.next()
    assert_equal(first[0], "a")
    var rest = r.read_all()
    assert_equal(len(rest), 2)
    assert_equal(rest[0][0], "c")
    assert_equal(rest[1][0], "e")
