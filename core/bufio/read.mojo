"""The buffered reader. Go's `bufio.Reader`.

Three decisions shape this file and none of them are Go's.

**It owns what it wraps, and it is generic over it.** `Reader[R]` holds an `R`
by value, so every call through to the source is direct and inlinable, which is
the whole reason to be generic rather than to hold an `AnyReader`. `limit.mojo`
in `core.io` made the same choice for the same reason. The cost lands on
`reset`, which can only be handed another `R`; a caller that needs to swap one
kind of source for another wraps an `AnyReader` and resets that.

**Nothing here returns a view into the buffer.** Go's `Peek`, `ReadSlice` and
`ReadLine` all return a slice of the reader's own memory and document that the
next read invalidates it. That would be a use after free here with nothing to
catch it: a `Span` stays usable across a mutation of what it points at, and the
compiler says nothing, which `probes/span_outlives_its_owner.mojo` pins and
design.md's "Where this is better than Go" used to claim the opposite of. So
these return owned bytes. The copy is the price of the guarantee and it is on
`deviations.md` as a cost rather than a win.

**A failure that arrives with bytes still buffered is delivered after them.**
That is the `io.Reader` contract, and this is the type it was written for. The
failure is held in an `errors.ErrorValue` rather than an `Error`, because an
`Error` is a string and its record lives in a thread local slot that the next
raise overwrites; capturing takes the code and the fields out of the thread so
they are still there one read later.

`IoReader` and `IoWriter` are `core.io`'s traits under different names, because
this package has a `Reader` and a `Writer` of its own and Go can write
`io.Reader` where Mojo cannot.
"""

from core.errors import Report, capture, matches, partial
from core.errors.codes import (
    EOF,
    ErrBadReadCount,
    ErrBufferFull,
    ErrInvalidUnreadByte,
    ErrInvalidUnreadRune,
    ErrNegativeCount,
    ErrNoProgress,
    ErrShortWrite,
)
from core.errors.value import ErrorValue
from core.io import (
    Byte,
    ByteScanner,
    WRITER_TO,
    Reader as IoReader,
    RuneScanner,
    Writer as IoWriter,
    WriterTo,
)

from core.unicode.utf8 import RUNE_SELF, UTF_MAX, decode_rune, full_rune

comptime _DEFAULT_BUFFER = 4096
"""The buffer `new_reader` asks for. Go's `defaultBufSize`, same number."""

comptime _MIN_BUFFER = 16
"""The smallest buffer that is allowed. Go's `minReadBufferSize`, same number.

A buffer has to be able to hold the longest thing `read_rune` might need to
look at, and a one byte buffer would turn `peek` into something that can never
succeed. Sixteen is Go's floor and there is no reason to differ.
"""


struct Reader[R: IoReader & Deinitable & Movable](
    ByteScanner, IoReader, Movable, RuneScanner, WriterTo
):
    """A reader with a buffer in front of it. Go's `bufio.Reader`.

    ```mojo
    from core.bufio import new_reader
    from core.io import AnyReader


    def first_line(var src: AnyReader) raises -> String:
        var r = new_reader(src^)
        return r.read_string(10)
    ```

    Not `Copyable`. Two copies of a buffered reader over one source would each
    believe they held the bytes the other consumed, and the mistake would show
    up as missing input rather than as anything that looks like a copy.
    """

    var buf: List[Byte]
    """The window. `start` and `stop` index into it and never move backwards."""

    var r: Self.R
    """Where the bytes come from. Owned, see the module docstring."""

    var start: Int
    """Where the unread bytes begin. Go's `b.r`."""

    var stop: Int
    """Where they end. Go's `b.w`."""

    var pending: Optional[ErrorValue]
    """A failure that has arrived but has not been delivered yet.

    Set by `_fill` and taken by whichever call first has nothing left to hand
    back. Cleared when it is delivered, so a reader that raised `EOF` and is
    then read again asks the source once more, which is what Go does and what
    lets a source that recovers be read again.
    """

    var last_byte: Int
    """The byte `read_byte` last handed over, or -1. Only `unread_byte` reads it.
    """

    var last_rune_size: Int
    """The width `read_rune` last consumed, or -1. Only `unread_rune` reads it."""

    def __init__(out self, var r: Self.R, size: Int):
        """Wrap `r` with a buffer of `size` bytes, or `_MIN_BUFFER` if smaller.

        Go's `NewReaderSize` clamps quietly and so does this. A size below the
        floor is almost always a caller who meant bytes and typed something
        else, and refusing it would mean a raising constructor for a mistake
        that has an obviously right answer.
        """
        var want = size
        if want < _MIN_BUFFER:
            want = _MIN_BUFFER
        self.buf = List[Byte](length=want, fill=0)
        self.r = r^
        self.start = 0
        self.stop = 0
        self.pending = Optional[ErrorValue]()
        self.last_byte = -1
        self.last_rune_size = -1

    def size(self) -> Int:
        """How big the buffer is. Go's `Size`."""
        return len(self.buf)

    def buffered(self) -> Int:
        """How many bytes can be read without touching the source. Go's `Buffered`.
        """
        return self.stop - self.start

    def reset(mut self, var r: Self.R):
        """Throw the buffer away and start again on `r`. Go's `Reset`.

        Go takes any `io.Reader`. This takes another `R`, because the type is
        fixed at construction; `deviations.md` has the row and the workaround,
        which is to be generic over `AnyReader` when the source really does
        change shape.
        """
        self.r = r^
        self.start = 0
        self.stop = 0
        self.pending = Optional[ErrorValue]()
        self.last_byte = -1
        self.last_rune_size = -1

    def _hold(mut self, e: Error):
        """Keep a failure until there are no buffered bytes left to hand over.
        """
        self.pending = Optional[ErrorValue](capture(e))

    def _deliver(mut self) raises:
        """Raise the held failure, if there is one, and forget it."""
        if self.pending:
            var held = self.pending.take()
            self.pending = Optional[ErrorValue]()
            raise held.error()

    def _fill(mut self) raises:
        """Slide what is left to the front and read once into the space after it.

        One read, not a loop. A caller that needs more calls again, and a reader
        that hands back nothing without saying why gets `ErrNoProgress` on the
        first offence rather than after Go's hundred: `core.io` made that
        decision and the reason is in that package's codes.
        """
        if self.start > 0:
            for i in range(self.start, self.stop):
                self.buf[i - self.start] = self.buf[i]
            self.stop -= self.start
            self.start = 0
        if self.stop >= len(self.buf):
            raise (
                Report("bufio: fill on a full buffer, which is a bug in bufio")
                .with_code(ErrBufferFull)
                .error()
            )

        var got: Int
        try:
            got = self.r.read(Span(self.buf)[self.stop :])
        except e:
            self._hold(e)
            return
        if got < 0 or got > len(self.buf) - self.stop:
            self._hold(
                Report("bufio: the source read outside the span it was given")
                .with_code(ErrBadReadCount)
                .error()
            )
            return
        self.stop += got
        if got == 0:
            self._hold(
                Report("bufio: the source returned no bytes and no error")
                .with_code(ErrNoProgress)
                .error()
            )

    def peek(mut self, n: Int) raises -> List[Byte]:
        """The next `n` bytes, without consuming them. Go's `Peek`.

        Go returns however many it has along with the reason there were not
        more. This raises instead, and loses nothing by it: peeking consumes
        nothing, so after a failure `buffered()` still says how much is there
        and `peek(r.buffered())` still returns it.

        `ErrNegativeCount` for a negative `n`, `ErrBufferFull` for an `n` larger
        than the buffer, and whatever the source raised for a stream that ended
        first.
        """
        if n < 0:
            raise (
                Report("bufio.peek: negative count")
                .with_code(ErrNegativeCount)
                .error()
            )
        self.last_byte = -1
        self.last_rune_size = -1
        if n > len(self.buf):
            raise (
                Report(
                    "bufio.peek: asked for more than the buffer can ever hold"
                )
                .with_code(ErrBufferFull)
                .with_count(self.buffered())
                .error()
            )

        while self.buffered() < n and self.buffered() < len(self.buf):
            if self.pending:
                break
            self._fill()
        if self.buffered() < n:
            if self.pending:
                self._deliver()
            raise (
                Report("bufio.peek: not enough buffered and no reason given")
                .with_code(ErrBufferFull)
                .with_count(self.buffered())
                .error()
            )

        var out = List[Byte](capacity=n)
        for i in range(n):
            out.append(self.buf[self.start + i])
        return out^

    def discard(mut self, n: Int) raises -> Int:
        """Skip `n` bytes and return how many were skipped. Go's `Discard`.

        Returns `n` or raises. A stream that ends first raises what the source
        raised, wrapped, with the number actually skipped on `errors.partial`,
        so a caller can tell how far it got.
        """
        if n < 0:
            raise (
                Report("bufio.discard: negative count")
                .with_code(ErrNegativeCount)
                .error()
            )
        if n == 0:
            return 0
        self.last_byte = -1
        self.last_rune_size = -1

        var left = n
        while True:
            if self.buffered() == 0:
                self._fill()
            var skip = self.buffered()
            if skip > left:
                skip = left
            self.start += skip
            left -= skip
            if left == 0:
                return n
            if self.pending:
                var held = self.pending.take()
                self.pending = Optional[ErrorValue]()
                raise (
                    Report("bufio.discard: input ended early")
                    .wrapping(held.error())
                    .with_count(n - left)
                    .error()
                )

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """Read into `into`. Go's `Read`.

        At most one read of the source, so this can come back short even when
        the source has more, exactly as Go's does. `io.read_full` is the loop.

        A span at least as long as the buffer and an empty buffer means the
        source is read straight into `into`, because copying through a buffer
        the same size would be a copy for nothing. That is Go's optimisation and
        it is observable: the source sees the caller's length rather than the
        buffer's.
        """
        if len(into) == 0:
            # An empty span reads nothing and raises nothing, `io.Reader`'s
            # rule, so it cannot be used to test for the end.
            return 0

        if self.buffered() == 0:
            self._deliver()
            if len(into) >= len(self.buf):
                var got = self.r.read(into)
                if got < 0 or got > len(into):
                    raise (
                        Report(
                            "bufio.read: the source read outside the span it"
                            " was given"
                        )
                        .with_code(ErrBadReadCount)
                        .error()
                    )
                if got > 0:
                    self.last_byte = Int(into[got - 1])
                    self.last_rune_size = -1
                return got
            self.start = 0
            self.stop = 0
            self._fill()
            if self.buffered() == 0:
                self._deliver()
                return 0

        var n = self.buffered()
        if n > len(into):
            n = len(into)
        for i in range(n):
            into[i] = self.buf[self.start + i]
        self.start += n
        self.last_byte = Int(self.buf[self.start - 1])
        self.last_rune_size = -1
        return n

    def read_byte(mut self) raises -> Byte:
        """One byte. Go's `ReadByte`."""
        self.last_rune_size = -1
        while self.buffered() == 0:
            # `_deliver` raises whatever the last fill found, and `_fill` never
            # comes back having added nothing without leaving something for it
            # to raise, so this ends.
            self._deliver()
            self._fill()
        var b = self.buf[self.start]
        self.start += 1
        self.last_byte = Int(b)
        return b

    def unread_byte(mut self) raises:
        """Put the last byte back. Go's `UnreadByte`.

        Only after a successful `read_byte`, and only once. Anything else is
        `ErrInvalidUnreadByte`, because moving the position back on a guess
        would corrupt the stream for whoever reads it next and the corruption
        would surface a long way from here.
        """
        if self.last_byte < 0 or (self.start == 0 and self.stop > 0):
            raise (
                Report("bufio.unread_byte: nothing was read to put back")
                .with_code(ErrInvalidUnreadByte)
                .error()
            )
        if self.start > 0:
            self.start -= 1
        else:
            self.stop = 1
        self.buf[self.start] = Byte(self.last_byte)
        self.last_byte = -1
        self.last_rune_size = -1

    def read_rune(mut self) raises -> Tuple[Int32, Int]:
        """One rune and its width in bytes. Go's `ReadRune`.

        Invalid input is one byte wide and decodes to `RUNE_ERROR`, which is
        Go's rule and the reason a decode loop always makes progress. A rune
        split across the end of the buffer is completed by reading more, unless
        the buffer is already full of it, which cannot happen for a buffer of at
        least `_MIN_BUFFER` bytes.
        """
        while (
            self.start + UTF_MAX > self.stop
            and not full_rune(Span(self.buf)[self.start : self.stop])
            and not self.pending
            and self.buffered() < len(self.buf)
        ):
            self._fill()
        if self.buffered() == 0:
            self._deliver()
            raise Report("bufio.read_rune: end of input").with_code(EOF).error()

        var r = Int32(self.buf[self.start])
        var size = 1
        if Int(r) >= RUNE_SELF:
            r, size = decode_rune(Span(self.buf)[self.start : self.stop])
        self.start += size
        self.last_byte = Int(self.buf[self.start - 1])
        self.last_rune_size = size
        return (r, size)

    def unread_rune(mut self) raises:
        """Put the last rune back. Go's `UnreadRune`.

        The same rule as `unread_byte` and a separate sentinel, because the
        width to put back is different and a caller that mixed the two up wants
        to be told which one it got wrong.
        """
        if self.last_rune_size < 0 or self.start < self.last_rune_size:
            raise (
                Report("bufio.unread_rune: the last read was not a rune")
                .with_code(ErrInvalidUnreadRune)
                .error()
            )
        self.start -= self.last_rune_size
        self.last_byte = -1
        self.last_rune_size = -1

    def _take(mut self, n: Int) -> List[Byte]:
        """Copy `n` bytes off the front of the buffer and consume them."""
        var out = List[Byte](capacity=n)
        for i in range(n):
            out.append(self.buf[self.start + i])
        self.start += n
        if n > 0:
            self.last_byte = Int(out[n - 1])
            self.last_rune_size = -1
        return out^

    def read_slice(mut self, delim: Byte) raises -> List[Byte]:
        """Everything up to and including the first `delim`. Go's `ReadSlice`.

        Three outcomes, and the caller tells them apart without a second
        channel:

        - returns bytes ending in `delim`: the delimiter was found.
        - returns bytes not ending in `delim`: the input ended first. The end
          itself arrives from the next call, which is `io.Reader`'s rule about
          bytes now and the reason for it.
        - raises `ErrBufferFull`: the buffer filled without one. **The bytes
          stay buffered**, unlike Go, which hands them over with the error.
          `buffered()` says how many and any read takes them; `read_bytes` is
          the version that grows instead and is what most callers want.

        Go returns a view into the buffer here and this returns a copy, so the
        only thing left between this and `read_bytes` is that failure. Both are
        still worth having: the difference is whether an unbounded token is an
        error or an allocation, and on input somebody else controls that is the
        difference that matters.
        """
        var searched = 0
        while True:
            var window = self.buffered()
            var found = -1
            for i in range(searched, window):
                if self.buf[self.start + i] == delim:
                    found = i
                    break
            if found >= 0:
                return self._take(found + 1)

            if self.pending:
                if window == 0:
                    self._deliver()
                # Bytes now, the reason next time. `pending` is left where it
                # is, so the following call raises it.
                return self._take(window)
            if window >= len(self.buf):
                self.last_byte = -1
                self.last_rune_size = -1
                raise (
                    Report(
                        "bufio.read_slice: the buffer filled without a"
                        " delimiter"
                    )
                    .with_code(ErrBufferFull)
                    .with_count(window)
                    .error()
                )
            # Nothing found in what has been searched, so the next pass only
            # has to look at what arrives. Without this the search is quadratic
            # in the length of the token, which is the bug that makes a long
            # line slow rather than wrong.
            searched = window
            self._fill()

    def read_bytes(mut self, delim: Byte) raises -> List[Byte]:
        """Everything up to and including the first `delim`. Go's `ReadBytes`.

        Grows past the buffer rather than raising `ErrBufferFull`, so the only
        limit is memory. On input from somewhere untrusted that is a way to run
        out of it, and `io.limit_reader` is the answer, same as for
        `io.read_all`.

        Go's rule is that the error is non-nil exactly when the returned data
        does not end in `delim`, so a caller has to read both to know what it
        got. Here the data says it: what comes back ends in `delim` or the
        input ended first, and the end itself arrives from the next call. The
        one thing that raises is having nothing at all, which is `EOF`, and
        anything that is not an ending.
        """
        var out = List[Byte]()
        while True:
            var chunk: List[Byte]
            try:
                chunk = self.read_slice(delim)
            except e:
                if not matches(e, ErrBufferFull):
                    if len(out) == 0:
                        raise e
                    raise (
                        Report("bufio.read_bytes: reading")
                        .wrapping(e)
                        .with_count(len(out))
                        .error()
                    )
                # A full buffer with no delimiter in it. Take it and keep going
                # in a list that can grow, which is the whole difference.
                var window = self.buffered()
                for i in range(window):
                    out.append(self.buf[self.start + i])
                self.start += window
                self.last_byte = -1
                self.last_rune_size = -1
                continue
            # Either the delimiter was found or the input ended, and in both
            # cases the fragment is the last of it.
            for b in chunk:
                out.append(b)
            return out^

    def read_string(mut self, delim: Byte) raises -> String:
        """`read_bytes` as text. Go's `ReadString`.

        Raises if what was read is not valid UTF-8, and this is the one place
        this package is deliberately stricter than Go rather than merely
        different. A Go string is a byte sequence that is usually text, so
        `ReadString` can hand back anything; a Mojo `String` says it is UTF-8,
        and there is no honest way to make one out of arbitrary bytes. The
        alternatives were to substitute U+FFFD for what did not decode, which
        loses bytes silently, or to assert the encoding without checking, which
        is the `unsafe_` constructor and would make this package unsafe on
        behalf of a caller who never asked.

        The bytes are consumed either way: a token that fails to decode is gone
        from the reader, because the delimiter search that found it is what
        moved the position. `read_bytes` is the version for input that is not
        text, and is what to reach for on a protocol that carries both.
        """
        var raw = self.read_bytes(delim)
        return String(from_utf8=Span(raw))

    def read_line(mut self) raises -> Tuple[List[Byte], Bool]:
        """One line, with the ending stripped, and whether it was cut short.

        Go's `ReadLine`. The second half of the pair is Go's `isPrefix`: true
        means the line was longer than the buffer and this is the front of it,
        so the rest arrives on the next calls. Both `\\n` and `\\r\\n` are
        endings and neither is returned.

        Go's own documentation calls this low level and points most callers at
        `read_bytes` or a `Scanner`, and that advice holds here. It exists
        because a caller that must not allocate for a hostile line has nowhere
        else to go.
        """
        var line: List[Byte]
        try:
            line = self.read_slice(10)
        except e:
            if not matches(e, ErrBufferFull):
                raise e
            # A line longer than the buffer. If what came back ends in a
            # carriage return that return might be the first half of an ending,
            # so it goes back rather than out.
            var window = self.buffered()
            var out = self._take(window)
            if len(out) > 0 and out[len(out) - 1] == 13:
                _ = out.pop()
                self.start -= 1
                self.last_byte = -1
            return (out^, True)

        if len(line) > 0 and line[len(line) - 1] == 10:
            _ = line.pop()
            if len(line) > 0 and line[len(line) - 1] == 13:
                _ = line.pop()
        return (line^, False)

    def capabilities(self) -> Int:
        """`write_to` is implemented, so `io.copy` can take it."""
        return WRITER_TO

    def write_to[W: IoWriter](mut self, mut dst: W) raises -> Int64:
        """Push everything left into `dst`. Go's `WriteTo`.

        The buffered bytes go first and then the source is drained straight
        into `dst`, so a copy out of a buffered reader never pays for the
        buffer twice. Ends at the source's end of input without raising `EOF`,
        which is `io.Writer.read_from`'s rule in reverse.
        """
        var moved = Int64(0)
        if self.buffered() > 0:
            var wrote = dst.write(Span(self.buf)[self.start : self.stop])
            if wrote < self.buffered():
                raise (
                    Report(
                        "bufio.write_to: the sink took only part of the buffer"
                    )
                    .with_code(ErrShortWrite)
                    .with_count(wrote)
                    .error()
                )
            self.start += wrote
            moved += Int64(wrote)

        while True:
            self.start = 0
            self.stop = 0
            self._fill()
            if self.buffered() == 0:
                if self.pending:
                    var held = self.pending.take()
                    self.pending = Optional[ErrorValue]()
                    var e = held.error()
                    if matches(e, EOF):
                        return moved
                    raise Report("bufio.write_to: reading").wrapping(
                        e
                    ).with_count(Int(moved) + partial(e)).error()
                return moved
            var wrote = dst.write(Span(self.buf)[self.start : self.stop])
            if wrote < self.buffered():
                raise (
                    Report(
                        "bufio.write_to: the sink took only part of the buffer"
                    )
                    .with_code(ErrShortWrite)
                    .with_count(Int(moved) + wrote)
                    .error()
                )
            self.start += wrote
            moved += Int64(wrote)


def new_reader_size[
    R: IoReader & Deinitable & Movable
](var r: R, size: Int) -> Reader[R]:
    """A buffered reader over `r` with a buffer of `size`. Go's `NewReaderSize`.

    Go returns `r` itself when it is already a `*bufio.Reader` big enough, which
    saves a layer. There is no assertion to make that decision with here, so
    wrapping a `Reader` in a `Reader` gives two buffers. It works and it is
    wasteful; `deviations.md` says so.
    """
    return Reader[R](r^, size)


def new_reader[R: IoReader & Deinitable & Movable](var r: R) -> Reader[R]:
    """A buffered reader over `r` with the default buffer. Go's `NewReader`."""
    return Reader[R](r^, _DEFAULT_BUFFER)
