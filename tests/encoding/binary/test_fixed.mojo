"""Whole values as bytes, against Go's own table.

Go's `binary_test.go` is built on one struct with a field of every fixed size
type in it and two golden byte arrays, `big` and `little`, that say what that
struct encodes to under each order. Both arrays are here in full and both are
produced field by field, which is the calls a generated encoder would make and
is what this package offers a caller who has a struct.

The two complex fields are not left out, which is worth saying because Mojo has
no complex scalar. A complex64 on the wire is its real float32 followed by its
imaginary one and a complex128 is the same with float64, so the sixteen bytes
Go's table spends on them are produced here by four calls rather than two. The
bytes are the ones Go wrote.

Also here: reading and writing runs of values, the bool rule that any non-zero
byte is true, a buffer with no room, a stream that stops part way, and the
types this cannot measure.
"""

from std.memory import bitcast
from std.testing import assert_equal, assert_raises, assert_true

from core.bytes import Buffer, new_reader
from core.encoding.binary import (
    BigEndian,
    ByteOrder,
    LittleEndian,
    NativeEndian,
    append,
    decode,
    encode,
    read,
    size,
    write,
)
from core.errors import matches
from core.errors.codes import EOF, ErrShortBuffer, ErrUnexpectedEOF
from core.io import Byte


def _bytes(var values: List[Int]) -> List[Byte]:
    """A list of bytes written as a list of numbers, since a literal is not one.
    """
    var out = List[Byte](capacity=len(values))
    for v in values:
        out.append(Byte(v))
    return out^


def _same(got: List[Byte], want: List[Byte], name: String) raises:
    """Two byte lists, byte for byte, naming the first place they differ."""
    if len(got) != len(want):
        raise Error(
            name
            + ": got "
            + String(len(got))
            + " bytes, wanted "
            + String(len(want))
        )
    for i in range(len(got)):
        if got[i] != want[i]:
            raise Error(
                name
                + ": byte "
                + String(i)
                + " is "
                + String(Int(got[i]))
                + ", wanted "
                + String(Int(want[i]))
            )


def _big() -> List[Byte]:
    """Go's `big`, which is what its `s` encodes to most significant first.

    One row per field of Go's struct, which its own table does not have and
    which is the whole value of writing it out again: a wrong byte says which
    field it is in. Read the rows in order and they are the numbers one to
    seventy, then the bool and the four bools. That is not a coincidence. The
    field values in Go's `s` were chosen to make it so, which is what makes a
    wrong byte in a big endian encoding obvious by eye.
    """
    var out = List[Byte]()
    out.extend(_bytes([1]))  # Int8
    out.extend(_bytes([2, 3]))  # Int16
    out.extend(_bytes([4, 5, 6, 7]))  # Int32
    out.extend(_bytes([8, 9, 10, 11, 12, 13, 14, 15]))  # Int64
    out.extend(_bytes([16]))  # Uint8
    out.extend(_bytes([17, 18]))  # Uint16
    out.extend(_bytes([19, 20, 21, 22]))  # Uint32
    out.extend(_bytes([23, 24, 25, 26, 27, 28, 29, 30]))  # Uint64
    out.extend(_bytes([31, 32, 33, 34]))  # Float32
    out.extend(_bytes([35, 36, 37, 38, 39, 40, 41, 42]))  # Float64
    out.extend(_bytes([43, 44, 45, 46, 47, 48, 49, 50]))  # Complex64
    out.extend(_bytes([51, 52, 53, 54, 55, 56, 57, 58]))  # Complex128, real
    out.extend(_bytes([59, 60, 61, 62, 63, 64, 65, 66]))  # and imaginary
    out.extend(_bytes([67, 68, 69, 70]))  # Array, four uint8
    out.extend(_bytes([1]))  # Bool
    out.extend(_bytes([1, 0, 1, 0]))  # BoolArray
    return out^


def _little() -> List[Byte]:
    """Go's `little`, the same struct least significant byte first.

    Every row of more than one byte is its big endian row reversed, and the one
    byte rows and the array of bytes are unchanged. That is the whole of what
    an order does, and the two eight byte halves of the complex128 being
    reversed one at a time rather than together is the part that is easy to get
    wrong and easy to see here.
    """
    var out = List[Byte]()
    out.extend(_bytes([1]))  # Int8
    out.extend(_bytes([3, 2]))  # Int16
    out.extend(_bytes([7, 6, 5, 4]))  # Int32
    out.extend(_bytes([15, 14, 13, 12, 11, 10, 9, 8]))  # Int64
    out.extend(_bytes([16]))  # Uint8
    out.extend(_bytes([18, 17]))  # Uint16
    out.extend(_bytes([22, 21, 20, 19]))  # Uint32
    out.extend(_bytes([30, 29, 28, 27, 26, 25, 24, 23]))  # Uint64
    out.extend(_bytes([34, 33, 32, 31]))  # Float32
    out.extend(_bytes([42, 41, 40, 39, 38, 37, 36, 35]))  # Float64
    out.extend(_bytes([46, 45, 44, 43, 50, 49, 48, 47]))  # Complex64
    out.extend(_bytes([58, 57, 56, 55, 54, 53, 52, 51]))  # Complex128, real
    out.extend(_bytes([66, 65, 64, 63, 62, 61, 60, 59]))  # and imaginary
    out.extend(_bytes([67, 68, 69, 70]))  # Array, four uint8
    out.extend(_bytes([1]))  # Bool
    out.extend(_bytes([1, 0, 1, 0]))  # BoolArray
    return out^


def _written[O: ByteOrder](order: O) raises -> List[Byte]:
    """Go's `s`, one call per field, in the order the struct declares them.

    This is what a generated encoder for that struct would emit, so it is the
    shape the check is worth making in. Nothing here knows it is encoding a
    struct.
    """
    var out = List[Byte]()
    _ = append(out, order, Int8(0x01))
    _ = append(out, order, Int16(0x0203))
    _ = append(out, order, Int32(0x04050607))
    _ = append(out, order, Int64(0x08090A0B0C0D0E0F))
    _ = append(out, order, UInt8(0x10))
    _ = append(out, order, UInt16(0x1112))
    _ = append(out, order, UInt32(0x13141516))
    _ = append(out, order, UInt64(0x1718191A1B1C1D1E))
    _ = append(out, order, bitcast[DType.float32](UInt32(0x1F202122)))
    _ = append(out, order, bitcast[DType.float64](UInt64(0x232425262728292A)))
    # complex64, which is two float32 in the order real then imaginary.
    _ = append(out, order, bitcast[DType.float32](UInt32(0x2B2C2D2E)))
    _ = append(out, order, bitcast[DType.float32](UInt32(0x2F303132)))
    # complex128, the same with float64.
    _ = append(out, order, bitcast[DType.float64](UInt64(0x333435363738393A)))
    _ = append(out, order, bitcast[DType.float64](UInt64(0x3B3C3D3E3F404142)))
    var array = _bytes([0x43, 0x44, 0x45, 0x46])
    _ = append(out, order, Span(array))
    _ = append(out, order, Scalar[DType.bool](True))
    var bools: List[Scalar[DType.bool]] = [True, False, True, False]
    _ = append(out, order, Span(bools))
    return out^


def test_go_s_encodes_to_go_big() raises:
    """Go's struct under `BigEndian`, byte for byte against Go's table."""
    _same(_written(BigEndian()), _big(), "big")


def test_go_s_encodes_to_go_little() raises:
    """Go's struct under `LittleEndian`, byte for byte against Go's table."""
    _same(_written(LittleEndian()), _little(), "little")


def test_every_field_of_go_s_reads_back() raises:
    """Go's `testRead`, which reads the golden bytes back into the fields.

    A field at a time out of the golden array, since that is what a generated
    decoder does, and the whole array has to be consumed exactly.
    """
    var data = _big()
    var at = 0

    var i8 = Int8(0)
    at += decode(Span(data)[at : len(data)], BigEndian(), i8)
    assert_equal(i8, Int8(0x01))
    var i16 = Int16(0)
    at += decode(Span(data)[at : len(data)], BigEndian(), i16)
    assert_equal(i16, Int16(0x0203))
    var i32 = Int32(0)
    at += decode(Span(data)[at : len(data)], BigEndian(), i32)
    assert_equal(i32, Int32(0x04050607))
    var i64 = Int64(0)
    at += decode(Span(data)[at : len(data)], BigEndian(), i64)
    assert_equal(i64, Int64(0x08090A0B0C0D0E0F))
    var u8 = UInt8(0)
    at += decode(Span(data)[at : len(data)], BigEndian(), u8)
    assert_equal(u8, UInt8(0x10))
    var u16 = UInt16(0)
    at += decode(Span(data)[at : len(data)], BigEndian(), u16)
    assert_equal(u16, UInt16(0x1112))
    var u32 = UInt32(0)
    at += decode(Span(data)[at : len(data)], BigEndian(), u32)
    assert_equal(u32, UInt32(0x13141516))
    var u64 = UInt64(0)
    at += decode(Span(data)[at : len(data)], BigEndian(), u64)
    assert_equal(u64, UInt64(0x1718191A1B1C1D1E))

    var f32 = Float32(0)
    at += decode(Span(data)[at : len(data)], BigEndian(), f32)
    assert_equal(bitcast[DType.uint32](f32), UInt32(0x1F202122))
    var f64 = Float64(0)
    at += decode(Span(data)[at : len(data)], BigEndian(), f64)
    assert_equal(bitcast[DType.uint64](f64), UInt64(0x232425262728292A))

    # The two complex fields, four reads rather than two.
    for want in [UInt32(0x2B2C2D2E), UInt32(0x2F303132)]:
        var part = Float32(0)
        at += decode(Span(data)[at : len(data)], BigEndian(), part)
        assert_equal(bitcast[DType.uint32](part), want)
    for want64 in [UInt64(0x333435363738393A), UInt64(0x3B3C3D3E3F404142)]:
        var part64 = Float64(0)
        at += decode(Span(data)[at : len(data)], BigEndian(), part64)
        assert_equal(bitcast[DType.uint64](part64), want64)

    var array = List[Byte](length=4, fill=0)
    at += decode(Span(data)[at : len(data)], BigEndian(), Span(array))
    _same(array, _bytes([0x43, 0x44, 0x45, 0x46]), "array")

    var flag = Scalar[DType.bool](False)
    at += decode(Span(data)[at : len(data)], BigEndian(), flag)
    assert_true(Bool(flag))
    var flags = List[Scalar[DType.bool]](length=4, fill=False)
    at += decode(Span(data)[at : len(data)], BigEndian(), Span(flags))
    assert_true(Bool(flags[0]))
    assert_true(not Bool(flags[1]))
    assert_true(Bool(flags[2]))
    assert_true(not Bool(flags[3]))

    assert_equal(at, len(data))


def test_a_run_of_values_reads_and_writes() raises:
    """Go's `TestReadSlice` and `TestWriteSlice`, both orders of the same fact.

    Eight bytes are two big endian int32, and the two int32 are those eight
    bytes again. Go runs the reading half through `Read` and `Decode` both, so
    this does too.
    """
    var src = _bytes([1, 2, 3, 4, 5, 6, 7, 8])
    var want: List[Int32] = [Int32(0x01020304), Int32(0x05060708)]

    var out = List[Int32](length=2, fill=0)
    assert_equal(decode(Span(src), BigEndian(), Span(out)), 8)
    assert_equal(out[0], want[0])
    assert_equal(out[1], want[1])

    var stream = new_reader(Span(src))
    var streamed = List[Int32](length=2, fill=0)
    read(stream, BigEndian(), Span(streamed))
    assert_equal(streamed[0], want[0])
    assert_equal(streamed[1], want[1])

    var sink = Buffer()
    write(sink, BigEndian(), Span(want))
    _same(sink.bytes(), src, "write slice")


def test_any_byte_that_is_not_zero_is_true() raises:
    """Go's `TestReadBool` and `TestReadBoolSlice`.

    Two is true and two hundred and fifty five is true. Go decodes a bool that
    way rather than refusing a byte that is neither zero nor one, because the
    bytes came from another program and a C compiler writes whatever it likes
    into a bool. Refusing them here would turn a file Go reads into a file this
    does not.
    """
    for byte in [0, 1, 2, 255]:
        var got = Scalar[DType.bool](False)
        var one = _bytes([byte])
        assert_equal(decode(Span(one), BigEndian(), got), 1)
        assert_equal(Bool(got), byte != 0)

    var four = _bytes([0, 1, 2, 255])
    var flags = List[Scalar[DType.bool]](length=4, fill=True)
    assert_equal(decode(Span(four), BigEndian(), Span(flags)), 4)
    assert_true(not Bool(flags[0]))
    assert_true(Bool(flags[1]))
    assert_true(Bool(flags[2]))
    assert_true(Bool(flags[3]))


def test_a_true_bool_is_written_as_one() raises:
    """The other direction, which Go's table pins and its bool tests do not.

    Mojo's `Scalar[DType.bool]` is a byte in memory and nothing says which
    byte, so writing the value straight out would be writing whatever the
    machine happened to hold.
    """
    var out = List[Byte]()
    _ = append(out, BigEndian(), Scalar[DType.bool](True))
    _ = append(out, BigEndian(), Scalar[DType.bool](False))
    _same(out, _bytes([1, 0]), "bools")


def test_a_hundred_of_each_width_round_trip() raises:
    """Go's `TestSliceRoundTrip`, a hundred values of each integer width.

    The value at each index is chosen so that it fills the width it is in,
    which is what catches an encoder that writes the low bytes of a wide
    number or a decoder that sign extends where it should not.
    """
    _round_trip[DType.int8]()
    _round_trip[DType.int16]()
    _round_trip[DType.int32]()
    _round_trip[DType.int64]()
    _round_trip[DType.uint8]()
    _round_trip[DType.uint16]()
    _round_trip[DType.uint32]()
    _round_trip[DType.uint64]()


def _round_trip[dtype: DType]() raises:
    """A hundred values out through `append` and back through `decode`."""
    var values = List[Scalar[dtype]](capacity=100)
    for i in range(100):
        values.append((UInt64(i) * 0x0101010101010101).cast[dtype]())

    var out = List[Byte]()
    assert_equal(append(out, LittleEndian(), Span(values)), size(Span(values)))

    var back = List[Scalar[dtype]](length=100, fill=0)
    assert_equal(decode(Span(out), LittleEndian(), Span(back)), len(out))
    for i in range(100):
        assert_equal(back[i], values[i])


def test_size_is_the_width_of_the_type() raises:
    """Go's `Size`, which is a call there and a constant here."""
    assert_equal(size(Scalar[DType.bool](True)), 1)
    assert_equal(size(Int8(0)), 1)
    assert_equal(size(Int16(0)), 2)
    assert_equal(size(Int32(0)), 4)
    assert_equal(size(Int64(0)), 8)
    assert_equal(size(UInt8(0)), 1)
    assert_equal(size(UInt16(0)), 2)
    assert_equal(size(UInt32(0)), 4)
    assert_equal(size(UInt64(0)), 8)
    assert_equal(size(Float32(0)), 4)
    assert_equal(size(Float64(0)), 8)

    var five = List[Int32](length=5, fill=0)
    assert_equal(size(Span(five)), 20)
    var none = List[Int32]()
    assert_equal(size(Span(none)), 0)


def test_a_type_with_no_fixed_size_is_refused() raises:
    """Go's `TestNoFixedSize` and `TestSizeInvalid`, for the types Mojo has.

    Go's case is a struct holding an `int`, which is a different width on a
    different machine. Mojo's `Int` is not a `Scalar` at all, so the same
    mistake does not compile here and the case that is left is an integer
    wider than a `ByteOrder` has a method for.
    """
    assert_equal(size(Scalar[DType.int128](0)), -1)
    assert_equal(size(Scalar[DType.uint256](0)), -1)
    var wide = List[Scalar[DType.int128]](length=2, fill=0)
    assert_equal(size(Span(wide)), -1)

    var buf = List[Byte](length=64, fill=0)
    var sink = Buffer()
    var source = new_reader(Span(buf))
    var grown = List[Byte]()
    var value = Scalar[DType.int128](0)

    with assert_raises(
        contains="binary.Encode: some values are not fixed-sized in type"
    ):
        _ = encode(Span(buf), BigEndian(), value)
    with assert_raises(
        contains="binary.Decode: some values are not fixed-sized in type"
    ):
        _ = decode(Span(buf), BigEndian(), value)
    with assert_raises(
        contains="binary.Append: some values are not fixed-sized in type"
    ):
        _ = append(grown, BigEndian(), value)
    with assert_raises(
        contains="binary.Write: some values are not fixed-sized in type"
    ):
        write(sink, BigEndian(), value)
    with assert_raises(
        contains="binary.Read: some values are not fixed-sized in type"
    ):
        read(source, BigEndian(), value)


def test_a_buffer_with_no_room_is_refused() raises:
    """Go's `errBufferTooSmall`, which is a refusal rather than a short write.

    Nothing is written into the buffer first, which is the part worth pinning:
    a caller who catches this and reuses the buffer is not looking at three
    bytes of a four byte number.
    """
    var buf = _bytes([9, 9, 9])
    with assert_raises(contains="buffer too small"):
        _ = encode(Span(buf), BigEndian(), UInt32(0x01020304))
    _same(buf, _bytes([9, 9, 9]), "untouched")

    var got = UInt32(0)
    with assert_raises(contains="buffer too small"):
        _ = decode(Span(buf), BigEndian(), got)
    assert_equal(got, UInt32(0))

    var pair = List[UInt16](length=2, fill=0)
    with assert_raises(contains="buffer too small"):
        _ = decode(Span(buf), BigEndian(), Span(pair))


def test_the_refusal_carries_the_short_buffer_code() raises:
    """`ErrShortBuffer`, so a caller matches on the sentinel rather than text.

    Go's is a private error value, which is matchable there because a caller
    can compare against `binary.Encode`'s only failure. Here it is the code
    `io` already uses for a buffer that is too small.
    """
    var buf = _bytes([9])
    try:
        _ = encode(Span(buf), BigEndian(), UInt32(1))
        raise Error("a four byte number went into a one byte buffer")
    except e:
        assert_true(matches(e, ErrShortBuffer))


def test_a_stream_that_stops_part_way_is_told_from_an_empty_one() raises:
    """Go's `TestReadTruncated`, which is the reason `read` uses `read_full`.

    Sixteen bytes are four little endian int32. Cut the stream anywhere in the
    middle and it is `ErrUnexpectedEOF`, because something was started. Cut it
    at nothing at all and it is `EOF`, because nothing was. A caller reading
    records off a socket acts on that difference: one means the peer finished
    and the other means the peer was interrupted.
    """
    var data = _bytes([0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37])
    data.extend(_bytes([0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66]))
    for cut in range(0, len(data) + 1):
        var prefix = List[Byte](capacity=cut)
        prefix.extend(Span(data)[0:cut])
        var source = new_reader(Span(prefix))
        var into = List[Int32](length=4, fill=0)
        if cut == len(data):
            read(source, LittleEndian(), Span(into))
            assert_equal(into[0], Int32(0x33323130))
            assert_equal(into[3], Int32(0x66656463))
            continue
        try:
            read(source, LittleEndian(), Span(into))
            raise Error("a stream of " + String(cut) + " bytes was accepted")
        except e:
            if cut == 0:
                assert_true(matches(e, EOF))
            else:
                assert_true(matches(e, ErrUnexpectedEOF))


def test_the_native_order_is_one_of_the_two() raises:
    """Go's `TestNativeEndian`, which is the whole of what can be said.

    A value written through `NativeEndian` reads back through whichever of the
    two this machine actually is, and there is no third possibility.
    """
    var out = List[Byte]()
    _ = append(out, NativeEndian(), UInt32(0x01020304))
    var big = _bytes([1, 2, 3, 4])
    var little = _bytes([4, 3, 2, 1])
    var is_big = True
    for i in range(4):
        if out[i] != big[i]:
            is_big = False
    if is_big:
        _same(out, big, "native")
    else:
        _same(out, little, "native")

    var back = UInt32(0)
    assert_equal(decode(Span(out), NativeEndian(), back), 4)
    assert_equal(back, UInt32(0x01020304))


def test_append_puts_the_bytes_after_what_was_there() raises:
    """Appending to a buffer that already holds something.

    Go returns the grown slice, this returns the count, and both have to leave
    what was already in the buffer alone. A writer building a record out of
    fields hits this on every field but the first.
    """
    var out = _bytes([0xFF, 0xFE])
    assert_equal(append(out, BigEndian(), UInt16(0x0102)), 2)
    assert_equal(append(out, BigEndian(), Int8(-1)), 1)
    _same(out, _bytes([0xFF, 0xFE, 0x01, 0x02, 0xFF]), "appended")


def test_a_negative_number_keeps_its_bits() raises:
    """Signed values are reinterpreted rather than converted.

    Go writes an int32 by taking its bits as a uint32, and a port that
    converted instead would turn every negative number into zero or into a
    huge one. Minus one is eight ones and it comes back as minus one.
    """
    var out = List[Byte]()
    _ = append(out, BigEndian(), Int32(-1))
    _ = append(out, BigEndian(), Int64(-2))
    var want = _bytes([0xFF, 0xFF, 0xFF, 0xFF])  # Int32(-1)
    want.extend(_bytes([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE]))
    _same(out, want, "negatives")

    var back32 = Int32(0)
    var back64 = Int64(0)
    var at = decode(Span(out), BigEndian(), back32)
    _ = decode(Span(out)[at : len(out)], BigEndian(), back64)
    assert_equal(back32, Int32(-1))
    assert_equal(back64, Int64(-2))


def test_a_float_keeps_its_payload() raises:
    """A NaN goes out and comes back as the same NaN.

    A port that went through a numeric conversion rather than the bits would
    lose the payload, and a signalling NaN would arrive as a quiet one. The
    bits are compared rather than the values, because a NaN is not equal to
    itself.
    """
    var quiet = bitcast[DType.float64](UInt64(0x7FF8000000000001))
    var out = List[Byte]()
    _ = append(out, LittleEndian(), quiet)
    var back = Float64(0)
    _ = decode(Span(out), LittleEndian(), back)
    assert_equal(bitcast[DType.uint64](back), UInt64(0x7FF8000000000001))

    var negative_zero = bitcast[DType.float32](UInt32(0x80000000))
    var out32 = List[Byte]()
    _ = append(out32, LittleEndian(), negative_zero)
    _same(out32, _bytes([0, 0, 0, 0x80]), "negative zero")
