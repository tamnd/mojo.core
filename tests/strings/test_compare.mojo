"""Comparing and counting. Go's `compare_test.go` and the `len` deviation.

Two subjects in one file because both are about the same question: what is the
size of a piece of text, and there is more than one answer.

`compare` orders by bytes, which for UTF-8 is the same order as by code point,
and neither is the order a reader would put the words in. The test says so
rather than leaving it to be discovered.

The counting half is this package's largest deviation from Go. There is no
`len`, because Go's counts bytes while reading like it counts characters. The
emoji case at the bottom is the one that makes the argument: one thing on the
screen, and three functions that answer 28, 9 and 3.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.strings import (
    compare,
    count_bytes,
    count_graphemes,
    count_runes,
    equal_fold,
    has_prefix,
    has_suffix,
)


def test_compare() raises:
    """Go's `compareTests`."""
    assert_equal(compare("", ""), 0)
    assert_equal(compare("a", ""), 1)
    assert_equal(compare("", "a"), -1)
    assert_equal(compare("abc", "abc"), 0)
    assert_equal(compare("abd", "abc"), 1)
    assert_equal(compare("abc", "abd"), -1)
    assert_equal(compare("ab", "abc"), -1)
    assert_equal(compare("abc", "ab"), 1)
    assert_equal(compare("x", "ab"), 1)
    assert_equal(compare("ab", "x"), -1)


def test_compare_is_not_alphabetical() raises:
    """Byte order, which is code point order, which is not reading order.

    `Z` sorts before `a` because it does in ASCII, and `é` sorts after both
    because its first byte is above 0x7F. Anything wanting the order a person
    would use needs collation, which is a Unicode algorithm and a table this
    library does not carry.
    """
    assert_equal(compare("Z", "a"), -1)
    assert_equal(compare("é", "z"), 1)


def test_has_prefix_and_has_suffix() raises:
    """Go's `prefixTests` and `suffixTests`."""
    assert_true(has_prefix("abc", "a"))
    assert_true(has_prefix("abc", "abc"))
    assert_true(has_prefix("abc", ""))
    assert_true(has_prefix("", ""))
    assert_false(has_prefix("", "a"))
    assert_false(has_prefix("abc", "b"))
    assert_false(has_prefix("a", "abc"))

    assert_true(has_suffix("abc", "c"))
    assert_true(has_suffix("abc", "abc"))
    assert_true(has_suffix("abc", ""))
    assert_false(has_suffix("", "a"))
    assert_false(has_suffix("abc", "b"))
    assert_false(has_suffix("a", "abc"))


def test_equal_fold() raises:
    """Go's `EqualFoldTests`.

    Simple folding, so the Kelvin sign folds to `k` and the long s to `s`, and
    the German ß does not fold to `ss`. Go answers the same way and for the
    same reason: full folding needs a table neither library has.
    """
    assert_true(equal_fold("abc", "abc"))
    assert_true(equal_fold("ABcd", "ABcd"))
    assert_true(equal_fold("123abc", "123ABC"))
    assert_true(equal_fold("αβδ", "ΑΒΔ"))
    assert_false(equal_fold("abc", "xyz"))
    assert_false(equal_fold("abc", "XYZ"))
    assert_false(equal_fold("abcdefghijk", "abcdefghijX"))
    # The three runes that fold to ASCII from outside it.
    assert_true(equal_fold("k", "K"))
    assert_true(equal_fold("s", "ſ"))
    assert_false(equal_fold("ß", "ss"))


def test_counting_agrees_on_ascii() raises:
    """On plain ASCII all three answers are the same, which is the trap.

    Every counting bug in a Go program passes its ASCII test. This row is here
    to say that passing it means nothing.
    """
    assert_equal(count_bytes("hello"), 5)
    assert_equal(count_runes("hello"), 5)
    assert_equal(count_graphemes("hello"), 5)
    assert_equal(count_bytes(""), 0)
    assert_equal(count_runes(""), 0)
    assert_equal(count_graphemes(""), 0)


def test_counting_disagrees_on_text() raises:
    """The reason there are three functions and no `len`.

    One family emoji and one accented letter. The family is a single thing on
    the screen built from four people and three joiners, and the accent is
    written as a letter and a combining mark. So: 28 bytes, 9 code points, 3
    characters, and the caller has to say which of the three they wanted.
    """
    var s = "a👩‍👩‍👧‍👦é"
    assert_equal(count_bytes(s), 28)
    assert_equal(count_runes(s), 9)
    assert_equal(count_graphemes(s), 3)


def test_counting_on_the_pieces() raises:
    """The same three counts on each piece, so the totals above add up."""
    assert_equal(count_bytes("👩‍👩‍👧‍👦"), 25)
    assert_equal(count_runes("👩‍👩‍👧‍👦"), 7)
    assert_equal(count_graphemes("👩‍👩‍👧‍👦"), 1)
    # The precomposed U+00E9, which is what a keyboard produces.
    assert_equal(count_bytes("é"), 2)
    assert_equal(count_runes("é"), 1)
    assert_equal(count_graphemes("é"), 1)


def test_counting_on_the_two_spellings_of_one_letter() raises:
    """The same letter written two ways, and only one count agrees.

    `é` is either U+00E9 or an `e` followed by U+0301 COMBINING ACUTE ACCENT.
    They look identical, they are canonically equivalent, and they are two
    different strings: 2 bytes and 1 rune against 3 bytes and 2 runes. Only the
    grapheme count sees one character in both, which is the count a program
    truncating a name for a fixed width field wanted all along.
    """
    var composed = "é"
    var decomposed = String("e") + chr(0x301)
    assert_equal(count_bytes(composed), 2)
    assert_equal(count_runes(composed), 1)
    assert_equal(count_graphemes(composed), 1)
    assert_equal(count_bytes(decomposed), 3)
    assert_equal(count_runes(decomposed), 2)
    assert_equal(count_graphemes(decomposed), 1)
    # And they are not equal, which is what makes comparing user typed text
    # without normalising it a bug waiting for the day somebody pastes one.
    assert_false(compare(composed, decomposed) == 0)
