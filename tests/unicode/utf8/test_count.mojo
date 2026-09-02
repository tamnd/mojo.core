"""Counting and validity, which are the two loops built on the decoder.

Both are one line of arithmetic around `decode_rune`, and both have exactly one
interesting property: they have to agree with what a caller's own decode loop
would produce. A `rune_count` that skipped a malformed sequence in one step
returns a smaller number than the loop that sizes a list from it, and the
mismatch surfaces as a bounds failure a long way from here.

`valid` gets its own attention because it cannot be written as "did any decode
return `RUNE_ERROR`". U+FFFD is a code point that valid input may contain, so
the test is on the size, and the case that proves it is in here.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.unicode.utf8 import (
    rune_count,
    rune_count_in_string,
    valid,
    valid_string,
)

from tests.unicode.utf8._fixtures import (
    invalid,
    joined,
    surrogate_cases,
    valid_cases,
)


def test_the_whole_table_counts_as_one_rune_per_entry() raises:
    """Go's `TestRuneCount` over the concatenation of `utf8map`."""
    var cases = valid_cases()
    var all = joined(cases)
    assert_equal(rune_count(Span(all)), len(cases))


def test_nothing_counts_as_nothing() raises:
    var empty = List[UInt8]()
    assert_equal(rune_count(Span(empty)), 0)
    assert_true(valid(Span(empty)))


def test_every_bad_byte_counts_as_one_rune() raises:
    """Which is the agreement with `decode_rune` written as a number.

    Four continuation bytes are four runes, not one and not zero, because a
    decode loop over them produces four replacement characters. Go answers the
    same and its test uses the same input.
    """
    var rubbish: List[UInt8] = [UInt8(0x80), 0x80, 0x80, 0x80]
    assert_equal(rune_count(Span(rubbish)), 4)
    assert_false(valid(Span(rubbish)))


def test_a_truncated_sequence_at_the_end_counts_its_bytes() raises:
    """`E4 B8` is two bytes of a three byte rune, so it is two runes.

    The alternative — counting an incomplete sequence as one rune because it
    was meant to be one — is what a decoder that returned the claimed width
    would give, and it disagrees with every loop written against it.
    """
    var cut: List[UInt8] = [UInt8(0x61), 0xE4, 0xB8]
    assert_equal(rune_count(Span(cut)), 3)
    assert_false(valid(Span(cut)))


def test_the_invalid_table_is_four_runes_each_and_never_valid() raises:
    """Every entry is four bytes and its first byte is refused, so the count
    is between one and four depending on what follows; what is fixed is that
    none of them is valid and none of them counts as fewer than one."""
    var _invalid = invalid()
    for data in _invalid:
        assert_false(valid(Span(data)))
        var n = rune_count(Span(data))
        assert_true(n >= 1)
        assert_true(n <= 4)


def test_the_surrogate_halves_are_three_runes_and_not_valid() raises:
    """Three, because each of the three bytes is stepped over one at a time
    once the sequence as a whole has been refused."""
    var _surrogates = surrogate_cases()
    for entry in _surrogates:
        assert_false(valid(Span(entry.encoded)))
        assert_equal(rune_count(Span(entry.encoded)), 3)


def test_an_encoded_replacement_character_is_valid() raises:
    """The case that stops `valid` from being written against the rune.

    `EF BF BD` decodes to `RUNE_ERROR` with a size of three, and it is
    ordinary valid text: it is what every other decoder in the world writes
    when it gives up. Checking the value instead of the size would make this
    library call its own error output malformed.
    """
    var replacement: List[UInt8] = [UInt8(0xEF), 0xBF, 0xBD]
    assert_true(valid(Span(replacement)))
    assert_equal(rune_count(Span(replacement)), 1)


def test_valid_over_the_whole_table_and_the_surrogates_together() raises:
    """One bad rune anywhere makes the whole thing invalid, which is the only
    thing the loop adds to `decode_rune`."""
    var cases = valid_cases()
    var all = joined(cases)
    assert_true(valid(Span(all)))
    var half = surrogate_cases()[0].encoded.copy()
    all.extend(half^)
    assert_false(valid(Span(all)))


def test_counting_a_string_agrees_with_counting_its_bytes() raises:
    """The forwarder, and the answer that makes it worth having.

    "日a本b語c" is six runes and twelve bytes, and the gap between those two
    numbers is the reason `core.strings` will have three different answers to
    "how long is this".
    """
    var s = String("日a本b語c")
    assert_equal(rune_count_in_string(s), 6)
    assert_equal(len(s.as_bytes()), 12)
    assert_equal(rune_count_in_string(s), rune_count(s.as_bytes()))
    assert_equal(rune_count_in_string(""), 0)
    assert_equal(rune_count_in_string("abcd"), 4)
    assert_equal(rune_count_in_string("☺☻☹"), 3)


def test_a_mojo_string_is_always_valid() raises:
    """Which is the finding rather than the tautology.

    Go's `ValidString` is the check you run on untrusted bytes, because a Go
    `string` is any bytes at all. A Mojo `String` is validated when it is
    built, so the only way past this is the `unsafe_` constructor. Keeping the
    function means that assertion still has somewhere to be audited, and
    keeping the test means the forwarder is wired to the right function.
    """
    assert_true(valid_string(""))
    assert_true(valid_string("abcd"))
    assert_true(valid_string("日a本b語c"))
    assert_true(valid_string("�"))
