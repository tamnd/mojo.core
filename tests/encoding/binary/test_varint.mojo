"""Varints, over Go's own tables.

`tests` in Go's `varint_test.go` is eighteen signed numbers, run through both
signs and through every one of the six calls, and `TestVarint` follows it with
the powers of two from seven upwards. Both are here. So are `TestOverflow`,
`TestBufferTooSmall`, `TestBufferTooBigWithOverflow` and `TestNonCanonicalZero`,
which are the four that say what happens to input a writer of this encoding did
not produce.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.bytes import new_reader
from core.encoding.binary import (
    MAX_VARINT_LEN16,
    MAX_VARINT_LEN32,
    MAX_VARINT_LEN64,
    append_uvarint,
    append_varint,
    put_uvarint,
    put_varint,
    read_uvarint,
    read_varint,
    uvarint,
    varint,
)
from core.errors import matches, partial
from core.errors.codes import EOF, ErrUnexpectedEOF, ErrVarintOverflow
from core.io import Byte


def _bytes(var values: List[Int]) -> List[Byte]:
    """A list of bytes written as a list of numbers."""
    var out = List[Byte](capacity=len(values))
    for v in values:
        out.append(Byte(v))
    return out^


def _rows() -> List[Int64]:
    """Go's `tests`, the eighteen numbers every varint test runs over."""
    var out: List[Int64] = [
        -0x8000000000000000,
        -0x7FFFFFFFFFFFFFFF,
        -1,
        0,
        1,
        2,
        10,
        20,
        63,
        64,
        65,
        127,
        128,
        129,
        255,
        256,
        257,
        0x7FFFFFFFFFFFFFFF,
    ]
    return out^


def _check_uvarint(x: UInt64) raises:
    """Go's `testUvarint`: write, read, append and read from a reader."""
    var buf = List[Byte](length=MAX_VARINT_LEN64, fill=0)
    var n = put_uvarint(Span(buf), x)

    var got = uvarint(Span(buf)[0:n])
    assert_equal(got[0], x)
    assert_equal(got[1], n)

    var onto = List[Byte]()
    onto.append(Byte(0x99))
    var appended = append_uvarint(onto, x)
    assert_equal(appended, n)
    assert_equal(len(onto), n + 1)
    for i in range(n):
        assert_equal(onto[i + 1], buf[i])

    var reader = new_reader(Span(buf))
    assert_equal(read_uvarint(reader), x)


def _check_varint(x: Int64) raises:
    """Go's `testVarint`, the signed twin of the above."""
    var buf = List[Byte](length=MAX_VARINT_LEN64, fill=0)
    var n = put_varint(Span(buf), x)

    var got = varint(Span(buf)[0:n])
    assert_equal(got[0], x)
    assert_equal(got[1], n)

    var onto = List[Byte]()
    onto.append(Byte(0x99))
    var appended = append_varint(onto, x)
    assert_equal(appended, n)
    assert_equal(len(onto), n + 1)
    for i in range(n):
        assert_equal(onto[i + 1], buf[i])

    var reader = new_reader(Span(buf))
    assert_equal(read_varint(reader), x)


def test_the_constants_are_the_widths_they_name() raises:
    """Go's `TestConstants`.

    The largest number of each width, written out, takes exactly the number of
    bytes the constant names.
    """
    var buf = List[Byte](length=MAX_VARINT_LEN64, fill=0)
    assert_equal(put_uvarint(Span(buf), 0xFFFF), MAX_VARINT_LEN16)
    assert_equal(put_uvarint(Span(buf), 0xFFFFFFFF), MAX_VARINT_LEN32)
    assert_equal(put_uvarint(Span(buf), 0xFFFFFFFFFFFFFFFF), MAX_VARINT_LEN64)


def test_the_unsigned_table_round_trips() raises:
    """Go's `TestUvarint`, the eighteen rows read as unsigned numbers."""
    for x in _rows():
        _check_uvarint(UInt64(x))


def test_the_unsigned_powers_of_two_round_trip() raises:
    """The second half of Go's `TestUvarint`, seven shifted left until it goes.

    Every one of these puts a set bit in a different place, so a shift that is
    off by one somewhere in the middle of the number shows up here and nowhere
    in the table above.
    """
    var x = UInt64(0x7)
    while x != 0:
        _check_uvarint(x)
        x <<= 1


def test_the_signed_table_round_trips() raises:
    """Go's `TestVarint`, both signs of every row."""
    for x in _rows():
        _check_varint(x)
        _check_varint(-x)


def test_the_signed_powers_of_two_round_trip() raises:
    """The second half of Go's `TestVarint`, both signs."""
    var x = Int64(0x7)
    while x != 0:
        _check_varint(x)
        _check_varint(-x)
        x <<= 1


def test_zig_zag_keeps_small_negatives_small() raises:
    """Minus one is one byte, which is the whole point of the signed form.

    Two's complement sign extension would have made it ten bytes of ones, and
    a format whose commonest negative number is its most expensive one is a
    format nobody would use for deltas.
    """
    var buf = List[Byte](length=MAX_VARINT_LEN64, fill=0)
    assert_equal(put_varint(Span(buf), -1), 1)
    assert_equal(buf[0], 1)
    assert_equal(put_varint(Span(buf), -2), 1)
    assert_equal(buf[0], 3)
    assert_equal(put_varint(Span(buf), 1), 1)
    assert_equal(buf[0], 2)
    assert_equal(put_varint(Span(buf), 0), 1)
    assert_equal(buf[0], 0)


def test_a_number_leaves_the_bytes_after_it_alone() raises:
    """Several numbers in a row are read one at a time.

    The count that comes back is what a caller slices off before the next one,
    which is how a record of varints is read.
    """
    var buf = List[Byte]()
    _ = append_uvarint(buf, 1)
    _ = append_uvarint(buf, 300)
    _ = append_uvarint(buf, 0)

    var at = 0
    var first = uvarint(Span(buf)[at:])
    assert_equal(first[0], 1)
    at += first[1]
    var second = uvarint(Span(buf)[at:])
    assert_equal(second[0], 300)
    at += second[1]
    var third = uvarint(Span(buf)[at:])
    assert_equal(third[0], 0)
    at += third[1]
    assert_equal(at, len(buf))


def test_an_empty_span_is_the_end_of_the_input() raises:
    """Nothing was started, so this is `EOF` rather than a truncation.

    Go answers zero for both and leaves the caller to work out which, which is
    the one place this reads more into Go's count than Go does.
    """
    var buf = List[Byte]()
    with assert_raises(contains="no varint to read"):
        _ = uvarint(Span(buf))
    try:
        _ = uvarint(Span(buf))
    except e:
        assert_true(matches(e, EOF))
        assert_equal(partial(e), 0)


def test_a_span_that_stops_part_way_is_a_truncation() raises:
    """Go's `TestBufferTooSmall`, which is four continuation bytes and no end.

    Go gets a count of zero from every prefix of it. Here the empty one is
    `EOF` and the other three are `ErrUnexpectedEOF`, and the count of bytes
    the number did use is on the error.
    """
    var whole = _bytes([0x80, 0x80, 0x80, 0x80])
    for i in range(1, len(whole) + 1):
        try:
            _ = uvarint(Span(whole)[0:i])
            assert_true(False, "a truncated varint was accepted")
        except e:
            assert_true(matches(e, ErrUnexpectedEOF))
            assert_equal(partial(e), i)


def test_a_reader_that_stops_part_way_is_a_truncation() raises:
    """The reader half of Go's `TestBufferTooSmall`.

    Go pins exactly this split on the reader, `io.EOF` when nothing was read
    and `io.ErrUnexpectedEOF` when something was, and the span form above
    follows it.
    """
    var whole = _bytes([0x80, 0x80, 0x80, 0x80])
    for i in range(0, len(whole) + 1):
        var reader = new_reader(Span(whole)[0:i])
        try:
            _ = read_uvarint(reader)
            assert_true(False, "a truncated varint was accepted")
        except e:
            if i == 0:
                assert_true(matches(e, EOF))
            else:
                assert_true(matches(e, ErrUnexpectedEOF))


def test_a_number_wider_than_sixty_four_bits_is_refused() raises:
    """Go's `TestOverflow`, all three rows.

    The first is ten bytes whose tenth carries more than the one bit that is
    left, the second is thirteen bytes, and the third is eleven bytes of ones.
    Go reports these as counts of minus ten, minus eleven and minus eleven; the
    magnitudes are on `errors.partial` here.
    """
    var tenth_byte_too_big = _bytes(
        [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02]
    )
    try:
        _ = uvarint(Span(tenth_byte_too_big))
        assert_true(False, "an overflowing varint was accepted")
    except e:
        assert_true(matches(e, ErrVarintOverflow))
        assert_equal(partial(e), 10)

    var thirteen = _bytes(
        [
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x01,
            0,
            0,
        ]
    )
    try:
        _ = uvarint(Span(thirteen))
        assert_true(False, "an overflowing varint was accepted")
    except e:
        assert_true(matches(e, ErrVarintOverflow))
        assert_equal(partial(e), 11)

    var eleven_ones = _bytes(
        [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    )
    try:
        _ = uvarint(Span(eleven_ones))
        assert_true(False, "an overflowing varint was accepted")
    except e:
        assert_true(matches(e, ErrVarintOverflow))
        assert_equal(partial(e), 11)


def test_the_reader_refuses_the_same_three_and_reads_no_further() raises:
    """The reader half of Go's `TestOverflow`.

    Go asserts that no more than `MAX_VARINT_LEN64` bytes were consumed, since
    a reader that ran to the end of a hostile stream looking for a byte under
    a hundred and twenty eight would read the whole of it. The reader is asked
    how much is left rather than how much was taken, which is the same fact.
    """
    var eleven_ones = _bytes(
        [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    )
    var reader = new_reader(Span(eleven_ones))
    with assert_raises(contains="overflows a 64-bit integer"):
        _ = read_uvarint(reader)
    assert_true(len(eleven_ones) - reader.len() <= MAX_VARINT_LEN64)

    var thirteen = _bytes(
        [
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x80,
            0x01,
            0,
            0,
        ]
    )
    var other = new_reader(Span(thirteen))
    with assert_raises(contains="overflows a 64-bit integer"):
        _ = read_uvarint(other)
    assert_true(len(thirteen) - other.len() <= MAX_VARINT_LEN64)


def test_the_signed_form_refuses_what_the_unsigned_one_does() raises:
    """Zig zag is undone after the number is read, so the refusals are shared.
    """
    var eleven_ones = _bytes(
        [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    )
    with assert_raises(contains="overflows a 64-bit integer"):
        _ = varint(Span(eleven_ones))

    var short = _bytes([0x80])
    with assert_raises(contains="ended in the middle"):
        _ = varint(Span(short))

    var reader = new_reader(Span(short))
    with assert_raises(contains="ended in the middle"):
        _ = read_varint(reader)


def test_the_widest_number_is_accepted() raises:
    """Go's `valid: math.MaxUint64-40` row, which is ten bytes ending in one.

    The tenth byte is the one bit the encoding has left, so this is the case
    that says the refusal above stops at the right place rather than one byte
    early.
    """
    var widest = _bytes(
        [0xD7, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
    )
    var got = uvarint(Span(widest))
    assert_equal(got[0], 0xFFFFFFFFFFFFFFFF - 40)
    assert_equal(got[1], 10)


def test_one_more_byte_after_the_widest_number_is_refused() raises:
    """Go's `invalid: with more than MaxVarintLen64 bytes`.

    The eleventh byte is refused before its value is looked at, which is the
    check Go added for its issue 41185: without it the shift that would have
    taken the byte in is a shift by seventy, which is not a shift of anything.
    """
    var too_long = _bytes(
        [0xD7, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
    )
    try:
        _ = uvarint(Span(too_long))
        assert_true(False, "an eleven byte varint was accepted")
    except e:
        assert_true(matches(e, ErrVarintOverflow))
        assert_equal(partial(e), 11)


def test_a_tenth_byte_above_one_is_refused() raises:
    """Go's `invalid: 10th byte`, which ends in 0x7f rather than 0x01."""
    var top_bits = _bytes(
        [0xD7, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]
    )
    try:
        _ = uvarint(Span(top_bits))
        assert_true(False, "a varint with bits to spare was accepted")
    except e:
        assert_true(matches(e, ErrVarintOverflow))
        assert_equal(partial(e), 10)


def test_a_number_written_with_more_bytes_than_it_needs_is_read() raises:
    """Go's `TestNonCanonicalZero`, and the decision it stands for.

    Zero written in four bytes is still zero and is accepted, which is Go's
    answer and the answer every varint reader in the wild gives. The encoding
    has no minimality rule, so there is nothing to enforce; the ASN.1 half of
    this milestone is the opposite, since DER does have one and a certificate
    that breaks it is refused.
    """
    var padded = _bytes([0x80, 0x80, 0x80, 0])
    var got = uvarint(Span(padded))
    assert_equal(got[0], 0)
    assert_equal(got[1], 4)

    var reader = new_reader(Span(padded))
    assert_equal(read_uvarint(reader), 0)


def test_put_and_append_write_the_same_bytes() raises:
    """The two writing forms agree on every row of the table.

    Go asserts this by building the appended buffer on a prefix and comparing
    the whole thing, which is what `_check_uvarint` does above; this is the
    same claim about the numbers that take more than one byte.
    """
    var sizes: List[UInt64] = [0, 1, 127, 128, 300, 0xFFFFFFFF]
    for x in sizes:
        var buf = List[Byte](length=MAX_VARINT_LEN64, fill=0)
        var n = put_uvarint(Span(buf), x)
        var onto = List[Byte]()
        assert_equal(append_uvarint(onto, x), n)
        for i in range(n):
            assert_equal(onto[i], buf[i])


def test_a_reader_gives_up_its_numbers_one_at_a_time() raises:
    """Three numbers written into one buffer come back in order.

    Go's own test reads one number from a fresh reader each time, so this is
    the claim its tests do not make: the reader is left pointing at the byte
    after the number rather than somewhere the next call has to guess at.
    """
    var buf = List[Byte]()
    _ = append_uvarint(buf, 1)
    _ = append_uvarint(buf, 300)
    _ = append_varint(buf, -5)

    var reader = new_reader(Span(buf))
    assert_equal(read_uvarint(reader), 1)
    assert_equal(read_uvarint(reader), 300)
    assert_equal(read_varint(reader), -5)
    try:
        _ = read_uvarint(reader)
        assert_true(False, "a reader with nothing left gave a number")
    except e:
        # The reader's own `EOF` rather than one of this package's, since
        # nothing was consumed and there is nothing to add to what it said.
        assert_true(matches(e, EOF))
