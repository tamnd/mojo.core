"""The readers, the writer and the two respellings the base32 tests share.

Go's tests reach for `strings.TrimRight` and `strings.ReplaceAll` to turn a row
of `pairs` into what an unpadded or oddly padded encoding would spell. Those two
live here as `raw_ref` and `at_ref` so the tables can be walked without them
being written out again in every loop.

The stream fixtures are the ones `tests/encoding/base64` has, which are the ones
`tests/bufio` has, cut down to what is used here. A copy rather than an import,
because a test package that reached into another test package would make the two
of them one thing.
"""

from core.errors import Report
from core.errors.codes import EOF
from core.io import Byte, Reader, Writer


def raw_ref(text: String) raises -> String:
    """Go's `strings.TrimRight(s, "=")`: the padding at the end comes off."""
    var raw = text.as_bytes()
    var end = len(raw)
    while end > 0 and raw[end - 1] == Byte(ord("=")):
        end -= 1
    return String(from_utf8=raw[0:end])


def at_ref(text: String) raises -> String:
    """The same row with `@` for `=`, which is Go's custom padding test."""
    var out = List[Byte]()
    for b in text.as_bytes():
        if b == Byte(ord("=")):
            out.append(Byte(ord("@")))
        else:
            out.append(b)
    return String(from_utf8=Span(out))


def as_text(data: List[Byte]) raises -> String:
    """A decoded row back as text, for an assertion that reads as prose.

    Every row of Go's base32 table is printable on both sides, unlike base64's,
    so this is the only conversion these tests need.
    """
    return String(from_utf8=Span(data))


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

    The decoder holds characters back until it has eight of them, so this is
    the fixture that says the holding works. A decoder that assumed a read
    filled the span would decode the first character of the input as a group of
    one.
    """

    var inner: Fixed

    def __init__(out self, s: String):
        self.inner = Fixed(s)

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        if len(into) == 0:
            return 0
        return self.inner.read(into[0:1])


struct Chunks(Copyable, Movable, Reader):
    """A reader that hands over one written down chunk per call.

    Go's `TestBufferedDecodingPadding` uses a pipe and a goroutine to make the
    decoder see a document arrive in pieces at the boundaries it chooses. There
    is no need for either here: the chunks are known in advance, so a reader
    that serves one of them per call is the same test without the concurrency.
    """

    var chunks: List[String]
    var at: Int

    def __init__(out self, var chunks: List[String]):
        self.chunks = chunks^
        self.at = 0

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        if self.at == len(self.chunks):
            raise Report("chunks: end").with_code(EOF).error()
        var chunk = self.chunks[self.at].as_bytes()
        var n = len(chunk)
        if n > len(into):
            n = len(into)
        for i in range(n):
            into[i] = chunk[i]
        if n == len(chunk):
            self.at += 1
        else:
            self.chunks[self.at] = String(from_utf8=chunk[n:])
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
