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
