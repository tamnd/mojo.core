"""Readers and converters the flate tests share.

Go's tests reach for `bytes.NewReader` and `strings.NewReader`, and both of
those are here in `core.bytes` and `core.strings` already. What is not here is
Go's habit of testing a decompressor against a reader that hands over exactly
one byte at a time, which the truncation tests need to be honest: a
decompressor that only works when its input arrives in one piece is not
working. `Drip` is that reader.
"""

from core.encoding.hex import decode_string, encode_to_string
from core.errors import Code, ErrorValue, Report, capture, matches
from core.errors.codes import EOF
from core.io import Byte, Reader as IoReader
from core.compress.flate import Reader as FlateReader


struct Bytes(Copyable, FlateReader, Movable):
    """A list of bytes read from the front, in as few calls as possible.

    `core.bytes.Reader` is the same thing and is what the tests would use if a
    trait could be satisfied by a type that does not name it. It cannot here,
    so the tests carry their own.
    """

    var data: List[Byte]
    """The bytes."""

    var at: Int
    """Where the next read starts."""

    def __init__(out self, var data: List[Byte]):
        self.data = data^
        self.at = 0

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        if self.at >= len(self.data):
            raise Report("bytes: no more").with_code(EOF).error()
        if len(into) == 0:
            return 0
        var n = len(self.data) - self.at
        if n > len(into):
            n = len(into)
        for i in range(n):
            into[i] = self.data[self.at + i]
        self.at += n
        return n

    def read_byte(mut self) raises -> Byte:
        if self.at >= len(self.data):
            raise Report("bytes: no more").with_code(EOF).error()
        var c = self.data[self.at]
        self.at += 1
        return c


struct Drip(Copyable, FlateReader, Movable):
    """The same bytes, one per `read`. Go's tests do this by hand.

    A decompressor is a state machine over a stream that does not arrive all at
    once, and the interesting bugs are the ones where a step assumes its input
    was already there. Running the whole corpus through this as well as through
    `Bytes` is what says the resumption paths are real.
    """

    var data: List[Byte]
    """The bytes."""

    var at: Int
    """Where the next read starts."""

    def __init__(out self, var data: List[Byte]):
        self.data = data^
        self.at = 0

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        if self.at >= len(self.data):
            raise Report("drip: no more").with_code(EOF).error()
        if len(into) == 0:
            return 0
        into[0] = self.data[self.at]
        self.at += 1
        return 1

    def read_byte(mut self) raises -> Byte:
        if self.at >= len(self.data):
            raise Report("drip: no more").with_code(EOF).error()
        var c = self.data[self.at]
        self.at += 1
        return c


struct Drained(Movable):
    """What a reader produced, and what it stopped on.

    Go's `io.ReadAll` hands back the bytes and the failure together and
    `core.io.read_all` deliberately does not, because a caller who ignores the
    failure and keeps the bytes has a bug. The truncation tests are exactly the
    case that wants both, so they read in a loop of their own and this is what
    the loop returns.
    """

    var data: List[Byte]
    """Everything that came out before the stop."""

    var err: Optional[ErrorValue]
    """What stopped it. Always set, because a reader stops by raising."""

    def __init__(out self, var data: List[Byte], var err: Optional[ErrorValue]):
        self.data = data^
        self.err = err^

    def stopped_on(self, code: Code) raises -> Bool:
        """Whether the stop carries `code`."""
        if not self.err:
            return False
        return matches(self.err.value().error(), code)


def drain[R: IoReader](mut r: R) -> Drained:
    """Read until something raises, keeping both halves."""
    var out = List[Byte]()
    var buf = List[Byte](length=512, fill=0)
    while True:
        try:
            var n = r.read(Span(buf))
            for i in range(n):
                out.append(buf[i])
        except e:
            return Drained(out^, Optional[ErrorValue](capture(e)))


def unhex(s: StringSlice) raises -> List[Byte]:
    """The bytes a hex string spells. Go's `hex.DecodeString`."""
    return decode_string(s)


def as_hex(data: List[Byte]) raises -> String:
    """A hex string for the bytes. Go's `hex.EncodeToString`."""
    return encode_to_string(Span(data))


def as_bytes(s: StringSlice) -> List[Byte]:
    """The bytes of a string literal, as a list a reader can own."""
    return List[Byte](s.as_bytes())
