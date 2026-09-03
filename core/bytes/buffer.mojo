"""A growable buffer of bytes with a read cursor. Go's `bytes.Buffer`.

One list, one offset. Writes append at the end, reads take from the front and
move the offset, and the space in front of the offset is reclaimed the next
time the buffer grows. That is Go's design and it is the reason a `Buffer` is
the right thing for building a document and the wrong thing for a queue that
never empties.

## Nothing here hands out a view

`bytes()`, `next(n)` and `peek(n)` return an owned `List[Byte]`. Go returns a
slice of the buffer's own array and documents it as valid only until the next
write; a Go program that keeps one too long reads stale bytes out of a live
allocation, which is wrong but is not a crash. Here the same mistake reads
freed memory, because the next write can reallocate and the span would still
point at the old block. `probes/span_outlives_its_owner.mojo` pins that the
compiler does not stop it.

So the copy is not negotiable, and there is no view-returning accessor beside
these under any name. What there is instead is three ways not to need one:
`len()` answers how much is there without touching the bytes, `write_to`
empties the whole buffer into a writer without a copy through the caller, and
`read` fills a span the caller already owns. `string()` builds the `String`
straight from the bytes rather than through a `List[Byte]` first.

`available_buffer` has no version here at all. Go's returns an empty slice over
the buffer's spare capacity for the caller to append into and write back, and
that is a view with a lifetime measured in method calls. `deviations.md` has
the row, next to the same four in `core.bufio`.

## What raises

Go's `Buffer` panics three ways: `Grow` on a negative count, `Truncate` out of
range, and `ErrTooLarge` when it cannot allocate. All three raise here, which
is the library's rule about aborting. `ErrTooLarge` is a sentinel in
`core/errors/codes.toml` so `errors.matches(e, ErrTooLarge)` works the way
comparing against Go's value does.
"""

from core.errors import Report, matches, partial
from core.errors.codes import EOF, ErrShortWrite, ErrTooLarge
from core.io import (
    Byte,
    ByteScanner,
    ByteWriter,
    READER_FROM,
    Reader as IoReader,
    ReaderFrom,
    RuneScanner,
    StringWriter,
    WRITER_TO,
    Writer,
    WriterTo,
)
from core.unicode.utf8 import RUNE_SELF, append_rune, decode_rune

from .search import index_byte

comptime MIN_READ = 512
"""The smallest read `read_from` will ask for. Go's `bytes.MinRead`.

A reader is entitled to fill only part of the span it is given, so asking for
one byte at a time would be correct and would cost a call per byte. Go picks
512 and so does this: it is large enough that a socket read is worth making and
small enough that draining a short reader does not reserve a page.
"""

comptime _OP_INVALID = 0
"""The last operation was not a read, so there is nothing to unread."""

comptime _OP_READ = -1
"""The last operation was a read of bytes rather than of one rune."""


struct Buffer(
    ByteScanner,
    ByteWriter,
    IoReader,
    Movable,
    ReaderFrom,
    RuneScanner,
    StringWriter,
    Writer,
    WriterTo,
):
    """Bytes with a write end and a read end. Go's `bytes.Buffer`.

    ```mojo
    from core.bytes import Buffer

    var b = Buffer()
    _ = b.write_string("hello ")
    _ = b.write_string("world")
    print(b.string())  # => hello world
    ```

    The zero value is ready to use, as in Go: `Buffer()` is an empty buffer
    with nothing allocated, and the first write allocates.
    """

    var _buf: List[Byte]
    """Everything, read and unread. The unread part starts at `_off`."""

    var _off: Int
    """Where the next read starts. `_buf[0:_off]` has been read and is dead."""

    var _last_read: Int
    """What the last operation was, so `unread_byte` and `unread_rune` know.

    `_OP_INVALID`, `_OP_READ`, or the width in bytes of the rune just read,
    which is Go's `readOp` and is why the two unread methods can be separate
    without a second field.
    """

    def __init__(out self):
        """An empty buffer with nothing allocated."""
        self._buf = List[Byte]()
        self._off = 0
        self._last_read = _OP_INVALID

    def __init__(out self, var buf: List[Byte]):
        """A buffer that owns `buf` and will read what is already in it.

        Go's `bytes.NewBuffer`, which documents that the slice must not be used
        afterwards. Here that is not a documented rule but a taken argument:
        the list moves in and the caller no longer has it.
        """
        self._buf = buf^
        self._off = 0
        self._last_read = _OP_INVALID

    def len(self) -> Int:
        """How many bytes are unread. Go's `Buffer.Len`."""
        return len(self._buf) - self._off

    def cap(self) -> Int:
        """How many bytes the storage can hold before it grows. Go's `Cap`.

        This counts the space taken by bytes already read as well, because it
        is the capacity of the allocation and not of the unread part. It is
        `len()` plus `available()` plus whatever the read cursor has passed.
        """
        return Int(self._buf.capacity())

    def available(self) -> Int:
        """How much can be written before the storage grows. Go's `Available`.
        """
        return Int(self._buf.capacity()) - len(self._buf)

    def reset(mut self):
        """Throw away everything, keeping the allocation. Go's `Buffer.Reset`.
        """
        self._buf.clear()
        self._off = 0
        self._last_read = _OP_INVALID

    def truncate(mut self, n: Int) raises:
        """Keep the first `n` unread bytes and discard the rest. Go's `Truncate`.

        Raises if `n` is negative or larger than `len()`, which Go panics on.
        """
        if n == 0:
            self.reset()
            return
        if n < 0 or n > self.len():
            raise Report("bytes.Buffer.truncate: out of range").error()
        self._last_read = _OP_INVALID
        self._buf.resize(self._off + n, 0)

    def _compact(mut self):
        """Move the unread bytes to the front when the dead prefix is big.

        Go slides the bytes down inside `grow` when the read cursor has passed
        half the allocation, and this is the same rule in its own method: the
        dead prefix is reclaimed once it is at least as long as what is left,
        so the sliding is amortised and a buffer written and drained in a loop
        does not grow without bound. Without it, a `Buffer` used as a pipe
        allocates once per byte that ever went through it.
        """
        if self._off == 0:
            return
        if self._off == len(self._buf):
            self._buf.clear()
            self._off = 0
            return
        if self._off * 2 < len(self._buf):
            return
        var live = len(self._buf) - self._off
        for i in range(live):
            self._buf[i] = self._buf[self._off + i]
        self._buf.resize(live, 0)
        self._off = 0

    def grow(mut self, n: Int) raises:
        """Make room for `n` more bytes without growing again. Go's `Grow`.

        Raises on a negative count, which Go panics on, and `ErrTooLarge` when
        the size asked for cannot be represented, which is the other thing Go
        panics on. Growing is an optimisation and never changes what the buffer
        holds.
        """
        if n < 0:
            raise Report("bytes.Buffer.grow: negative count").error()
        self._compact()
        var want = len(self._buf) + n
        if want < 0:
            raise Report("bytes.Buffer.grow: too large").with_code(
                ErrTooLarge
            ).error()
        self._buf.reserve(want)

    def bytes(self) -> List[Byte]:
        """A copy of the unread bytes. Go's `Buffer.Bytes`.

        A copy, and the package docstring says why at length: Go's version is
        a view that the next write invalidates, and a view invalidated here is
        a pointer into freed memory rather than stale but live bytes.
        """
        var out = List[Byte](capacity=self.len())
        for i in range(self._off, len(self._buf)):
            out.append(self._buf[i])
        return out^

    def string(self) raises -> String:
        """The unread bytes as text. Go's `Buffer.String`.

        Raises if they are not valid UTF-8, for the reason
        `bufio.Reader.read_string` gives: a Mojo `String` promises UTF-8 and
        there is no honest way to make one from arbitrary bytes. `bytes()` is
        the version that never refuses.
        """
        return String(from_utf8=Span(self._buf)[self._off : len(self._buf)])

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        """Append `data`. Go's `Buffer.Write`.

        Always accepts everything and returns `len(data)`, so the short write
        the `Writer` contract talks about cannot happen here — the only way to
        fail is to run out of memory, which raises.
        """
        self._last_read = _OP_INVALID
        self._compact()
        self._buf.reserve(len(self._buf) + len(data))
        for i in range(len(data)):
            self._buf.append(data[i])
        return len(data)

    def write_string(mut self, s: String) raises -> Int:
        """Append the bytes of `s`. Go's `Buffer.WriteString`.

        A `String` lends its bytes without a copy, so this is `write` and the
        method exists because `io.StringWriter` asks for it and a port looks
        for the name.
        """
        return self.write(s.as_bytes())

    def write_byte(mut self, c: Byte) raises:
        """Append one byte. Go's `Buffer.WriteByte`."""
        self._last_read = _OP_INVALID
        self._compact()
        self._buf.append(c)

    def write_rune(mut self, r: Int32) raises -> Int:
        """Append `r` encoded as UTF-8, and return how many bytes that was.

        Go's `Buffer.WriteRune`. A rune that is not a code point is written as
        U+FFFD, which is `utf8.append_rune`'s rule and means this cannot fail
        on a bad rune.
        """
        self._last_read = _OP_INVALID
        self._compact()
        return append_rune(self._buf, r)

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """Move up to `len(into)` unread bytes into `into`. Go's `Buffer.Read`.

        Raises `EOF` when the buffer is empty, unless `into` is empty too, in
        which case it returns zero: an empty span is not a way to ask whether
        there is anything left.
        """
        if self.len() == 0:
            self.reset()
            if len(into) == 0:
                return 0
            raise Report("bytes.Buffer.read: buffer is empty").with_code(
                EOF
            ).error()
        var n = self.len()
        if n > len(into):
            n = len(into)
        for i in range(n):
            into[i] = self._buf[self._off + i]
        self._off += n
        if n > 0:
            self._last_read = _OP_READ
        return n

    def next(mut self, n: Int) -> List[Byte]:
        """Take the next `n` unread bytes, or all of them if there are fewer.

        Go's `Buffer.Next`. The bytes are consumed either way, and what comes
        back is owned, so unlike Go's version it stays valid across the next
        write. `len()` beforehand is how to know whether `n` was available.
        """
        var m = self.len()
        if n < m:
            m = n
        if m < 0:
            m = 0
        var out = List[Byte](capacity=m)
        for i in range(m):
            out.append(self._buf[self._off + i])
        self._off += m
        self._last_read = _OP_READ if m > 0 else _OP_INVALID
        return out^

    def peek(self, n: Int) raises -> List[Byte]:
        """A copy of the next `n` unread bytes, without consuming them.

        Go's `Buffer.Peek`. Returns fewer than `n` when there are fewer, and
        raises `EOF` only when there are none and `n` is positive, which is
        this library's rule everywhere: bytes come back as bytes and the reason
        the stream ended arrives on the call that has nothing to hand over.
        Go returns the short slice and `io.EOF` together.
        """
        if n < 0:
            raise Report("bytes.Buffer.peek: negative count").error()
        if self.len() == 0 and n > 0:
            raise Report("bytes.Buffer.peek: buffer is empty").with_code(
                EOF
            ).error()
        var m = self.len()
        if n < m:
            m = n
        var out = List[Byte](capacity=m)
        for i in range(m):
            out.append(self._buf[self._off + i])
        return out^

    def read_byte(mut self) raises -> Byte:
        """The next unread byte. Go's `Buffer.ReadByte`."""
        if self.len() == 0:
            self.reset()
            raise Report("bytes.Buffer.read_byte: buffer is empty").with_code(
                EOF
            ).error()
        var c = self._buf[self._off]
        self._off += 1
        self._last_read = _OP_READ
        return c

    def read_rune(mut self) raises -> Tuple[Int32, Int]:
        """The next rune and its width. Go's `Buffer.ReadRune`.

        Bytes that are not valid UTF-8 come back as U+FFFD one byte at a time,
        which is `io.RuneReader`'s rule and Go's.
        """
        if self.len() == 0:
            self.reset()
            raise Report("bytes.Buffer.read_rune: buffer is empty").with_code(
                EOF
            ).error()
        var c = self._buf[self._off]
        if Int(c) < RUNE_SELF:
            self._off += 1
            self._last_read = 1
            return (Int32(Int(c)), 1)
        var r, width = decode_rune(Span(self._buf)[self._off : len(self._buf)])
        self._off += width
        self._last_read = width
        return (r, width)

    def unread_byte(mut self) raises:
        """Put the last byte read back. Go's `Buffer.UnreadByte`.

        Raises if the last operation was not a read, because there is nothing
        to put back and moving the cursor anyway would hand out a byte that was
        never delivered.
        """
        if self._last_read == _OP_INVALID:
            raise Report(
                "bytes.Buffer.unread_byte: the last operation was not a read"
            ).error()
        self._last_read = _OP_INVALID
        if self._off > 0:
            self._off -= 1

    def unread_rune(mut self) raises:
        """Put the last rune read back. Go's `Buffer.UnreadRune`.

        Raises unless the last operation was `read_rune`, which is stricter
        than `unread_byte` and has to be: the width to give back is the width
        that was taken, and after a `read` of bytes there is no such number.
        """
        if self._last_read <= _OP_INVALID:
            raise Report(
                "bytes.Buffer.unread_rune: the last operation was not read_rune"
            ).error()
        if self._off >= self._last_read:
            self._off -= self._last_read
        self._last_read = _OP_INVALID

    def read_bytes(mut self, delim: Byte) raises -> List[Byte]:
        """Everything up to and including the first `delim`. Go's `ReadBytes`.

        When `delim` is not there, everything left comes back and the end
        arrives from the next call. Go returns the same bytes together with
        `io.EOF`; here the rule is bytes now and the reason next time, as in
        `bufio`. Having nothing at all raises `EOF`.
        """
        if self.len() == 0:
            self.reset()
            raise Report("bytes.Buffer.read_bytes: buffer is empty").with_code(
                EOF
            ).error()
        var at = index_byte(Span(self._buf)[self._off : len(self._buf)], delim)
        var take = self.len()
        if at >= 0:
            take = at + 1
        return self.next(take)

    def read_string(mut self, delim: Byte) raises -> String:
        """`read_bytes` as text. Go's `Buffer.ReadString`.

        Raises if what was read is not valid UTF-8, and the bytes are consumed
        either way. `bufio.Reader.read_string` has the full argument for why
        this is stricter than Go.
        """
        var raw = self.read_bytes(delim)
        return String(from_utf8=Span(raw))

    def capabilities(self) -> Int:
        """Both fast paths: this reads from a reader and writes to a writer."""
        return READER_FROM | WRITER_TO

    def read_from[R: IoReader](mut self, mut src: R) raises -> Int64:
        """Drain `src` into this buffer. Go's `Buffer.ReadFrom`.

        Reads in chunks of `MIN_READ` straight into the buffer's own storage
        rather than through a staging array, so the bytes are copied once. The
        end of `src` is not a failure and is not reraised; anything else comes
        out with the count that moved on `errors.partial`.
        """
        self._last_read = _OP_INVALID
        var moved = Int64(0)
        while True:
            self._compact()
            var base = len(self._buf)
            self._buf.resize(base + MIN_READ, 0)
            var got: Int
            try:
                got = src.read(Span(self._buf)[base : base + MIN_READ])
            except e:
                self._buf.resize(base, 0)
                if matches(e, EOF):
                    return moved
                raise Report("bytes.Buffer.read_from: reading").wrapping(
                    e
                ).with_count(Int(moved) + partial(e)).error()
            self._buf.resize(base + got, 0)
            moved += Int64(got)

    def write_to[W: Writer](mut self, mut dst: W) raises -> Int64:
        """Write every unread byte to `dst` and empty this buffer. Go's `WriteTo`.

        The buffer is reset afterwards whether or not everything was accepted,
        because a writer that takes less than it was given raises here and the
        count it took is on the failure. A writer that accepts everything
        leaves an empty buffer, which is what makes this the way to hand a
        built document over.
        """
        self._last_read = _OP_INVALID
        var pending = self.len()
        if pending == 0:
            self.reset()
            return Int64(0)
        var wrote: Int
        try:
            wrote = dst.write(Span(self._buf)[self._off : len(self._buf)])
        except e:
            self._off += partial(e)
            raise Report("bytes.Buffer.write_to: writing").wrapping(
                e
            ).with_count(partial(e)).error()
        self._off += wrote
        if wrote != pending:
            raise (
                Report("bytes.Buffer.write_to: the writer took only part")
                .with_code(ErrShortWrite)
                .with_count(wrote)
                .error()
            )
        self.reset()
        return Int64(wrote)


def new_buffer(var buf: List[Byte]) -> Buffer:
    """A buffer that owns `buf` and reads what is in it. Go's `NewBuffer`.

    Go's own documentation says to use this only to set the initial contents or
    the initial capacity, and that `Buffer()` is enough otherwise. The same
    holds here, with the difference that the argument moves in rather than
    being shared, so there is no way to keep using it by mistake.
    """
    return Buffer(buf^)


def new_buffer_string(s: String) -> Buffer:
    """A buffer holding a copy of `s`'s bytes. Go's `NewBufferString`.

    Go copies too, because a `string` is immutable and a `Buffer` writes. The
    copy is the whole function.
    """
    var buf = List[Byte](capacity=s.byte_length())
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        buf.append(bytes[i])
    return Buffer(buf^)
