"""Which end of a number goes first. Go's `ByteOrder` and its three values.

A sixteen, thirty two or sixty four bit number is a sequence of bytes once it
leaves the machine, and there are two orders those bytes can go in. Big endian
puts the most significant byte first, which is what every network protocol
written since the seventies does and is why it is also called network order.
Little endian puts the least significant byte first, which is what x86 and
arm64 hold numbers as, so it is what a file written by a program that memcpyed
a struct into it holds.

Neither is more correct and both are still in use, so anything reading bytes it
did not write has to be told which one it is looking at. That is the whole of
what this file is: two orders, a third that names whichever one the machine
uses, and a trait so that code can be written once and told the order later.

```mojo
from core.encoding.binary import BigEndian


def port(header: Span[Byte, MutableAnyOrigin]) -> UInt16:
    return BigEndian().uint16(header[2:4])
```

Go's `ByteOrder` is an interface, so `binary.BigEndian` is a value a caller
passes at run time and every call through it is an indirect one. A trait here
is a constraint rather than a value, so `BigEndian` is an empty struct and the
generic function that takes it is compiled once per order with the shifts
inlined. A caller that genuinely has to choose at run time writes the branch
itself, which is one branch rather than one per call.

Go also has a second interface, `AppendByteOrder`, holding the three appending
methods. It is separate there because adding methods to `ByteOrder` after the
fact would have broken every type outside the standard library that implements
it. There is no such worry here, and the split is kept anyway, because the two
say different things: reading and writing into a buffer the caller sized, and
growing a buffer the caller owns.

None of these check the length of what they are handed. Go documents that as a
panic and gets one from the bounds check on the slice; Mojo aborts on the same
bounds check for the same reason. A caller reading a header out of bytes that
arrived from somewhere else checks the length once, before the four calls that
take it apart, rather than paying for it in each of them.
"""

from std.sys.info import is_big_endian

from core.io import Byte

comptime _NATIVE_IS_BIG = is_big_endian()
"""Whether this machine holds numbers most significant byte first.

Go picks between two files with a build tag. This is a compile time constant
and the branches on it fold away, which is the same thing without the files.
"""


trait ByteOrder(Writable):
    """Reading and writing fixed width numbers. Go's `binary.ByteOrder`.

    Six methods, three widths in each direction. Eight bit numbers are not here
    because one byte has no order to put it in, and Go leaves them out for the
    same reason.

    Signed numbers are not here either, and Go does not have them either: the
    bits of an `Int32` and a `UInt32` are the same bits, so a caller writes
    `Int32(order.uint32(b))` and gets two's complement without this having to
    have an opinion about it.
    """

    def uint16[o: Origin](self, b: Span[Byte, o]) -> UInt16:
        """The number the first two bytes of `b` spell."""
        ...

    def uint32[o: Origin](self, b: Span[Byte, o]) -> UInt32:
        """The number the first four bytes of `b` spell."""
        ...

    def uint64[o: Origin](self, b: Span[Byte, o]) -> UInt64:
        """The number the first eight bytes of `b` spell."""
        ...

    def put_uint16[o: Origin[mut=True]](self, b: Span[Byte, o], v: UInt16):
        """Spell `v` into the first two bytes of `b`."""
        ...

    def put_uint32[o: Origin[mut=True]](self, b: Span[Byte, o], v: UInt32):
        """Spell `v` into the first four bytes of `b`."""
        ...

    def put_uint64[o: Origin[mut=True]](self, b: Span[Byte, o], v: UInt64):
        """Spell `v` into the first eight bytes of `b`."""
        ...


trait AppendByteOrder(Writable):
    """Growing a buffer by one number. Go's `binary.AppendByteOrder`.

    Go's three return the grown slice, since appending to a Go slice may move
    it. Growing a `List` in place is the same operation without the return, and
    these are the one family of appending calls in this library that hands back
    nothing at all rather than a count: `append_uint32` writes four bytes, the
    name says four, and a count that is always four tells the caller nothing
    they did not type themselves.
    """

    def append_uint16(self, mut dst: List[Byte], v: UInt16):
        """Put the two bytes of `v` on the end of `dst`."""
        ...

    def append_uint32(self, mut dst: List[Byte], v: UInt32):
        """Put the four bytes of `v` on the end of `dst`."""
        ...

    def append_uint64(self, mut dst: List[Byte], v: UInt64):
        """Put the eight bytes of `v` on the end of `dst`."""
        ...


struct LittleEndian(
    AppendByteOrder, ByteOrder, Copyable, ImplicitlyCopyable, Movable
):
    """Least significant byte first. Go's `binary.LittleEndian`.

    What x86 and arm64 hold numbers as, so this is the order a file written by
    a program that copied a struct straight out of memory is in. It is also the
    order of every format designed on those machines: bitmaps, wav files, the
    ELF and PE headers of a little endian build, and the varints in this
    package's other half.
    """

    def __init__(out self):
        """An order carries nothing, so this exists only to spell the name."""
        pass

    def uint16[o: Origin](self, b: Span[Byte, o]) -> UInt16:
        """The number the first two bytes of `b` spell."""
        return UInt16(b[0]) | (UInt16(b[1]) << 8)

    def uint32[o: Origin](self, b: Span[Byte, o]) -> UInt32:
        """The number the first four bytes of `b` spell."""
        return (
            UInt32(b[0])
            | (UInt32(b[1]) << 8)
            | (UInt32(b[2]) << 16)
            | (UInt32(b[3]) << 24)
        )

    def uint64[o: Origin](self, b: Span[Byte, o]) -> UInt64:
        """The number the first eight bytes of `b` spell."""
        return (
            UInt64(b[0])
            | (UInt64(b[1]) << 8)
            | (UInt64(b[2]) << 16)
            | (UInt64(b[3]) << 24)
            | (UInt64(b[4]) << 32)
            | (UInt64(b[5]) << 40)
            | (UInt64(b[6]) << 48)
            | (UInt64(b[7]) << 56)
        )

    def put_uint16[o: Origin[mut=True]](self, b: Span[Byte, o], v: UInt16):
        """Spell `v` into the first two bytes of `b`."""
        b[0] = Byte(v)
        b[1] = Byte(v >> 8)

    def put_uint32[o: Origin[mut=True]](self, b: Span[Byte, o], v: UInt32):
        """Spell `v` into the first four bytes of `b`."""
        b[0] = Byte(v)
        b[1] = Byte(v >> 8)
        b[2] = Byte(v >> 16)
        b[3] = Byte(v >> 24)

    def put_uint64[o: Origin[mut=True]](self, b: Span[Byte, o], v: UInt64):
        """Spell `v` into the first eight bytes of `b`."""
        b[0] = Byte(v)
        b[1] = Byte(v >> 8)
        b[2] = Byte(v >> 16)
        b[3] = Byte(v >> 24)
        b[4] = Byte(v >> 32)
        b[5] = Byte(v >> 40)
        b[6] = Byte(v >> 48)
        b[7] = Byte(v >> 56)

    def append_uint16(self, mut dst: List[Byte], v: UInt16):
        """Put the two bytes of `v` on the end of `dst`."""
        dst.append(Byte(v))
        dst.append(Byte(v >> 8))

    def append_uint32(self, mut dst: List[Byte], v: UInt32):
        """Put the four bytes of `v` on the end of `dst`."""
        dst.append(Byte(v))
        dst.append(Byte(v >> 8))
        dst.append(Byte(v >> 16))
        dst.append(Byte(v >> 24))

    def append_uint64(self, mut dst: List[Byte], v: UInt64):
        """Put the eight bytes of `v` on the end of `dst`."""
        dst.append(Byte(v))
        dst.append(Byte(v >> 8))
        dst.append(Byte(v >> 16))
        dst.append(Byte(v >> 24))
        dst.append(Byte(v >> 32))
        dst.append(Byte(v >> 40))
        dst.append(Byte(v >> 48))
        dst.append(Byte(v >> 56))

    def write_to[W: Writer](self, mut writer: W):
        """`LittleEndian`, which is what Go's `String` method says."""
        writer.write("LittleEndian")


struct BigEndian(
    AppendByteOrder, ByteOrder, Copyable, ImplicitlyCopyable, Movable
):
    """Most significant byte first. Go's `binary.BigEndian`.

    Network order. Every header defined by an RFC is in it, which is why this
    is the order the TLS, DNS and HTTP/2 code above this reaches for, and it is
    also the order DER writes lengths and integers in, so the ASN.1 half of
    this milestone is built on it.
    """

    def __init__(out self):
        """An order carries nothing, so this exists only to spell the name."""
        pass

    def uint16[o: Origin](self, b: Span[Byte, o]) -> UInt16:
        """The number the first two bytes of `b` spell."""
        return UInt16(b[1]) | (UInt16(b[0]) << 8)

    def uint32[o: Origin](self, b: Span[Byte, o]) -> UInt32:
        """The number the first four bytes of `b` spell."""
        return (
            UInt32(b[3])
            | (UInt32(b[2]) << 8)
            | (UInt32(b[1]) << 16)
            | (UInt32(b[0]) << 24)
        )

    def uint64[o: Origin](self, b: Span[Byte, o]) -> UInt64:
        """The number the first eight bytes of `b` spell."""
        return (
            UInt64(b[7])
            | (UInt64(b[6]) << 8)
            | (UInt64(b[5]) << 16)
            | (UInt64(b[4]) << 24)
            | (UInt64(b[3]) << 32)
            | (UInt64(b[2]) << 40)
            | (UInt64(b[1]) << 48)
            | (UInt64(b[0]) << 56)
        )

    def put_uint16[o: Origin[mut=True]](self, b: Span[Byte, o], v: UInt16):
        """Spell `v` into the first two bytes of `b`."""
        b[0] = Byte(v >> 8)
        b[1] = Byte(v)

    def put_uint32[o: Origin[mut=True]](self, b: Span[Byte, o], v: UInt32):
        """Spell `v` into the first four bytes of `b`."""
        b[0] = Byte(v >> 24)
        b[1] = Byte(v >> 16)
        b[2] = Byte(v >> 8)
        b[3] = Byte(v)

    def put_uint64[o: Origin[mut=True]](self, b: Span[Byte, o], v: UInt64):
        """Spell `v` into the first eight bytes of `b`."""
        b[0] = Byte(v >> 56)
        b[1] = Byte(v >> 48)
        b[2] = Byte(v >> 40)
        b[3] = Byte(v >> 32)
        b[4] = Byte(v >> 24)
        b[5] = Byte(v >> 16)
        b[6] = Byte(v >> 8)
        b[7] = Byte(v)

    def append_uint16(self, mut dst: List[Byte], v: UInt16):
        """Put the two bytes of `v` on the end of `dst`."""
        dst.append(Byte(v >> 8))
        dst.append(Byte(v))

    def append_uint32(self, mut dst: List[Byte], v: UInt32):
        """Put the four bytes of `v` on the end of `dst`."""
        dst.append(Byte(v >> 24))
        dst.append(Byte(v >> 16))
        dst.append(Byte(v >> 8))
        dst.append(Byte(v))

    def append_uint64(self, mut dst: List[Byte], v: UInt64):
        """Put the eight bytes of `v` on the end of `dst`."""
        dst.append(Byte(v >> 56))
        dst.append(Byte(v >> 48))
        dst.append(Byte(v >> 40))
        dst.append(Byte(v >> 32))
        dst.append(Byte(v >> 24))
        dst.append(Byte(v >> 16))
        dst.append(Byte(v >> 8))
        dst.append(Byte(v))

    def write_to[W: Writer](self, mut writer: W):
        """`BigEndian`, which is what Go's `String` method says."""
        writer.write("BigEndian")


struct NativeEndian(
    AppendByteOrder, ByteOrder, Copyable, ImplicitlyCopyable, Movable
):
    """Whichever order this machine uses. Go's `binary.NativeEndian`.

    The one order that is not a wire format. It is here for reading a file some
    other program on the same machine wrote by copying a struct into it, and
    for nothing else: bytes written through this on one machine and read
    through it on another are read wrong on any pair of machines that disagree,
    silently and with no way to tell from the bytes.

    Every branch below is on a compile time constant, so this costs exactly
    what naming the right order directly would.
    """

    def __init__(out self):
        """An order carries nothing, so this exists only to spell the name."""
        pass

    def uint16[o: Origin](self, b: Span[Byte, o]) -> UInt16:
        """The number the first two bytes of `b` spell."""
        comptime if _NATIVE_IS_BIG:
            return BigEndian().uint16(b)
        else:
            return LittleEndian().uint16(b)

    def uint32[o: Origin](self, b: Span[Byte, o]) -> UInt32:
        """The number the first four bytes of `b` spell."""
        comptime if _NATIVE_IS_BIG:
            return BigEndian().uint32(b)
        else:
            return LittleEndian().uint32(b)

    def uint64[o: Origin](self, b: Span[Byte, o]) -> UInt64:
        """The number the first eight bytes of `b` spell."""
        comptime if _NATIVE_IS_BIG:
            return BigEndian().uint64(b)
        else:
            return LittleEndian().uint64(b)

    def put_uint16[o: Origin[mut=True]](self, b: Span[Byte, o], v: UInt16):
        """Spell `v` into the first two bytes of `b`."""
        comptime if _NATIVE_IS_BIG:
            BigEndian().put_uint16(b, v)
        else:
            LittleEndian().put_uint16(b, v)

    def put_uint32[o: Origin[mut=True]](self, b: Span[Byte, o], v: UInt32):
        """Spell `v` into the first four bytes of `b`."""
        comptime if _NATIVE_IS_BIG:
            BigEndian().put_uint32(b, v)
        else:
            LittleEndian().put_uint32(b, v)

    def put_uint64[o: Origin[mut=True]](self, b: Span[Byte, o], v: UInt64):
        """Spell `v` into the first eight bytes of `b`."""
        comptime if _NATIVE_IS_BIG:
            BigEndian().put_uint64(b, v)
        else:
            LittleEndian().put_uint64(b, v)

    def append_uint16(self, mut dst: List[Byte], v: UInt16):
        """Put the two bytes of `v` on the end of `dst`."""
        comptime if _NATIVE_IS_BIG:
            BigEndian().append_uint16(dst, v)
        else:
            LittleEndian().append_uint16(dst, v)

    def append_uint32(self, mut dst: List[Byte], v: UInt32):
        """Put the four bytes of `v` on the end of `dst`."""
        comptime if _NATIVE_IS_BIG:
            BigEndian().append_uint32(dst, v)
        else:
            LittleEndian().append_uint32(dst, v)

    def append_uint64(self, mut dst: List[Byte], v: UInt64):
        """Put the eight bytes of `v` on the end of `dst`."""
        comptime if _NATIVE_IS_BIG:
            BigEndian().append_uint64(dst, v)
        else:
            LittleEndian().append_uint64(dst, v)

    def write_to[W: Writer](self, mut writer: W):
        """`NativeEndian`, which is what Go's `String` method says.

        Go says the same on both kinds of machine, so this does too. A caller
        who wants to know which order that actually is asks the order it means
        rather than reading this.
        """
        writer.write("NativeEndian")
