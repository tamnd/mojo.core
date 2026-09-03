"""Finding things in a byte slice. Go's index, count and contains tables.

`indexTests` is the table that matters most in the whole package. Two thirds of
its rows are the `fofofofofofoboo` family, which look like noise and are not:
each one is a needle whose prefix repeats inside the haystack, which is exactly
the input that breaks a search that skips forward by the wrong amount after a
partial match. The Rabin-Karp fallback row at the end is 72 zeros against 67
zeros, which is the case that decides whether the fallback is entered at all.

Everything here is run over the same tables Go runs, transcribed row for row,
including the rows that are not valid UTF-8. `index_any` and `last_index_any`
take a span here rather than Go's `string`, which is the same bytes.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.bytes import (
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
from core.io import Byte
from core.unicode import is_digit, is_space, is_upper
from core.unicode.utf8 import MAX_RUNE, RUNE_ERROR

from tests.bytes._fixtures import SPACE, enc

comptime DOTS = "1....2....3....4"
"""Go's `dots`."""

comptime FACES = "☺☻☹"
"""Go's `faces`."""


@fieldwise_init
struct BinOp(Copyable, Movable):
    """Go's `BinOpTest`: two slices and an offset."""

    var a: String
    var b: String
    var want: Int


def index_cases() -> List[BinOp]:
    """Go's `indexTests`."""
    var out = List[BinOp]()
    out.append(BinOp("", "", 0))
    out.append(BinOp("", "a", -1))
    out.append(BinOp("", "foo", -1))
    out.append(BinOp("fo", "foo", -1))
    out.append(BinOp("foo", "baz", -1))
    out.append(BinOp("foo", "foo", 0))
    out.append(BinOp("oofofoofooo", "f", 2))
    out.append(BinOp("oofofoofooo", "foo", 4))
    out.append(BinOp("barfoobarfoo", "foo", 3))
    out.append(BinOp("foo", "", 0))
    out.append(BinOp("foo", "o", 1))
    out.append(BinOp("abcABCabc", "A", 3))
    # One byte needles, which are `index_byte` reached through `index`.
    out.append(BinOp("x", "a", -1))
    out.append(BinOp("x", "x", 0))
    out.append(BinOp("abc", "a", 0))
    out.append(BinOp("abc", "b", 1))
    out.append(BinOp("abc", "c", 2))
    out.append(BinOp("abc", "x", -1))
    out.append(BinOp("barfoobarfooyyyzzzyyyzzzyyyzzzyyyxxxzzzyyy", "x", 33))
    # Needles whose own prefix repeats in the haystack.
    out.append(BinOp("fofofofooofoboo", "oo", 7))
    out.append(BinOp("fofofofofofoboo", "ob", 11))
    out.append(BinOp("fofofofofofoboo", "boo", 12))
    out.append(BinOp("fofofofofofoboo", "oboo", 11))
    out.append(BinOp("fofofofofoooboo", "fooo", 8))
    out.append(BinOp("fofofofofofoboo", "foboo", 10))
    out.append(BinOp("fofofofofofoboo", "fofob", 8))
    out.append(BinOp("fofofofofofofoffofoobarfoo", "foffof", 12))
    out.append(BinOp("fofofofofoofofoffofoobarfoo", "foffof", 13))
    out.append(BinOp("fofofofofofofoffofoobarfoo", "foffofo", 12))
    out.append(BinOp("fofofofofoofofoffofoobarfoo", "foffofo", 13))
    out.append(BinOp("fofofofofoofofoffofoobarfoo", "foffofoo", 13))
    out.append(BinOp("fofofofofofofoffofoobarfoo", "foffofoo", 12))
    out.append(BinOp("fofofofofoofofoffofoobarfoo", "foffofoob", 13))
    out.append(BinOp("fofofofofofofoffofoobarfoo", "foffofoob", 12))
    out.append(BinOp("fofofofofoofofoffofoobarfoo", "foffofooba", 13))
    out.append(BinOp("fofofofofofofoffofoobarfoo", "foffofooba", 12))
    out.append(BinOp("fofofofofoofofoffofoobarfoo", "foffofoobar", 13))
    out.append(BinOp("fofofofofofofoffofoobarfoo", "foffofoobar", 12))
    out.append(BinOp("fofofofofoofofoffofoobarfoo", "foffofoobarf", 13))
    out.append(BinOp("fofofofofofofoffofoobarfoo", "foffofoobarf", 12))
    out.append(BinOp("fofofofofoofofoffofoobarfoo", "foffofoobarfo", 13))
    out.append(BinOp("fofofofofofofoffofoobarfoo", "foffofoobarfo", 12))
    out.append(BinOp("fofofofofoofofoffofoobarfoo", "foffofoobarfoo", 13))
    out.append(BinOp("fofofofofofofoffofoobarfoo", "foffofoobarfoo", 12))
    out.append(BinOp("fofofofofoofofoffofoobarfoo", "ofoffofoobarfoo", 12))
    out.append(BinOp("fofofofofofofoffofoobarfoo", "ofoffofoobarfoo", 11))
    out.append(BinOp("fofofofofoofofoffofoobarfoo", "fofoffofoobarfoo", 11))
    out.append(BinOp("fofofofofofofoffofoobarfoo", "fofoffofoobarfoo", 10))
    out.append(BinOp("fofofofofoofofoffofoobarfoo", "foobars", -1))
    out.append(BinOp("foofyfoobarfoobar", "y", 4))
    out.append(BinOp("oooooooooooooooooooooo", "r", -1))
    out.append(BinOp("oxoxoxoxoxoxoxoxoxoxoxoy", "oy", 22))
    out.append(BinOp("oxoxoxoxoxoxoxoxoxoxoxox", "oy", -1))
    # The Rabin-Karp fallback: 72 zeros with a one at the end, 67 zeros.
    out.append(
        BinOp(
            "000000000000000000000000000000000000000000000000000000000000000000000001",
            "0000000000000000000000000000000000000000000000000000000000000000001",
            5,
        )
    )
    # A needle that is one rune, found past the point a byte search gives up.
    out.append(BinOp("oxoxoxoxoxoxoxoxoxoxox☺", "☺", 22))
    # A needle that is not valid UTF-8, so the rune path must not be taken.
    out.append(
        BinOp(
            "xx0123456789012345678901234567890123456789012345678901234567890120123456789012345678901234567890123456xxx\\xed\\x9f\\xc0",
            "\\xed\\x9f\\xc0",
            105,
        )
    )
    return out^


def last_index_cases() -> List[BinOp]:
    """Go's `lastIndexTests`."""
    var out = List[BinOp]()
    out.append(BinOp("", "", 0))
    out.append(BinOp("", "a", -1))
    out.append(BinOp("", "foo", -1))
    out.append(BinOp("fo", "foo", -1))
    out.append(BinOp("foo", "foo", 0))
    out.append(BinOp("foo", "f", 0))
    out.append(BinOp("oofofoofooo", "f", 7))
    out.append(BinOp("oofofoofooo", "foo", 7))
    out.append(BinOp("barfoobarfoo", "foo", 9))
    out.append(BinOp("foo", "", 3))
    out.append(BinOp("foo", "o", 2))
    out.append(BinOp("abcABCabc", "A", 3))
    out.append(BinOp("abcABCabc", "a", 6))
    return out^


def index_any_cases() -> List[BinOp]:
    """Go's `indexAnyTests`."""
    var out = List[BinOp]()
    out.append(BinOp("", "", -1))
    out.append(BinOp("", "a", -1))
    out.append(BinOp("", "abc", -1))
    out.append(BinOp("a", "", -1))
    out.append(BinOp("a", "a", 0))
    out.append(BinOp("\\x80", "\\xffb", 0))
    out.append(BinOp("aaa", "a", 0))
    out.append(BinOp("abc", "xyz", -1))
    out.append(BinOp("abc", "xcz", 2))
    out.append(BinOp("ab☺c", "x☺yz", 2))
    out.append(BinOp("a☺b☻c☹d", "cx", 8))
    out.append(BinOp("a☺b☻c☹d", "uvw☻xyz", 5))
    out.append(BinOp("aRegExp*", ".(|)*+?^$[]", 7))
    out.append(BinOp(DOTS + DOTS + DOTS, " ", -1))
    out.append(BinOp("012abcba210", "\\xffb", 4))
    out.append(BinOp("012\\x80bcb\\x80210", "\\xffb", 3))
    out.append(BinOp("0123456\\xcf\\x80abc", "\\xcfb\\x80", 10))
    return out^


def last_index_any_cases() -> List[BinOp]:
    """Go's `lastIndexAnyTests`."""
    var out = List[BinOp]()
    out.append(BinOp("", "", -1))
    out.append(BinOp("", "a", -1))
    out.append(BinOp("", "abc", -1))
    out.append(BinOp("a", "", -1))
    out.append(BinOp("a", "a", 0))
    out.append(BinOp("\\x80", "\\xffb", 0))
    out.append(BinOp("aaa", "a", 2))
    out.append(BinOp("abc", "xyz", -1))
    out.append(BinOp("abc", "ab", 1))
    out.append(BinOp("ab☺c", "x☺yz", 2))
    out.append(BinOp("a☺b☻c☹d", "cx", 8))
    out.append(BinOp("a☺b☻c☹d", "uvw☻xyz", 5))
    out.append(BinOp("a.RegExp*", ".(|)*+?^$[]", 8))
    out.append(BinOp(DOTS + DOTS + DOTS, " ", -1))
    out.append(BinOp("012abcba210", "\\xffb", 6))
    out.append(BinOp("012\\x80bcb\\x80210", "\\xffb", 7))
    out.append(BinOp("0123456\\xcf\\x80abc", "\\xcfb\\x80", 10))
    return out^


def test_index() raises:
    """Go's `TestIndex`."""
    var cases = index_cases()
    for row in cases:
        var s = enc(row.a)
        var sep = enc(row.b)
        assert_equal(index(Span(s), Span(sep)), row.want)


def test_last_index() raises:
    """Go's `TestLastIndex`."""
    var cases = last_index_cases()
    for row in cases:
        var s = enc(row.a)
        var sep = enc(row.b)
        assert_equal(last_index(Span(s), Span(sep)), row.want)


def test_index_any() raises:
    """Go's `TestIndexAny`. The set is runes, so `\\xff` matches `\\x80`
    through `RUNE_ERROR` and not by byte."""
    var cases = index_any_cases()
    for row in cases:
        var s = enc(row.a)
        var chars = enc(row.b)
        assert_equal(index_any(Span(s), Span(chars)), row.want)


def test_last_index_any() raises:
    """Go's `TestLastIndexAny`."""
    var cases = last_index_any_cases()
    for row in cases:
        var s = enc(row.a)
        var chars = enc(row.b)
        assert_equal(last_index_any(Span(s), Span(chars)), row.want)


def test_index_byte_and_last_index_byte() raises:
    """Go's `TestIndexByte` and `TestLastIndexByte`, over the one byte rows of
    the index tables, plus the byte that is not there."""
    var s = enc("abcABCabc")
    assert_equal(index_byte(Span(s), Byte(Int32(ord("a")))), 0)
    assert_equal(last_index_byte(Span(s), Byte(Int32(ord("a")))), 6)
    assert_equal(index_byte(Span(s), Byte(Int32(ord("A")))), 3)
    assert_equal(last_index_byte(Span(s), Byte(Int32(ord("C")))), 5)
    assert_equal(index_byte(Span(s), Byte(Int32(ord("x")))), -1)
    assert_equal(last_index_byte(Span(s), Byte(Int32(ord("x")))), -1)
    var empty = enc("")
    assert_equal(index_byte(Span(empty), Byte(Int32(ord("a")))), -1)
    assert_equal(last_index_byte(Span(empty), Byte(Int32(ord("a")))), -1)


def test_index_byte_at_every_offset_of_a_page() raises:
    """Go's `TestIndexByteBig` in the shape that matters here.

    A buffer larger than a page, with the byte at each offset in turn, so that
    a search reading a word at a time cannot run off the end and cannot skip
    the last few bytes. The naive loop passes trivially; the test is here for
    whatever replaces it.
    """
    # slow: five thousand searches over a five thousand byte buffer
    var size = 5015
    var b = List[Byte](length=size, fill=Byte(Int32(ord("z"))))
    for at in range(size):
        b[at] = Byte(Int32(ord("x")))
        assert_equal(index_byte(Span(b), Byte(Int32(ord("x")))), at)
        assert_equal(last_index_byte(Span(b), Byte(Int32(ord("x")))), at)
        b[at] = Byte(Int32(ord("z")))


@fieldwise_init
struct RuneCase(Copyable, Movable):
    """A haystack, a rune, and the offset of its first byte."""

    var s: String
    var r: Int32
    var want: Int


def test_index_rune() raises:
    """Go's `TestIndexRune`, including the rows that are not code points.

    The last group is the reason the function is not `index` over an encoding:
    a rune that cannot be encoded is looked for as `RUNE_ERROR`, so searching
    for a surrogate finds the replacement character, and searching for one in
    a slice that has no invalid bytes finds nothing.
    """
    var cases = List[RuneCase]()
    cases.append(RuneCase("", Int32(ord("a")), -1))
    cases.append(RuneCase("", 0x263A, -1))
    cases.append(RuneCase("foo", 0x2639, -1))
    cases.append(RuneCase("foo", Int32(ord("o")), 1))
    cases.append(RuneCase("foo☺bar", 0x263A, 3))
    cases.append(RuneCase("foo☺☻☹bar", 0x2639, 9))
    cases.append(RuneCase("a A x", Int32(ord("A")), 2))
    cases.append(RuneCase("some_text=some_value", Int32(ord("=")), 9))
    cases.append(RuneCase("☺a", Int32(ord("a")), 3))
    cases.append(RuneCase("a☻☺b", 0x263A, 4))
    # Two, three and four byte runes, each present and each absent.
    cases.append(RuneCase("ӆ", 0x4C6, 0))
    cases.append(RuneCase("a", 0x4C6, -1))
    cases.append(RuneCase("  ӆ", 0x4C6, 2))
    cases.append(RuneCase("Ꚁ", 0xA680, 0))
    cases.append(RuneCase("  Ꚁ", 0xA680, 2))
    cases.append(RuneCase("  a", 0xA680, -1))
    cases.append(RuneCase("𡌀", 0x21300, 0))
    cases.append(RuneCase("  𡌀", 0x21300, 2))
    cases.append(RuneCase("  a", 0x21300, -1))
    # `RUNE_ERROR` matches any byte that is not valid UTF-8.
    cases.append(RuneCase("\\xef\\xbf\\xbd", RUNE_ERROR, 0))
    cases.append(RuneCase("\\xff", RUNE_ERROR, 0))
    cases.append(RuneCase("☻x\\xef\\xbf\\xbd", RUNE_ERROR, 4))
    cases.append(RuneCase("☻x\\xe2\\x98", RUNE_ERROR, 4))
    cases.append(RuneCase("☻x\\xe2\\x98x", RUNE_ERROR, 4))
    # A rune that is not a code point never matches valid input.
    cases.append(RuneCase("a☺b☻c☹d", -1, -1))
    cases.append(RuneCase("a☺b☻c☹d", 0xD800, -1))
    cases.append(RuneCase("a☺b☻c☹d", MAX_RUNE + 1, -1))
    for row in cases:
        var s = enc(row.s)
        assert_equal(index_rune(Span(s), row.r), row.want)


def test_index_rune_at_the_cutover() raises:
    """Go's cutover rows: sixty four copies of a rune, then a different one
    that shares its last bytes."""
    var two = String("")
    for _ in range(64):
        two += "ц"
    var two_bytes = enc(two + "ӆ")
    assert_equal(index_rune(Span(two_bytes), 0x4C6), 128)
    var only = enc(two)
    assert_equal(index_rune(Span(only), 0x4C6), -1)

    var three = String("")
    for _ in range(64):
        three += "Ꙁ"
    var three_bytes = enc(three + "Ꚁ")
    assert_equal(index_rune(Span(three_bytes), 0xA680), 192)
    # U+A680 and U+4680 share their last two bytes, which is what a search
    # comparing suffixes gets wrong.
    assert_equal(index_rune(Span(three_bytes), 0x4680), -1)

    var four = String("")
    for _ in range(64):
        four += "𡋀"
    var four_bytes = enc(four + "𡌀")
    assert_equal(index_rune(Span(four_bytes), 0x21300), 256)
    assert_equal(index_rune(Span(four_bytes), 0x23300), -1)


def test_count() raises:
    """Go's `TestCount`, plus the empty needle rule.

    `count(s, "")` is the number of runes plus one, because that is how many
    places `split` on an empty separator cuts. The last row is the one that
    makes the two functions agree on input that is not valid UTF-8.
    """
    assert_equal(count(Span(enc("")), Span(enc(""))), 1)
    assert_equal(count(Span(enc("")), Span(enc("notempty"))), 0)
    assert_equal(count(Span(enc("notempty")), Span(enc(""))), 9)
    assert_equal(count(Span(enc("smaller")), Span(enc("not smaller"))), 0)
    assert_equal(count(Span(enc("12345678987654321")), Span(enc("6"))), 2)
    assert_equal(count(Span(enc("611161116")), Span(enc("6"))), 3)
    assert_equal(count(Span(enc("notequal")), Span(enc("NotEqual"))), 0)
    assert_equal(count(Span(enc("equal")), Span(enc("equal"))), 1)
    assert_equal(count(Span(enc("abc1231231123q")), Span(enc("123"))), 3)
    assert_equal(count(Span(enc("11111")), Span(enc("11"))), 2)
    assert_equal(count(Span(enc("☺☻☹")), Span(enc(""))), 4)


def test_count_a_byte_at_every_window() raises:
    """Go's `TestCountByte`: the same byte written across a moving window.

    The point is the boundaries. A count written a word at a time is right in
    the middle of a buffer and wrong at either end, and the windows here are
    the sizes on both sides of every alignment Go's assembly uses.
    """
    var size = 5015
    var b = List[Byte](length=size, fill=0)
    var windows = List[Int]()
    windows.append(1)
    windows.append(2)
    windows.append(3)
    windows.append(4)
    windows.append(15)
    windows.append(16)
    windows.append(17)
    windows.append(31)
    windows.append(32)
    windows.append(33)
    windows.append(63)
    windows.append(64)
    windows.append(65)
    windows.append(128)
    var needle = enc("d")
    for window in windows:
        for start in range(0, size - window, 997):
            for j in range(window):
                b[start + j] = Byte(Int32(ord("d")))
                var view = Span(b)[start : start + window]
                assert_equal(count(view, Span(needle)), j + 1)
            for j in range(window):
                b[start + j] = Byte(0)


def test_contains() raises:
    """Go's `TestContains`."""
    assert_true(contains(Span(enc("hello")), Span(enc("hel"))))
    assert_true(contains(Span(enc("日本語")), Span(enc("日本"))))
    assert_false(contains(Span(enc("hello")), Span(enc("Hello, world"))))
    assert_false(contains(Span(enc("東京")), Span(enc("京東"))))


def test_contains_any() raises:
    """Go's `TestContainsAny`."""
    assert_false(contains_any(Span(enc("")), Span(enc(""))))
    assert_false(contains_any(Span(enc("")), Span(enc("a"))))
    assert_false(contains_any(Span(enc("")), Span(enc("abc"))))
    assert_false(contains_any(Span(enc("a")), Span(enc(""))))
    assert_true(contains_any(Span(enc("a")), Span(enc("a"))))
    assert_true(contains_any(Span(enc("aaa")), Span(enc("a"))))
    assert_false(contains_any(Span(enc("abc")), Span(enc("xyz"))))
    assert_true(contains_any(Span(enc("abc")), Span(enc("xcz"))))
    assert_true(contains_any(Span(enc("a☺b☻c☹d")), Span(enc("uvw☻xyz"))))
    assert_true(contains_any(Span(enc("aRegExp*")), Span(enc(".(|)*+?^$[]"))))
    assert_false(contains_any(Span(enc(DOTS + DOTS + DOTS)), Span(enc(" "))))


def test_contains_rune() raises:
    """Go's `TestContainsRune`."""
    assert_false(contains_rune(Span(enc("")), Int32(ord("a"))))
    assert_true(contains_rune(Span(enc("a")), Int32(ord("a"))))
    assert_true(contains_rune(Span(enc("aaa")), Int32(ord("a"))))
    assert_false(contains_rune(Span(enc("abc")), Int32(ord("y"))))
    assert_true(contains_rune(Span(enc("abc")), Int32(ord("c"))))
    assert_false(contains_rune(Span(enc("a☺b☻c☹d")), Int32(ord("x"))))
    assert_true(contains_rune(Span(enc("a☺b☻c☹d")), 0x263B))
    assert_true(contains_rune(Span(enc("aRegExp*")), Int32(ord("*"))))


def test_contains_func() raises:
    """Go's `TestContainsFunc`, which runs the `contains_rune` table through a
    predicate that asks the same question."""

    @parameter
    def is_smiley(r: Int32) -> Bool:
        return r == 0x263B

    assert_true(contains_func[is_smiley](Span(enc("a☺b☻c☹d"))))
    assert_false(contains_func[is_smiley](Span(enc("abc"))))


@fieldwise_init
struct FuncCase(Copyable, Movable):
    """An input and the first and last offsets a predicate matches at."""

    var s: String
    var first: Int
    var last: Int


def test_index_func_over_digits() raises:
    """Go's `indexFuncTests`, the `isDigit` rows."""
    var cases = List[FuncCase]()
    cases.append(FuncCase("abc", -1, -1))
    cases.append(FuncCase("0123", 0, 3))
    cases.append(FuncCase("a1b", 1, 1))
    cases.append(
        FuncCase(
            "\\xe0\\xb9\\x90\\xe0\\xb9\\x9212hello34\\xe0\\xb9\\x90\\xe0\\xb9\\x91",
            0,
            18,
        )
    )
    cases.append(FuncCase("\\x801", 1, 1))
    cases.append(FuncCase("\\x80abc", -1, -1))

    @parameter
    def digit(r: Int32) -> Bool:
        return is_digit(r)

    for row in cases:
        var s = enc(row.s)
        assert_equal(index_func[digit](Span(s)), row.first)
        assert_equal(last_index_func[digit](Span(s)), row.last)


def test_index_func_over_the_other_predicates() raises:
    """The rest of Go's `indexFuncTests`: space, upper, and validity.

    The validity rows are the ones with teeth. `\\xc0☺\\xc0\\xc0` has a run of
    two invalid bytes at the end, and the answer for the last one is the first
    byte of that run rather than the last, which is what a backwards scan
    decoding one byte at a time gets wrong.

    Go's predicate there is `r != utf8.RuneError`, not `utf8.ValidRune(r)`, and
    the difference is the whole point: U+FFFD is a perfectly valid code point,
    so the question these rows ask is whether the decoder reported damage, not
    whether the rune it handed back could be encoded.
    """

    @parameter
    def space(r: Int32) -> Bool:
        return is_space(r)

    @parameter
    def upper(r: Int32) -> Bool:
        return is_upper(r)

    @parameter
    def not_valid(r: Int32) -> Bool:
        return r == RUNE_ERROR

    @parameter
    def valid(r: Int32) -> Bool:
        return r != RUNE_ERROR

    var spaces = enc(SPACE)
    assert_equal(index_func[space](Span(spaces)), 0)
    assert_equal(last_index_func[space](Span(spaces)), len(spaces) - 3)

    var uppers = enc(
        "\\xe2\\xb1\\xaf\\xe2\\xb1\\xaf\\xe2\\xb1\\xaf\\xe2\\xb1\\xafABCDhelloEF\\xe2\\xb1\\xaf\\xe2\\xb1\\xafGH\\xe2\\xb1\\xaf\\xe2\\xb1\\xaf"
    )
    assert_equal(index_func[upper](Span(uppers)), 0)
    assert_equal(last_index_func[upper](Span(uppers)), 34)

    assert_equal(index_func[valid](Span(enc(""))), -1)
    assert_equal(last_index_func[valid](Span(enc(""))), -1)
    assert_equal(index_func[valid](Span(enc("\\xc0a\\xc0"))), 1)
    assert_equal(last_index_func[valid](Span(enc("\\xc0a\\xc0"))), 1)
    assert_equal(index_func[not_valid](Span(enc("\\xc0a\\xc0"))), 0)
    assert_equal(last_index_func[not_valid](Span(enc("\\xc0a\\xc0"))), 2)
    assert_equal(index_func[not_valid](Span(enc("\\xc0☺\\xc0"))), 0)
    assert_equal(last_index_func[not_valid](Span(enc("\\xc0☺\\xc0"))), 4)
    assert_equal(last_index_func[not_valid](Span(enc("\\xc0☺\\xc0\\xc0"))), 5)
    assert_equal(index_func[not_valid](Span(enc("ab\\xc0a\\xc0cd"))), 2)
    assert_equal(last_index_func[not_valid](Span(enc("ab\\xc0a\\xc0cd"))), 4)
    assert_equal(index_func[not_valid](Span(enc("a\\xe0\\x80cd"))), 1)
    assert_equal(last_index_func[not_valid](Span(enc("a\\xe0\\x80cd"))), 2)
