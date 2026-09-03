"""Changing case and rewriting text. Go's `TestToUpper` and the edit half.

Two subjects, both of them functions that return an owned `String` rather than
a view, because none of them produce a subsequence of what they were given.
Upper casing can make a string longer, `replace` can make it shorter, and `map`
can do either.

The case tables are Go's, plus the rows that say what one to one case mapping
does not do: ß stays ß, because SS is full case mapping and needs a table
neither library carries, and title case is not the same as upper case for the
few dozen digraphs that exist to have three forms.
"""

from std.testing import assert_equal, assert_raises

from core.strings import (
    clone,
    join,
    map,
    repeat,
    replace,
    replace_all,
    to_lower,
    to_lower_special,
    to_title,
    to_title_special,
    to_upper,
    to_upper_special,
    to_valid_utf8,
)
from core.unicode import AzeriCase, TurkishCase


def test_to_upper_and_to_lower() raises:
    """Go's `upperTests` and `lowerTests`."""
    assert_equal(to_upper(""), "")
    assert_equal(to_upper("abc"), "ABC")
    assert_equal(to_upper("AbC123"), "ABC123")
    assert_equal(to_upper("azAZ09_"), "AZAZ09_")
    assert_equal(
        to_upper("longStrinGwitHmixofsmaLLandcAps"),
        "LONGSTRINGWITHMIXOFSMALLANDCAPS",
    )
    assert_equal(to_upper("αβδ"), "ΑΒΔ")

    assert_equal(to_lower(""), "")
    assert_equal(to_lower("abc"), "abc")
    assert_equal(to_lower("AbC123"), "abc123")
    assert_equal(to_lower("azAZ09_"), "azaz09_")
    assert_equal(to_lower("ΑΒΔ"), "αβδ")


def test_case_mapping_is_one_rune_at_a_time() raises:
    """What one to one mapping cannot do, said out loud.

    ß upper cases to itself and not to SS, and the Turkish dotless ı upper
    cases to `I` and loses the distinction it was carrying. Both are Go's
    answers, and both need the full case mapping tables to do better.
    """
    assert_equal(to_upper("ß"), "ß")
    assert_equal(to_upper("straße"), "STRAßE")
    # Upper casing can still change the length: U+0250 is two bytes and the
    # U+2C6F it maps to is three.
    assert_equal(to_upper("ɐ"), "Ɐ")


def test_to_title() raises:
    """Rune by rune title case, which is not capitalise each word.

    Go's `strings.ToTitle` does this and Go's `strings.Title` does the other
    one; `Title` is deprecated in Go itself for getting the word boundaries
    wrong, and it is waived here rather than ported.
    """
    assert_equal(to_title("abc"), "ABC")
    assert_equal(to_title(" aaa bbb "), " AAA BBB ")
    # The reason title case is a third function: U+01C6 has three forms, and
    # the title one has exactly one capital letter in it.
    assert_equal(to_title("ǆ"), "ǅ")
    assert_equal(to_upper("ǆ"), "Ǆ")


def test_special_cases() raises:
    """Go's `TestSpecialCase`.

    Turkish is the language these exist for. Without the special case, `I`
    lower cases to `i` and the word is a different word.
    """
    assert_equal(to_upper_special(TurkishCase(), "istanbul"), "İSTANBUL")
    assert_equal(to_lower_special(TurkishCase(), "İSTANBUL"), "istanbul")
    assert_equal(to_lower_special(TurkishCase(), "I"), "ı")
    assert_equal(to_title_special(TurkishCase(), "istanbul"), "İSTANBUL")
    # Azeri ships the same four rows in Go, so it answers the same way.
    assert_equal(to_upper_special(AzeriCase(), "i"), "İ")
    # A rune the table says nothing about takes the ordinary mapping, which is
    # what makes these usable on a whole document.
    assert_equal(to_upper_special(TurkishCase(), "abc"), "ABC")


def test_clone_and_join() raises:
    """Go's `TestClone` and `TestJoin`."""
    assert_equal(clone(""), "")
    assert_equal(clone("abc"), "abc")

    var empty = List[StringSlice[StaticConstantOrigin]]()
    assert_equal(join(empty, ","), "")

    var one = List[StringSlice[StaticConstantOrigin]]()
    one.append("foo")
    assert_equal(join(one, ","), "foo")

    var many = List[StringSlice[StaticConstantOrigin]]()
    many.append("foo")
    many.append("bar")
    many.append("baz")
    assert_equal(join(many, ", "), "foo, bar, baz")
    assert_equal(join(many, ""), "foobarbaz")

    # The separator goes between and never on an end, so two pieces get one
    # separator and an empty piece still counts as a piece.
    var blanks = List[StringSlice[StaticConstantOrigin]]()
    blanks.append("")
    blanks.append("")
    assert_equal(join(blanks, "-"), "-")


def test_repeat() raises:
    """Go's `TestRepeat`, including the counts that are not repetition."""
    assert_equal(repeat("", 0), "")
    assert_equal(repeat("", 5), "")
    assert_equal(repeat("-", 0), "")
    assert_equal(repeat("-", 1), "-")
    assert_equal(repeat("-", 5), "-----")
    assert_equal(repeat("abc", 3), "abcabcabc")
    # Go panics on a negative count. Raising is the same refusal with a value
    # the caller can catch.
    with assert_raises():
        _ = repeat("x", -1)


def test_replace() raises:
    """Go's `ReplaceTests`.

    The empty `old` row is the one that looks like a bug and is not: it
    inserts before every rune and once at the end, which is the same counting
    `count(s, "")` does.
    """
    assert_equal(replace("hello", "l", "L", 0), "hello")
    assert_equal(replace("hello", "l", "L", -1), "heLLo")
    assert_equal(replace("hello", "x", "X", -1), "hello")
    assert_equal(replace("", "x", "X", -1), "")
    assert_equal(replace("radar", "r", "<r>", -1), "<r>ada<r>")
    assert_equal(replace("", "", "<>", -1), "<>")
    assert_equal(replace("banana", "a", "<>", -1), "b<>n<>n<>")
    assert_equal(replace("banana", "a", "<>", 1), "b<>nana")
    assert_equal(replace("banana", "a", "<>", 1000), "b<>n<>n<>")
    assert_equal(replace("banana", "an", "", -1), "ba")
    assert_equal(replace("banana", "", "-", -1), "-b-a-n-a-n-a-")
    assert_equal(replace("banana", "", "-", 5), "-b-a-n-a-na")
    assert_equal(replace("banana", "", "-", 1), "-banana")
    assert_equal(replace_all("banana", "a", "o"), "bonono")
    # An empty `old` counts runes and not bytes, so a three byte character
    # gets one insertion and not three.
    assert_equal(replace("☺", "", "-", -1), "-☺-")


def test_map() raises:
    """Go's `TestMap`.

    A negative result drops the rune, which is how Go says delete this one and
    is why the answer can be shorter than the input.
    """

    @parameter
    def rot13(r: Int32) -> Int32:
        if r >= Int32(ord("a")) and r <= Int32(ord("z")):
            return (r - Int32(ord("a")) + 13) % 26 + Int32(ord("a"))
        if r >= Int32(ord("A")) and r <= Int32(ord("Z")):
            return (r - Int32(ord("A")) + 13) % 26 + Int32(ord("A"))
        return r

    @parameter
    def drop_vowels(r: Int32) -> Int32:
        if (
            r == Int32(ord("a"))
            or r == Int32(ord("e"))
            or r == Int32(ord("i"))
            or r == Int32(ord("o"))
            or r == Int32(ord("u"))
        ):
            return -1
        return r

    @parameter
    def widen(r: Int32) -> Int32:
        if r == Int32(ord("a")):
            return 0x263A
        return r

    assert_equal(map[rot13]("a to zed"), "n gb mrq")
    assert_equal(map[rot13](map[rot13]("a to zed")), "a to zed")
    assert_equal(map[drop_vowels]("banana"), "bnn")
    assert_equal(map[drop_vowels]("aeiou"), "")
    assert_equal(map[widen]("cat"), "c☺t")
    assert_equal(map[rot13](""), "")


def test_to_valid_utf8() raises:
    """Nothing to repair, because a `StringSlice` is valid by construction.

    In Go this function earns its place, since a `string` read off a socket
    routinely is not text. Here the only input the type system allows is
    already valid, so the answer is always a copy of the argument. It is kept
    so that code ported from Go still compiles, and `tests/bytes` is where the
    repairing is actually exercised.
    """
    assert_equal(to_valid_utf8("", "x"), "")
    assert_equal(to_valid_utf8("abc", "x"), "abc")
    assert_equal(to_valid_utf8("☺☻☹", "x"), "☺☻☹")
