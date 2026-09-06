"""A hex dump in the layout `hexdump -C` prints. Go's `Dump` and `Dumper`.

```
00000000  1e 1f 20 21 22 23 24 25  26 27 28 29 2a 2b 2c 2d  |.. !"#$%&'()*+,-|
```

Sixteen bytes to the line: the offset in hex, the bytes in two groups of eight,
then the same bytes as text with everything outside printable ASCII shown as a
full stop. `dump` gives the whole thing as a `String` and `dumper` writes it as
it goes, for input too large to hold or not yet arrived.

The layout is fixed to the byte, including the two spaces after the offset and
the extra one between the two groups, because the value of a dump is that it
lines up with every other tool that prints one.
"""

from core.errors import Report
from core.errors.codes import ErrDumperClosed
from core.io import Byte, Closer, Writer as IoWriter

from .hex import encode

comptime _SPACE = Byte(ord(" "))
"""The separator, and what a short last line is padded with."""

comptime _BAR = Byte(ord("|"))
"""What the text column is fenced with."""

comptime _NEWLINE = Byte(ord("\n"))
"""The end of a line, including the last one."""

comptime _DOT = Byte(ord("."))
"""What a byte outside printable ASCII shows as in the text column."""


def _to_char(b: Byte) -> Byte:
    """`b` if it is printable ASCII, a full stop otherwise. Go's `toChar`.

    Printable here means 32 through 126, which is Go's rule and is narrower
    than `unicode.IsPrint`. A dump is a grid and a character that is not one
    byte wide on the terminal would break it, so anything above ASCII is a dot
    however printable it is on its own.
    """
    if b < 32 or b > 126:
        return _DOT
    return b


struct Dumper[W: IoWriter & Deinitable & Movable](Closer, IoWriter, Movable):
    """A dump written as it goes. Go's `Dumper`.

    ```mojo
    from core.encoding.hex import dumper
    from core.io import AnyWriter


    def dump_into(var dst: AnyWriter, data: Span[UInt8, MutableAnyOrigin]):
        var d = dumper(dst^)
        _ = d.write(data)
        d.close()
    ```

    **It has to be closed.** The last line is short unless the input happened
    to be a multiple of sixteen bytes, and `close` is what pads it and writes
    the text column and the final newline. Writing after closing raises, since
    the offsets of anything written then would be the offsets of nothing.
    """

    var w: Self.W
    """Where the dump goes. Owned, so the call through is direct."""

    var right: List[Byte]
    """The text column of the line being built, plus its bar and newline."""

    var buf: List[Byte]
    """Scratch for the piece of the line being written. Go's `buf`."""

    var offset: List[Byte]
    """The four bytes of the current offset, before they are encoded.

    Go keeps these in the front of `buf` and encodes them into the back of the
    same array. Two spans of one field cannot be taken at once here, one to
    read and one to write, so the four bytes live in a field of their own.
    """

    var used: Int
    """How many bytes of the current line are filled. Go's `used`."""

    var n: Int
    """How many bytes have been dumped in total. Go's `n`."""

    var closed: Bool
    """Whether `close` has run. Go's `closed`."""

    def __init__(out self, var w: Self.W):
        """Dump into `w`. `dumper` is Go's name for this."""
        self.w = w^
        self.right = List[Byte](length=18, fill=0)
        self.buf = List[Byte](length=14, fill=0)
        self.offset = List[Byte](length=4, fill=0)
        self.used = 0
        self.n = 0
        self.closed = False

    def _send(mut self, start: Int, end: Int, accepted: Int) raises:
        """Write `buf[start:end]`, blaming the caller's count if it fails."""
        try:
            _ = self.w.write(Span(self.buf)[start:end])
        except e:
            raise (
                Report("hex.dumper: writing")
                .wrapping(e)
                .with_count(accepted)
                .error()
            )

    def _send_right(mut self, count: Int, accepted: Int) raises:
        """Write the first `count` bytes of the text column, the same way."""
        try:
            _ = self.w.write(Span(self.right)[0:count])
        except e:
            raise (
                Report("hex.dumper: writing")
                .wrapping(e)
                .with_count(accepted)
                .error()
            )

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        """Dump `data` and return how many bytes of it were taken. Go's `Write`.

        A line is written a piece at a time rather than assembled and written
        once, which is Go's shape. It costs several small writes per line and
        buys back the property that a dumper holds no line buffer, so the only
        state between calls is the sixteen characters of the text column.
        """
        if self.closed:
            raise (
                Report("encoding/hex: dumper closed")
                .with_code(ErrDumperClosed)
                .error()
            )

        var taken = 0
        for i in range(len(data)):
            if self.used == 0:
                # A new line starts with the offset in eight hex digits and
                # two spaces.
                self.offset[0] = Byte((self.n >> 24) & 0xFF)
                self.offset[1] = Byte((self.n >> 16) & 0xFF)
                self.offset[2] = Byte((self.n >> 8) & 0xFF)
                self.offset[3] = Byte(self.n & 0xFF)
                _ = encode(Span(self.buf)[4:], Span(self.offset))
                self.buf[12] = _SPACE
                self.buf[13] = _SPACE
                self._send(4, 14, taken)

            _ = encode(Span(self.buf), data[i : i + 1])
            self.buf[2] = _SPACE
            var width = 3
            if self.used == 7:
                # An extra space between the two groups of eight.
                self.buf[3] = _SPACE
                width = 4
            elif self.used == 15:
                # And an extra space and the bar before the text column.
                self.buf[3] = _SPACE
                self.buf[4] = _BAR
                width = 5
            self._send(0, width, taken)

            taken += 1
            self.right[self.used] = _to_char(data[i])
            self.used += 1
            self.n += 1
            if self.used == 16:
                self.right[16] = _BAR
                self.right[17] = _NEWLINE
                self._send_right(18, taken)
                self.used = 0
        return taken

    def close(mut self) raises:
        """Finish the last line. Go's `Close`.

        Closing twice writes nothing the second time, which is what Go's does
        and is why a dumper can be closed on the way out of a function that
        already closed it. Writing after closing is the case that raises.
        """
        if self.closed:
            return
        self.closed = True
        if self.used == 0:
            return

        # The columns the missing bytes would have filled, as spaces, then the
        # text column cut to the length of the line that is really there.
        self.buf[0] = _SPACE
        self.buf[1] = _SPACE
        self.buf[2] = _SPACE
        self.buf[3] = _SPACE
        self.buf[4] = _BAR
        var have = self.used
        while self.used < 16:
            var width = 3
            if self.used == 7:
                width = 4
            elif self.used == 15:
                width = 5
            self._send(0, width, 0)
            self.used += 1
        self.right[have] = _BAR
        self.right[have + 1] = _NEWLINE
        self._send_right(have + 2, 0)


def dumper[W: IoWriter & Deinitable & Movable](var w: W) -> Dumper[W]:
    """A dumper writing into `w`. Go's `Dumper`.

    The caller must `close` it, or the last line is never finished.
    """
    return Dumper[W](w^)


struct _Collect(IoWriter, Movable):
    """A writer that keeps what it is given, for `dump` to read back."""

    var got: List[Byte]
    """Everything written so far."""

    def __init__(out self):
        self.got = List[Byte]()

    def write[o: Origin](mut self, data: Span[Byte, o]) -> Int:
        for b in data:
            self.got.append(b)
        return len(data)


def dump[o: Origin](data: Span[Byte, o]) raises -> String:
    """`data` as a hex dump. Go's `Dump`.

    Empty input gives an empty string rather than an empty line, which is Go's
    answer and the one that makes a dump of nothing concatenate cleanly with
    whatever is printed around it.
    """
    if len(data) == 0:
        return String()
    var d = dumper(_Collect())
    _ = d.write(data)
    d.close()
    return String(from_utf8_lossy=d.w.got)
