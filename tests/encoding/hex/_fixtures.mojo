"""The readers, the writer and the two conversions the hex tests share.

Go's `encDecTests` holds its decoded side as a byte slice, and `tools/testgen`
brings that across as a `List[UInt64]`, so `as_bytes` is what turns a row into
something to encode. `hex_of` goes the other way for an assertion, because half
the rows decode to bytes that are not text and comparing hex strings says which
byte differs where comparing raw bytes says only that they do.

The stream fixtures are the ones `tests/encoding/base32` has, cut down to what
is used here. A copy rather than an import, because a test package that reached
into another test package would make the two of them one thing.
"""

from core.errors import Report
from core.errors.codes import EOF
from core.io import Byte, Reader, Writer


def as_bytes(row: List[UInt64]) -> List[Byte]:
    """One row's decoded side as bytes, which is what the calls here take."""
    var out = List[Byte](capacity=len(row))
    for v in row:
        out.append(Byte(Int(v)))
    return out^


def hex_of(data: List[Byte]) -> String:
    """`data` spelled out, for an assertion that names the byte that differs.

    Written here rather than reached for from the package under test, since a
    test that checks a decoder with its own encoder proves only that the two
    agree.
    """
    comptime digits = "0123456789abcdef"
    var table = digits.as_bytes()
    var out = String()
    for b in data:
        out += chr(Int(table[Int(b >> 4)]))
        out += chr(Int(table[Int(b & 0x0F)]))
    return out^


struct Fixed(Copyable, Movable, Reader):
    """A reader over a list that fills whatever span it is given."""

    var data: List[Byte]
    var pos: Int

    def __init__(out self, var data: List[Byte]):
        self.data = data^
        self.pos = 0

    def __init__(out self, s: String):
        var bytes = List[Byte]()
        for b in s.as_bytes():
            bytes.append(b)
        self = Self(bytes^)

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        var n = 0
        while n < len(into) and self.pos < len(self.data):
            into[n] = self.data[self.pos]
            n += 1
            self.pos += 1
        if n == 0 and len(into) > 0:
            raise Report("fixed: end").with_code(EOF).error()
        return n


struct OneByte(Copyable, Movable, Reader):
    """Go's `iotest.OneByteReader`: one byte per read, however much was asked.

    The decoder holds a character back when a pair is split across two reads,
    and this is the fixture that says the holding works, since with one byte
    per read every pair is split.
    """

    var inner: Fixed

    def __init__(out self, s: String):
        self.inner = Fixed(s)

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        if len(into) == 0:
            return 0
        return self.inner.read(into[0:1])


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
