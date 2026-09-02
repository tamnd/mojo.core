"""Windows onto something bigger: the limit, the section and the offset.

The three types here are the ones that do arithmetic on positions, so most of
this file is boundaries. Off by one in `SectionReader.read` is the interesting
bug, because it does not corrupt anything: it hands back one byte too many or
one too few from a stream that is otherwise perfect, and only a test that
counts catches it.

`limit_reader` gets one test that is really about `read_all`. Reading an
untrusted stream into memory with no limit is how a program is made to run out
of it, and the pair is the answer, so the pair is what is tested.
"""

from std.testing import assert_equal, assert_true

from core.errors import Report, matches
from core.io import (
    EOF,
    LimitedReader,
    OffsetWriter,
    Reader,
    ReaderAt,
    SEEK_CURRENT,
    SEEK_END,
    SEEK_START,
    SectionReader,
    Writer,
    WriterAt,
    limit_reader,
    new_offset_writer,
    new_section_reader,
    read_all,
)

comptime Byte = UInt8


def bytes(n: Int) -> List[Byte]:
    var out = List[Byte](capacity=n)
    for i in range(n):
        out.append(Byte(i % 251))
    return out^


struct Fixed(Copyable, Movable, Reader):
    """A reader over a list."""

    var data: List[Byte]
    var pos: Int

    def __init__(out self, var data: List[Byte]):
        self.data = data^
        self.pos = 0

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        var n = 0
        while n < len(into) and self.pos < len(self.data):
            into[n] = self.data[self.pos]
            n += 1
            self.pos += 1
        if n == 0 and len(into) > 0:
            raise Report("fixed: end").with_code(EOF).error()
        return n


struct Endless(Copyable, Movable, Reader):
    """Never ends. The thing `limit_reader` is for."""

    def __init__(out self):
        pass

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        for i in range(len(into)):
            into[i] = 65
        return len(into)


struct Blob(Copyable, Movable, ReaderAt, WriterAt):
    """A list addressed by position, both ways.

    `read_at` takes an immutable `self` because reading moves nothing, which is
    what lets two `SectionReader`s share one of these.
    """

    var data: List[Byte]

    def __init__(out self, var data: List[Byte]):
        self.data = data^

    def read_at[
        o: Origin[mut=True]
    ](self, into: Span[Byte, o], offset: Int64) raises -> Int:
        if offset < 0 or Int(offset) >= len(self.data):
            raise Report("blob: past the end").with_code(EOF).error()
        var n = 0
        var at = Int(offset)
        while n < len(into) and at < len(self.data):
            into[n] = self.data[at]
            n += 1
            at += 1
        return n

    def write_at[
        o: Origin
    ](mut self, data: Span[Byte, o], offset: Int64) raises -> Int:
        var at = Int(offset)
        while len(self.data) < at + len(data):
            self.data.append(0)
        for i in range(len(data)):
            self.data[at + i] = data[i]
        return len(data)


def test_a_limited_reader_stops_at_its_limit() raises:
    var src = limit_reader(Fixed(bytes(100)), 10)
    var got = read_all(src)
    assert_equal(len(got), 10)
    for i in range(10):
        assert_equal(got[i], Byte(i))


def test_a_limited_reader_leaves_a_shorter_stream_alone() raises:
    var src = limit_reader(Fixed(bytes(4)), 100)
    assert_equal(len(read_all(src)), 4)


def test_a_limited_reader_reports_what_is_left() raises:
    var src = limit_reader(Fixed(bytes(100)), 10)
    var buf = bytes(4)
    assert_equal(src.read(Span(buf)), 4)
    assert_equal(src.n, 6)


def test_a_limited_reader_bounds_a_stream_that_never_ends() raises:
    # Without the limit this is an infinite loop and then a dead machine, which
    # is the reason the type exists.
    var src = limit_reader(Endless(), 2048)
    assert_equal(len(read_all(src)), 2048)


def test_a_spent_limited_reader_reports_the_end_every_time() raises:
    var src = limit_reader(Fixed(bytes(100)), 2)
    var buf = bytes(8)
    assert_equal(src.read(Span(buf)), 2)
    for _ in range(3):
        var raised = False
        try:
            _ = src.read(Span(buf))
        except e:
            raised = True
            assert_true(matches(e, EOF))
        assert_true(raised)


def test_a_limit_of_zero_reads_nothing() raises:
    var src = limit_reader(Fixed(bytes(100)), 0)
    assert_equal(len(read_all(src)), 0)


def test_a_section_reads_only_its_window() raises:
    var src = new_section_reader(Blob(bytes(100)), 10, 5)
    var got = read_all(src)
    assert_equal(len(got), 5)
    for i in range(5):
        assert_equal(got[i], Byte(10 + i))


def test_a_section_asked_for_more_than_the_window_stops_at_the_edge() raises:
    var src = new_section_reader(Blob(bytes(100)), 10, 5)
    var buf = bytes(50)
    assert_equal(src.read(Span(buf)), 5)
    assert_equal(buf[0], Byte(10))
    assert_equal(buf[4], Byte(14))


def test_a_section_knows_its_size_and_where_it_came_from() raises:
    var src = new_section_reader(Blob(bytes(100)), 10, 5)
    assert_equal(src.size(), 5)
    var made_with = src.outer()
    assert_equal(made_with[0], 10)
    assert_equal(made_with[1], 5)
    # The source is the public field, because a method cannot hand back a
    # borrow of one alongside two values. `limit.mojo` says so on `outer`.
    assert_equal(len(src.r.data), 100)


def test_a_sections_read_at_is_relative_to_the_section() raises:
    var src = new_section_reader(Blob(bytes(100)), 10, 5)
    var buf = bytes(3)
    assert_equal(src.read_at(Span(buf), 2), 3)
    assert_equal(buf[0], Byte(12))
    # It moved nothing, so a following read still starts at the beginning.
    var again = bytes(1)
    assert_equal(src.read(Span(again)), 1)
    assert_equal(again[0], Byte(10))


def test_a_sections_read_at_past_the_window_is_the_end() raises:
    var src = new_section_reader(Blob(bytes(100)), 10, 5)
    var buf = bytes(4)
    var raised = False
    try:
        _ = src.read_at(Span(buf), 5)
    except e:
        raised = True
        assert_true(matches(e, EOF))
    assert_true(raised)


def test_a_sections_read_at_clips_to_the_window() raises:
    var src = new_section_reader(Blob(bytes(100)), 10, 5)
    var buf = bytes(20)
    # Four bytes left in the window from offset one, and the source has ninety
    # more. A version that forgot the limit would return twenty.
    assert_equal(src.read_at(Span(buf), 1), 4)


def test_seeking_in_a_section_is_relative_to_the_section() raises:
    var src = new_section_reader(Blob(bytes(100)), 10, 5)
    assert_equal(src.seek(2, SEEK_START), 2)
    var buf = bytes(1)
    assert_equal(src.read(Span(buf)), 1)
    assert_equal(buf[0], Byte(12))
    assert_equal(src.seek(-1, SEEK_CURRENT), 2)
    assert_equal(src.seek(0, SEEK_END), 5)


def test_seeking_before_the_start_of_a_section_fails() raises:
    var src = new_section_reader(Blob(bytes(100)), 10, 5)
    var raised = False
    try:
        _ = src.seek(-1, SEEK_START)
    except e:
        raised = True
    assert_true(raised)
    # And the position is untouched, so the reader is still usable.
    var buf = bytes(1)
    assert_equal(src.read(Span(buf)), 1)
    assert_equal(buf[0], Byte(10))


def test_a_section_seeked_to_the_end_reports_the_end() raises:
    var src = new_section_reader(Blob(bytes(100)), 10, 5)
    _ = src.seek(0, SEEK_END)
    var buf = bytes(4)
    var raised = False
    try:
        _ = src.read(Span(buf))
    except e:
        raised = True
        assert_true(matches(e, EOF))
    assert_true(raised)


def test_two_sections_over_one_source_do_not_disturb_each_other() raises:
    # The whole reason `ReaderAt` is a separate trait from `Reader`.
    var first = new_section_reader(Blob(bytes(100)), 0, 4)
    var second = new_section_reader(Blob(bytes(100)), 50, 4)
    var a = bytes(4)
    var b = bytes(4)
    assert_equal(first.read(Span(a)), 4)
    assert_equal(second.read(Span(b)), 4)
    assert_equal(a[0], Byte(0))
    assert_equal(b[0], Byte(50))


def test_an_offset_writer_starts_where_it_was_told() raises:
    var dst = new_offset_writer(Blob(List[Byte]()), 4)
    assert_equal(dst.write("ab".as_bytes()), 2)
    assert_equal(len(dst.w.data), 6)
    assert_equal(dst.w.data[4], Byte(97))
    assert_equal(dst.w.data[5], Byte(98))


def test_an_offset_writer_advances() raises:
    var dst = new_offset_writer(Blob(List[Byte]()), 0)
    _ = dst.write("ab".as_bytes())
    _ = dst.write("cd".as_bytes())
    assert_equal(len(dst.w.data), 4)
    assert_equal(dst.w.data[2], Byte(99))


def test_an_offset_writers_write_at_moves_nothing() raises:
    var dst = new_offset_writer(Blob(List[Byte]()), 0)
    assert_equal(dst.write_at("zz".as_bytes(), 10), 2)
    # The position is still zero, so the next `write` starts at the beginning
    # and does not follow the `write_at`.
    _ = dst.write("ab".as_bytes())
    assert_equal(dst.w.data[0], Byte(97))
    assert_equal(dst.w.data[10], Byte(122))


def test_seeking_an_offset_writer() raises:
    var dst = new_offset_writer(Blob(List[Byte]()), 4)
    assert_equal(dst.seek(2, SEEK_START), 2)
    _ = dst.write("x".as_bytes())
    assert_equal(dst.w.data[6], Byte(120))
    assert_equal(dst.seek(0, SEEK_CURRENT), 3)


def test_an_offset_writer_has_no_end_to_seek_from() raises:
    var dst = new_offset_writer(Blob(List[Byte]()), 0)
    var raised = False
    try:
        _ = dst.seek(0, SEEK_END)
    except e:
        raised = True
    assert_true(raised)
