"""`copy_n` and `copy_buffer`: the two copies with something extra to get wrong.

`copy_n` has to stop on a boundary the reader knows nothing about, so the last
read has to ask for less than a full buffer. The test that pins that is the one
with a count smaller than the buffer and a source longer than the count: a
version that read a whole buffer and wrote only part of it would pass every
other test here and quietly eat the rest of the stream.

`copy_buffer` has to use the buffer it was handed and still take the fast paths,
which are the two claims that make it worth having, and both are checked by
counting rather than by looking at the bytes.
"""

from std.testing import assert_equal, assert_true

from core.errors import Report, matches, partial
from core.io import (
    AnyReader,
    AnyWriter,
    EOF,
    ErrNoProgress,
    READER_FROM,
    Reader,
    WRITER_TO,
    Writer,
    copy_buffer,
    copy_n,
)

comptime Byte = UInt8


def bytes(n: Int) -> List[Byte]:
    var out = List[Byte](capacity=n)
    for i in range(n):
        out.append(Byte(i % 251))
    return out^


def buffer(n: Int) -> List[Byte]:
    var out = List[Byte](capacity=n)
    for _ in range(n):
        out.append(0)
    return out^


struct Fixed(Copyable, Movable, Reader):
    """A reader over a list, counting how often it was asked."""

    var data: List[Byte]
    var pos: Int
    var reads: Int
    var biggest: Int

    def __init__(out self, var data: List[Byte]):
        self.data = data^
        self.pos = 0
        self.reads = 0
        self.biggest = 0

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        self.reads += 1
        if len(into) > self.biggest:
            self.biggest = len(into)
        var n = 0
        while n < len(into) and self.pos < len(self.data):
            into[n] = self.data[self.pos]
            n += 1
            self.pos += 1
        if n == 0 and len(into) > 0:
            raise Report("fixed: end").with_code(EOF).error()
        return n


struct Sink(Copyable, Movable, Writer):
    """Keeps what it is given."""

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


struct Eager(Copyable, Movable, Writer):
    """A writer with a `read_from` fast path, and a counter on each side."""

    var got: List[Byte]
    var writes: Int
    var drains: Int
    var bits: Int

    def __init__(out self, bits: Int = READER_FROM):
        self.got = List[Byte]()
        self.writes = 0
        self.drains = 0
        self.bits = bits

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        self.writes += 1
        for b in data:
            self.got.append(b)
        return len(data)

    def capabilities(self) -> Int:
        return self.bits

    def read_from[R: Reader](mut self, mut src: R) raises -> Int64:
        self.drains += 1
        var buf = buffer(64)
        var moved = Int64(0)
        while True:
            var n: Int
            try:
                n = src.read(Span(buf))
            except e:
                if matches(e, EOF):
                    return moved
                raise e
            for i in range(n):
                self.got.append(buf[i])
            moved += Int64(n)


struct Broken(Copyable, Movable, Reader):
    """Hands over `ok` bytes and then fails with something that is not the end.
    """

    var ok: Int
    var done: Int

    def __init__(out self, ok: Int):
        self.ok = ok
        self.done = 0

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        if self.done >= self.ok:
            raise Report("broken: the device fell over").error()
        var n = len(into)
        if n > self.ok - self.done:
            n = self.ok - self.done
        for i in range(n):
            into[i] = 9
        self.done += n
        return n


struct Stuck(Copyable, Movable, Reader):
    """Zero bytes and no failure, forever, which the contract forbids."""

    def __init__(out self):
        pass

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        return 0


def test_copy_n_moves_exactly_that_many() raises:
    var src = Fixed(bytes(100))
    var dst = Sink()
    assert_equal(copy_n(dst, src, 10), 10)
    assert_equal(len(dst.got), 10)
    for i in range(10):
        assert_equal(dst.got[i], Byte(i))
    # And it left the rest of the source alone.
    assert_equal(src.pos, 10)


def test_copy_n_never_asks_for_more_than_it_wants() raises:
    # The claim: the last read is clipped to the count. Without the clip the
    # reader is asked for a whole buffer and everything past the count is read
    # and then dropped, which is invisible in the output and fatal on a stream
    # somebody else is going to read next.
    var src = Fixed(bytes(1000))
    var dst = Sink()
    assert_equal(copy_n(dst, src, 10), 10)
    assert_true(src.biggest <= 10)


def test_copy_n_of_zero_does_nothing() raises:
    var src = Fixed(bytes(100))
    var dst = Sink()
    assert_equal(copy_n(dst, src, 0), 0)
    assert_equal(src.reads, 0)


def test_copy_n_of_a_negative_count_does_nothing() raises:
    var src = Fixed(bytes(100))
    var dst = Sink()
    assert_equal(copy_n(dst, src, -5), 0)
    assert_equal(src.reads, 0)


def test_copy_n_past_the_end_is_the_end() raises:
    var src = Fixed(bytes(4))
    var dst = Sink()
    var raised = False
    try:
        _ = copy_n(dst, src, 10)
    except e:
        raised = True
        assert_true(matches(e, EOF))
        # How far it got, so a caller can tell short from broken.
        assert_equal(partial(e), 4)
    assert_true(raised)
    # The bytes that did arrive are in the sink, not thrown away.
    assert_equal(len(dst.got), 4)


def test_copy_n_across_more_than_one_buffer() raises:
    var src = Fixed(bytes(200000))
    var dst = Sink()
    assert_equal(copy_n(dst, src, 100000), 100000)
    assert_equal(len(dst.got), 100000)
    assert_equal(dst.got[99999], Byte(99999 % 251))


def test_copy_n_ignores_the_writers_fast_path() raises:
    # Documented, not accidental: taking `read_from` would drain the whole
    # source and blow past the count. `copy.mojo` says how to get Go's
    # behaviour when the caller owns its reader.
    var src = Fixed(bytes(100))
    var dst = Eager()
    assert_equal(copy_n(dst, src, 10), 10)
    assert_equal(dst.drains, 0)
    assert_true(dst.writes > 0)


def test_copy_n_carries_a_failure_out_with_its_count() raises:
    var src = Broken(ok=5)
    var dst = Sink()
    var raised = False
    try:
        _ = copy_n(dst, src, 10)
    except e:
        raised = True
        assert_true(not matches(e, EOF))
        assert_equal(partial(e), 5)
    assert_true(raised)


def test_copy_buffer_uses_the_buffer_it_was_given() raises:
    var src = Fixed(bytes(100))
    var dst = Sink()
    var buf = buffer(8)
    assert_equal(copy_buffer(dst, src, Span(buf)), 100)
    assert_equal(len(dst.got), 100)
    # Thirteen reads of eight bytes rather than one of thirty two kilobytes,
    # which is how the buffer proves it was the one being used.
    assert_true(src.biggest <= 8)
    assert_true(src.reads >= 13)


def test_copy_buffer_moves_the_bytes_in_order() raises:
    var src = Fixed(bytes(100))
    var dst = Sink()
    var buf = buffer(7)
    _ = copy_buffer(dst, src, Span(buf))
    for i in range(100):
        assert_equal(dst.got[i], Byte(i))


def test_copy_buffer_refuses_an_empty_buffer() raises:
    var src = Fixed(bytes(100))
    var dst = Sink()
    var buf = List[Byte]()
    var raised = False
    try:
        _ = copy_buffer(dst, src, Span(buf))
    except e:
        raised = True
    assert_true(raised)
    assert_equal(src.reads, 0)


def test_copy_buffer_still_takes_the_writers_fast_path() raises:
    # And therefore never touches the buffer, which surprises people and is
    # Go's behaviour too.
    var src = Fixed(bytes(100))
    var dst = Eager()
    var buf = buffer(8)
    assert_equal(copy_buffer(dst, src, Span(buf)), 100)
    assert_equal(dst.drains, 1)
    assert_equal(dst.writes, 0)
    assert_true(src.biggest > 8)


def test_copy_buffer_does_not_take_a_fast_path_that_is_not_offered() raises:
    var src = Fixed(bytes(100))
    var dst = Eager(bits=0)
    var buf = buffer(8)
    assert_equal(copy_buffer(dst, src, Span(buf)), 100)
    assert_equal(dst.drains, 0)
    assert_true(src.biggest <= 8)


def test_copy_buffer_refuses_a_reader_that_makes_no_progress() raises:
    var src = Stuck()
    var dst = Sink()
    var buf = buffer(8)
    var raised = False
    try:
        _ = copy_buffer(dst, src, Span(buf))
    except e:
        raised = True
        assert_true(matches(e, ErrNoProgress))
    assert_true(raised)


def test_copy_n_refuses_a_reader_that_makes_no_progress() raises:
    var src = Stuck()
    var dst = Sink()
    var raised = False
    try:
        _ = copy_n(dst, src, 8)
    except e:
        raised = True
        assert_true(matches(e, ErrNoProgress))
    assert_true(raised)


def test_copy_buffer_works_across_erasure() raises:
    var src = AnyReader(Fixed(bytes(100)))
    var dst = AnyWriter(Sink())
    var buf = buffer(8)
    assert_equal(copy_buffer(dst, src, Span(buf)), 100)
    assert_equal(len(dst.get[Sink]().got), 100)
