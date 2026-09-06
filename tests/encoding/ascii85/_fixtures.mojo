"""The conversions, the readers and the writer the ascii85 tests share.

Every row of Go's `pairs` is printable text on both sides, which is unusual for
this directory and is what lets the assertions here compare strings rather than
hex. `strip85` is Go's own helper of the same name and it earns its place: the
encoded side of the big row is wrapped at seventy five characters and nothing
in this package writes those newlines, so the two sides of an assertion only
line up once the whitespace is out of both.

The stream fixtures are the ones `tests/encoding/hex` has. A copy rather than an
import, because a test package that reached into another test package would make
the two of them one thing.
"""

from core.errors import Report
from core.errors.codes import EOF
from core.io import Byte, Reader, Writer


def strip85[o: Origin](data: Span[Byte, o]) -> String:
    """`data` as text with the whitespace taken out. Go's `strip85`.

    Everything at or below a space goes, which is the same rule the decoder
    skips by, so what is left is exactly the characters that carry data.
    """
    var out = String()
    for b in data:
        if b > Byte(ord(" ")):
            out += chr(Int(b))
    return out^


def as_text(data: List[Byte]) raises -> String:
    """`data` as a string, for an assertion that prints something readable."""
    return String(from_utf8=Span(data))


def bytes_of(s: String) -> List[Byte]:
    """`s` as a list, which is what the calls here take."""
    var out = List[Byte]()
    for b in s.as_bytes():
        out.append(b)
    return out^


struct Fixed(Copyable, Movable, Reader):
    """A reader over a list that fills whatever span it is given."""

    var data: List[Byte]
    var pos: Int

    def __init__(out self, var data: List[Byte]):
        self.data = data^
        self.pos = 0

    def __init__(out self, s: String):
        self = Self(bytes_of(s))

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

    A group is five characters and this fixture never hands over more than one,
    so every group is split across five reads and the decoder has to hold four
    characters back to get through it.
    """

    var inner: Fixed

    def __init__(out self, var data: List[Byte]):
        self.inner = Fixed(data^)

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
