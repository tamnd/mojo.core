"""Readers and writers that see part of something bigger.

`LimitedReader` stops after a number of bytes. `SectionReader` and
`OffsetWriter` shift a window onto something addressed by position. All three
are Go's, and all three are generic over what they wrap rather than holding an
erased value, which is the one real difference.

Go has to hold an interface, so `io.LimitReader` returns an `io.Reader` and
every read through it is an indirect call. Here the wrapped type is a
parameter, so `LimitedReader[Fixed]` is a distinct type whose `read` calls
`Fixed.read` directly and can be inlined into it. That is why these take their
argument by value and own it: a parameter has to be a type, and taking a
borrow instead would mean putting a `ReaderView` in a field, which
`erased.mojo` forbids for the reason given there. A caller that has to keep the
original wraps an `AnyReader`, which is copyable and refcounted, and keeps its
own copy.
"""

from core.errors import Report
from core.errors.codes import EOF

from .iface import (
    Byte,
    Reader,
    ReaderAt,
    SEEK_CURRENT,
    SEEK_END,
    SEEK_START,
    Seeker,
    Writer,
    WriterAt,
)


struct LimitedReader[R: Reader & Deinitable & Movable](Movable, Reader):
    """A reader that reports the end after `n` bytes. Go's `io.LimitedReader`.

    Both fields are public and mean what Go's `R` and `N` mean, so a caller can
    read `n` afterwards to find out how much of the allowance is left, or set
    it to extend one.

    This is the answer to reading from something you do not trust. `read_all`
    over a socket has no limit and neither does Go's; `read_all` over
    `limit_reader(socket, 1 << 20)` cannot use more than a megabyte whatever
    the other end sends.
    """

    var r: Self.R
    """What is being read. Go's `LimitedReader.R`."""

    var n: Int64
    """How many bytes are still allowed through. Go's `LimitedReader.N`."""

    def __init__(out self, var r: Self.R, n: Int64):
        """Wrap `r` and allow `n` bytes through it."""
        self.r = r^
        self.n = n

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """Read, never more than the remaining allowance.

        Raises `EOF` once the allowance is gone, whether or not the underlying
        reader had more, which is the point.
        """
        if self.n <= 0:
            raise Report("io.LimitedReader: limit reached").with_code(
                EOF
            ).error()
        var want = len(into)
        if Int64(want) > self.n:
            want = Int(self.n)
        var got = self.r.read(into[0:want])
        self.n -= Int64(got)
        return got


def limit_reader[
    R: Reader & Deinitable & Movable
](var r: R, n: Int64) -> LimitedReader[R]:
    """Wrap `r` so it reports the end after `n` bytes. Go's `io.LimitReader`.

    Exactly `LimitedReader(r^, n)`, and it exists because Go has the name and a
    port should find it. Note this cannot raise: nothing is read here.
    """
    return LimitedReader(r^, n)


struct SectionReader[R: ReaderAt & Deinitable & Movable](
    Movable, Reader, ReaderAt, Seeker
):
    """A window onto part of something addressed by position.

    Go's `io.SectionReader`. It reads the `n` bytes starting at `off` and
    reports the end there, and because it is built on `read_at` rather than on
    a cursor, two of them over the same source can be read at the same time.
    That is the whole reason `ReaderAt` promises what it promises.
    """

    var r: Self.R
    """The source. Go keeps this unexported; there is no way to hand it back
    from `outer` here, so it is a field instead. See `outer`."""

    var base: Int64
    """Where the window starts in the source."""

    var off: Int64
    """Where the next `read` will start, in the source's coordinates."""

    var limit: Int64
    """One past the last byte of the window, in the source's coordinates."""

    def __init__(out self, var r: Self.R, off: Int64, n: Int64):
        """The `n` bytes of `r` starting at `off`."""
        self.r = r^
        self.base = off
        self.off = off
        self.limit = off + n

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """Read from the current position and advance it."""
        if self.off >= self.limit:
            raise Report("io.SectionReader: end of section").with_code(
                EOF
            ).error()
        var want = len(into)
        var left = self.limit - self.off
        if Int64(want) > left:
            want = Int(left)
        var got = self.r.read_at(into[0:want], self.off)
        self.off += Int64(got)
        return got

    def read_at[
        o: Origin[mut=True]
    ](self, into: Span[Byte, o], offset: Int64) raises -> Int:
        """Read at `offset` from the start of the window, moving nothing.

        `offset` is relative to the window and not to the source, so a section
        of a section composes the way it should.
        """
        if offset < 0 or offset >= self.limit - self.base:
            raise Report(
                "io.SectionReader: read_at outside the section"
            ).with_code(EOF).error()
        var at = self.base + offset
        var want = len(into)
        var left = self.limit - at
        if Int64(want) > left:
            want = Int(left)
        return self.r.read_at(into[0:want], at)

    def seek(mut self, offset: Int64, whence: Int) raises -> Int64:
        """Move the read position. Offsets are relative to the window."""
        var to: Int64
        if whence == SEEK_START:
            to = self.base + offset
        elif whence == SEEK_CURRENT:
            to = self.off + offset
        elif whence == SEEK_END:
            to = self.limit + offset
        else:
            raise Report(
                "io.SectionReader: seek with an unknown whence"
            ).error()
        if to < self.base:
            raise Report("io.SectionReader: seek before the start").error()
        self.off = to
        return to - self.base

    def size(self) -> Int64:
        """How many bytes are in the window. Go's `SectionReader.Size`."""
        return self.limit - self.base

    def outer(self) -> Tuple[Int64, Int64]:
        """The offset and size this was made with. Go's `SectionReader.Outer`.

        Go also hands back the underlying `ReaderAt`, because its caller has no
        other way to reach it. A method here cannot return a borrow of a field
        alongside two values, so the source is the public field `r` instead and
        this returns the pair Go returns with it. `deviations.md` has the row.
        """
        return (self.base, self.limit - self.base)


def new_section_reader[
    R: ReaderAt & Deinitable & Movable
](var r: R, off: Int64, n: Int64) -> SectionReader[R]:
    """The `n` bytes of `r` starting at `off`. Go's `io.NewSectionReader`."""
    return SectionReader(r^, off, n)


struct OffsetWriter[W: WriterAt & Deinitable & Movable](
    Movable, Seeker, Writer, WriterAt
):
    """A writer that starts at an offset into something. Go's `io.OffsetWriter`.

    The mirror of `SectionReader` with no upper bound, because Go has none
    either: a write past where the source currently ends extends it, which is
    what a file does.
    """

    var w: Self.W
    """The sink."""

    var base: Int64
    """Where offset zero of this writer sits in the sink."""

    var off: Int64
    """Where the next `write` will start, in the sink's coordinates."""

    def __init__(out self, var w: Self.W, off: Int64):
        """Write into `w`, starting at `off`."""
        self.w = w^
        self.base = off
        self.off = off

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        """Write at the current position and advance it."""
        var n = self.w.write_at(data, self.off)
        self.off += Int64(n)
        return n

    def write_at[
        o: Origin
    ](mut self, data: Span[Byte, o], offset: Int64) raises -> Int:
        """Write at `offset` from the start, leaving this writer's own
        position alone. `mut self` because the sink underneath needs it, not
        because anything here changes."""
        if offset < 0:
            raise Report("io.OffsetWriter: write_at before the start").error()
        return self.w.write_at(data, self.base + offset)

    def seek(mut self, offset: Int64, whence: Int) raises -> Int64:
        """Move the write position. `SEEK_END` has no meaning without a size."""
        var to: Int64
        if whence == SEEK_START:
            to = self.base + offset
        elif whence == SEEK_CURRENT:
            to = self.off + offset
        else:
            raise Report(
                "io.OffsetWriter: seek with an unknown whence, and SEEK_END has"
                " no end to count from"
            ).error()
        if to < self.base:
            raise Report("io.OffsetWriter: seek before the start").error()
        self.off = to
        return to - self.base


def new_offset_writer[
    W: WriterAt & Deinitable & Movable
](var w: W, off: Int64) -> OffsetWriter[W]:
    """Write into `w` starting at `off`. Go's `io.NewOffsetWriter`."""
    return OffsetWriter(w^, off)
