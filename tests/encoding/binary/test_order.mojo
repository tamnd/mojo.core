"""The three byte orders, in both directions and all three widths.

Go's own tests for this half go through `Read` and `Write` on a struct with one
field of every type, which is the reflection half and is not here yet. So the
tables below are written out rather than borrowed: one number of each width
whose bytes are all different, so that a transposition shows up rather than
cancelling, and the ends of each range, where a shift that lost the top bit
would be the only way to be wrong.
"""

from std.testing import assert_equal, assert_true

from core.encoding.binary import (
    AppendByteOrder,
    BigEndian,
    ByteOrder,
    LittleEndian,
    NativeEndian,
)
from core.io import Byte


def _bytes(var values: List[Int]) -> List[Byte]:
    """A list of bytes written as a list of numbers, since a literal is not one.
    """
    var out = List[Byte](capacity=len(values))
    for v in values:
        out.append(Byte(v))
    return out^


def _read16[O: ByteOrder](order: O, var b: List[Byte]) -> UInt16:
    """`uint16` over a list, so that the span does not outlive the call."""
    return order.uint16(Span(b))


def _read32[O: ByteOrder](order: O, var b: List[Byte]) -> UInt32:
    """`uint32` over a list."""
    return order.uint32(Span(b))


def _read64[O: ByteOrder](order: O, var b: List[Byte]) -> UInt64:
    """`uint64` over a list."""
    return order.uint64(Span(b))


def test_big_endian_reads_most_significant_first() raises:
    """The first byte is the top of the number."""
    assert_equal(_read16(BigEndian(), _bytes([0x12, 0x34])), 0x1234)
    assert_equal(
        _read32(BigEndian(), _bytes([0x12, 0x34, 0x56, 0x78])), 0x12345678
    )
    assert_equal(
        _read64(
            BigEndian(),
            _bytes([0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]),
        ),
        0x123456789ABCDEF0,
    )


def test_little_endian_reads_least_significant_first() raises:
    """The same bytes the other way round, which is the same number reversed."""
    assert_equal(_read16(LittleEndian(), _bytes([0x34, 0x12])), 0x1234)
    assert_equal(
        _read32(LittleEndian(), _bytes([0x78, 0x56, 0x34, 0x12])), 0x12345678
    )
    assert_equal(
        _read64(
            LittleEndian(),
            _bytes([0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12]),
        ),
        0x123456789ABCDEF0,
    )


def test_a_read_stops_at_the_width_it_was_asked_for() raises:
    """Bytes past the number are not looked at.

    A record is usually several numbers in a row, so every read here is handed
    more bytes than it needs and has to leave the rest alone.
    """
    var b = _bytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    var big = BigEndian()
    assert_equal(big.uint16(Span(b)), 0x0102)
    assert_equal(big.uint32(Span(b)), 0x01020304)
    assert_equal(big.uint32(Span(b)[4:]), 0x05060708)


def test_put_writes_exactly_the_width() raises:
    """Neither order touches a byte past the one it was asked for."""
    var out = List[Byte](length=10, fill=0xEE)
    BigEndian().put_uint32(Span(out)[1:], 0x12345678)
    assert_equal(out[0], 0xEE)
    assert_equal(out[1], 0x12)
    assert_equal(out[2], 0x34)
    assert_equal(out[3], 0x56)
    assert_equal(out[4], 0x78)
    assert_equal(out[5], 0xEE)

    var other = List[Byte](length=10, fill=0xEE)
    LittleEndian().put_uint32(Span(other)[1:], 0x12345678)
    assert_equal(other[0], 0xEE)
    assert_equal(other[1], 0x78)
    assert_equal(other[2], 0x56)
    assert_equal(other[3], 0x34)
    assert_equal(other[4], 0x12)
    assert_equal(other[5], 0xEE)


def test_put_and_read_round_trip_at_both_ends_of_every_width() raises:
    """Zero, the largest value and a value with every byte different.

    The largest is the case a shift that dropped the top bit would fail and
    nothing else would.
    """
    var sixteen: List[UInt16] = [0, 1, 0x1234, 0x7FFF, 0x8000, 0xFFFF]
    for v in sixteen:
        var buf = List[Byte](length=2, fill=0)
        BigEndian().put_uint16(Span(buf), v)
        assert_equal(BigEndian().uint16(Span(buf)), v)
        LittleEndian().put_uint16(Span(buf), v)
        assert_equal(LittleEndian().uint16(Span(buf)), v)

    var thirty_two: List[UInt32] = [
        0,
        1,
        0x12345678,
        0x7FFFFFFF,
        0x80000000,
        0xFFFFFFFF,
    ]
    for v in thirty_two:
        var buf = List[Byte](length=4, fill=0)
        BigEndian().put_uint32(Span(buf), v)
        assert_equal(BigEndian().uint32(Span(buf)), v)
        LittleEndian().put_uint32(Span(buf), v)
        assert_equal(LittleEndian().uint32(Span(buf)), v)

    var sixty_four: List[UInt64] = [
        0,
        1,
        0x123456789ABCDEF0,
        0x7FFFFFFFFFFFFFFF,
        0x8000000000000000,
        0xFFFFFFFFFFFFFFFF,
    ]
    for v in sixty_four:
        var buf = List[Byte](length=8, fill=0)
        BigEndian().put_uint64(Span(buf), v)
        assert_equal(BigEndian().uint64(Span(buf)), v)
        LittleEndian().put_uint64(Span(buf), v)
        assert_equal(LittleEndian().uint64(Span(buf)), v)


def test_the_two_orders_are_each_other_reversed() raises:
    """One number written both ways gives one byte sequence and its reverse."""
    var big = List[Byte](length=8, fill=0)
    var little = List[Byte](length=8, fill=0)
    BigEndian().put_uint64(Span(big), 0x0102030405060708)
    LittleEndian().put_uint64(Span(little), 0x0102030405060708)
    for i in range(8):
        assert_equal(big[i], little[7 - i])


def test_append_puts_the_same_bytes_on_the_end() raises:
    """The appending form and the writing form agree, and neither disturbs
    what was already there."""
    var onto = List[Byte]()
    onto.append(0xAA)
    BigEndian().append_uint16(onto, 0x1234)
    BigEndian().append_uint32(onto, 0x12345678)
    BigEndian().append_uint64(onto, 0x123456789ABCDEF0)
    assert_equal(len(onto), 1 + 2 + 4 + 8)
    assert_equal(onto[0], 0xAA)

    var written = List[Byte](length=15, fill=0)
    written[0] = 0xAA
    BigEndian().put_uint16(Span(written)[1:], 0x1234)
    BigEndian().put_uint32(Span(written)[3:], 0x12345678)
    BigEndian().put_uint64(Span(written)[7:], 0x123456789ABCDEF0)
    for i in range(len(written)):
        assert_equal(onto[i], written[i])


def test_append_in_the_other_order() raises:
    """The same, little end first."""
    var onto = List[Byte]()
    LittleEndian().append_uint16(onto, 0x1234)
    LittleEndian().append_uint32(onto, 0x12345678)
    LittleEndian().append_uint64(onto, 0x123456789ABCDEF0)
    assert_equal(len(onto), 14)
    assert_equal(onto[0], 0x34)
    assert_equal(onto[1], 0x12)
    assert_equal(onto[2], 0x78)
    assert_equal(onto[5], 0x12)
    assert_equal(onto[6], 0xF0)
    assert_equal(onto[13], 0x12)


def test_native_endian_is_one_of_the_two() raises:
    """Whichever it is, it agrees with that one on every width.

    This is the whole of what can be asserted about the native order without
    asserting which machine the test is running on, and it is the assertion
    that matters: the compile time branch picked one of the two and did not
    pick something in between.
    """
    var buf = List[Byte](length=8, fill=0)
    NativeEndian().put_uint64(Span(buf), 0x0102030405060708)
    var big = buf[0] == 0x01
    if big:
        assert_equal(BigEndian().uint64(Span(buf)), 0x0102030405060708)
    else:
        assert_equal(LittleEndian().uint64(Span(buf)), 0x0102030405060708)

    var two = List[Byte](length=2, fill=0)
    NativeEndian().put_uint16(Span(two), 0x0102)
    assert_equal(two[0] == 0x01, big)

    var four = List[Byte](length=4, fill=0)
    NativeEndian().put_uint32(Span(four), 0x01020304)
    assert_equal(four[0] == 0x01, big)


def test_native_endian_round_trips_every_width() raises:
    """Written and read back through the same order, which is what it is for."""
    var two = List[Byte](length=2, fill=0)
    NativeEndian().put_uint16(Span(two), 0xFEDC)
    assert_equal(NativeEndian().uint16(Span(two)), 0xFEDC)

    var four = List[Byte](length=4, fill=0)
    NativeEndian().put_uint32(Span(four), 0xFEDCBA98)
    assert_equal(NativeEndian().uint32(Span(four)), 0xFEDCBA98)

    var eight = List[Byte](length=8, fill=0)
    NativeEndian().put_uint64(Span(eight), 0xFEDCBA9876543210)
    assert_equal(NativeEndian().uint64(Span(eight)), 0xFEDCBA9876543210)


def test_native_endian_appends_what_it_writes() raises:
    """The appending form and the writing form agree here too."""
    var onto = List[Byte]()
    NativeEndian().append_uint16(onto, 0x1234)
    NativeEndian().append_uint32(onto, 0x12345678)
    NativeEndian().append_uint64(onto, 0x123456789ABCDEF0)

    var written = List[Byte](length=14, fill=0)
    NativeEndian().put_uint16(Span(written), 0x1234)
    NativeEndian().put_uint32(Span(written)[2:], 0x12345678)
    NativeEndian().put_uint64(Span(written)[6:], 0x123456789ABCDEF0)
    assert_equal(len(onto), len(written))
    for i in range(len(written)):
        assert_equal(onto[i], written[i])


def test_each_order_says_its_name() raises:
    """Go's `String` method, which is `write_to` here."""
    assert_equal(String(BigEndian()), "BigEndian")
    assert_equal(String(LittleEndian()), "LittleEndian")
    assert_equal(String(NativeEndian()), "NativeEndian")


def _decode_header[O: ByteOrder](order: O, var b: List[Byte]) -> UInt32:
    """A caller that was told its order rather than choosing one.

    The point of the trait: this is compiled once per order with the shifts
    inlined, where Go compiles it once and calls through an interface.
    """
    return (
        order.uint16(Span(b)[0:2]).cast[DType.uint32]()
        + order.uint16(Span(b)[2:4]).cast[DType.uint32]()
    )


def test_a_function_can_take_the_order_as_a_parameter() raises:
    """All three orders go through one generic function."""
    var b = _bytes([0x00, 0x02, 0x00, 0x03])
    assert_equal(_decode_header(BigEndian(), b.copy()), 5)
    assert_equal(_decode_header(LittleEndian(), b.copy()), 0x0200 + 0x0300)
    var native = _decode_header(NativeEndian(), b.copy())
    assert_true(native == 5 or native == 0x0500)


def _append_two[O: AppendByteOrder](order: O, mut dst: List[Byte]):
    """The other trait, on its own, which is what Go's split is for."""
    order.append_uint16(dst, 0x0102)


def test_a_function_can_take_the_appending_trait_alone() raises:
    """A writer that never reads needs only the three appending methods."""
    var out = List[Byte]()
    _append_two(BigEndian(), out)
    assert_equal(out[0], 0x01)
    assert_equal(out[1], 0x02)

    var other = List[Byte]()
    _append_two(LittleEndian(), other)
    assert_equal(other[0], 0x02)
    assert_equal(other[1], 0x01)
