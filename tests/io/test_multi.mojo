"""The four combinators, and what they do when one of their parts fails.

Joining readers and duplicating writers is easy to get right in the happy case
and easy to get wrong everywhere else, so most of this file is the edges: an
empty source in the middle of a chain, a sink that fails after another has
already been written to, a tee whose sink falls over after the read succeeded.

The last of those is the one worth stating. `tee_reader` has already taken the
bytes out of the source by the time it writes them, so a write failure it
swallowed would lose them silently. It raises instead, and the test asserts it.
"""

from std.testing import assert_equal, assert_true

from core.errors import Report, matches
from core.io import (
    AnyReader,
    AnyWriter,
    Discard,
    EOF,
    ErrShortWrite,
    NopCloser,
    READER_FROM,
    ReadCloser,
    Reader,
    Writer,
    copy,
    multi_reader,
    multi_writer,
    nop_closer,
    read_all,
    tee_reader,
)

comptime Byte = UInt8


struct Text(Copyable, Movable, Reader):
    """A reader over the bytes of a string, so a test reads like one."""

    var data: List[Byte]
    var pos: Int
    var reads: Int

    def __init__(out self, s: String):
        self.data = List[Byte]()
        for b in s.as_bytes():
            self.data.append(b)
        self.pos = 0
        self.reads = 0

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        self.reads += 1
        var n = 0
        while n < len(into) and self.pos < len(self.data):
            into[n] = self.data[self.pos]
            n += 1
            self.pos += 1
        if n == 0 and len(into) > 0:
            raise Report("text: end").with_code(EOF).error()
        return n


struct Sink(Copyable, Movable, Writer):
    """Keeps what it is given, and counts."""

    var got: List[Byte]
    var writes: Int

    def __init__(out self):
        self.got = List[Byte]()
        self.writes = 0

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        self.writes += 1
        for b in data:
            self.got.append(b)
        return len(data)


struct Broken(Copyable, Movable, Writer):
    """A sink that refuses everything."""

    def __init__(out self):
        pass

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        raise Report("broken: the disk is full").error()


struct Stingy(Copyable, Movable, Writer):
    """Takes one byte and reports it, which is a short write."""

    def __init__(out self):
        pass

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        if len(data) == 0:
            return 0
        return 1


def text(s: String) -> List[Byte]:
    var out = List[Byte]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def test_a_multi_reader_reads_its_sources_in_order() raises:
    var src = multi_reader(
        [
            AnyReader(Text("one ")),
            AnyReader(Text("two ")),
            AnyReader(Text("three")),
        ]
    )
    assert_equal(read_all(src), text("one two three"))


def test_a_multi_reader_of_one_source_is_that_source() raises:
    var src = multi_reader([AnyReader(Text("only"))])
    assert_equal(read_all(src), text("only"))


def test_a_multi_reader_of_nothing_is_immediately_the_end() raises:
    var src = multi_reader(List[AnyReader]())
    assert_equal(len(read_all(src)), 0)


def test_an_empty_source_in_the_middle_is_skipped() raises:
    # Go hands back a zero here and moves on next time round, so a caller doing
    # its own loop sees a zero length read in the middle of a full stream.
    # This keeps going instead. `multi.mojo` says why.
    var src = multi_reader(
        [AnyReader(Text("ab")), AnyReader(Text("")), AnyReader(Text("cd"))]
    )
    var buf = List[Byte]()
    for _ in range(4):
        buf.append(0)
    assert_equal(src.read(Span(buf)), 2)
    assert_equal(src.read(Span(buf)), 2)


def test_a_spent_multi_reader_reports_the_end_every_time() raises:
    var src = multi_reader([AnyReader(Text("ab"))])
    _ = read_all(src)
    for _ in range(3):
        var buf = List[Byte]()
        buf.append(0)
        var raised = False
        try:
            _ = src.read(Span(buf))
        except e:
            raised = True
            assert_true(matches(e, EOF))
        assert_true(raised)


def test_a_multi_writer_writes_to_all_of_them() raises:
    var first = AnyWriter(Sink())
    var second = AnyWriter(Sink())
    var dst = multi_writer([AnyWriter(copy=first), AnyWriter(copy=second)])
    assert_equal(dst.write(text("hello")), 5)
    assert_equal(first.get[Sink]().got, text("hello"))
    assert_equal(second.get[Sink]().got, text("hello"))


def test_a_multi_writer_of_nothing_accepts_everything() raises:
    var dst = multi_writer(List[AnyWriter]())
    assert_equal(dst.write(text("hello")), 5)


def test_a_multi_writer_stops_at_the_first_failure() raises:
    var first = AnyWriter(Sink())
    var third = AnyWriter(Sink())
    var dst = multi_writer(
        [AnyWriter(copy=first), AnyWriter(Broken()), AnyWriter(copy=third)]
    )
    var raised = False
    try:
        _ = dst.write(text("hello"))
    except e:
        raised = True
    assert_true(raised)
    # The earlier sink kept its bytes and the later one never saw any. There is
    # no way to unwrite, so this is the behaviour and not a bug.
    assert_equal(first.get[Sink]().got, text("hello"))
    assert_equal(len(third.get[Sink]().got), 0)


def test_a_multi_writer_treats_a_short_write_as_a_failure() raises:
    var dst = multi_writer([AnyWriter(Stingy())])
    var raised = False
    try:
        _ = dst.write(text("hello"))
    except e:
        raised = True
        assert_true(matches(e, ErrShortWrite))
    assert_true(raised)


def test_a_tee_reader_copies_what_it_reads() raises:
    var spy = AnyWriter(Sink())
    var src = tee_reader(AnyReader(Text("hello")), AnyWriter(copy=spy))
    assert_equal(read_all(src), text("hello"))
    assert_equal(spy.get[Sink]().got, text("hello"))


def test_a_tee_reader_writes_nothing_it_did_not_read() raises:
    var spy = AnyWriter(Sink())
    var src = tee_reader(AnyReader(Text("hello")), AnyWriter(copy=spy))
    var buf = List[Byte]()
    for _ in range(2):
        buf.append(0)
    assert_equal(src.read(Span(buf)), 2)
    assert_equal(spy.get[Sink]().got, text("he"))


def test_a_tee_reader_raises_when_its_sink_fails() raises:
    # The bytes are already out of the source at this point, so swallowing the
    # write failure would lose them without telling anybody.
    var src = tee_reader(AnyReader(Text("hello")), AnyWriter(Broken()))
    var buf = List[Byte]()
    for _ in range(4):
        buf.append(0)
    var raised = False
    try:
        _ = src.read(Span(buf))
    except e:
        raised = True
    assert_true(raised)


def test_a_tee_reader_raises_on_a_short_write() raises:
    var src = tee_reader(AnyReader(Text("hello")), AnyWriter(Stingy()))
    var buf = List[Byte]()
    for _ in range(4):
        buf.append(0)
    var raised = False
    try:
        _ = src.read(Span(buf))
    except e:
        raised = True
        assert_true(matches(e, ErrShortWrite))
    assert_true(raised)


def close_it[C: ReadCloser](mut c: C) raises:
    """Something that insists on closing what it is handed."""
    c.close()


def test_a_nop_closer_reads_and_closes() raises:
    var src = nop_closer(Text("hello"))
    assert_equal(read_all(src), text("hello"))
    close_it(src)
    # Closing changed nothing, so it still reports the end rather than failing
    # in some new way.
    assert_equal(len(read_all(src)), 0)


def test_a_nop_closer_can_be_closed_twice() raises:
    var src = nop_closer(Text("hello"))
    src.close()
    src.close()
    assert_equal(read_all(src), text("hello"))


def test_discard_accepts_everything() raises:
    var dst = Discard()
    assert_equal(dst.write(text("hello")), 5)
    assert_equal(dst.write(List[Byte]()), 0)


def test_discard_takes_the_reader_from_fast_path() raises:
    var src = Text("hello there, this is a stream")
    var dst = Discard()
    assert_true(dst.capabilities() & READER_FROM != 0)
    assert_equal(copy(dst, src), 29)


def test_copying_into_discard_drains_the_source() raises:
    var src = Text("hello")
    var dst = Discard()
    _ = copy(dst, src)
    assert_equal(src.pos, 5)
