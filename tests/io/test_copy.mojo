"""Readers, writers, and which path `copy` actually took.

The claim this file is here to check is that `copy` works across every
combination of static and erased on both sides, and that the capability bit is
what selects the fast path. The second half is the one that needs care, because
"the fast path ran" is not observable from the outside: the bytes come out the
same either way. So the writers count their own calls, `write` and `read_from`
separately, and the test reads the counters afterwards.

For an erased writer the counter is inside the box, which is what `AnyWriter.get`
is for. That works because the box is refcounted and the test still holds a
reference, so reading it after the copy is reading the same value the copy wrote
through, not a snapshot of one.

The mutation that makes the counters mean something is `Eager(bits=0)`: same
type, same `read_from`, bit cleared. If the slow path does not run then the bit
is not what is being read.
"""

from std.testing import assert_equal, assert_true

from core.errors import matches, partial, Report
from core.io import (
    AnyReader,
    AnyWriter,
    copy,
    EOF,
    ErrNoProgress,
    READER_FROM,
    Reader,
    ReaderView,
    WRITER_TO,
    Writer,
    WriterView,
)

comptime Byte = UInt8


def bytes(n: Int) -> List[Byte]:
    """`n` bytes with distinguishable values, so a mixed up copy shows."""
    var out = List[Byte](capacity=n)
    for i in range(n):
        out.append(Byte(i % 251))
    return out^


struct Fixed(Copyable, Movable, Reader):
    """A reader over a list. No optional methods, so it inherits both stubs."""

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


struct Sink(Copyable, Movable, Writer):
    """A writer that keeps what it is given and counts how often."""

    var got: List[Byte]
    var writes: Int

    def __init__(out self):
        self.got = List[Byte]()
        self.writes = 0

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        self.writes += 1
        for i in range(len(data)):
            self.got.append(data[i])
        return len(data)


struct Eager(Copyable, Movable, Writer):
    """A `Sink` that also implements `read_from`, with a switchable bit.

    `bits` is a constructor argument so that a test can offer the method and
    withhold the advertisement. That is the whole proof that `copy` reads the
    bit rather than noticing the method exists.
    """

    var got: List[Byte]
    var writes: Int
    var read_froms: Int
    var bits: Int

    def __init__(out self, bits: Int = READER_FROM):
        self.got = List[Byte]()
        self.writes = 0
        self.read_froms = 0
        self.bits = bits

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        self.writes += 1
        for i in range(len(data)):
            self.got.append(data[i])
        return len(data)

    def capabilities(self) -> Int:
        return self.bits

    def read_from[R: Reader](mut self, mut src: R) raises -> Int64:
        self.read_froms += 1
        var buf = List[Byte](capacity=8)
        for _ in range(8):
            buf.append(0)
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


struct Pushy(Copyable, Movable, Reader):
    """A reader that implements `write_to`, with a switchable bit."""

    var data: List[Byte]
    var pos: Int
    var write_tos: Int
    var bits: Int

    def __init__(out self, var data: List[Byte], bits: Int = WRITER_TO):
        self.data = data^
        self.pos = 0
        self.write_tos = 0
        self.bits = bits

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        var n = 0
        while n < len(into) and self.pos < len(self.data):
            into[n] = self.data[self.pos]
            n += 1
            self.pos += 1
        if n == 0 and len(into) > 0:
            raise Report("pushy: end").with_code(EOF).error()
        return n

    def capabilities(self) -> Int:
        return self.bits

    def write_to[W: Writer](mut self, mut dst: W) raises -> Int64:
        self.write_tos += 1
        var moved = Int64(0)
        while self.pos < len(self.data):
            var n = dst.write(Span(self.data)[self.pos :])
            self.pos += n
            moved += Int64(n)
        return moved


struct Liar(Copyable, Movable, Writer):
    """Advertises `read_from` and never implemented it.

    The trait's default body is what answers, so the failure is a raise at the
    first call rather than a wrong byte count.
    """

    var writes: Int

    def __init__(out self):
        self.writes = 0

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        self.writes += 1
        return len(data)

    def capabilities(self) -> Int:
        return READER_FROM


struct Stuck(Copyable, Movable, Reader):
    """Returns zero from a buffer with room in it, and never raises."""

    def __init__(out self):
        pass

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        return 0


struct Broken(Copyable, Movable, Reader):
    """Fails after handing over some bytes, the way a socket does."""

    var left: Int

    def __init__(out self, left: Int):
        self.left = left

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        if self.left == 0:
            raise Report("broken: the wire went away").with_count(7).error()
        var n = min(self.left, len(into))
        for i in range(n):
            into[i] = 42
        self.left -= n
        return n


# The four combinations the issue asks for. Two static, two erased, one `copy`.


def test_copy_static_reader_into_static_writer() raises:
    var src = Fixed(bytes(100))
    var dst = Sink()
    assert_equal(copy(dst, src), 100)
    assert_equal(len(dst.got), 100)
    assert_equal(dst.got[99], Byte(99))


def test_copy_static_reader_into_erased_writer() raises:
    var src = Fixed(bytes(100))
    var dst = AnyWriter(Sink())
    assert_equal(copy(dst, src), 100)
    assert_equal(len(dst.get[Sink]().got), 100)


def test_copy_erased_reader_into_static_writer() raises:
    var src = AnyReader(Fixed(bytes(100)))
    var dst = Sink()
    assert_equal(copy(dst, src), 100)
    assert_equal(len(dst.got), 100)
    assert_equal(dst.got[99], Byte(99))


def test_copy_erased_reader_into_erased_writer() raises:
    var src = AnyReader(Fixed(bytes(100)))
    var dst = AnyWriter(Sink())
    assert_equal(copy(dst, src), 100)
    assert_equal(len(dst.get[Sink]().got), 100)


def test_a_copy_larger_than_the_buffer_still_arrives_in_order() raises:
    """More than one trip round the slow path, and through the tables."""
    var src = AnyReader(Fixed(bytes(70000)))
    var dst = AnyWriter(Sink())
    assert_equal(copy(dst, src), 70000)
    ref got = dst.get[Sink]().got
    assert_equal(len(got), 70000)
    assert_equal(got[0], Byte(0))
    assert_equal(got[69999], Byte(69999 % 251))


# Which path ran, by counter.


def test_the_writer_fast_path_runs_when_its_bit_is_set() raises:
    var src = Fixed(bytes(100))
    var dst = Eager()
    assert_equal(copy(dst, src), 100)
    assert_equal(dst.read_froms, 1)
    assert_equal(dst.writes, 0)


def test_the_writer_fast_path_does_not_run_when_its_bit_is_clear() raises:
    """Same type and the same `read_from`, advertised as absent."""
    var src = Fixed(bytes(100))
    var dst = Eager(bits=0)
    assert_equal(copy(dst, src), 100)
    assert_equal(dst.read_froms, 0)
    assert_equal(dst.writes, 1)
    assert_equal(len(dst.got), 100)


def test_the_reader_fast_path_runs_when_its_bit_is_set() raises:
    var src = Pushy(bytes(100))
    var dst = Sink()
    assert_equal(copy(dst, src), 100)
    assert_equal(src.write_tos, 1)


def test_the_reader_fast_path_does_not_run_when_its_bit_is_clear() raises:
    var src = Pushy(bytes(100), bits=0)
    var dst = Sink()
    assert_equal(copy(dst, src), 100)
    assert_equal(src.write_tos, 0)
    assert_equal(dst.writes, 1)


def test_the_reader_fast_path_wins_when_both_are_offered() raises:
    """Go's order. The reader knows where its bytes already are."""
    var src = Pushy(bytes(100))
    var dst = Eager()
    assert_equal(copy(dst, src), 100)
    assert_equal(src.write_tos, 1)
    assert_equal(dst.read_froms, 0)


def test_the_bits_survive_erasure() raises:
    """An erased writer answers from what it copied off its target."""
    var src = Fixed(bytes(100))
    var dst = AnyWriter(Eager())
    assert_equal(dst.capabilities(), READER_FROM)
    assert_equal(copy(dst, src), 100)
    assert_equal(dst.get[Eager]().read_froms, 1)
    assert_equal(dst.get[Eager]().writes, 0)


def test_a_cleared_bit_survives_erasure_too() raises:
    var src = Fixed(bytes(100))
    var dst = AnyWriter(Eager(bits=0))
    assert_equal(dst.capabilities(), 0)
    assert_equal(copy(dst, src), 100)
    assert_equal(dst.get[Eager]().read_froms, 0)
    assert_equal(dst.get[Eager]().writes, 1)


def test_the_fast_path_runs_through_two_tables() raises:
    """Erased on both sides, so `read_from` gets a `ReaderView` of an
    `AnyReader` and every call in the copy is indirect."""
    var src = AnyReader(Fixed(bytes(100)))
    var dst = AnyWriter(Eager())
    assert_equal(copy(dst, src), 100)
    assert_equal(dst.get[Eager]().read_froms, 1)
    assert_equal(len(dst.get[Eager]().got), 100)


# Failures.


def test_a_writer_that_advertises_a_method_it_lacks_raises() raises:
    var src = Fixed(bytes(10))
    var dst = Liar()
    var raised = False
    try:
        _ = copy(dst, src)
    except e:
        raised = True
        assert_true("read_from" in String(e))
    assert_true(raised, "the inherited stub should have raised")
    assert_equal(dst.writes, 0)


def test_a_reader_that_makes_no_progress_raises_rather_than_looping() raises:
    var src = Stuck()
    var dst = Sink()
    var raised = False
    try:
        _ = copy(dst, src)
    except e:
        raised = True
        assert_true(matches(e, ErrNoProgress))
    assert_true(raised, "a reader stuck at zero should not spin")


def test_a_failing_read_carries_how_far_the_copy_got() raises:
    var src = Broken(left=300)
    var dst = Sink()
    var raised = False
    try:
        _ = copy(dst, src)
    except e:
        raised = True
        # 300 that arrived, plus the 7 the reader itself reported.
        assert_equal(partial(e), 307)
        assert_true("io.copy: reading" in String(e))
    assert_true(raised, "the reader's failure should come out of copy")
    assert_equal(len(dst.got), 300)


def test_end_of_input_is_not_an_error() raises:
    """`EOF` stops the loop and is not reraised, which is the whole point of
    it being a code rather than a failure."""
    var src = Fixed(List[Byte]())
    var dst = Sink()
    assert_equal(copy(dst, src), 0)
    assert_equal(dst.writes, 0)


# The erased values themselves.


def test_an_erased_reader_is_shared_rather_than_copied() raises:
    var src = AnyReader(Fixed(bytes(10)))
    assert_equal(src.count(), 1)
    var other = AnyReader(copy=src)
    assert_equal(src.count(), 2)
    # Both refer to one reader, so a read through one moves the other's
    # position. That is Go's interface value and not a value copy.
    var dst = Sink()
    assert_equal(copy(dst, other), 10)
    var again = Sink()
    assert_equal(copy(again, src), 0)


def test_a_view_calls_through_without_owning() raises:
    var target = Fixed(bytes(10))
    var view = ReaderView(target)
    var dst = Sink()
    assert_equal(copy(dst, view), 10)
    # The target moved, because the view was pointing at it and not at a copy.
    assert_equal(target.pos, 10)
    assert_true(target.reads > 0)


def test_a_writer_view_calls_through_without_owning() raises:
    var target = Sink()
    var view = WriterView(target)
    var src = Fixed(bytes(10))
    assert_equal(copy(view, src), 10)
    assert_equal(len(target.got), 10)
