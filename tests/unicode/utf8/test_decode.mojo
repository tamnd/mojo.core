"""Reading runes out of bytes, and mostly out of bytes that are wrong.

The table half of this is Go's, transcribed in `_fixtures.mojo`. The half that
is not Go's is exhaustive: every one of the 256 single bytes is decoded here,
because the single byte case is where a decoder's error handling either has a
rule or has a pile of conditions, and 256 is small enough that sampling it would
be a choice to know less.

The property under all of it is the one in `decode.mojo`'s docstring: bad input
advances exactly one byte. A test suite that only checked `RUNE_ERROR` came back
would pass an implementation that consumed the whole malformed sequence, and
that implementation silently disagrees with `rune_count`, with `valid`, and with
every loop a caller writes.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.unicode.utf8 import (
    RUNE_ERROR,
    RUNE_SELF,
    UTF_MAX,
    decode_last_rune,
    decode_last_rune_in_string,
    decode_rune,
    decode_rune_in_string,
    full_rune,
    full_rune_in_string,
    rune_start,
)

from tests.unicode.utf8._fixtures import (
    invalid,
    joined,
    surrogate_cases,
    valid_cases,
)


def test_every_encoding_in_the_table_decodes_to_its_rune() raises:
    """Go's `TestDecodeRune` over `utf8map`, the forward direction."""
    var r: Int32
    var size: Int
    var _cases = valid_cases()
    for entry in _cases:
        r, size = decode_rune(Span(entry.encoded))
        assert_equal(Int(r), Int(entry.rune))
        assert_equal(size, len(entry.encoded))


def test_a_trailing_byte_does_not_change_the_first_rune() raises:
    """The decode reads what it needs and stops, rather than the whole span.

    Go tests this by appending a NUL. It is the difference between a function
    that decodes a rune and one that validates a string, and callers that scan
    a buffer depend on the first.
    """
    var r: Int32
    var size: Int
    var _cases = valid_cases()
    for entry in _cases:
        var padded = entry.encoded.copy()
        padded.append(UInt8(0))
        r, size = decode_rune(Span(padded))
        assert_equal(Int(r), Int(entry.rune))
        assert_equal(size, len(entry.encoded))


def test_one_byte_short_is_a_failure_not_a_smaller_rune() raises:
    """Truncation gives `(RUNE_ERROR, 1)`, or `(RUNE_ERROR, 0)` if that
    emptied the input.

    The zero is only for empty, and this is the test that says so, because a
    truncated four byte sequence has a first byte to advance over and an empty
    span does not. A decoder that returned zero for both would loop forever on
    a buffer ending mid rune.
    """
    var r: Int32
    var size: Int
    var _cases = valid_cases()
    for entry in _cases:
        var want = 1 if len(entry.encoded) > 1 else 0
        r, size = decode_rune(Span(entry.encoded)[: len(entry.encoded) - 1])
        assert_equal(Int(r), Int(RUNE_ERROR))
        assert_equal(size, want)


def test_empty_input_decodes_to_a_size_of_zero() raises:
    """The one zero the function ever returns, spelled out on its own."""
    var data = List[UInt8]()
    var r: Int32
    var size: Int
    r, size = decode_rune(Span(data))
    assert_equal(Int(r), Int(RUNE_ERROR))
    assert_equal(size, 0)


def test_the_surrogate_halves_are_refused() raises:
    """Go's `TestDecodeSurrogateRune`.

    `ED A0 80` is arithmetically a perfectly good three byte sequence and
    UTF-8 may not carry it, so this is the case that separates a decoder
    written from the shape of the bytes from one written from the standard.
    """
    var r: Int32
    var size: Int
    var _surrogates = surrogate_cases()
    for entry in _surrogates:
        r, size = decode_rune(Span(entry.encoded))
        assert_equal(Int(r), Int(RUNE_ERROR))
        assert_equal(size, 1)


def test_the_invalid_table_all_fails_one_byte_at_a_time() raises:
    """Go's `TestDecodeInvalidSequence`, including the overlong forms.

    Every entry is four bytes long, so nothing here is refused for want of
    input; each is refused because of what it says.
    """
    var r: Int32
    var size: Int
    var _invalid = invalid()
    for data in _invalid:
        r, size = decode_rune(Span(data))
        assert_equal(Int(r), Int(RUNE_ERROR))
        assert_equal(size, 1)


def test_the_two_bytes_that_can_only_be_overlong() raises:
    """`C0` and `C1` begin nothing, which is not obvious from the arithmetic.

    `C0 80` would be a two byte spelling of NUL and `C1 BF` of `\\x7F`. Both
    decode cleanly if you only mask and shift, and accepting them is how a
    filter looking for `/` and a consumer decoding properly are made to
    disagree about the same bytes.
    """
    var r: Int32
    var size: Int
    var nul: List[UInt8] = [UInt8(0xC0), 0x80]
    r, size = decode_rune(Span(nul))
    assert_equal(Int(r), Int(RUNE_ERROR))
    assert_equal(size, 1)
    var one_less: List[UInt8] = [UInt8(0xC1), 0xBF]
    r, size = decode_rune(Span(one_less))
    assert_equal(Int(r), Int(RUNE_ERROR))
    assert_equal(size, 1)


def test_every_one_of_the_two_hundred_and_fifty_six_single_bytes() raises:
    """Exhaustive, because the rule is short enough to state and check.

    A byte below `RUNE_SELF` is itself. Every other byte alone decodes to
    `(RUNE_ERROR, 1)`, whether it is a continuation byte, a byte that begins
    nothing, or the first byte of a sequence whose rest never arrived. The
    third of those is the one worth having: a decoder that answered "not yet"
    for a truncated start would return a size of zero and hang its caller.

    `full_rune` is the function that tells those apart, and it is checked in
    the same loop so the two answers cannot drift.
    """
    var r: Int32
    var size: Int
    for i in range(256):
        var data: List[UInt8] = [UInt8(i)]
        r, size = decode_rune(Span(data))
        if i < RUNE_SELF:
            assert_equal(Int(r), i)
            assert_equal(size, 1)
            assert_true(full_rune(Span(data)))
        else:
            assert_equal(Int(r), Int(RUNE_ERROR))
            assert_equal(size, 1)
            # Complete iff no further byte could ever help: a continuation
            # byte, `C0`, `C1` and anything above `F4` are already decided.
            var hopeless = (
                (i & 0xC0) == 0x80 or i == 0xC0 or i == 0xC1 or i > 0xF4
            )
            assert_equal(full_rune(Span(data)), hopeless)


def test_rune_start_is_true_for_everything_but_continuation_bytes() raises:
    """Exhaustive as well, and it is a boundary test rather than a validity
    test: `C0` is not the start of anything valid and `rune_start` says True.
    """
    for i in range(256):
        assert_equal(rune_start(UInt8(i)), (i & 0xC0) != 0x80)


def test_a_sequence_decodes_the_same_forwards_as_the_table_says() raises:
    """Go's `TestSequencing`, the concatenation of the whole table.

    One rune at a time is not the same test as a run of them, because an
    off by one in the size shows up only when the next decode starts in the
    wrong place, and here it shows up as the wrong rune rather than as a
    boundary error.
    """
    var cases = valid_cases()
    var all = joined(cases)
    var i = 0
    var seen = 0
    var r: Int32
    var size: Int
    while i < len(all):
        r, size = decode_rune(Span(all)[i:])
        assert_equal(Int(r), Int(cases[seen].rune))
        assert_equal(size, len(cases[seen].encoded))
        i += size
        seen += 1
    assert_equal(seen, len(cases))


def test_the_last_rune_of_every_encoding_is_the_whole_of_it() raises:
    """Go's `TestDecodeLastRune` over the table."""
    var r: Int32
    var size: Int
    var _cases = valid_cases()
    for entry in _cases:
        r, size = decode_last_rune(Span(entry.encoded))
        assert_equal(Int(r), Int(entry.rune))
        assert_equal(size, len(entry.encoded))


def test_the_last_rune_of_a_pair_is_the_second_one() raises:
    """With an ASCII byte in front, so the backwards scan has to stop.

    Every encoding in the table is checked with an `x` before it, which makes
    the scan pass over a real boundary rather than run off the front.
    """
    var r: Int32
    var size: Int
    var _cases = valid_cases()
    for entry in _cases:
        var data: List[UInt8] = [UInt8(0x78)]
        data.extend(entry.encoded.copy())
        r, size = decode_last_rune(Span(data))
        assert_equal(Int(r), Int(entry.rune))
        assert_equal(size, len(entry.encoded))


def test_the_last_rune_of_a_truncated_sequence_is_a_failure() raises:
    """Dropping the final byte of a multi byte encoding, over the whole table.

    This is the easy half, and it is worth saying which half it is: the
    forward decode from the recovered start byte already fails here, because
    what it is given is short. The landing check is not what produces the
    answer, and the test below is the one that reaches it.
    """
    var r: Int32
    var size: Int
    var _cases = valid_cases()
    for entry in _cases:
        if len(entry.encoded) == 1:
            continue
        r, size = decode_last_rune(
            Span(entry.encoded)[: len(entry.encoded) - 1]
        )
        assert_equal(Int(r), Int(RUNE_ERROR))
        assert_equal(size, 1)


def test_a_stray_continuation_byte_at_the_end_is_the_last_rune() raises:
    """The case the landing check exists for, and the only one that reaches it.

    `A`, then a complete two byte rune, then one loose continuation byte.
    Scanning back from the end skips that byte, finds the `C2`, and decodes
    forward from it perfectly happily: `C2 80` is a real rune and the decode
    returns it with a size of two. It stops one byte short of the end, so it
    is not the last rune, and only the landing check knows that.

    Every truncated input answers `(RUNE_ERROR, 1)` because the forward decode
    itself failed, which is why removing the check leaves those tests passing.
    Here the forward decode succeeds and is still the wrong answer.
    """
    var data: List[UInt8] = [UInt8(0x41), 0xC2, 0x80, 0x80]
    var r: Int32
    var size: Int
    r, size = decode_last_rune(Span(data))
    assert_equal(Int(r), Int(RUNE_ERROR))
    assert_equal(size, 1)
    # And the same bytes without the stray one do give the rune back, so the
    # failure above is about where the decode landed and nothing else.
    r, size = decode_last_rune(Span(data)[:3])
    assert_equal(Int(r), 0x80)
    assert_equal(size, 2)


def test_the_last_rune_of_nothing_has_a_size_of_zero() raises:
    """Same rule as forwards, and the same reason: a loop has to end."""
    var data = List[UInt8]()
    var r: Int32
    var size: Int
    r, size = decode_last_rune(Span(data))
    assert_equal(Int(r), Int(RUNE_ERROR))
    assert_equal(size, 0)


def test_the_backwards_scan_gives_up_after_four_bytes() raises:
    """A long run of continuation bytes must not be walked to the front.

    Sixty four `0x80`s have no start byte anywhere in them. The bound is what
    makes a backwards walk over a buffer linear instead of quadratic, and the
    answer is the same one byte failure a forward decode of the tail gives.
    """
    var data = List[UInt8](length=64, fill=UInt8(0x80))
    var r: Int32
    var size: Int
    r, size = decode_last_rune(Span(data))
    assert_equal(Int(r), Int(RUNE_ERROR))
    assert_equal(size, 1)


def test_a_start_byte_just_outside_the_window_is_not_reached() raises:
    """`UTF_MAX` is a real bound and not an optimisation with a safety net.

    A two byte encoding followed by four continuation bytes has a start byte
    six back, which is further than the scan looks. Go answers
    `(RUNE_ERROR, 1)` here and so does this, and the point of the test is that
    the answer is decided by the bound rather than by the data.
    """
    var data: List[UInt8] = [UInt8(0xC2), 0x80, 0x80, 0x80, 0x80, 0x80]
    var r: Int32
    var size: Int
    r, size = decode_last_rune(Span(data))
    assert_equal(Int(r), Int(RUNE_ERROR))
    assert_equal(size, 1)
    assert_equal(UTF_MAX, 4)


def test_full_rune_answers_would_reading_more_help() raises:
    """Go's `TestFullRune`, over every prefix of every encoding in the table.

    A proper prefix of a valid encoding is the one shape that answers `False`.
    Everything else — the complete encoding, and anything already wrong —
    answers `True`, because no further byte changes the outcome.
    """
    var _cases = valid_cases()
    for entry in _cases:
        var whole = Span(entry.encoded)
        assert_true(full_rune(whole))
        for cut in range(1, len(entry.encoded)):
            assert_false(full_rune(whole[:cut]))


def test_full_rune_of_nothing_is_false() raises:
    """Empty is the extreme case of a proper prefix, and reading more helps."""
    var data = List[UInt8]()
    assert_false(full_rune(Span(data)))


def test_a_short_sequence_already_wrong_is_complete() raises:
    """`E0 80` is two bytes of a three byte encoding and there is no third
    byte that rescues it, because `E0` may not be followed by `80` at all.

    This is the branch that separates `full_rune` from a length comparison,
    and a buffered reader that used the length would wait for a byte that
    cannot help.
    """
    var overlong3: List[UInt8] = [UInt8(0xE0), 0x80]
    var overlong4: List[UInt8] = [UInt8(0xF0), 0x80]
    var bad_third: List[UInt8] = [UInt8(0xF0), 0x90, 0x20]
    assert_true(full_rune(Span(overlong3)))
    assert_true(full_rune(Span(overlong4)))
    assert_true(full_rune(Span(bad_third)))
    # And the same first bytes with a legal continuation are still short.
    var short3: List[UInt8] = [UInt8(0xE0), 0xA0]
    var short4: List[UInt8] = [UInt8(0xF0), 0x90, 0x80]
    assert_false(full_rune(Span(short3)))
    assert_false(full_rune(Span(short4)))


def test_the_string_forms_agree_with_the_span_forms() raises:
    """Three one line forwarders, checked because they are one line each.

    A Mojo `String` is already valid UTF-8, so these can only ever be given
    the easy half of the input. What they are for is the name a Go programmer
    reaches for, and the thing that can go wrong is a forwarder wired to the
    wrong function.
    """
    var s = String("héllo, 世界")
    var want: Int32
    var want_size: Int
    want, want_size = decode_rune(s.as_bytes())
    var got: Int32
    var got_size: Int
    got, got_size = decode_rune_in_string(s)
    assert_equal(Int(got), Int(want))
    assert_equal(got_size, want_size)

    want, want_size = decode_last_rune(s.as_bytes())
    got, got_size = decode_last_rune_in_string(s)
    assert_equal(Int(got), Int(want))
    assert_equal(got_size, want_size)
    assert_equal(Int(got), 0x754C)
    assert_equal(got_size, 3)

    assert_equal(full_rune_in_string(s), full_rune(s.as_bytes()))
    assert_true(full_rune_in_string(s))
