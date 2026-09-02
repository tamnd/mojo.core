"""The reading functions, and mostly the short reads they exist to survive.

Go's own `io` tests lean on `iotest.HalfReader`, a reader that hands back half
of what it was asked for, because the bug these functions prevent only appears
when a read comes back short. `Half` here is that reader. Every test that
matters is run through it as well as through a reader that fills the span, and
a `read_full` that had been written as a single `read` would pass the second
and fail the first.

The other half of the file is the distinction between `EOF` and
`ErrUnexpectedEOF`, which is the only reason those are two sentinels: a
truncated record and a clean end of input have to be told apart by the caller,
and the only place that can be decided is here.
"""

from std.testing import assert_equal, assert_true

from core.errors import Report, matches, partial
from core.io import (
    EOF,
    ErrNoProgress,
    ErrShortBuffer,
    ErrUnexpectedEOF,
    Reader,
    Writer,
    read_all,
    read_at_least,
    read_full,
    write_string,
)

comptime Byte = UInt8


def bytes(n: Int) -> List[Byte]:
    """`n` bytes with distinguishable values, so a mixed up read shows."""
    var out = List[Byte](capacity=n)
    for i in range(n):
        out.append(Byte(i % 251))
    return out^


struct Fixed(Copyable, Movable, Reader):
    """A reader over a list that fills whatever span it is given."""

    var data: List[Byte]
    var pos: Int
    var reads: Int

    def __init__(out self, var data: List[Byte]):
        self.data = data^
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
            raise Report("fixed: end").with_code(EOF).error()
        return n


struct Half(Copyable, Movable, Reader):
    """Go's `iotest.HalfReader`: never fills more than half the span.

    The point of the type is that every function in `read.mojo` has to loop,
    and a version written without the loop passes every test that uses `Fixed`
    and fails every test that uses this.
    """

    var inner: Fixed

    def __init__(out self, var data: List[Byte]):
        self.inner = Fixed(data^)

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        var want = (len(into) + 1) // 2
        return self.inner.read(into[0:want])


struct Broken(Copyable, Movable, Reader):
    """Fails after `ok` reads, with something that is not `EOF`."""

    var ok: Int
    var done: Int

    def __init__(out self, ok: Int):
        self.ok = ok
        self.done = 0

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        if self.done >= self.ok:
            raise Report("broken: the device fell over").with_count(3).error()
        self.done += 1
        for i in range(len(into)):
            into[i] = 7
        return len(into)


struct Stuck(Copyable, Movable, Reader):
    """Returns zero and no error forever, which the contract forbids."""

    def __init__(out self):
        pass

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        return 0


struct Sink(Copyable, Movable, Writer):
    """Keeps what it is given."""

    var got: List[Byte]

    def __init__(out self):
        self.got = List[Byte]()

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        for b in data:
            self.got.append(b)
        return len(data)


def test_read_full_fills_the_span() raises:
    var src = Fixed(bytes(10))
    var buf = bytes(10)
    assert_equal(read_full(src, Span(buf)), 10)
    for i in range(10):
        assert_equal(buf[i], Byte(i))


def test_read_full_loops_over_a_short_reader() raises:
    var src = Half(bytes(10))
    var buf = List[Byte](capacity=10)
    for _ in range(10):
        buf.append(0)
    assert_equal(read_full(src, Span(buf)), 10)
    for i in range(10):
        assert_equal(buf[i], Byte(i))
    # Four calls to get ten bytes out of a reader that halves: 5, 3, 1, 1.
    assert_true(src.inner.reads > 1)


def test_read_full_on_an_empty_span_reads_nothing() raises:
    var src = Fixed(List[Byte]())
    var buf = List[Byte]()
    assert_equal(read_full(src, Span(buf)), 0)
    assert_equal(src.reads, 0)


def test_read_full_of_an_empty_stream_is_eof() raises:
    var src = Fixed(List[Byte]())
    var buf = bytes(4)
    var raised = False
    try:
        _ = read_full(src, Span(buf))
    except e:
        raised = True
        assert_true(matches(e, EOF))
        assert_true(not matches(e, ErrUnexpectedEOF))
    assert_true(raised)


def test_read_full_of_a_truncated_stream_is_unexpected_eof() raises:
    var src = Fixed(bytes(3))
    var buf = bytes(8)
    var raised = False
    try:
        _ = read_full(src, Span(buf))
    except e:
        raised = True
        assert_true(matches(e, ErrUnexpectedEOF))
        assert_true(not matches(e, EOF))
        # How much did arrive, which is what tells a caller where it stopped.
        assert_equal(partial(e), 3)
    assert_true(raised)


def test_read_at_least_stops_once_the_minimum_is_reached() raises:
    var src = Fixed(bytes(10))
    var buf = bytes(10)
    # One read fills the whole span, so it comes back with more than asked.
    assert_equal(read_at_least(src, Span(buf), 4), 10)


def test_read_at_least_over_a_short_reader_reaches_the_minimum() raises:
    var src = Half(bytes(10))
    var buf = List[Byte](capacity=10)
    for _ in range(10):
        buf.append(0)
    var n = read_at_least(src, Span(buf), 8)
    assert_true(n >= 8)


def test_read_at_least_rejects_a_buffer_that_could_never_hold_it() raises:
    var src = Fixed(bytes(100))
    var buf = bytes(4)
    var raised = False
    try:
        _ = read_at_least(src, Span(buf), 5)
    except e:
        raised = True
        assert_true(matches(e, ErrShortBuffer))
    assert_true(raised)
    # Nothing was read. The mistake is the caller's and is caught before the
    # reader is touched, which is what makes it a safe thing to retry.
    assert_equal(src.reads, 0)


def test_read_at_least_passes_a_failure_that_is_not_the_end_through() raises:
    var src = Broken(ok=0)
    var buf = bytes(8)
    var raised = False
    try:
        _ = read_at_least(src, Span(buf), 8)
    except e:
        raised = True
        assert_true(not matches(e, EOF))
        assert_true(not matches(e, ErrUnexpectedEOF))
        assert_equal(partial(e), 3)
    assert_true(raised)


def test_read_at_least_refuses_a_reader_that_makes_no_progress() raises:
    var src = Stuck()
    var buf = bytes(8)
    var raised = False
    try:
        _ = read_at_least(src, Span(buf), 8)
    except e:
        raised = True
        assert_true(matches(e, ErrNoProgress))
    assert_true(raised)


def test_read_all_returns_everything() raises:
    var src = Fixed(bytes(1000))
    var got = read_all(src)
    assert_equal(len(got), 1000)
    for i in range(1000):
        assert_equal(got[i], Byte(i % 251))


def test_read_all_over_a_short_reader_returns_everything() raises:
    var src = Half(bytes(1000))
    var got = read_all(src)
    assert_equal(len(got), 1000)
    for i in range(1000):
        assert_equal(got[i], Byte(i % 251))


def test_read_all_of_an_empty_stream_is_empty_and_not_an_error() raises:
    var src = Fixed(List[Byte]())
    assert_equal(len(read_all(src)), 0)


def test_read_all_grows_past_its_first_chunk() raises:
    # 512 is the chunk, so this needs the list to grow at least three times and
    # the offsets to stay right across the growth.
    var src = Fixed(bytes(1500))
    var got = read_all(src)
    assert_equal(len(got), 1500)
    assert_equal(got[512], Byte(512 % 251))
    assert_equal(got[1499], Byte(1499 % 251))


def test_read_all_raises_on_a_failure_that_is_not_the_end() raises:
    var src = Broken(ok=1)
    var raised = False
    try:
        _ = read_all(src)
    except e:
        raised = True
        assert_true(not matches(e, EOF))
    assert_true(raised)


def test_write_string_writes_the_bytes() raises:
    var dst = Sink()
    assert_equal(write_string(dst, "hello"), 5)
    assert_equal(len(dst.got), 5)
    assert_equal(dst.got[0], Byte(104))
    assert_equal(dst.got[4], Byte(111))


def test_write_string_of_an_empty_string_writes_nothing() raises:
    var dst = Sink()
    assert_equal(write_string(dst, ""), 0)
    assert_equal(len(dst.got), 0)


def test_write_string_writes_utf8_rather_than_runes() raises:
    var dst = Sink()
    # Three bytes, one rune. A version that counted characters would say one.
    assert_equal(write_string(dst, "€"), 3)
    assert_equal(len(dst.got), 3)
