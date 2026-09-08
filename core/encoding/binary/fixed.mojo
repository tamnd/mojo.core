"""Whole values as bytes. Go's `Read`, `Write`, `Size`, `Encode`, `Decode` and
`Append`.

The other half of this package moves one number at a time and the caller says
which width. These six move a value, or a run of values, and take the width
from the type. Go works that out by walking the type while the program runs.
There is no such walk here, so the type is a parameter and the walk happens
while the program is built.

```mojo
from core.encoding.binary import BigEndian, append, size


def frame(mut out: List[Byte], samples: Span[Int16, MutableAnyOrigin]) raises:
    _ = append(out, BigEndian(), UInt32(size(samples)))
    _ = append(out, BigEndian(), samples)
```

Go's own implementation is the argument for the shape of this. Every one of
its six starts with a fast path, `intDataSize` and `encodeFast`, that handles a
bool, a sized integer, a float, and a slice of any of those, without touching
reflection at all; reflection is the fallback for a struct or an array. What is
here is that fast path, with the type switch that Go does at run time done by
overload resolution instead, so the bytes are the same bytes and the shifts are
inlined. Structs are the part that is missing, and a caller who has one writes
the calls a field at a time or generates them, one encoder per struct, which is
the same division the JSON codec makes.

## What counts as a fixed size value

A `Scalar[dtype]` whose width is one, two, four or eight bytes, and a `Span` of
them. That is Go's set with two differences worth knowing.

Go's `int` and `uint` are not fixed size, because they are thirty two bits on
one machine and sixty four on another, and Go refuses them so that a file
written on one machine reads on the other. Mojo's `Int` and `UInt` are the same
two types and they are refused here for the same reason, and refused more
firmly: they are not `Scalar` at all, so `write(w, order, 3)` does not compile
rather than failing when it runs. `Int64(3)` is what a caller means.

The narrow floats Mojo has and Go does not are allowed, since a float16 is two
bytes with an order to put them in like anything else. The hundred and twenty
eight and two hundred and fifty six bit integers are refused, because a
`ByteOrder` has no method that wide and inventing one here would be inventing a
wire format rather than porting one.

A refused type is not a compile error, because Mojo 1.0 has no way to make one.
It is Go's answer instead: `size` gives back -1, which is exactly what Go's
`Size` does for a type it cannot measure, and the other five raise with Go's
message.
"""

from std.memory import bitcast
from std.sys import bit_width_of

from core.errors import Report
from core.errors.codes import ErrShortBuffer
from core.io import Byte, Reader, Writer, read_full

from .order import ByteOrder


def _width[dtype: DType]() -> Int:
    """How many bytes one `dtype` takes on the wire, or -1 if it is not fixed.

    Go's `dataSize` answers the same question about a `reflect.Value` and
    returns -1 the same way. The difference is when: this is folded while the
    program is built, so a caller who wrote a width into a header beside the
    data gets a constant rather than a call.
    """
    comptime bits = bit_width_of[dtype]()
    if bits == 8 or bits == 16 or bits == 32 or bits == 64:
        return bits // 8
    return -1


def _unsupported(entry: StaticString, dtype: DType) -> Error:
    """A type this cannot measure, named the way Go names it.

    Go prints the Go type after its message, which it has because it got there
    through an `any`. The `DType` is the same information here.
    """
    return Report(
        String(
            "binary.",
            entry,
            ": some values are not fixed-sized in type ",
            dtype,
        )
    ).error()


def _too_small() -> Error:
    """A buffer with no room for what was asked of it.

    Go's `errBufferTooSmall`, whose text carries no package name because Go
    never wrapped it in one. The code is `ErrShortBuffer`, which is what a
    caller matches on and is the sentinel Go's own `io` uses for this.
    """
    return Report("buffer too small").with_code(ErrShortBuffer).error()


def _put[
    dtype: DType, O: ByteOrder, o: Origin[mut=True]
](b: Span[Byte, o], order: O, v: Scalar[dtype]):
    """One value into the first `_width[dtype]()` bytes of `b`.

    A bool is one byte, one for true and zero for false, which is Go's rule.
    Everything else is its bits under the given order, and the bits of a
    signed integer and a float are had by reinterpreting rather than by
    converting, so a negative number keeps its two's complement and a float
    keeps its payload, including a NaN's.
    """
    comptime if dtype == DType.bool:
        b[0] = Byte(1) if v else Byte(0)
    elif _width[dtype]() == 1:
        b[0] = bitcast[DType.uint8](v)
    elif _width[dtype]() == 2:
        order.put_uint16(b, bitcast[DType.uint16](v))
    elif _width[dtype]() == 4:
        order.put_uint32(b, bitcast[DType.uint32](v))
    else:
        order.put_uint64(b, bitcast[DType.uint64](v))


def _get[
    dtype: DType, O: ByteOrder, o: Origin
](b: Span[Byte, o], order: O) -> Scalar[dtype]:
    """One value out of the first `_width[dtype]()` bytes of `b`.

    Go decodes a bool as false for a zero byte and true for any other, rather
    than refusing the bytes that are neither zero nor one, and that is kept:
    the data being read was written by somebody else and a C program writing a
    bool writes whatever its compiler felt like.
    """
    comptime if dtype == DType.bool:
        return rebind[Scalar[dtype]](b[0] != Byte(0))
    elif _width[dtype]() == 1:
        return bitcast[dtype](b[0])
    elif _width[dtype]() == 2:
        return bitcast[dtype](order.uint16(b))
    elif _width[dtype]() == 4:
        return bitcast[dtype](order.uint32(b))
    else:
        return bitcast[dtype](order.uint64(b))


def size[dtype: DType](v: Scalar[dtype]) -> Int:
    """How many bytes `v` takes. Go's `Size`.

    -1 for a type with no fixed size, which is Go's answer and is the only
    thing any of these six can say about one.
    """
    return _width[dtype]()


def size[dtype: DType, o: Origin](v: Span[Scalar[dtype], o]) -> Int:
    """How many bytes the whole span takes. Go's `Size` over a slice.

    -1 if the element type has no fixed size, however many elements there are,
    which is Go's answer as well. An empty span of a good type is zero rather
    than -1, since nothing is a fixed number of bytes.
    """
    comptime width = _width[dtype]()
    comptime if width < 0:
        return -1
    return width * len(v)


def encode[
    dtype: DType, O: ByteOrder, o: Origin[mut=True]
](buf: Span[Byte, o], order: O, v: Scalar[dtype]) raises -> Int:
    """`v` into the front of `buf`, and how many bytes that took. Go's
    `Encode`.

    Raises rather than writing a prefix when `buf` is too small, so a caller
    never finds half a value in a buffer they will go on to use.
    """
    comptime width = _width[dtype]()
    comptime if width < 0:
        raise _unsupported("Encode", dtype)
    else:
        if len(buf) < width:
            raise _too_small()
        _put(buf, order, v)
        return width


def encode[
    dtype: DType, O: ByteOrder, o: Origin[mut=True], p: Origin
](buf: Span[Byte, o], order: O, v: Span[Scalar[dtype], p]) raises -> Int:
    """A whole span into the front of `buf`. Go's `Encode` over a slice."""
    comptime width = _width[dtype]()
    comptime if width < 0:
        raise _unsupported("Encode", dtype)
    else:
        var wanted = width * len(v)
        if len(buf) < wanted:
            raise _too_small()
        for i in range(len(v)):
            _put(buf[i * width : (i + 1) * width], order, v[i])
        return wanted


def decode[
    dtype: DType, O: ByteOrder, o: Origin
](buf: Span[Byte, o], order: O, mut v: Scalar[dtype]) raises -> Int:
    """The front of `buf` into `v`, and how many bytes that took. Go's
    `Decode`.

    Go takes a pointer here because that is the only way to hand a value back
    through an `any`. This takes the destination as a `mut` argument, which is
    the same thing said in the language rather than through a type erased
    indirection.
    """
    comptime width = _width[dtype]()
    comptime if width < 0:
        raise _unsupported("Decode", dtype)
    else:
        if len(buf) < width:
            raise _too_small()
        v = _get[dtype](buf, order)
        return width


def decode[
    dtype: DType, O: ByteOrder, o: Origin, p: Origin[mut=True]
](buf: Span[Byte, o], order: O, v: Span[Scalar[dtype], p]) raises -> Int:
    """The front of `buf` into every element of `v`.

    The span says how many values to read, exactly as the length of Go's slice
    does. Nothing is appended and nothing is grown.
    """
    comptime width = _width[dtype]()
    comptime if width < 0:
        raise _unsupported("Decode", dtype)
    else:
        var wanted = width * len(v)
        if len(buf) < wanted:
            raise _too_small()
        for i in range(len(v)):
            v[i] = _get[dtype](buf[i * width : (i + 1) * width], order)
        return wanted


def append[
    dtype: DType, O: ByteOrder
](mut buf: List[Byte], order: O, v: Scalar[dtype]) raises -> Int:
    """`v` on the end of `buf`, and how many bytes that took. Go's `Append`.

    Go hands back the grown slice because appending to a Go slice may move it.
    Growing a `List` in place is the same operation without the return, so this
    hands back the count instead, which is what every appending call in this
    library does.
    """
    comptime width = _width[dtype]()
    comptime if width < 0:
        raise _unsupported("Append", dtype)
    else:
        var at = len(buf)
        buf.resize(at + width, 0)
        _put(Span(buf)[at : at + width], order, v)
        return width


def append[
    dtype: DType, O: ByteOrder, p: Origin
](mut buf: List[Byte], order: O, v: Span[Scalar[dtype], p]) raises -> Int:
    """A whole span on the end of `buf`. Go's `Append` over a slice."""
    comptime width = _width[dtype]()
    comptime if width < 0:
        raise _unsupported("Append", dtype)
    else:
        var at = len(buf)
        var wanted = width * len(v)
        buf.resize(at + wanted, 0)
        for i in range(len(v)):
            _put(Span(buf)[at + i * width : at + (i + 1) * width], order, v[i])
        return wanted


def write[
    W: Writer, O: ByteOrder, dtype: DType
](mut w: W, order: O, v: Scalar[dtype]) raises:
    """`v` written to `w`. Go's `Write`.

    One `write` call for the whole value, as Go does, so a value never arrives
    at the far end of a socket split across two packets by this library's own
    doing.
    """
    comptime width = _width[dtype]()
    comptime if width < 0:
        raise _unsupported("Write", dtype)
    else:
        var buf = List[Byte](length=width, fill=0)
        _put(Span(buf), order, v)
        _ = w.write(Span(buf))


def write[
    W: Writer, O: ByteOrder, dtype: DType, p: Origin
](mut w: W, order: O, v: Span[Scalar[dtype], p]) raises:
    """A whole span written to `w`. Go's `Write` over a slice.

    Also one `write` call, which is why the bytes are built into a buffer
    first rather than being handed over a value at a time.
    """
    comptime width = _width[dtype]()
    comptime if width < 0:
        raise _unsupported("Write", dtype)
    else:
        var buf = List[Byte](length=width * len(v), fill=0)
        for i in range(len(v)):
            _put(Span(buf)[i * width : (i + 1) * width], order, v[i])
        _ = w.write(Span(buf))


def read[
    R: Reader, O: ByteOrder, dtype: DType
](mut r: R, order: O, mut v: Scalar[dtype]) raises:
    """One value read from `r` into `v`. Go's `Read`.

    The whole value is read before anything is decoded, through `read_full`,
    so a reader that hands over bytes a few at a time is fine and a reader that
    stops part way is `ErrUnexpectedEOF` rather than a value with half of it
    left over. A reader that had nothing at all to give is `EOF`, which is the
    split Go documents and gets from `io.ReadFull` in the same way.
    """
    comptime width = _width[dtype]()
    comptime if width < 0:
        raise _unsupported("Read", dtype)
    else:
        var buf = List[Byte](length=width, fill=0)
        _ = read_full(r, Span(buf))
        v = _get[dtype](Span(buf), order)


def read[
    R: Reader, O: ByteOrder, dtype: DType, p: Origin[mut=True]
](mut r: R, order: O, v: Span[Scalar[dtype], p]) raises:
    """As many values as `v` holds, read from `r`. Go's `Read` over a slice.

    Nothing is written into `v` unless every byte arrived, which is worth more
    than it sounds: a caller who catches the failure and retries is looking at
    the values they had before rather than at a run that is half new and half
    old with no way to tell where the seam is.
    """
    comptime width = _width[dtype]()
    comptime if width < 0:
        raise _unsupported("Read", dtype)
    else:
        var buf = List[Byte](length=width * len(v), fill=0)
        _ = read_full(r, Span(buf))
        for i in range(len(v)):
            v[i] = _get[dtype](Span(buf)[i * width : (i + 1) * width], order)
