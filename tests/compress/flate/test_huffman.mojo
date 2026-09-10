"""Building a Huffman table out of lengths somebody else chose.

Every one of these is a Go regression test with an issue number on it, and
every one of them was a crash before it was a test. That is the shape of the
whole file: a decompressor takes a table description from the stream, so the
question is never whether a well formed description works, it is what a
malformed one does. `build` answering False is the only acceptable answer, and
these are the descriptions that used to get a different one.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.compress.flate.huffman import _HuffmanDecoder, _fixed_decoder
from core.compress.flate.inflate import Decompressor
from core.errors import matches
from core.errors.codes import ErrFlateCorruptInput
from core.io import Byte

from ._fixtures import Bytes


def test_issue_5915() raises:
    """Go's `TestIssue5915`: sixty three lengths that are not a tree."""
    var bits: List[Int] = [
        4,
        0,
        0,
        6,
        4,
        3,
        2,
        3,
        3,
        4,
        4,
        5,
        0,
        0,
        0,
        0,
        5,
        5,
        6,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        11,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        7,
        8,
        6,
        0,
        11,
        0,
        8,
        0,
        6,
        6,
        10,
        8,
    ]
    var h = _HuffmanDecoder()
    assert_false(h.build(Span(bits)))


def test_issue_5962() raises:
    """Go's `TestIssue5962`: the same shape cut short at thirty lengths."""
    var bits: List[Int] = [
        4,
        0,
        0,
        6,
        4,
        3,
        2,
        3,
        3,
        4,
        4,
        5,
        0,
        0,
        0,
        0,
        5,
        5,
        6,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        11,
    ]
    var h = _HuffmanDecoder()
    assert_false(h.build(Span(bits)))


def test_issue_6255() raises:
    """Go's `TestIssue6255`: a good table, then a bad one in the same decoder.

    The second half is the point. Building over a decoder that already holds a
    table has to start from nothing, and the bug this pins was a leftover
    making the second description look complete when it is not.
    """
    var good: List[Int] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 11]
    var bad: List[Int] = [11, 13]
    var h = _HuffmanDecoder()
    assert_true(h.build(Span(good)))
    assert_false(h.build(Span(bad)))


def test_invalid_bits() raises:
    """Go's `TestInvalidBits`: the two ways a set of lengths is not a tree.

    Over subscribed means the lengths spell more codes than the longest length
    has bit patterns, so two symbols would share one. Incomplete means they
    spell fewer, so some pattern decodes to nothing and a stream using it would
    have nowhere to go.
    """
    var oversubscribed: List[Int] = [1, 2, 3, 4, 4, 5]
    var incomplete: List[Int] = [1, 2, 4, 4]
    var h = _HuffmanDecoder()
    assert_false(h.build(Span(oversubscribed)))
    assert_false(h.build(Span(incomplete)))


def test_a_degenerate_table_is_accepted() raises:
    """One symbol of one bit, which zlib writes and RFC 1951 does not allow.

    Go accepts it for compatibility and says so in a comment, so this is here
    to say the exception is deliberate rather than a hole in the check above.
    """
    var single: List[Int] = [1]
    var h = _HuffmanDecoder()
    assert_true(h.build(Span(single)))


def test_a_bit_pattern_the_table_does_not_cover_is_corrupt() raises:
    """Go's `TestInvalidEncoding`.

    The degenerate table above spells one code, a single zero bit, and leaves
    the other half of the space spelling nothing at all. A stream that arrives
    with that bit set has named a symbol the table does not have, and the entry
    it lands on is zero, which the length check reads as corrupt. That check is
    the only thing standing between a malformed table and a lookup that returns
    whatever was in memory.
    """
    var one: List[Int] = [1]
    var h = _HuffmanDecoder()
    assert_true(h.build(Span(one)))

    var none = List[Byte]()
    var stream: List[Byte] = [0xFF]
    var d = Decompressor(Bytes(stream^), Span(none))
    d.h1 = h^
    var raised = False
    try:
        _ = d._huff_sym(False, True)
    except e:
        raised = True
        assert_true(matches(e, ErrFlateCorruptInput))
    assert_true(raised)


def test_the_fixed_table_decodes_the_lengths_rfc_1951_gives() raises:
    """The four runs of section 3.2.6, read back out of the built table.

    Nothing in Go checks this directly, and it is worth checking because the
    fixed table is the one table no stream describes: a mistake in it would
    show up as every fixed block being wrong and no error anywhere.
    """
    var h = _fixed_decoder()
    assert_equal(h.min, 7)
    # 0 through 143 are eight bits, so the code for 0 is 00110000 and the
    # table is indexed by those bits reversed.
    assert_equal(Int(h.chunks[0b00001100] & 15), 8)
    assert_equal(Int(h.chunks[0b00001100] >> 4), 0)
    # 256, the end of block marker, is seven bits and all zero.
    assert_equal(Int(h.chunks[0] & 15), 7)
    assert_equal(Int(h.chunks[0] >> 4), 256)
