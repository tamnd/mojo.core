"""Finding things in a string. Go's `strings_test.go` search half.

The functions under test hand their work to `core.bytes`, which has its own
tests over the same tables, so what is being checked here is not the search
algorithm. It is that each of the fourteen names is wired to the right one of
the fourteen names next door, which is exactly the kind of mistake a copied
block of one line functions invites and the kind that no amount of testing
`core.bytes` would catch.

The tables are Go's, minus the rows whose input is not valid UTF-8. Those rows
matter in Go, where a `string` is arbitrary bytes; here they cannot be written
at all, and `tests/bytes` is where that input gets tested.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.io import Byte
from core.strings import (
    contains,
    contains_any,
    contains_func,
    contains_rune,
    count,
    index,
    index_any,
    index_byte,
    index_func,
    index_rune,
    last_index,
    last_index_any,
    last_index_byte,
    last_index_func,
)


@fieldwise_init
struct Case(Copyable, Movable):
    """A string, something to look for in it, and the offset expected."""

    var s: String
    var sep: String
    var want: Int


def test_index() raises:
    """Go's `indexTests`."""
    var cases = List[Case]()
    cases.append(Case("", "", 0))
    cases.append(Case("", "a", -1))
    cases.append(Case("", "foo", -1))
    cases.append(Case("fo", "foo", -1))
    cases.append(Case("foo", "foo", 0))
    cases.append(Case("oofofoofooo", "f", 2))
    cases.append(Case("oofofoofooo", "foo", 4))
    cases.append(Case("barfoobarfoo", "foo", 3))
    cases.append(Case("foo", "", 0))
    cases.append(Case("foo", "o", 1))
    cases.append(Case("abcABCabc", "A", 3))
    # The rune the whole library keeps coming back to: three bytes, so the
    # answer is 2 and not 1, and a caller who thinks in characters is wrong.
    cases.append(Case("ab☺c", "☺", 2))
    cases.append(Case("a☺b☻c☹d", "☹", 9))
    for row in cases:
        assert_equal(index(row.s, row.sep), row.want)


def test_last_index() raises:
    """Go's `lastIndexTests`."""
    var cases = List[Case]()
    cases.append(Case("", "", 0))
    cases.append(Case("", "a", -1))
    cases.append(Case("", "foo", -1))
    cases.append(Case("fo", "foo", -1))
    cases.append(Case("foo", "foo", 0))
    cases.append(Case("foo", "f", 0))
    cases.append(Case("oofofoofooo", "f", 7))
    cases.append(Case("oofofoofooo", "foo", 7))
    cases.append(Case("barfoobarfoo", "foo", 9))
    cases.append(Case("foo", "", 3))
    cases.append(Case("foo", "o", 2))
    cases.append(Case("abcABCabc", "A", 3))
    cases.append(Case("abcABCabc", "a", 6))
    for row in cases:
        assert_equal(last_index(row.s, row.sep), row.want)


def test_index_byte_and_last_index_byte() raises:
    """One byte rather than a substring, from both ends."""
    assert_equal(index_byte("", Byte(ord("a"))), -1)
    assert_equal(index_byte("abcabc", Byte(ord("b"))), 1)
    assert_equal(last_index_byte("abcabc", Byte(ord("b"))), 4)
    assert_equal(index_byte("abc", Byte(ord("z"))), -1)
    assert_equal(last_index_byte("abc", Byte(ord("z"))), -1)
    # A byte, so the second byte of a two byte rune is a legal thing to ask
    # for and is found in the middle of a character.
    assert_equal(index_byte("é", 0xA9), 1)


def test_index_rune() raises:
    """Go's `indexRuneTests`, minus the invalid input rows."""
    assert_equal(index_rune("", Int32(ord("a"))), -1)
    assert_equal(index_rune("", 0), -1)
    assert_equal(index_rune("chicken", Int32(ord("k"))), 4)
    assert_equal(index_rune("chicken", Int32(ord("d"))), -1)
    assert_equal(index_rune("a☺b☻c☹d", 0x263A), 1)
    assert_equal(index_rune("a☺b☻c☹d", 0x2639), 9)
    assert_equal(index_rune("a☺b☻c☹d", Int32(ord("d"))), 12)
    # Go's rule for a rune that is not a code point: it matches U+FFFD,
    # because that is what writing it out would have produced.
    assert_equal(index_rune("日本語日本語日本語", 0xD800), -1)


def test_index_any_and_last_index_any() raises:
    """Go's `indexAnyTests` and `lastIndexAnyTests`.

    A set of runes and not a substring, which is the difference between
    `index_any` and `index` and is worth one row of its own: `xcz` is not in
    `abc` anywhere, and `c` is.
    """
    assert_equal(index_any("", ""), -1)
    assert_equal(index_any("", "a"), -1)
    assert_equal(index_any("a", ""), -1)
    assert_equal(index_any("a", "a"), 0)
    assert_equal(index_any("aaa", "a"), 0)
    assert_equal(index_any("abc", "xyz"), -1)
    assert_equal(index_any("abc", "xcz"), 2)
    assert_equal(index_any("ab☺c", "x☺yz"), 2)
    assert_equal(index_any("a☺b☻c☹d", "cx"), 8)
    assert_equal(index_any("aRegExp*", ".(|)*+?^$[]"), 7)

    assert_equal(last_index_any("", ""), -1)
    assert_equal(last_index_any("", "a"), -1)
    assert_equal(last_index_any("a", "a"), 0)
    assert_equal(last_index_any("aaa", "a"), 2)
    assert_equal(last_index_any("abc", "xcz"), 2)
    assert_equal(last_index_any("a☺b☻c☹d", "cx"), 8)
    assert_equal(last_index_any("a.RegExp*", ".(|)*+?^$[]"), 8)


def test_index_func_and_last_index_func() raises:
    """Go's `TestIndexFunc`, with its own predicate.

    The answer is a byte offset even though the predicate is asked about
    runes, which is what makes the result usable as a slice bound.
    """

    @parameter
    def is_valid_rune(r: Int32) -> Bool:
        return r != 0xFFFD

    @parameter
    def is_digit(r: Int32) -> Bool:
        return r >= Int32(ord("0")) and r <= Int32(ord("9"))

    assert_equal(index_func[is_digit]("abc123"), 3)
    assert_equal(index_func[is_digit]("abc"), -1)
    assert_equal(last_index_func[is_digit]("abc123"), 5)
    assert_equal(last_index_func[is_digit]("abc"), -1)
    assert_equal(index_func[is_valid_rune]("☺abc"), 0)
    assert_equal(last_index_func[is_valid_rune]("abc☺"), 3)
    assert_true(contains_func[is_digit]("abc123"))
    assert_false(contains_func[is_digit]("abc"))


def test_contains() raises:
    """Go's `containsTests`, `containsAnyTests` and `containsRuneTests`."""
    assert_true(contains("abc", "bc"))
    assert_true(contains("abc", ""))
    assert_true(contains("", ""))
    assert_false(contains("", "a"))
    assert_false(contains("abc", "d"))

    assert_false(contains_any("", ""))
    assert_false(contains_any("", "a"))
    assert_false(contains_any("a", ""))
    assert_true(contains_any("hello", "el"))
    assert_false(contains_any("hello", "xyz"))
    assert_true(contains_any("failure", "ui"))
    assert_true(contains_any("some words", "xyzabc "))

    assert_false(contains_rune("", Int32(ord("a"))))
    assert_true(contains_rune("abc", Int32(ord("b"))))
    assert_true(contains_rune("aardvark", Int32(ord("a"))))
    assert_true(contains_rune("timeout", 0x74))
    assert_false(contains_rune("hello", 0x263A))
    assert_true(contains_rune("a☺b", 0x263A))


def test_count() raises:
    """Go's `countTests`.

    The empty separator row is the interesting one: it counts the places a
    string can be cut, which is one more than the number of runes, and it
    counts runes rather than bytes.
    """
    assert_equal(count("", ""), 1)
    assert_equal(count("", "notempty"), 0)
    assert_equal(count("notempty", ""), 9)
    assert_equal(count("smaller", "not smaller"), 0)
    assert_equal(count("12345678987654321", "6"), 2)
    assert_equal(count("611161116", "6"), 3)
    assert_equal(count("notequal", "NotEqual"), 0)
    assert_equal(count("equal", "equal"), 1)
    assert_equal(count("abc1231231123q", "123"), 3)
    assert_equal(count("11111", "11"), 2)
    # Four runes in nine bytes, so the empty separator answers five.
    assert_equal(count("日本語日", ""), 5)
