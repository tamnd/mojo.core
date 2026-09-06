"""The readers, the writer and the five spellings the base64 tests share.

Go's table of encodings pairs each one with a function that rewrites a standard
reference string into that encoding's spelling, so one table of pairs covers
all five. A function is not a value `tools/testgen` can carry across, so the
five conversions are here and the table is walked by index. `ref_for` is the
one that picks between them and it is what the loops in `test_base64.mojo`
call.

The three stream fixtures are the ones `tests/bufio` has, cut down to what is
used here. A copy rather than an import, because a test package that reached
into another test package would make the two of them one thing.
"""

from core.errors import Report
from core.errors.codes import EOF
from core.io import Byte, Reader, Writer

comptime STD = 0
"""`std_encoding`, whose spelling is the reference string as it stands."""

comptime URL = 1
"""`url_encoding`, which spells the last two symbols `-` and `_`."""

comptime RAW_STD = 2
"""`raw_std_encoding`, which is the standard one with the padding cut off."""

comptime RAW_URL = 3
"""`raw_url_encoding`, which is both of the above."""

comptime FUNNY = 4
"""The standard alphabet padded with `@`, which is Go's `funnyEncoding`."""


def std_ref(text: String) -> String:
    """Go's `stdRef`, which leaves a reference string alone."""
    return text


def url_ref(text: String) raises -> String:
    """Go's `urlRef`: `+` and `/` become `-` and `_`."""
    var out = List[Byte]()
    for b in text.as_bytes():
        if b == Byte(ord("+")):
            out.append(Byte(ord("-")))
        elif b == Byte(ord("/")):
            out.append(Byte(ord("_")))
        else:
            out.append(b)
    return String(from_utf8=Span(out))


def raw_ref(text: String) raises -> String:
    """Go's `rawRef`: the padding at the end comes off."""
    var raw = text.as_bytes()
    var end = len(raw)
    while end > 0 and raw[end - 1] == Byte(ord("=")):
        end -= 1
    return String(from_utf8=raw[0:end])


def raw_url_ref(text: String) raises -> String:
    """Go's `rawURLRef`, which is both conversions."""
    return raw_ref(url_ref(text))


def funny_ref(text: String) raises -> String:
    """Go's `funnyRef`: the padding is `@` rather than `=`."""
    var out = List[Byte]()
    for b in text.as_bytes():
        if b == Byte(ord("=")):
            out.append(Byte(ord("@")))
        else:
            out.append(b)
    return String(from_utf8=Span(out))


def ref_for(which: Int, text: String) raises -> String:
    """`text` as the encoding `which` would spell it."""
    if which == URL:
        return url_ref(text)
    if which == RAW_STD:
        return raw_ref(text)
    if which == RAW_URL:
        return raw_url_ref(text)
    if which == FUNNY:
        return funny_ref(text)
    return std_ref(text)


def as_text(data: List[Byte]) raises -> String:
    """An encoded row back as text, for an assertion that reads as prose."""
    return String(from_utf8=Span(data))


def as_hex(data: List[Byte]) raises -> String:
    """The same thing for bytes that are not text.

    Half of Go's rows have a decoded side that is not valid UTF-8, so an
    assertion about what came out of a decoder cannot go through `as_text`.
    Hex reads worse than prose but it prints, and a failure that prints is a
    failure somebody can read.
    """
    var digits = "0123456789abcdef".as_bytes()
    var out = List[Byte]()
    for b in data:
        out.append(digits[Int(b) >> 4])
        out.append(digits[Int(b) & 0xF])
    return String(from_utf8=Span(out))


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

    The decoder holds characters back until it has four of them, so this is the
    fixture that says the holding works. A decoder that assumed a read filled
    the span would decode the first byte of the input as a group of one.
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
