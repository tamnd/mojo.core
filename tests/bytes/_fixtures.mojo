"""What the `bytes` tests are written in terms of. Mostly two functions.

Go's `bytes` tests are string literals, because a Go `string` is arbitrary
bytes and `[]byte("012\\x80bcb")` is a legal way to write a byte slice with a
lone continuation byte in the middle of it. A Mojo `String` cannot hold that at
all, and half the value of Go's tables is in exactly those rows: the ones that
prove a function decoding UTF-8 does something defined with input that is not
UTF-8.

So the tables here are written in Go's own notation and `enc` expands it. A
row reads `enc("012\\x80bcb\\x80210")`, which is the Go literal with the
backslash doubled, and the result is a `List[Byte]`. Everything valid passes
through untouched, so a row with nothing interesting in it reads as the plain
string it is.

`quote` is the other half. Assertions compare quoted forms rather than byte
lists, because a failure then prints `a\\xffb` instead of a column of numbers,
and because a `String` cannot be built from the answers these functions give
for invalid input. `joined` does the same for a list of pieces, so one
assertion covers a whole split.
"""

from core.errors import Report
from core.errors.codes import EOF, ErrShortWrite
from core.io import Byte, Reader, Writer

comptime BAR = "|"
"""What `joined` puts between pieces. No table here contains one."""

comptime SPACE = "\\x09\\x0b\\x0d\\x0c\\x0a\\xc2\\x85\\xc2\\xa0\\xe2\\x80\\x80\\xe3\\x80\\x80"
"""Go's `space`: tab, vertical tab, return, form feed, newline, NEL, no-break
space, EN QUAD and IDEOGRAPHIC SPACE, in `enc` notation.

Written as bytes rather than as characters because four of the nine are
invisible and two of those are easy to confuse with the space this file is
indented with. Fifteen bytes, and the last rune is three of them, which two
tests assert on directly.
"""


def _hex(c: Byte) -> Int:
    """One hex digit as a number. Anything else is zero, and no table has one.
    """
    var v = Int(c)
    if v >= ord("0") and v <= ord("9"):
        return v - ord("0")
    if v >= ord("a") and v <= ord("f"):
        return v - ord("a") + 10
    if v >= ord("A") and v <= ord("F"):
        return v - ord("A") + 10
    return 0


def enc(s: String) -> List[Byte]:
    """The bytes of `s`, with `\\xNN` expanded. Go's byte string literal.

    Written in a Mojo source file as `enc("a\\\\xffb")`, which is Go's
    `[]byte("a\\xffb")` with the backslash doubled so that Mojo's own literal
    parser leaves it alone.
    """
    var raw = s.as_bytes()
    var out = List[Byte](capacity=len(raw))
    var i = 0
    while i < len(raw):
        var escape = (
            raw[i] == Byte(ord("\\"))
            and i + 3 < len(raw)
            and raw[i + 1] == Byte(ord("x"))
        )
        if escape:
            out.append(Byte(_hex(raw[i + 2]) * 16 + _hex(raw[i + 3])))
            i += 4
            continue
        out.append(raw[i])
        i += 1
    return out^


def _nibble(v: Int) -> String:
    """One hex digit as a character."""
    if v < 10:
        return chr(ord("0") + v)
    return chr(ord("a") + v - 10)


def quote[o: Origin](b: Span[Byte, o]) -> String:
    """`b` in the notation `enc` reads, so that the two sides of an assertion
    are written the same way.

    Printable ASCII stays as itself and everything else becomes `\\xNN`, which
    is Go's `%q` without the quotes and the only form that can name the bytes
    these tests are about.
    """
    var out = String("")
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 0x20 and c < 0x7F and c != ord("\\"):
            out += chr(c)
        else:
            out += "\\x" + _nibble(c >> 4) + _nibble(c & 15)
    return out^


def expect(s: String) -> String:
    """The `want` column of a table, written the way the input rows are.

    A table row says `"☺☻|"` and `joined` prints `"\\xe2\\x98\\xba..."`, so one
    of the two has to be converted before they can be compared. Converting the
    expectation is the direction that keeps the tables readable: a row still
    reads as the characters it is about, and a row that is about bytes still
    reads as `\\xNN` because expanding and requoting gives that back unchanged.

    The bar survives both steps — it is printable ASCII — so a whole split is
    one string on each side.
    """
    var raw = enc(s)
    return quote(Span(raw))


def joined[o: Origin](parts: List[Span[Byte, o]]) -> String:
    """The pieces, quoted, with a bar between them.

    Go compares a `[]string` against a `[]string`. One string against one
    string says the same thing, fails with both in the message, and does not
    need a per-element loop at every call site. The empty list is the empty
    string, and a list holding one empty piece is also the empty string, so the
    count is asserted separately wherever that difference is the point.
    """
    var out = String("")
    var first = True
    for piece in parts:
        if not first:
            out += BAR
        first = False
        out += quote(piece)
    return out^


struct Fixed(Copyable, Movable, Reader):
    """A reader that fills whatever span it is given, and counts the calls."""

    var data: List[Byte]
    var pos: Int
    var reads: Int

    def __init__(out self, var data: List[Byte]):
        self.data = data^
        self.pos = 0
        self.reads = 0

    def __init__(out self, s: String):
        self = Self(enc(s))

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        self.reads += 1
        if self.pos >= len(self.data):
            raise Report("fixture: end of input").with_code(EOF).error()
        var n = len(self.data) - self.pos
        if n > len(into):
            n = len(into)
        for i in range(n):
            into[i] = self.data[self.pos + i]
        self.pos += n
        return n


struct OneByte(Copyable, Movable, Reader):
    """A reader that hands back one byte a call. Go's `iotest.OneByteReader`.

    `read_from` is a loop around a source, so the version written as a single
    read passes over `Fixed` and loses everything after the first byte here.
    """

    var data: List[Byte]
    var pos: Int
    var reads: Int

    def __init__(out self, var data: List[Byte]):
        self.data = data^
        self.pos = 0
        self.reads = 0

    def __init__(out self, s: String):
        self = Self(enc(s))

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        self.reads += 1
        if self.pos >= len(self.data):
            raise Report("fixture: end of input").with_code(EOF).error()
        if len(into) == 0:
            return 0
        into[0] = self.data[self.pos]
        self.pos += 1
        return 1


struct Sink(Copyable, Movable, Writer):
    """A writer that keeps everything and counts the calls."""

    var data: List[Byte]
    var writes: Int

    def __init__(out self):
        self.data = List[Byte]()
        self.writes = 0

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        self.writes += 1
        for i in range(len(data)):
            self.data.append(data[i])
        return len(data)


struct Short(Copyable, Movable, Writer):
    """A writer that takes the first `limit` bytes and then refuses.

    A short write has to come out of `write_to` as a raise carrying the count,
    and the count has to be the number the writer really took, which is the one
    thing a test over a cooperative sink cannot check.
    """

    var data: List[Byte]
    var limit: Int

    def __init__(out self, limit: Int):
        self.data = List[Byte]()
        self.limit = limit

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        var room = self.limit - len(self.data)
        if room > len(data):
            room = len(data)
        for i in range(room):
            self.data.append(data[i])
        if room < len(data):
            raise (
                Report("fixture: the sink is full")
                .with_code(ErrShortWrite)
                .with_count(room)
                .error()
            )
        return room
