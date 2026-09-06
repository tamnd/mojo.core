"""Go's `TestRead`, split into the three things it checks at once.

Go runs one subtest per row and inside it reads the file twice, once with
`ReadAll` and once record by record to check `FieldPos`. The same work is here,
split into `test_read_all`, `test_read_offset` and `test_field_pos`, because a
subtest per row is what names the failure in Go and a raised message is what
names it here.

The assertions raise with the row name rather than calling `assert_equal`,
since the helpers in `std.testing` take no message and a table of sixty rows
needs to say which row went wrong.
"""

from std.testing import assert_equal, assert_true

from core.bytes import Buffer, new_buffer, new_buffer_string
from core.encoding.csv import ParseError, new_reader
from core.errors import NO_CODE, Code, matches
from core.errors.codes import EOF, ErrFieldCount, ErrInvalidDelim, ErrNotText
from core.encoding.csv.reader import Reader

from ._fixtures import Marked, ReadCase, make_positions, read_cases


def _reader_for(row: ReadCase, text: String) -> Reader[Buffer]:
    """Go's `newReader` closure, settings and all.

    A comma of zero means the row did not ask for one, which is why it is not
    assigned, and `fields_per_record` is minus one unless the row asked.
    """
    var r = new_reader(new_buffer_string(text))
    if row.comma != 0:
        r.comma = row.comma
    r.comment = row.comment
    if row.use_fields_per_record:
        r.fields_per_record = row.fields_per_record
    else:
        r.fields_per_record = -1
    r.lazy_quotes = row.lazy_quotes
    r.trim_leading_space = row.trim_leading_space
    return r^


def _want(ok: Bool, name: String, what: String) raises:
    """Fail the whole test, saying which row and what about it."""
    if not ok:
        raise Error("case " + name + ": " + what)


def _same_row(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _same_rows(a: List[List[String]], b: List[List[String]]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if not _same_row(a[i], b[i]):
            return False
    return True


def _show(rows: List[List[String]]) -> String:
    """A table on one line, for a failure message."""
    var out = String("[")
    for i in range(len(rows)):
        if i > 0:
            out += " "
        out += "["
        for j in range(len(rows[i])):
            if j > 0:
                out += " "
            out += repr(rows[i][j])
        out += "]"
    return out + "]"


def _first_failure(row: ReadCase) -> Int:
    """The index of the record Go's `firstError` picks, or minus one."""
    for i in range(len(row.errors)):
        if row.errors[i] != NO_CODE:
            return i
    return -1


def _check_parse_error(
    row: ReadCase, marked: Marked, rec_num: Int, e: Error
) raises:
    """The three numbers Go's `errorWithPosition` fills in.

    Skipped for a delimiter failure, which Go leaves alone as well because it
    is not a `*ParseError` and so has no position to fill in.
    """
    if matches(e, ErrInvalidDelim):
        return
    var failure = ParseError.of(e)
    _want(Bool(failure), row.name, "no ParseError behind " + String(e))
    var got = failure.value().copy()
    var want_start = marked.positions[rec_num][0].line
    var spot = marked.failures[rec_num]
    _want(
        got.start_line == want_start,
        row.name,
        "start_line " + String(got.start_line) + ", want " + String(want_start),
    )
    _want(
        got.line == spot.line,
        row.name,
        "line " + String(got.line) + ", want " + String(spot.line),
    )
    _want(
        got.column == spot.col,
        row.name,
        "column " + String(got.column) + ", want " + String(spot.col),
    )


def test_read_all() raises:
    """Every row read in one go, checked against `output` or against `errors`.
    """
    var cases = read_cases()
    for i in range(len(cases)):
        var row = cases[i].copy()
        var marked = make_positions(row.input)
        var r = _reader_for(row, marked.text)
        var at = _first_failure(row)
        var got = List[List[String]]()
        var raised = Optional[Error](None)
        try:
            got = r.read_all()
        except e:
            raised = e
        if at < 0:
            _want(
                not raised,
                row.name,
                "read_all raised " + String(raised.or_else(Error(""))),
            )
            _want(
                _same_rows(got, row.output),
                row.name,
                "read_all gave " + _show(got) + ", want " + _show(row.output),
            )
            continue
        _want(Bool(raised), row.name, "read_all did not raise")
        _want(
            matches(raised.value(), row.errors[at]),
            row.name,
            "read_all raised " + String(raised.value()),
        )
        _want(len(got) == 0, row.name, "read_all gave " + _show(got))
        _check_parse_error(row, marked, at, raised.value())


def test_read_offset() raises:
    """`input_offset` is the whole file once a file has been read through."""
    var cases = read_cases()
    for i in range(len(cases)):
        var row = cases[i].copy()
        if _first_failure(row) >= 0:
            continue
        var marked = make_positions(row.input)
        var r = _reader_for(row, marked.text)
        _ = r.read_all()
        _want(
            r.input_offset() == Int64(marked.text.byte_length()),
            row.name,
            "input_offset "
            + String(r.input_offset())
            + ", want "
            + String(marked.text.byte_length()),
        )


def test_field_pos() raises:
    """Record by record, checking every field against its marked position."""
    var cases = read_cases()
    for i in range(len(cases)):
        var row = cases[i].copy()
        var marked = make_positions(row.input)
        var r = _reader_for(row, marked.text)
        var rec_num = 0
        while True:
            var rec = List[String]()
            var raised = Optional[Error](None)
            try:
                rec = r.read()
            except e:
                raised = e
                rec = r.last_record()
            var want = NO_CODE
            if rec_num < len(row.errors):
                want = row.errors[rec_num]
            if want == NO_CODE and rec_num >= len(row.output):
                want = EOF
            if want == NO_CODE:
                _want(
                    not raised,
                    row.name,
                    "record "
                    + String(rec_num)
                    + " raised "
                    + String(raised.or_else(Error(""))),
                )
            else:
                _want(
                    Bool(raised),
                    row.name,
                    "record " + String(rec_num) + " did not raise",
                )
                _want(
                    matches(raised.value(), want),
                    row.name,
                    "record "
                    + String(rec_num)
                    + " raised "
                    + String(raised.value()),
                )
                if want != EOF:
                    _check_parse_error(row, marked, rec_num, raised.value())
                # A count failure is the one raise that leaves a whole record
                # behind, so it is the one the loop carries on past. Go says
                # the same with a comment about `ErrFieldCount` being non fatal.
                if want != ErrFieldCount:
                    break
            _want(
                rec_num < len(row.output),
                row.name,
                "record " + String(rec_num) + " is past the expected output",
            )
            _want(
                _same_row(rec, row.output[rec_num]),
                row.name,
                "record " + String(rec_num) + " read differently from read_all",
            )
            var pos = marked.positions[rec_num].copy()
            _want(
                len(pos) == len(rec),
                row.name,
                "record "
                + String(rec_num)
                + " has "
                + String(len(rec))
                + " fields, marked "
                + String(len(pos)),
            )
            for f in range(len(rec)):
                var spot = r.field_pos(f)
                _want(
                    spot[0] == pos[f].line and spot[1] == pos[f].col,
                    row.name,
                    "field "
                    + String(f)
                    + " of record "
                    + String(rec_num)
                    + " at "
                    + String(spot[0])
                    + ":"
                    + String(spot[1])
                    + ", want "
                    + String(pos[f].line)
                    + ":"
                    + String(pos[f].col),
                )
            rec_num += 1


def test_binary_blob_field() raises:
    """Go's `BinaryBlobField` row, which is a failure here rather than a record.

    Go reads `x09A\\xb4\\x1c` into a `string` and hands it back, because a Go
    string is any bytes at all. A Mojo `String` says it is UTF-8, so the same
    input raises `ErrNotText`. This is the one row of Go's table that is not in
    `read_cases`, and the deviations page says so as well.
    """
    var raw = List[UInt8]()
    for b in String("x09").as_bytes():
        raw.append(b)
    raw.append(0x41)
    raw.append(0xB4)
    raw.append(0x1C)
    for b in String(",aktau").as_bytes():
        raw.append(b)
    var r = new_reader(new_buffer(raw^))
    var raised = False
    try:
        _ = r.read()
    except e:
        raised = True
        assert_true(matches(e, ErrNotText))
    assert_true(raised)
