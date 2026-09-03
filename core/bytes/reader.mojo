"""A byte slice read as a stream. Go's `bytes.Reader`.

Ten lines of state and eleven methods, and between them they turn a span into
almost every reading interface `core.io` declares: `Reader`, `ReaderAt`,
`Seeker`, `ByteScanner`, `RuneScanner` and `WriterTo`. That is what makes it
the thing to reach for when a function wants a reader and what you have is
bytes already in memory.

It borrows rather than owns, exactly as Go's does. The span's origin is a
parameter of the type, so `Reader[o]` is a reader over that particular caller's
bytes and the compiler knows it cannot outlive them. Nothing is copied when one
is made and nothing is copied when one is read from through `write_to`.

The one thing that costs something is `reset`. Go's takes any `[]byte`, because
a slice header carries no lifetime; here it takes a span with the same origin,
so a reader can be pointed at a different part of the same buffer but not at a
different buffer. Making a new `Reader` is two words and no allocation, so what
is lost is a line rather than a capability. `deviations.md` has the row, beside
`bufio.Reader.reset` which is the same shape of problem.
"""

from core.errors import Report, matches, partial
from core.errors.codes import EOF, ErrShortWrite
from core.io import (
    Byte,
    ByteScanner,
    Reader as IoReader,
    ReaderAt,
    RuneScanner,
    SEEK_CURRENT,
    SEEK_END,
    SEEK_START,
    Seeker,
    WRITER_TO,
    Writer,
    WriterTo,
)
from core.unicode.utf8 import RUNE_SELF, decode_rune


struct Reader[o: Origin](
    ByteScanner,
    Copyable,
    IoReader,
    Movable,
    ReaderAt,
    RuneScanner,
    Seeker,
    WriterTo,
):
    """A span read from the front. Go's `bytes.Reader`.

    ```mojo
    from core.bytes import new_reader
    from core.io import read_all

    var text = String("hello")
    var r = new_reader(text.as_bytes())
    var all = read_all(r)
    ```
    """

    var _s: Span[Byte, Self.o].Immutable
    """The bytes. Never written to, which is why the span is immutable."""

    var _at: Int
    """Where the next read starts."""

    var _prev_rune: Int
    """Where the last `read_rune` started, or -1 if the last call was not one.

    Go keeps the same field for the same reason: `unread_rune` has to know the
    width it gave out, and after anything other than a `read_rune` there is no
    such number and the call has to be refused.
    """

    def __init__(out self, s: Span[Byte, Self.o]):
        """Read `s` from the beginning."""
        self._s = s.as_imm()
        self._at = 0
        self._prev_rune = -1

    def len(self) -> Int:
        """How many bytes are unread. Go's `Reader.Len`."""
        if self._at >= len(self._s):
            return 0
        return len(self._s) - self._at

    def size(self) -> Int64:
        """How many bytes there are in total. Go's `Reader.Size`.

        Fixed for the life of the reader and unaffected by reading, which is
        what `ReaderAt` needs and what `len()` is not.
        """
        return Int64(len(self._s))

    def reset(mut self, s: Span[Byte, Self.o]):
        """Start again over `s`. Go's `Reader.Reset`.

        The span has to come from the same place as the one this reader was
        built over, because the origin is part of the type. For a different
        source, make a different reader.
        """
        self._s = s.as_imm()
        self._at = 0
        self._prev_rune = -1

    def read[
        o2: Origin[mut=True]
    ](mut self, into: Span[Byte, o2]) raises -> Int:
        """Move up to `len(into)` unread bytes into `into`. Go's `Reader.Read`.

        Raises `EOF` at the end, with nothing moved, which is the rule for
        every reader here.
        """
        if self._at >= len(self._s):
            raise Report("bytes.Reader.read: end of input").with_code(
                EOF
            ).error()
        var n = len(self._s) - self._at
        if n > len(into):
            n = len(into)
        for i in range(n):
            into[i] = self._s[self._at + i]
        self._at += n
        self._prev_rune = -1
        return n

    def read_at[
        o2: Origin[mut=True]
    ](self, into: Span[Byte, o2], offset: Int64) raises -> Int:
        """Read at `offset` without moving the cursor. Go's `Reader.ReadAt`.

        Fills `into` or reaches the end, so a short result means the end and
        nothing else. A negative offset raises; an offset past the end raises
        `EOF`, which is what a caller reading a fixed size record wants.
        """
        if offset < 0:
            raise Report("bytes.Reader.read_at: negative offset").error()
        var at = Int(offset)
        if at >= len(self._s):
            raise Report("bytes.Reader.read_at: past the end").with_code(
                EOF
            ).error()
        var n = len(self._s) - at
        if n > len(into):
            n = len(into)
        for i in range(n):
            into[i] = self._s[at + i]
        if n < len(into):
            raise (
                Report("bytes.Reader.read_at: input ended part way through")
                .with_code(EOF)
                .with_count(n)
                .error()
            )
        return n

    def read_byte(mut self) raises -> Byte:
        """The next byte. Go's `Reader.ReadByte`."""
        self._prev_rune = -1
        if self._at >= len(self._s):
            raise Report("bytes.Reader.read_byte: end of input").with_code(
                EOF
            ).error()
        var c = self._s[self._at]
        self._at += 1
        return c

    def unread_byte(mut self) raises:
        """Step back one byte. Go's `Reader.UnreadByte`.

        Raises at the beginning of the input, which Go also does. Unlike
        `Buffer.unread_byte` this does not insist that the last call was a
        read, because a `Reader` is over a fixed span and stepping back is
        always meaningful — Go draws the line in the same place.
        """
        if self._at <= 0:
            raise Report(
                "bytes.Reader.unread_byte: at the beginning of the input"
            ).error()
        self._prev_rune = -1
        self._at -= 1

    def read_rune(mut self) raises -> Tuple[Int32, Int]:
        """The next rune and its width. Go's `Reader.ReadRune`.

        Invalid encodings come back as U+FFFD one byte at a time, as everywhere
        else.
        """
        if self._at >= len(self._s):
            self._prev_rune = -1
            raise Report("bytes.Reader.read_rune: end of input").with_code(
                EOF
            ).error()
        self._prev_rune = self._at
        var c = self._s[self._at]
        if Int(c) < RUNE_SELF:
            self._at += 1
            return (Int32(Int(c)), 1)
        var r, width = decode_rune(self._s[self._at : len(self._s)])
        self._at += width
        return (r, width)

    def unread_rune(mut self) raises:
        """Step back over the last rune read. Go's `Reader.UnreadRune`.

        Raises unless the last call was `read_rune`, because the width to give
        back is only known then.
        """
        if self._at <= 0:
            raise Report(
                "bytes.Reader.unread_rune: at the beginning of the input"
            ).error()
        if self._prev_rune < 0:
            raise Report(
                "bytes.Reader.unread_rune: the last operation was not read_rune"
            ).error()
        self._at = self._prev_rune
        self._prev_rune = -1

    def seek(mut self, offset: Int64, whence: Int) raises -> Int64:
        """Move the cursor and return where it ended up. Go's `Reader.Seek`.

        Seeking before the start raises. Seeking past the end is allowed and
        the next read reports the end, which is what a file does and what Go's
        reader does.
        """
        var target: Int64
        if whence == SEEK_START:
            target = offset
        elif whence == SEEK_CURRENT:
            target = Int64(self._at) + offset
        elif whence == SEEK_END:
            target = Int64(len(self._s)) + offset
        else:
            raise Report("bytes.Reader.seek: unknown whence").error()
        if target < 0:
            raise Report("bytes.Reader.seek: before the start").error()
        self._at = Int(target)
        self._prev_rune = -1
        return target

    def capabilities(self) -> Int:
        """The bytes are already in memory, so `write_to` is the fast path."""
        return WRITER_TO

    def write_to[W: Writer](mut self, mut dst: W) raises -> Int64:
        """Write everything unread to `dst`. Go's `Reader.WriteTo`.

        One `write` call with the whole remainder, because the bytes are
        contiguous and there is nothing to be gained by cutting them up. The
        cursor ends at the end whether or not the write was accepted in full,
        and a short write raises with the count on it.
        """
        self._prev_rune = -1
        if self._at >= len(self._s):
            return Int64(0)
        var pending = len(self._s) - self._at
        var wrote: Int
        try:
            wrote = dst.write(self._s[self._at : len(self._s)])
        except e:
            self._at += partial(e)
            raise Report("bytes.Reader.write_to: writing").wrapping(
                e
            ).with_count(partial(e)).error()
        self._at += wrote
        if wrote != pending:
            raise (
                Report("bytes.Reader.write_to: the writer took only part")
                .with_code(ErrShortWrite)
                .with_count(wrote)
                .error()
            )
        return Int64(wrote)


def new_reader[o: Origin](b: Span[Byte, o]) -> Reader[o]:
    """A reader over `b`. Go's `bytes.NewReader`.

    ```mojo
    from core.bytes import new_reader

    var text = String("hello")
    var r = new_reader(text.as_bytes())
    print(r.len())  # => 5
    ```

    Nothing is copied and nothing is allocated: the reader is a span, an offset
    and a rune position. It borrows `b`, so `b` has to outlive it, and the
    compiler is the one enforcing that rather than a sentence in a comment.
    """
    return Reader[o](b)
