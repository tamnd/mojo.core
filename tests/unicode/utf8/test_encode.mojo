"""Writing runes into bytes, and the exhaustive round trip.

The table gives the encoder the same boundaries the decoder got, from the same
hand written source. The round trip then runs every code point from zero to
`MAX_RUNE` — 1,114,112 of them — through `encode_rune` and back through
`decode_rune`, which is the test that an encoder and a decoder written by the
same person on the same afternoon cannot both be wrong and still pass, because
the surrogate gap and the four length boundaries are checked at every value
rather than at the ones somebody thought of.

The other half is the two questions asked before encoding. `rune_len` returning
-1 rather than 3 for a value that is not a code point is the trap in this
package, and `test_rune_len_and_encode_rune_disagree_on_purpose` is where that
is written down rather than discovered.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.unicode.utf8 import (
    MAX_RUNE,
    RUNE_ERROR,
    UTF_MAX,
    append_rune,
    decode_rune,
    encode_rune,
    rune_len,
    valid_rune,
)

from tests.unicode.utf8._fixtures import surrogate_cases, valid_cases

comptime _SURROGATE_MIN = 0xD800
"""Spelled again here rather than imported, because it is private to the
package and a test that reached for it would be checking the implementation
against itself."""

comptime _SURROGATE_MAX = 0xDFFF


def test_every_rune_in_the_table_encodes_to_its_bytes() raises:
    """Go's `TestEncodeRune`, the reverse of the decode table."""
    var _cases = valid_cases()
    for entry in _cases:
        var buf = List[UInt8](length=UTF_MAX, fill=0)
        var n = encode_rune(Span(buf), entry.rune)
        assert_equal(n, len(entry.encoded))
        for i in range(n):
            assert_equal(Int(buf[i]), Int(entry.encoded[i]))


def test_append_rune_writes_what_encode_rune_writes() raises:
    """Go's `TestAppendRune`, onto an empty list and onto a non-empty one.

    The non-empty half is the whole of it: an implementation that wrote at
    index zero instead of appending passes the first and fails the second.
    """
    var _cases = valid_cases()
    for entry in _cases:
        var fresh = List[UInt8]()
        assert_equal(append_rune(fresh, entry.rune), len(entry.encoded))
        assert_equal(len(fresh), len(entry.encoded))
        for i in range(len(fresh)):
            assert_equal(Int(fresh[i]), Int(entry.encoded[i]))

        var onto: List[UInt8] = [UInt8(0x21), 0x22]
        assert_equal(append_rune(onto, entry.rune), len(entry.encoded))
        assert_equal(len(onto), 2 + len(entry.encoded))
        assert_equal(Int(onto[0]), 0x21)
        assert_equal(Int(onto[1]), 0x22)
        for i in range(len(entry.encoded)):
            assert_equal(Int(onto[2 + i]), Int(entry.encoded[i]))


def test_a_surrogate_encodes_as_the_replacement_character() raises:
    """Go's `TestNegativeRune` neighbour: the value is not a code point, so
    the substitution happens rather than the arithmetic.

    The bytes it writes are the ones `_fixtures` calls U+FFFD, not the ones
    the surrogate table holds, and that is the point: the surrogate encodings
    in that table are what a broken encoder would have produced.
    """
    var replacement: List[UInt8] = [UInt8(0xEF), 0xBF, 0xBD]
    var _surrogates = surrogate_cases()
    for entry in _surrogates:
        var buf = List[UInt8](length=UTF_MAX, fill=0)
        var n = encode_rune(Span(buf), entry.rune)
        assert_equal(n, 3)
        for i in range(3):
            assert_equal(Int(buf[i]), Int(replacement[i]))


def test_values_that_are_not_code_points_all_encode_the_same_way() raises:
    """Negative, past `MAX_RUNE`, and the two ends of the surrogate range.

    Go substitutes rather than failing, and `encode.mojo` says why the
    asymmetry with the decoder is deliberate. What this pins is that the
    substitution is total: there is no value of `Int32` for which
    `encode_rune` writes nothing or writes something else.
    """
    var bad = [
        Int32(-1),
        Int32(-0x10FFFF),
        Int32(0x110000),
        Int32(0x7FFFFFFF),
        Int32(_SURROGATE_MIN),
        Int32(_SURROGATE_MAX),
    ]
    for r in bad:
        var buf = List[UInt8](length=UTF_MAX, fill=0)
        var n = encode_rune(Span(buf), r)
        assert_equal(n, 3)
        assert_equal(Int(buf[0]), 0xEF)
        assert_equal(Int(buf[1]), 0xBF)
        assert_equal(Int(buf[2]), 0xBD)

        var appended = List[UInt8]()
        assert_equal(append_rune(appended, r), 3)
        assert_equal(len(appended), 3)
        assert_equal(Int(appended[0]), 0xEF)


def test_valid_rune_over_the_boundaries() raises:
    """Go's `TestValidRune`. Both sides of every edge, none of them sampled."""
    assert_true(valid_rune(0))
    assert_true(valid_rune(Int32(_SURROGATE_MIN - 1)))
    assert_false(valid_rune(Int32(_SURROGATE_MIN)))
    assert_false(valid_rune(Int32(_SURROGATE_MAX)))
    assert_true(valid_rune(Int32(_SURROGATE_MAX + 1)))
    assert_true(valid_rune(MAX_RUNE))
    assert_false(valid_rune(MAX_RUNE + 1))
    assert_false(valid_rune(-1))
    # U+FFFD is a code point like any other, which is the corollary the
    # package docstring warns about.
    assert_true(valid_rune(RUNE_ERROR))


def test_rune_len_over_the_boundaries() raises:
    """Go's `TestRuneLen`, the four widths and the values that have none."""
    assert_equal(rune_len(0), 1)
    assert_equal(rune_len(0x7F), 1)
    assert_equal(rune_len(0x80), 2)
    assert_equal(rune_len(0x7FF), 2)
    assert_equal(rune_len(0x800), 3)
    assert_equal(rune_len(0xFFFF), 3)
    assert_equal(rune_len(0x10000), 4)
    assert_equal(rune_len(MAX_RUNE), 4)
    assert_equal(rune_len(-1), -1)
    assert_equal(rune_len(MAX_RUNE + 1), -1)
    assert_equal(rune_len(Int32(_SURROGATE_MIN)), -1)
    assert_equal(rune_len(Int32(_SURROGATE_MAX)), -1)


def test_rune_len_and_encode_rune_disagree_on_purpose() raises:
    """The trap, written down. `rune_len` says -1 and `encode_rune` writes 3.

    Sizing a buffer from `rune_len` and then encoding into it is the bug this
    exists to make findable, because it only shows up for input somebody else
    chose. `bufio`'s private predecessor returned 3 here, which was the wrong
    fix: it made the two agree by making the question unanswerable.
    """
    var surrogate = Int32(_SURROGATE_MIN)
    assert_equal(rune_len(surrogate), -1)
    var buf = List[UInt8](length=UTF_MAX, fill=0)
    assert_equal(encode_rune(Span(buf), surrogate), 3)
    assert_false(valid_rune(surrogate))


def test_every_code_point_round_trips() raises:
    """Exhaustive over 0 to `MAX_RUNE`, which is what makes this convincing.

    Encoding then decoding gives back the value and the width, except in the
    surrogate range, where the value is not a code point and both directions
    say so: the encode substitutes U+FFFD and the decode agrees with it.
    `rune_len` is checked in the same loop, so the three functions cannot
    disagree about a single value anywhere in the space.
    """
    var buf = List[UInt8](length=UTF_MAX, fill=0)
    var r: Int32
    var size: Int
    for i in range(Int(MAX_RUNE) + 1):
        var want = Int32(i)
        var n = encode_rune(Span(buf), want)
        r, size = decode_rune(Span(buf)[:n])
        assert_equal(size, n)
        if i >= _SURROGATE_MIN and i <= _SURROGATE_MAX:
            assert_equal(Int(r), Int(RUNE_ERROR))
            assert_equal(n, 3)
            assert_equal(rune_len(want), -1)
        else:
            assert_equal(Int(r), i)
            assert_equal(rune_len(want), n)


def test_every_encoding_is_the_only_one_of_its_length() raises:
    """The shorter form of the same sweep, run over a fixed span.

    A rune encoded into `UTF_MAX` bytes and decoded from exactly `n` of them
    is the round trip above. Decoding from the whole four byte span instead
    checks the other half: that the encoder wrote a self delimiting sequence
    and the decoder stops where the encoder stopped, rather than reading the
    stale bytes left in the buffer by the previous iteration.
    """
    var buf = List[UInt8](length=UTF_MAX, fill=UInt8(0xFF))
    var r: Int32
    var size: Int
    var _cases = valid_cases()
    for entry in _cases:
        var n = encode_rune(Span(buf), entry.rune)
        r, size = decode_rune(Span(buf))
        assert_equal(Int(r), Int(entry.rune))
        assert_equal(size, n)
