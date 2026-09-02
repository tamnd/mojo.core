"""A buffered reader and a buffered writer, in one value. Go's `bufio.ReadWriter`.

Go's version is two embedded pointers, so `rw.ReadString('\\n')` and
`rw.WriteString("x")` both resolve through promotion and the type itself
declares no methods at all. There is no promotion here — `design.md` says why —
so this is two named fields and the forwarding written out.

That turns out to be an improvement rather than a cost, and it is worth naming
which part. Go's `ReadWriter` has two `Buffered` methods, two `Size` methods and
two `Reset` methods, and the promotion rules resolve none of them: `rw.Buffered`
is ambiguous and does not compile, so a Go caller writes `rw.Reader.Buffered()`
anyway and only finds out at the moment of the mistake. Here the three
ambiguous names are simply not forwarded, and the fields are public, so
`rw.reader.buffered()` and `rw.writer.buffered()` are what everybody writes and
there is nothing to be ambiguous about. Everything with one honest meaning is
forwarded; the three with two meanings are not. `deviations.md` has the row.

The reader and the writer are independent. Reading does not flush, which is
worth knowing on a socket: a request written into the writer and then read back
through the reader without a `flush` in between deadlocks, and that is Go's
behaviour too.
"""

from core.io import (
    Byte,
    ByteScanner,
    READER_FROM,
    ReadWriter as IoReadWriter,
    Reader as IoReader,
    ReaderFrom,
    RuneScanner,
    StringWriter,
    WRITER_TO,
    Writer as IoWriter,
    WriterTo,
)

from .read import Reader
from .write import Writer


struct ReadWriter[
    R: IoReader & Deinitable & Movable, W: IoWriter & Deinitable & Movable
](
    ByteScanner,
    IoReadWriter,
    Movable,
    ReaderFrom,
    RuneScanner,
    StringWriter,
    WriterTo,
):
    """A buffered reader and writer over a source and a sink.

    ```mojo
    from core.bufio import new_read_writer, new_reader, new_writer
    from core.io import AnyReader, AnyWriter


    def echo_line(var src: AnyReader, var dst: AnyWriter) raises:
        var rw = new_read_writer(new_reader(src^), new_writer(dst^))
        var line = rw.read_string(10)
        _ = rw.write_string(line)
        rw.flush()
    ```

    Two parameters rather than Go's one type, because the reader and the writer
    each name what they wrap. A conversation over one socket has the same type
    in both, which is the common case and reads no worse for being written
    twice.
    """

    var reader: Reader[Self.R]
    """The reading half. Public, so `rw.reader.buffered()` is available."""

    var writer: Writer[Self.W]
    """The writing half. Public, for the same reason."""

    def __init__(
        out self, var reader: Reader[Self.R], var writer: Writer[Self.W]
    ):
        """Join a reader and a writer. Go's `NewReadWriter`.

        Both are taken by value and owned from here on, so there is no way for
        the buffered reader to be read from behind this type's back.
        """
        self.reader = reader^
        self.writer = writer^

    # The reading half.

    def peek(mut self, n: Int) raises -> List[Byte]:
        """`Reader.peek`."""
        return self.reader.peek(n)

    def discard(mut self, n: Int) raises -> Int:
        """`Reader.discard`."""
        return self.reader.discard(n)

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """`Reader.read`."""
        return self.reader.read(into)

    def read_byte(mut self) raises -> Byte:
        """`Reader.read_byte`."""
        return self.reader.read_byte()

    def unread_byte(mut self) raises:
        """`Reader.unread_byte`."""
        self.reader.unread_byte()

    def read_rune(mut self) raises -> Tuple[Int32, Int]:
        """`Reader.read_rune`."""
        return self.reader.read_rune()

    def unread_rune(mut self) raises:
        """`Reader.unread_rune`."""
        self.reader.unread_rune()

    def read_slice(mut self, delim: Byte) raises -> List[Byte]:
        """`Reader.read_slice`."""
        return self.reader.read_slice(delim)

    def read_bytes(mut self, delim: Byte) raises -> List[Byte]:
        """`Reader.read_bytes`."""
        return self.reader.read_bytes(delim)

    def read_string(mut self, delim: Byte) raises -> String:
        """`Reader.read_string`."""
        return self.reader.read_string(delim)

    def read_line(mut self) raises -> Tuple[List[Byte], Bool]:
        """`Reader.read_line`."""
        return self.reader.read_line()

    def write_to[D: IoWriter](mut self, mut dst: D) raises -> Int64:
        """`Reader.write_to`. Pushes what is left of the source into `dst`.

        Nothing to do with this value's own writer, which is a thing worth
        saying out loud: `rw.write_to(rw.writer)` is not expressible and would
        not be a copy from the reader to the writer if it were. `io.copy` over
        the two halves is that.
        """
        return self.reader.write_to(dst)

    # The writing half.

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        """`Writer.write`."""
        return self.writer.write(data)

    def write_byte(mut self, c: Byte) raises:
        """`Writer.write_byte`."""
        self.writer.write_byte(c)

    def write_string(mut self, s: String) raises -> Int:
        """`Writer.write_string`."""
        return self.writer.write_string(s)

    def write_rune(mut self, r: Int32) raises -> Int:
        """`Writer.write_rune`."""
        return self.writer.write_rune(r)

    def available(mut self) raises -> Int:
        """`Writer.available`. Unambiguous, because the reader has no such thing.
        """
        return self.writer.available()

    def flush(mut self) raises:
        """`Writer.flush`. Sends the buffered bytes; nothing is written before it.
        """
        self.writer.flush()

    def read_from[S: IoReader](mut self, mut src: S) raises -> Int64:
        """`Writer.read_from`. Drains `src` into the sink."""
        return self.writer.read_from(src)

    # Both.

    def capabilities(self) -> Int:
        """Both fast paths, because both halves have one."""
        return WRITER_TO | READER_FROM


def new_read_writer[
    R: IoReader & Deinitable & Movable, W: IoWriter & Deinitable & Movable
](var reader: Reader[R], var writer: Writer[W]) -> ReadWriter[R, W]:
    """Join a buffered reader and a buffered writer. Go's `NewReadWriter`.

    Go takes pointers and keeps them, so the caller can still reach both halves
    afterwards. These are moved in, and the halves are reached through the
    fields instead.
    """
    return ReadWriter[R, W](reader^, writer^)
