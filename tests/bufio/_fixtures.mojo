"""The readers and writers the `bufio` tests are run through.

Go's `bufio` tests get most of their value from the sources that misbehave:
`iotest.OneByteReader`, `iotest.HalfReader`, `iotest.DataErrReader` and the
short writers. A buffered reader written as though every read fills the span
passes every test over `Fixed` and fails half of them over `Half`, which is the
entire reason these exist and the reason issue #14 names short reads.

`_fixtures.mojo` rather than one copy per file, because there are four test
files here and the same six types belong in all of them. `tests/io` defines its
own inside one file, which was right when there was one file.
"""

from core.errors import Report
from core.errors.codes import EOF, ErrShortWrite
from core.io import Byte, Reader, Writer

comptime NEWLINE = Byte(10)
"""`\\n`, spelled once so the tests read as prose rather than as numbers."""

comptime RETURN = Byte(13)
"""`\\r`."""


def as_bytes(s: String) -> List[Byte]:
    """The bytes of `s`, owned, because most of the fixtures want a list."""
    var out = List[Byte]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def as_text(data: List[Byte]) raises -> String:
    """A token back as text, for assertions that read better than byte lists."""
    return String(from_utf8=Span(data))


struct Fixed(Copyable, Movable, Reader):
    """A reader over a list that fills whatever span it is given.

    `reads` counts the calls, which is how the tests about buffering being
    worth anything are written: reading ten single bytes through a buffered
    reader has to touch this once.
    """

    var data: List[Byte]
    var pos: Int
    var reads: Int

    def __init__(out self, var data: List[Byte]):
        self.data = data^
        self.pos = 0
        self.reads = 0

    def __init__(out self, s: String):
        self = Self(as_bytes(s))

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        self.reads += 1
        var n = 0
        while n < len(into) and self.pos < len(self.data):
            into[n] = self.data[self.pos]
            n += 1
            self.pos += 1
        if n == 0 and len(into) > 0:
            raise Report("fixed: end").with_code(EOF).error()
        return n


struct Half(Copyable, Movable, Reader):
    """Go's `iotest.HalfReader`: never fills more than half the span."""

    var inner: Fixed

    def __init__(out self, var data: List[Byte]):
        self.inner = Fixed(data^)

    def __init__(out self, s: String):
        self = Self(as_bytes(s))

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        var want = (len(into) + 1) // 2
        return self.inner.read(into[0:want])


struct OneByte(Copyable, Movable, Reader):
    """Go's `iotest.OneByteReader`: one byte per read, however much was asked.

    The worst case a buffered reader is supposed to hide, and the one where a
    `read_slice` that only searched the bytes that had just arrived, or one
    that researched the whole window every time, both still pass — which is why
    there is a separate test counting the reads.
    """

    var inner: Fixed

    def __init__(out self, var data: List[Byte]):
        self.inner = Fixed(data^)

    def __init__(out self, s: String):
        self = Self(as_bytes(s))

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        if len(into) == 0:
            return 0
        return self.inner.read(into[0:1])


struct Broken(Copyable, Movable, Reader):
    """Hands over `data` and then fails with something that is not `EOF`.

    Go's `iotest.DataErrReader` delivers the data and the error in the same
    call, which `core.io` forbids: a read that moved bytes returns them. This
    is the same test in the shape this library allows, and the thing it checks
    is that the failure arrives after the bytes rather than instead of them.
    """

    var data: List[Byte]
    var pos: Int

    def __init__(out self, var data: List[Byte]):
        self.data = data^
        self.pos = 0

    def __init__(out self, s: String):
        self = Self(as_bytes(s))

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        if self.pos >= len(self.data):
            raise Report("broken: the device fell over").error()
        var n = 0
        while n < len(into) and self.pos < len(self.data):
            into[n] = self.data[self.pos]
            n += 1
            self.pos += 1
        return n


struct Sink(Copyable, Movable, Writer):
    """Keeps what it is given, and counts the calls."""

    var got: List[Byte]
    var writes: Int

    def __init__(out self):
        self.got = List[Byte]()
        self.writes = 0

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        self.writes += 1
        for b in data:
            self.got.append(b)
        return len(data)

    def text(self) raises -> String:
        return String(from_utf8=Span(self.got))


struct Cracked(Copyable, Movable, Writer):
    """Takes `ok` bytes in total and then fails, reporting what it did take."""

    var got: List[Byte]
    var ok: Int

    def __init__(out self, ok: Int):
        self.got = List[Byte]()
        self.ok = ok

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        var room = self.ok - len(self.got)
        if room > len(data):
            room = len(data)
        if room < 0:
            room = 0
        for i in range(room):
            self.got.append(data[i])
        if room < len(data):
            raise (
                Report("cracked: the sink is full")
                .with_code(ErrShortWrite)
                .with_count(room)
                .error()
            )
        return len(data)


struct Partial(Copyable, Movable, Writer):
    """Accepts half of every write and says so, without raising.

    `io.Writer`'s contract says a short write is a failure, so this is a sink
    that breaks the contract, and the point of it is that `Writer.flush` says
    `ErrShortWrite` rather than losing the rest quietly.
    """

    var got: List[Byte]

    def __init__(out self):
        self.got = List[Byte]()

    def text(self) raises -> String:
        return String(from_utf8=Span(self.got))

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        var take = (len(data) + 1) // 2
        for i in range(take):
            self.got.append(data[i])
        return take
