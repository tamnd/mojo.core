"""Go's `writeTests`, `TestWrite` and `TestError`.

Two of Go's rows are missing and both hold the same four bytes, `x09A\\xb4\\x1c`,
which are not valid UTF-8 and so are not a Mojo `String`. Go writes them out
unchanged because a Go string is any bytes at all. Everything those two rows
were checking, that a field is copied through untouched and that a field holding
a delimiter gets quoted, is checked by the rows either side of them.
"""

from std.testing import assert_equal, assert_true

from core.bytes import new_buffer
from core.encoding.csv import new_writer
from core.errors import matches
from core.errors.codes import ErrInvalidDelim
from core.io import Byte, Writer as IoWriter

from ._fixtures import fields, rows


struct Broken(Copyable, IoWriter, Movable):
    """A sink that refuses everything. Go's `errorWriter`."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        self.calls += 1
        raise Error("broken: this sink takes nothing")


struct WriteCase(Copyable, Movable):
    """One row of Go's `writeTests`."""

    var input: List[List[String]]
    var output: String
    var use_crlf: Bool
    var comma: Int32
    var refused: Bool

    def __init__(
        out self,
        var input: List[List[String]],
        var output: String,
        use_crlf: Bool = False,
        comma: Int32 = 0,
        refused: Bool = False,
    ):
        self.input = input^
        self.output = output^
        self.use_crlf = use_crlf
        self.comma = comma
        self.refused = refused


def _write_cases() -> List[WriteCase]:
    """Go's table, in Go's order."""
    var out = List[WriteCase]()
    out.append(WriteCase(rows(fields("abc")), "abc\n"))
    out.append(WriteCase(rows(fields("abc")), "abc\r\n", use_crlf=True))
    out.append(WriteCase(rows(fields('"abc"')), String('"""abc"""') + "\n"))
    out.append(WriteCase(rows(fields('a"b')), String('"a""b"') + "\n"))
    out.append(WriteCase(rows(fields('"a"b"')), String('"""a""b"""') + "\n"))
    out.append(WriteCase(rows(fields(" abc")), String('" abc"') + "\n"))
    out.append(WriteCase(rows(fields("abc,def")), String('"abc,def"') + "\n"))
    out.append(WriteCase(rows(fields("abc", "def")), "abc,def\n"))
    out.append(WriteCase(rows(fields("abc"), fields("def")), "abc\ndef\n"))
    out.append(WriteCase(rows(fields("abc\ndef")), String('"abc\ndef"') + "\n"))
    out.append(
        WriteCase(
            rows(fields("abc\ndef")),
            String('"abc\r\ndef"') + "\r\n",
            use_crlf=True,
        )
    )
    out.append(
        WriteCase(
            rows(fields("abc\rdef")), String('"abcdef"') + "\r\n", use_crlf=True
        )
    )
    out.append(WriteCase(rows(fields("abc\rdef")), String('"abc\rdef"') + "\n"))
    out.append(WriteCase(rows(fields("")), "\n"))
    out.append(WriteCase(rows(fields("", "")), ",\n"))
    out.append(WriteCase(rows(fields("", "", "")), ",,\n"))
    out.append(WriteCase(rows(fields("", "", "a")), ",,a\n"))
    out.append(WriteCase(rows(fields("", "a", "")), ",a,\n"))
    out.append(WriteCase(rows(fields("", "a", "a")), ",a,a\n"))
    out.append(WriteCase(rows(fields("a", "", "")), "a,,\n"))
    out.append(WriteCase(rows(fields("a", "", "a")), "a,,a\n"))
    out.append(WriteCase(rows(fields("a", "a", "")), "a,a,\n"))
    out.append(WriteCase(rows(fields("a", "a", "a")), "a,a,a\n"))
    # A field that would look like the end of a PostgreSQL copy, quoted so it
    # cannot be read back as one.
    out.append(WriteCase(rows(fields("\\.")), String('"\\."') + "\n"))
    out.append(
        WriteCase(rows(fields("a", "a", "")), "a|a|\n", comma=Int32(ord("|")))
    )
    out.append(
        WriteCase(rows(fields(",", ",", "")), ",|,|\n", comma=Int32(ord("|")))
    )
    out.append(
        WriteCase(rows(fields("foo")), "", comma=Int32(ord('"')), refused=True)
    )
    return out^


def test_write() raises:
    var cases = _write_cases()
    for i in range(len(cases)):
        var row = cases[i].copy()
        var w = new_writer(new_buffer(List[Byte]()))
        w.use_crlf = row.use_crlf
        if row.comma != 0:
            w.comma = row.comma
        var raised = Optional[Error](None)
        try:
            w.write_all(Span(row.input))
        except e:
            raised = e
        if row.refused:
            if not raised:
                raise Error("row " + String(i) + ": write_all did not raise")
            if not matches(raised.value(), ErrInvalidDelim):
                raise Error(
                    "row " + String(i) + ": raised " + String(raised.value())
                )
        elif raised:
            raise Error(
                "row " + String(i) + ": raised " + String(raised.value())
            )
        var got = w.w.w.string()
        if got != row.output:
            raise Error(
                "row "
                + String(i)
                + ": wrote "
                + repr(got)
                + ", want "
                + repr(row.output)
            )


def test_error() raises:
    """Go's `TestError`: nothing to report, then something to report."""
    var record: List[String] = ["abc"]
    var w = new_writer(new_buffer(List[Byte]()))
    w.write(Span(record))
    w.flush()
    assert_true(not w.error())

    var bad = new_writer(Broken())
    bad.write(Span(record))
    var raised = False
    try:
        bad.flush()
    except:
        raised = True
    assert_true(raised)
    assert_true(Bool(bad.error()))


def test_write_then_error_keeps_failing() raises:
    """A stuck writer stays stuck, which is what `error` answering means."""
    var record: List[String] = ["abc"]
    var bad = new_writer(Broken())
    bad.write(Span(record))
    try:
        bad.flush()
    except:
        pass
    var again = False
    try:
        bad.write(Span(record))
        bad.flush()
    except:
        again = True
    assert_true(again)
    assert_true(Bool(bad.error()))
