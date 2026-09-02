"""Combinators. Go's `MultiReader`, `MultiWriter`, `TeeReader`, `NopCloser`.

These are the four places in `io` where Go builds a new reader or writer out of
ones it was handed, and they are the four that have to hold their inputs
erased. `limit.mojo` can be generic over what it wraps because it wraps exactly
one thing; a multi reader wraps a list, a list has one element type, and a list
of different readers therefore needs `AnyReader`.

So these cost an indirect call per read, which is what they cost in Go too. The
difference is that here it is visible in the signature: a function that takes
`AnyReader` is saying it will pay for a table, and a function generic over
`Reader` is saying it will not.
"""

from core.errors import Report, matches, partial
from core.errors.codes import EOF, ErrNoProgress, ErrShortWrite

from .erased import AnyReader, AnyWriter
from .iface import Byte, READER_FROM, ReadCloser, Reader, Writer


struct _MultiReader(Copyable, Movable, Reader):
    """The sources in order, one after another. `multi_reader` builds it."""

    var sources: List[AnyReader]
    var at: Int

    def __init__(out self, var sources: List[AnyReader]):
        self.sources = sources^
        self.at = 0

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """Read from the current source, moving on when it ends.

        Go returns a zero and an `EOF` from an exhausted source and then tries
        the next one on the following call, so a multi reader over an empty
        reader and a full one hands back a zero in the middle. Here the loop
        keeps going instead, because a zero without an error is what
        `ErrNoProgress` is for and this would be producing one on purpose.
        """
        while self.at < len(self.sources):
            try:
                return self.sources[self.at].read(into)
            except e:
                if not matches(e, EOF):
                    raise e
            self.at += 1
        raise Report("io.multi_reader: all sources are spent").with_code(
            EOF
        ).error()


def multi_reader(var sources: List[AnyReader]) raises -> AnyReader:
    """The sources read end to end, as one reader. Go's `io.MultiReader`.

    ```mojo
    from core.io import AnyReader, multi_reader, read_all


    def joined(var a: AnyReader, var b: AnyReader) raises -> List[UInt8]:
        var both = multi_reader([a^, b^])
        return read_all(both)
    ```

    Go flattens a multi reader given to a multi reader, to keep a chain built
    one source at a time from nesting a thousand deep. There is nothing to
    flatten against here, because the erased value's type is gone by the time
    this sees it, so a chain built that way stays nested. Build the list
    instead, which is what the flattening is trying to make you do anyway.
    """
    return AnyReader(_MultiReader(sources^))


struct _MultiWriter(Copyable, Movable, Writer):
    """Every write goes to all of them. `multi_writer` builds it."""

    var sinks: List[AnyWriter]

    def __init__(out self, var sinks: List[AnyWriter]):
        self.sinks = sinks^

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        """Write to each sink in turn, and stop at the first failure.

        A failure part way through leaves the earlier sinks written to and the
        later ones not, which is Go's behaviour and unavoidable: there is no
        way to unwrite. The count on `errors.partial` is how many bytes the
        failing sink took, not how many sinks succeeded.
        """
        for ref sink in self.sinks:
            var n = sink.write(data)
            if n != len(data):
                raise (
                    Report(
                        "io.multi_writer: a sink took only part of the write"
                    )
                    .with_code(ErrShortWrite)
                    .with_count(n)
                    .error()
                )
        return len(data)


def multi_writer(var sinks: List[AnyWriter]) raises -> AnyWriter:
    """One writer that copies to all of them. Go's `io.MultiWriter`."""
    return AnyWriter(_MultiWriter(sinks^))


struct _TeeReader(Copyable, Movable, Reader):
    """Reads from the source and writes what it read. `tee_reader` builds it."""

    var src: AnyReader
    var dst: AnyWriter

    def __init__(out self, var src: AnyReader, var dst: AnyWriter):
        self.src = src^
        self.dst = dst^

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """Read, then write what arrived before handing it over.

        A failure out of the write comes out of the read, because a caller
        which got the bytes and never heard that the copy failed would be the
        whole hazard this exists to avoid.
        """
        var n = self.src.read(into)
        if n > 0:
            var wrote = self.dst.write(into[0:n])
            if wrote != n:
                raise (
                    Report("io.tee_reader: the sink took only part of the read")
                    .with_code(ErrShortWrite)
                    .with_count(wrote)
                    .error()
                )
        return n


def tee_reader(var src: AnyReader, var dst: AnyWriter) raises -> AnyReader:
    """A reader that writes to `dst` everything it reads. Go's `io.TeeReader`.

    The write happens on the way past, so nothing is buffered and nothing is
    written that was not also handed to the caller.
    """
    return AnyReader(_TeeReader(src^, dst^))


struct NopCloser[R: Reader & Deinitable & Movable](Movable, ReadCloser):
    """A reader given a `close` that does nothing. Go's `io.NopCloser`.

    Go returns this as an `io.ReadCloser` and keeps the type unexported. There
    is no erased `ReadCloser` here, so the type is the return type and has to
    have a name.

    Go's version also forwards `WriteTo` when the wrapped reader has one. This
    does not, and does not need to: `capabilities` is not overridden, so the
    fast path is simply not advertised, and `copy` uses the slow loop rather
    than calling a `write_to` that would be the trait's raising stub.
    """

    var r: Self.R
    """The wrapped reader."""

    def __init__(out self, var r: Self.R):
        self.r = r^

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        return self.r.read(into)

    def close(mut self) raises:
        """Nothing. That is the entire point of the type."""
        pass


def nop_closer[R: Reader & Deinitable & Movable](var r: R) -> NopCloser[R]:
    """Give `r` a `close` that does nothing. Go's `io.NopCloser`.

    For handing a reader to something that insists on closing what it is given,
    when the caller means to keep the reader afterwards.
    """
    return NopCloser(r^)


struct Discard(Copyable, Movable, Writer):
    """A writer that throws everything away. Go's `io.Discard`.

    Go's is a package level variable, because an `io.Writer` has to be a value
    and there is nothing to construct. Here it is a type with no fields, so it
    is `Discard()` at the use site rather than `io.Discard`, and the difference
    is one pair of brackets.

    It sets `READER_FROM` and implements `read_from`, which is what makes
    `copy(Discard(), src)` drain a reader without ever allocating a buffer.
    """

    def __init__(out self):
        pass

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        """Accept everything and keep none of it."""
        return len(data)

    def capabilities(self) -> Int:
        return READER_FROM

    def read_from[R: Reader](mut self, mut src: R) raises -> Int64:
        """Drain `src` through one small buffer that is never looked at."""
        var buf = List[Byte](capacity=_DRAIN)
        for _ in range(_DRAIN):
            buf.append(0)
        var moved = Int64(0)
        while True:
            var n: Int
            try:
                n = src.read(Span(buf))
            except e:
                if matches(e, EOF):
                    return moved
                raise Report("io.Discard: reading").wrapping(e).with_count(
                    Int(moved) + partial(e)
                ).error()
            if n == 0:
                raise (
                    Report("io.Discard: reader returned no bytes and no error")
                    .with_code(ErrNoProgress)
                    .with_count(Int(moved))
                    .error()
                )
            moved += Int64(n)


comptime _DRAIN = 8192
"""`Discard.read_from`'s buffer. Go uses the same number for the same reason:
nothing reads it, so it only has to be big enough to keep the call count down.
"""
