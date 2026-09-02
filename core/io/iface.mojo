"""`Reader` and `Writer`, and the bits that stand in for Go's type assertion.

Go discovers an optional interface at run time:

```go
if wt, ok := src.(WriterTo); ok {
    return wt.WriteTo(dst)
}
```

There is nothing to assert on here. A trait is a compile time constraint rather
than a value, design.md section 1, so there is no `src.(WriterTo)` and there is
no specialization on conformance either: a generic function cannot ask whether
its `R` happens to implement something. Both halves of Go's mechanism are
missing, and they have to be replaced by the same thing.

That thing is `capabilities`, an `Int` of bits, declared on the trait with a
default body returning zero. The optional methods are declared on the trait too,
with default bodies that raise. So a type that implements none of them writes
none of them and inherits a reader that says it can do nothing, and a type that
implements `write_to` overrides two methods: the one that does the work and the
one that admits to it.

The reason this is one mechanism rather than two is that it works identically on
both paths. A static `Reader` answers from a constant the compiler can see; an
erased `AnyReader` answers from a field it copied off its target at
construction. `copy` reads the bits the same way in both cases and does not
know or care which it has. Go needs an interface table lookup for the erased
case and cannot do the static case at all.

The cost is that a type can lie. Setting the bit without overriding the method
gets you the raising stub, which is a clear failure at the first call rather
than a wrong answer, and `tests/io` has a case for it.
"""

from core.errors import Report
from core.errors.codes import ErrUnsupported

comptime Byte = UInt8
"""What a stream is made of. Go's `byte`, and `[]byte` is `Span[Byte, o]`."""

comptime WRITER_TO = 1
"""The reader implements `write_to`. Go's `io.WriterTo`."""

comptime READER_FROM = 2
"""The writer implements `read_from`. Go's `io.ReaderFrom`."""

comptime SEEK_START = 0
"""`seek` counts from the beginning. Go's `io.SeekStart`."""

comptime SEEK_CURRENT = 1
"""`seek` counts from where it is now. Go's `io.SeekCurrent`."""

comptime SEEK_END = 2
"""`seek` counts back from the end. Go's `io.SeekEnd`."""


trait Writer:
    """Somewhere bytes go. Go's `io.Writer`.

    ```mojo
    from core.io import Writer


    def send[W: Writer](mut dst: W, data: Span[UInt8, MutableAnyOrigin]) raises:
        _ = dst.write(data)
    ```
    """

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        """Write `data` and return how much of it was accepted.

        A write that accepts everything returns `len(data)` and does not raise.
        A write that accepts less has to raise, because a caller that ignored a
        short count would silently lose the tail; `ErrShortWrite` is the
        sentinel for a writer that has nothing more specific to say, and the
        count that was accepted goes on `errors.partial`.

        `data` is immutable. A writer may not scribble on the caller's buffer,
        and taking any origin means a caller holding a mutable one does not have
        to give that up to call this.
        """
        ...

    def capabilities(self) -> Int:
        """Which of the optional methods below this type actually implements.

        Zero, unless the type says otherwise. Overriding this without also
        overriding the method it advertises gets the raising stub.
        """
        return 0

    def read_from[R: Reader](mut self, mut src: R) raises -> Int64:
        """Drain `src` into this writer, and return how many bytes moved.

        Go's `io.ReaderFrom`. Implement it when the writer can take bytes
        somewhere better than through its own `write`, which for a buffered
        writer means straight into the buffer without a copy, and set
        `READER_FROM`.

        Ends when `src` reports `EOF`, which is not an error here and is not
        reraised. Any other error from `src` comes out of this call, with the
        count that moved before it on `errors.partial`.
        """
        raise Report("io: this writer has no read_from").with_code(
            ErrUnsupported
        ).error()


trait Reader:
    """Somewhere bytes come from. Go's `io.Reader`.

    ```mojo
    from core.io import Reader


    def one[R: Reader](mut src: R) raises -> Int:
        var buf = List[UInt8](0, __list_literal__=None)
        return src.read(Span(buf))
    ```
    """

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """Read into `into` and return how many bytes arrived.

        **A read that moved bytes returns the count and does not raise.** It
        raises only when it moved nothing, so `EOF` always arrives with a count
        of zero and a caller never has to handle bytes and a failure at once.

        Go allows both together and then tells every caller to process the `n`
        before looking at the `err`, which is a rule a caller can forget and a
        familiar source of silently truncated data. A reader here that has bytes
        and a sticky failure returns the bytes now and raises on the next call,
        which is what Go's own `bufio` does anyway. See `deviations.md`.

        Reading into an empty span returns zero without raising, including at
        end of input, so a caller cannot use it to test for `EOF`.
        """
        ...

    def capabilities(self) -> Int:
        """Which of the optional methods below this type actually implements."""
        return 0

    def write_to[W: Writer](mut self, mut dst: W) raises -> Int64:
        """Push everything this reader has into `dst`, and return how much.

        Go's `io.WriterTo`. Implement it when the reader already has the bytes
        somewhere and can hand them over without a copy through a caller's
        buffer, which is the case for anything reading out of memory, and set
        `WRITER_TO`.

        Ends at this reader's own end of input, and does not raise `EOF` for
        it. `copy` prefers this over the writer's `read_from` when both are
        offered, matching Go.
        """
        raise Report("io: this reader has no write_to").with_code(
            ErrUnsupported
        ).error()


trait ReaderFrom:
    """A writer that can drain a reader itself. Go's `io.ReaderFrom`.

    The same method `Writer` already declares, under the name Go gives it, and
    that is the whole of it. A type writes `read_from` once and lists both
    traits; there is no second mechanism and no second signature.

    Which of the two names to use is a question about what a function needs
    rather than about what a type is. A function that only makes sense over a
    writer with a fast path takes `[W: ReaderFrom]` and the compiler enforces
    it. `copy` cannot do that, because it takes any writer and finds out at run
    time, which is what the capability bit is for. The bit stays the thing
    `copy` reads; this trait is a bound, not a second source of truth.

    A type must still set `READER_FROM` in `capabilities` to be found by
    `copy`. Conforming here and not setting the bit is legal and means the fast
    path is available to anyone who asks for it by name and invisible to
    anything that discovers it at run time.
    """

    def read_from[R: Reader](mut self, mut src: R) raises -> Int64:
        """Drain `src` into this writer, and return how many bytes moved."""
        ...


trait WriterTo:
    """A reader that can push itself into a writer. Go's `io.WriterTo`.

    `ReaderFrom` the other way round, and everything it says applies.
    """

    def write_to[W: Writer](mut self, mut dst: W) raises -> Int64:
        """Push everything this reader has into `dst`, and return how much."""
        ...


trait Closer:
    """Something with an end. Go's `io.Closer`.

    Closing twice is not defined here any more than it is in Go, and a type
    whose second close is harmless should say so in its own documentation.
    What is defined is that a close which fails says so: this library does not
    have Go's problem of a deferred `Close()` whose error goes nowhere, because
    there is no `defer`, cleanup is a `with` block, and a failure out of one
    reaches the caller.
    """

    def close(mut self) raises:
        """Release whatever this holds. A failure here is a real failure."""
        ...


trait ByteReader:
    """A reader that can hand over one byte. Go's `io.ByteReader`.

    Worth having as its own thing rather than a one byte `read`, because the
    types that implement it are sitting on a buffer and can answer without the
    span, the bounds check and the loop that a general `read` needs. Every
    parser in this library that walks input a byte at a time takes this.
    """

    def read_byte(mut self) raises -> Byte:
        """The next byte. Raises `EOF` at the end, like every read here."""
        ...


trait ByteScanner(ByteReader):
    """A `ByteReader` that can put one byte back. Go's `io.ByteScanner`.

    One byte, and only the one just read. That is Go's rule and it is the
    right one: a parser that has to look at the next byte to know whether it
    wanted it needs exactly this much lookahead, and anything more is a buffer
    the caller should be holding itself.
    """

    def unread_byte(mut self) raises:
        """Put the last byte read back. Raises if the last call was not a read.
        """
        ...


trait ByteWriter:
    """A writer that can take one byte. Go's `io.ByteWriter`."""

    def write_byte(mut self, c: Byte) raises:
        """Write one byte. Nothing to return: it went or it raised."""
        ...


trait RuneReader:
    """A reader that decodes UTF-8 as it goes. Go's `io.RuneReader`.

    Returns the rune and how many bytes it took, because a caller that is
    counting positions needs the width and cannot recover it from the rune
    without encoding it again.

    An invalid encoding is Go's replacement rune with a width of one, not a
    failure. That is deliberate and it is Go's behaviour: a decoder that raised
    on bad input would make every text tool in this library refuse whole files
    over one bad byte, and the replacement character is what the caller wants
    to see printed anyway.
    """

    def read_rune(mut self) raises -> Tuple[Int32, Int]:
        """The next rune and its width in bytes. Raises `EOF` at the end."""
        ...


trait RuneScanner(RuneReader):
    """A `RuneReader` that can put one rune back. Go's `io.RuneScanner`."""

    def unread_rune(mut self) raises:
        """Put the last rune read back. Raises if the last call was not a read.
        """
        ...


trait StringWriter:
    """A writer that can take a `String` without a copy. Go's `io.StringWriter`.

    Go's reason is that converting a string to a byte slice allocates. Mojo's
    is different and smaller: a `String` already knows its bytes and handing
    them over as a span is free, so this exists mostly so that `write_string`
    has something to look for. It is still worth having, because a writer that
    builds a string wants the string.
    """

    def write_string(mut self, s: String) raises -> Int:
        """Write `s` and return how many bytes were accepted."""
        ...


trait Seeker:
    """Something you can move around in. Go's `io.Seeker`.

    `whence` is `SEEK_START`, `SEEK_CURRENT` or `SEEK_END`, and the return is
    the new position from the start. Seeking before the start raises; seeking
    past the end is allowed and reading there gives nothing, which is what a
    file does.
    """

    def seek(mut self, offset: Int64, whence: Int) raises -> Int64:
        """Move to `offset` relative to `whence` and return the new position."""
        ...


trait ReaderAt:
    """A reader addressed by position rather than by a cursor. Go's `io.ReaderAt`.

    The one trait here with a concurrency promise attached: several calls may
    run at once on the same value, because none of them moves anything. That
    is what makes a `SectionReader` over one of these safe to hand to two
    readers at the same time, and a type that cannot keep the promise must not
    conform.

    Unlike `read`, this one reads until it has filled the span or run out, so a
    short result always means the end of the input.
    """

    def read_at[
        o: Origin[mut=True]
    ](self, into: Span[Byte, o], offset: Int64) raises -> Int:
        """Read at `offset` into `into`. `self` is immutable on purpose."""
        ...


trait WriterAt:
    """A writer addressed by position. Go's `io.WriterAt`.

    Go says two `WriteAt` calls on the same destination may run at once as
    long as their ranges do not overlap. That is a promise about the
    destination and not about the value, and Go can make it because its
    implementations write through a pointer while the interface value itself
    never changes.

    Here the receiver is `mut self`, unlike `ReaderAt`'s. Writing changes
    something by definition, and a sink that keeps its bytes in a field cannot
    change them through an immutable borrow without interior mutability, which
    this library does not have. So Go's allowance survives as a property of the
    destination, and the borrow checker will not let two calls overlap on one
    value anyway. Nothing is lost that could have been expressed.
    """

    def write_at[
        o: Origin
    ](mut self, data: Span[Byte, o], offset: Int64) raises -> Int:
        """Write `data` at `offset`, without moving any write position."""
        ...


trait ReadWriter(Reader, Writer):
    """Both directions on one value. Go's `io.ReadWriter`.

    The composed traits below are all this: a name for a set of bounds, no
    method of their own. Go needs them because an interface value can only be
    one type and a function taking two interfaces cannot be written; here they
    are a convenience, because `[T: Reader & Writer]` says the same thing.
    They exist anyway so that a port of Go code has the name it is looking for,
    and because a signature reads better with one bound than three.
    """

    pass


trait ReadCloser(Closer, Reader):
    """A reader with an end. Go's `io.ReadCloser`."""

    pass


trait WriteCloser(Closer, Writer):
    """A writer with an end. Go's `io.WriteCloser`."""

    pass


trait ReadWriteCloser(Closer, Reader, Writer):
    """Both directions, with an end. Go's `io.ReadWriteCloser`."""

    pass


trait ReadSeeker(Reader, Seeker):
    """A reader you can move around in. Go's `io.ReadSeeker`."""

    pass


trait WriteSeeker(Seeker, Writer):
    """A writer you can move around in. Go's `io.WriteSeeker`."""

    pass


trait ReadWriteSeeker(Reader, Seeker, Writer):
    """Both directions, seekable. Go's `io.ReadWriteSeeker`."""

    pass


trait ReadSeekCloser(Closer, Reader, Seeker):
    """A seekable reader with an end. Go's `io.ReadSeekCloser`."""

    pass
