"""Integers that take as many bytes as they need. Go's `varint.go`.

Seven bits of the number to a byte, least significant seven first, and the top
bit of each byte says whether another one follows. So every number under a
hundred and twenty eight is one byte, which is what makes this worth having:
the field numbers, lengths and small counts that fill a protocol buffer or an
index file are nearly all small, and spending eight bytes on each of them is
most of the file.

```mojo
from core.encoding.binary import append_uvarint, uvarint


def round_trip(n: UInt64) raises -> UInt64:
    var buf = List[Byte]()
    _ = append_uvarint(buf, n)
    return uvarint(Span(buf))[0]
```

Signed numbers go through zig zag first: a number is doubled and a negative one
is then complemented, so that small negatives are small unsigned numbers rather
than the huge ones two's complement would make of them. Minus one is 1 and
minus two is 3, where sign extension would have written ten bytes of ones for
each.

Sixty four bits need ten bytes, because the ten sevens they are cut into are
seventy bits and the last byte carries a single one. Go's own note says the
format could have used the previous byte's top bit for it and stopped at nine,
and that it does not, because the top bit meaning continuation is the invariant
that lets the same encoding hold a number wider than sixty four bits one day.
That reasoning is why `MAX_VARINT_LEN64` is ten here as well.

## Refusing rather than returning a negative count

Go's `Uvarint` hands back a number and a count, and the count carries the
failures: zero means the buffer ran out and a negative one means the number did
not fit in sixty four bits, with its magnitude the bytes read. A caller who
does not look at the count gets zero and carries on.

Here the two are raises, and they are three codes rather than two, because the
first of Go's cases covers a distinction Go's own `ReadUvarint` makes and its
`Uvarint` does not: an empty span has nothing at all in it and raises `EOF`,
and a span that ends in the middle of a number raises `ErrUnexpectedEOF`. Both
mean the same thing to a caller reading a stream, that more bytes are needed,
and only one of them means it to a caller who was handed a whole record.
A number too wide raises `ErrVarintOverflow` with the bytes it read on
`errors.partial`, which is the magnitude of Go's negative count.
"""

from core.errors import Report, matches
from core.errors.codes import EOF, ErrUnexpectedEOF, ErrVarintOverflow
from core.io import Byte, ByteReader

comptime MAX_VARINT_LEN16 = 3
"""How many bytes a sixteen bit number can take. Go's `MaxVarintLen16`."""

comptime MAX_VARINT_LEN32 = 5
"""How many bytes a thirty two bit number can take. Go's `MaxVarintLen32`."""

comptime MAX_VARINT_LEN64 = 10
"""How many bytes a sixty four bit number can take. Go's `MaxVarintLen64`."""


def _overflow(used: Int) -> Error:
    """A number that needs more than sixty four bits, and how far it got.

    Go's message word for word, and the count is the magnitude of the negative
    one `Uvarint` returns.
    """
    return (
        Report("binary: varint overflows a 64-bit integer")
        .with_code(ErrVarintOverflow)
        .with_count(used)
        .error()
    )


def _truncated(used: Int) -> Error:
    """The input ended part way through a number.

    An empty input is `EOF`, since nothing was started, and anything else is
    `ErrUnexpectedEOF`, since something was. That is the split Go's
    `ReadUvarint` makes and this makes it in the span form too.
    """
    if used == 0:
        return (
            Report("binary: no varint to read")
            .with_code(EOF)
            .with_count(0)
            .error()
        )
    return (
        Report("binary: the input ended in the middle of a varint")
        .with_code(ErrUnexpectedEOF)
        .with_count(used)
        .error()
    )


def append_uvarint(mut dst: List[Byte], x: UInt64) -> Int:
    """Put `x` on the end of `dst` and say how many bytes that took.

    Go's `AppendUvarint` returns the grown slice. Growing a `List` in place is
    the same operation without the return, so this hands back the count, which
    is the rule every appending call in this library follows and is the one
    number a caller of this cannot work out for themselves.
    """
    var n = 0
    var v = x
    while v >= 0x80:
        dst.append(Byte(v) | 0x80)
        v >>= 7
        n += 1
    dst.append(Byte(v))
    return n + 1


def put_uvarint[o: Origin[mut=True]](buf: Span[Byte, o], x: UInt64) -> Int:
    """Write `x` into `buf` and say how many bytes that took. Go's `PutUvarint`.

    The caller has to have made room. `MAX_VARINT_LEN64` is always enough and
    is what Go's own examples size a buffer with; a caller who knows the number
    is under a hundred and twenty eight needs one byte. Too small a buffer runs
    off the end of the span, which aborts, the same as the panic Go documents.
    """
    var i = 0
    var v = x
    while v >= 0x80:
        buf[i] = Byte(v) | 0x80
        v >>= 7
        i += 1
    buf[i] = Byte(v)
    return i + 1


def uvarint[o: Origin](buf: Span[Byte, o]) raises -> Tuple[UInt64, Int]:
    """The number `buf` starts with, and how many bytes it took. Go's `Uvarint`.

    Bytes after the number are left alone, so a record holding several of them
    is a loop that slices off what the last call used.

    An input that ends part way through raises `ErrUnexpectedEOF`, an empty one
    raises `EOF`, and a number that does not fit in sixty four bits raises
    `ErrVarintOverflow`. The module docstring says why those are three codes
    where Go has one count with two meanings.
    """
    var x = UInt64(0)
    var s = UInt64(0)
    for i in range(len(buf)):
        if i == MAX_VARINT_LEN64:
            # Go grew this check after issue 41185: ten bytes is the whole of
            # what sixty four bits can take, so an eleventh byte is an overflow
            # even before its value is looked at, and without this the shift
            # below would be undefined rather than merely wrong.
            raise _overflow(i + 1)
        var b = buf[i]
        if b < 0x80:
            if i == MAX_VARINT_LEN64 - 1 and b > 1:
                # The tenth byte carries one bit of the number and nothing
                # else, so anything above one is a bit that has nowhere to go.
                raise _overflow(i + 1)
            return (x | (UInt64(b) << s), i + 1)
        x |= UInt64(b & 0x7F) << s
        s += 7
    raise _truncated(len(buf))


def append_varint(mut dst: List[Byte], x: Int64) -> Int:
    """Put `x` on the end of `dst` and say how many bytes that took.

    Go's `AppendVarint`, and the same thing this file's unsigned form says
    about returning a count rather than a slice.
    """
    return append_uvarint(dst, _zigzag(x))


def put_varint[o: Origin[mut=True]](buf: Span[Byte, o], x: Int64) -> Int:
    """Write `x` into `buf` and say how many bytes that took. Go's `PutVarint`.

    The caller has to have made room, the same as `put_uvarint`. Zig zag makes
    a small negative a small number, so minus one is one byte, but minus one
    followed by a doubling means the widest signed numbers still take ten.
    """
    return put_uvarint(buf, _zigzag(x))


def varint[o: Origin](buf: Span[Byte, o]) raises -> Tuple[Int64, Int]:
    """The number `buf` starts with, and how many bytes it took. Go's `Varint`.

    Zig zag undone, and the same three refusals as `uvarint`, which is where
    they are described.
    """
    var got = uvarint(buf)
    return (_unzigzag(got[0]), got[1])


def read_uvarint[R: ByteReader](mut r: R) raises -> UInt64:
    """Read one number from `r`. Go's `ReadUvarint`.

    One byte at a time and no further than the number goes, so a reader handed
    to this twice gives two numbers. `EOF` means nothing at all was there and
    `ErrUnexpectedEOF` means the reader stopped part way, which is Go's rule
    and is the reason a caller can tell an orderly end of stream apart from a
    truncated one.

    Go returns whatever it had assembled alongside the failure. A raise carries
    one value, and the half of a number is not a number, so this raises without
    it; the bytes consumed are on `errors.partial`.
    """
    var x = UInt64(0)
    var s = UInt64(0)
    for i in range(MAX_VARINT_LEN64):
        var b = Byte(0)
        try:
            b = r.read_byte()
        except e:
            if i > 0 and matches(e, EOF):
                raise _truncated(i)
            raise e
        if b < 0x80:
            if i == MAX_VARINT_LEN64 - 1 and b > 1:
                raise _overflow(i + 1)
            return x | (UInt64(b) << s)
        x |= UInt64(b & 0x7F) << s
        s += 7
    raise _overflow(MAX_VARINT_LEN64)


def read_varint[R: ByteReader](mut r: R) raises -> Int64:
    """Read one signed number from `r`. Go's `ReadVarint`.

    Zig zag undone, and the same refusals as `read_uvarint`.
    """
    return _unzigzag(read_uvarint(r))


def _zigzag(x: Int64) -> UInt64:
    """`x` as an unsigned number small negatives stay small in.

    Doubled, and complemented if it was negative, so the sign ends up in the
    lowest bit rather than in the top thirty of them.
    """
    var ux = UInt64(x) << 1
    if x < 0:
        return ~ux
    return ux


def _unzigzag(ux: UInt64) -> Int64:
    """`_zigzag` undone."""
    var x = Int64(ux >> 1)
    if ux & 1 != 0:
        return ~x
    return x
