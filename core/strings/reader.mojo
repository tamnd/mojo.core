"""A string read as a stream. Go's `strings.Reader`.

Eleven methods and not one of them does any work. Every one forwards to a
`core.bytes.Reader` over the same bytes, which is possible because a Mojo
`String` lends its bytes without copying and impossible in Go, where
`bytes.NewReader([]byte(s))` copies the whole string. Go therefore has two
readers with two copies of the seek arithmetic and the rune unreading, and this
package has one reader and a wrapper.

The forwarding is written out rather than inherited, because Mojo has no
embedding and because a hand written forwarder is where the type differences
live: `reset` takes a `StringSlice` and hands down a span, and that is the only
line in the file that is not a one to one call.

What it borrows is in the type. `Reader[o]` is a reader over that particular
caller's text and the compiler will not let it outlive it, which is the one
place this differs from Go: `reset` takes a slice with the same origin, and a
different source means a new reader, which is two words and no allocation.
`deviations.md` has the row, next to `bytes.Reader.Reset` and
`bufio.Reader.Reset`, which are the same shape.
"""

import core.bytes.reader as br
from core.io import (
    Byte,
    ByteScanner,
    Reader as IoReader,
    ReaderAt,
    RuneScanner,
    Seeker,
    WRITER_TO,
    Writer,
    WriterTo,
)


struct Reader[o: ImmOrigin](
    ByteScanner,
    Copyable,
    IoReader,
    Movable,
    ReaderAt,
    RuneScanner,
    Seeker,
    WriterTo,
):
    """Text read from the front. Go's `strings.Reader`.

    ```mojo
    from core.strings import new_reader
    from core.io import read_all

    var text = String("hello")
    var r = new_reader(text)
    var all = read_all(r)
    ```
    """

    var _inner: br.Reader[Self.o]
    """The byte reader doing all of it."""

    def __init__(out self, s: StringSlice[Self.o]):
        """Read `s` from the beginning."""
        self._inner = br.Reader[Self.o](s.as_bytes())

    def len(self) -> Int:
        """How many bytes are unread. Go's `Reader.Len`.

        Bytes, not runes and not characters, which is Go's answer and is what
        makes it usable as a size for the buffer a caller is about to fill.
        `count_runes` is the other question and it needs a scan.
        """
        return self._inner.len()

    def size(self) -> Int64:
        """How many bytes there are in total. Go's `Reader.Size`."""
        return self._inner.size()

    def reset(mut self, s: StringSlice[Self.o]):
        """Start again over `s`. Go's `Reader.Reset`.

        The slice has to come from the same place as the one this reader was
        built over, because the origin is part of the type. For different text,
        make a different reader.
        """
        self._inner.reset(s.as_bytes())

    def read[
        o2: Origin[mut=True]
    ](mut self, into: Span[Byte, o2]) raises -> Int:
        """Move up to `len(into)` unread bytes into `into`. Go's `Reader.Read`.

        Bytes, so a read can stop in the middle of a character. That is Go's
        behaviour and the reason `bufio.Reader.read_rune` exists; a caller
        wanting whole runes uses `read_rune` here.
        """
        return self._inner.read(into)

    def read_at[
        o2: Origin[mut=True]
    ](self, into: Span[Byte, o2], offset: Int64) raises -> Int:
        """Read at `offset` without moving the cursor. Go's `Reader.ReadAt`."""
        return self._inner.read_at(into, offset)

    def read_byte(mut self) raises -> Byte:
        """The next byte. Go's `Reader.ReadByte`."""
        return self._inner.read_byte()

    def unread_byte(mut self) raises:
        """Step back one byte. Go's `Reader.UnreadByte`."""
        self._inner.unread_byte()

    def read_rune(mut self) raises -> Tuple[Int32, Int]:
        """The next rune and its width. Go's `Reader.ReadRune`."""
        return self._inner.read_rune()

    def unread_rune(mut self) raises:
        """Step back over the last rune read. Go's `Reader.UnreadRune`.

        Raises unless the last call was `read_rune`, because the width to give
        back is only known then.
        """
        self._inner.unread_rune()

    def seek(mut self, offset: Int64, whence: Int) raises -> Int64:
        """Move the cursor and return where it ended up. Go's `Reader.Seek`.

        A byte offset, so seeking to a position inside a character is allowed
        and the read that follows decodes from there. Go behaves the same way
        and neither library can do better, because a byte offset is what the
        interface promises.
        """
        return self._inner.seek(offset, whence)

    def capabilities(self) -> Int:
        """The text is already in memory, so `write_to` is the fast path."""
        return WRITER_TO

    def write_to[W: Writer](mut self, mut dst: W) raises -> Int64:
        """Write everything unread to `dst`. Go's `Reader.WriteTo`."""
        return self._inner.write_to(dst)


def new_reader[o: ImmOrigin](s: StringSlice[o]) -> Reader[o]:
    """A reader over `s`. Go's `strings.NewReader`.

    ```mojo
    from core.strings import new_reader

    var text = String("hello")
    var r = new_reader(text)
    print(r.len())  # => 5
    ```

    Nothing is copied and nothing is allocated. This is the function to reach
    for whenever something wants a reader and what you have is a string, which
    in Go is the difference between `strings.NewReader(s)` and the
    `bytes.NewReader([]byte(s))` that copies.
    """
    return Reader[o](s)
