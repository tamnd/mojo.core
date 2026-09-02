"""The buffered writer. Go's `bufio.Writer`.

The same three decisions as `read.mojo`: it owns and is generic over what it
wraps, nothing here hands out a view into the buffer, and a failure is captured
rather than held as a bare `Error` so that its code survives the next raise.

One decision is this file's own. **A writer that has failed stays failed.** Go
keeps the error in `b.err` and every method returns it without touching the
sink again, and only `Reset` clears it. That is right and it is worth saying why
rather than copying it: a buffered writer that kept accepting bytes after its
sink broke would look like it was working, and the bytes would be discarded at
the flush that never succeeds. So the failure is sticky, and `errors.ErrorValue`
is borrowed rather than consumed when it is re-raised, which is exactly the case
its documentation calls out.

The thing to remember about any buffered writer, Go's included: **bytes are not
written until `flush`**. A program that writes and exits without flushing writes
nothing, and no destructor here will save it, because a destructor cannot raise
and a silently swallowed write failure is worse than a missing one.
"""

from core.errors import Report, capture, matches, partial
from core.errors.codes import (
    EOF,
    ErrBadReadCount,
    ErrNoProgress,
    ErrShortWrite,
)
from core.errors.value import ErrorValue
from core.io import (
    Byte,
    READER_FROM,
    Reader as IoReader,
    ReaderFrom,
    StringWriter,
    Writer as IoWriter,
)

from ._rune import RUNE_SELF, UTF_MAX, _encode_rune
from .read import _DEFAULT_BUFFER, _MIN_BUFFER


struct Writer[W: IoWriter & Deinitable & Movable](
    IoWriter, Movable, ReaderFrom, StringWriter
):
    """A writer with a buffer in front of it. Go's `bufio.Writer`.

    ```mojo
    from core.bufio import new_writer
    from core.io import AnyWriter


    def greet(var dst: AnyWriter) raises:
        var w = new_writer(dst^)
        _ = w.write_string("hello\\n")
        w.flush()
    ```

    Not `Copyable`, for the reason `Reader` is not: two copies over one sink
    would each hold bytes the other did not, and flushing them would interleave.
    """

    var buf: List[Byte]
    """The bytes waiting to go out. `n` says how many of them are real."""

    var w: Self.W
    """Where they go. Owned, so the call through is direct."""

    var n: Int
    """How much of `buf` is filled. Go's `b.n`."""

    var pending: Optional[ErrorValue]
    """The failure this writer is stuck on, if it has one. Cleared by `reset`."""

    def __init__(out self, var w: Self.W, size: Int):
        """Wrap `w` with a buffer of `size` bytes, or `_MIN_BUFFER` if smaller.

        Go only replaces a size of zero or less. The floor here is the same one
        `Reader` has and it exists for `write_rune`: Go carries a branch for a
        buffer too small to hold one rune, and sixteen bytes makes that branch
        unreachable and lets it go. It is on `deviations.md`.
        """
        var want = size
        if want < _MIN_BUFFER:
            want = _MIN_BUFFER
        self.buf = List[Byte](length=want, fill=0)
        self.w = w^
        self.n = 0
        self.pending = Optional[ErrorValue]()

    def size(self) -> Int:
        """How big the buffer is. Go's `Size`."""
        return len(self.buf)

    def buffered(self) -> Int:
        """How many bytes are waiting to be flushed. Go's `Buffered`."""
        return self.n

    def available(self) -> Int:
        """How many more will fit before a flush is needed. Go's `Available`."""
        return len(self.buf) - self.n

    def reset(mut self, var w: Self.W):
        """Throw the buffered bytes away and start again on `w`. Go's `Reset`.

        Away, not out: anything not flushed is lost, which is Go's behaviour and
        is the only one that makes sense for a writer whose sink has gone. This
        is also the only thing that clears a sticky failure.

        Go takes any `io.Writer`; this takes another `W`, for the reason in
        `Reader.reset`.
        """
        self.w = w^
        self.n = 0
        self.pending = Optional[ErrorValue]()

    def _check(self) raises:
        """Raise the sticky failure, if there is one, without clearing it."""
        if self.pending:
            raise self.pending.value().error()

    def _hold(mut self, e: Error):
        """Make this writer stuck, from here until `reset`."""
        self.pending = Optional[ErrorValue](capture(e))

    def flush(mut self) raises:
        """Send the buffered bytes to the sink. Go's `Flush`.

        Nothing is written before this is called. A sink that takes only part of
        what it was given leaves the rest at the front of the buffer, which
        matters only in that the bytes are still there to look at; the writer is
        stuck either way and the next call says so.
        """
        self._check()
        if self.n == 0:
            return

        var wrote: Int
        try:
            wrote = self.w.write(Span(self.buf)[0 : self.n])
        except e:
            var took = partial(e)
            if took < 0:
                took = 0
            if took > self.n:
                took = self.n
            self._keep(took)
            self._hold(e)
            raise Report("bufio.flush: writing").wrapping(e).with_count(
                took
            ).error()

        if wrote < 0 or wrote > self.n:
            self._hold(
                Report("bufio.flush: the sink claimed more than it was given")
                .with_code(ErrBadReadCount)
                .error()
            )
            self._check()
        if wrote < self.n:
            self._keep(wrote)
            self._hold(
                Report("bufio.flush: the sink took only part of the buffer")
                .with_code(ErrShortWrite)
                .with_count(wrote)
                .error()
            )
            self._check()
        self.n = 0

    def _keep(mut self, written: Int):
        """Drop the first `written` bytes and slide the rest to the front."""
        for i in range(written, self.n):
            self.buf[i - written] = self.buf[i]
        self.n -= written

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        """Buffer `data`, flushing as needed. Go's `Write`.

        Returns `len(data)` or raises with the number of bytes that were
        accepted on `errors.partial`. Accepted means taken from `data`, which
        includes bytes that are sitting in the buffer and have not reached the
        sink yet; a caller that needs to know they arrived has to `flush`.

        A write longer than the buffer with nothing buffered goes straight to
        the sink, because copying it through a buffer it does not fit in would
        be a copy for nothing. Go does the same and it is observable: the sink
        sees the caller's length rather than the buffer's.
        """
        self._check()
        var off = 0
        while len(data) - off > self.available():
            if self.n == 0:
                var wrote: Int
                try:
                    wrote = self.w.write(data[off:])
                except e:
                    self._hold(e)
                    raise Report("bufio.write: writing").wrapping(e).with_count(
                        off + partial(e)
                    ).error()
                if wrote <= 0 or wrote > len(data) - off:
                    self._hold(
                        Report(
                            "bufio.write: the sink accepted nothing and said"
                            " nothing"
                        )
                        .with_code(ErrNoProgress)
                        .with_count(off)
                        .error()
                    )
                    self._check()
                off += wrote
            else:
                var room = self.available()
                for i in range(room):
                    self.buf[self.n + i] = data[off + i]
                self.n += room
                off += room
                try:
                    self.flush()
                except e:
                    raise Report("bufio.write: flushing").wrapping(
                        e
                    ).with_count(off).error()

        for i in range(len(data) - off):
            self.buf[self.n + i] = data[off + i]
        self.n += len(data) - off
        return len(data)

    def write_byte(mut self, c: Byte) raises:
        """One byte. Go's `WriteByte`."""
        self._check()
        if self.available() <= 0:
            self.flush()
        self.buf[self.n] = c
        self.n += 1

    def write_string(mut self, s: String) raises -> Int:
        """The bytes of `s`. Go's `WriteString`, and `io.StringWriter`.

        `String.as_bytes` borrows rather than copies, so this is `write` with no
        conversion in front of it, which is the same reason `io.write_string`
        does not bother with Go's type assertion.
        """
        return self.write(s.as_bytes())

    def write_rune(mut self, r: Int32) raises -> Int:
        """One rune, UTF-8 encoded, and how many bytes it took. Go's `WriteRune`.

        Anything that is not a code point is written as U+FFFD, which is Go's
        behaviour and the reason this cannot fail on the value it was given.

        Go carries a branch here for a buffer too small to hold one rune. The
        minimum buffer makes that unreachable, so it is not written.
        """
        if r >= 0 and Int(r) < RUNE_SELF:
            self.write_byte(Byte(r))
            return 1
        self._check()
        if self.available() < UTF_MAX:
            self.flush()
        var size = _encode_rune(Span(self.buf)[self.n :], r)
        self.n += size
        return size

    def capabilities(self) -> Int:
        """`read_from` is implemented, so `io.copy` can take it."""
        return READER_FROM

    def read_from[R: IoReader](mut self, mut src: R) raises -> Int64:
        """Drain `src` into this writer. Go's `ReadFrom`.

        Reads straight into the free space in the buffer, so a copy through this
        writer never goes through a second buffer of the caller's. When there is
        nothing buffered and the sink has its own `read_from`, that is used
        instead and this writer stays out of the way entirely, which is Go's
        behaviour and the reason two buffered writers in a row cost one buffer's
        worth of copying rather than two.

        Ends at `src`'s end of input without raising `EOF`. Does not flush, for
        the same reason nothing else here does.
        """
        self._check()
        if self.n == 0 and self.w.capabilities() & READER_FROM != 0:
            return self.w.read_from(src)

        var moved = Int64(0)
        while True:
            if self.available() == 0:
                try:
                    self.flush()
                except e:
                    raise Report("bufio.read_from: flushing").wrapping(
                        e
                    ).with_count(Int(moved)).error()
            var got: Int
            try:
                got = src.read(Span(self.buf)[self.n :])
            except e:
                if matches(e, EOF):
                    return moved
                raise Report("bufio.read_from: reading").wrapping(e).with_count(
                    Int(moved) + partial(e)
                ).error()
            if got <= 0 or got > self.available():
                raise (
                    Report(
                        "bufio.read_from: the source read nothing, or outside"
                        " the span it was given"
                    )
                    .with_code(ErrNoProgress)
                    .with_count(Int(moved))
                    .error()
                )
            self.n += got
            moved += Int64(got)


def new_writer_size[
    W: IoWriter & Deinitable & Movable
](var w: W, size: Int) -> Writer[W]:
    """A buffered writer over `w` with a buffer of `size`. Go's `NewWriterSize`.

    Go hands back `w` itself when it is already a big enough `*bufio.Writer`.
    There is no assertion to do that with here, so wrapping a `Writer` in a
    `Writer` gives two buffers and two copies. It works; `deviations.md` says
    not to.
    """
    return Writer[W](w^, size)


def new_writer[W: IoWriter & Deinitable & Movable](var w: W) -> Writer[W]:
    """A buffered writer over `w` with the default buffer. Go's `NewWriter`."""
    return Writer[W](w^, _DEFAULT_BUFFER)
