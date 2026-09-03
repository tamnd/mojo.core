"""Taking characters off the ends. Go's `TestTrim` and friends.

There is real arithmetic under these, which is why the tables are here in full
rather than being trusted to `tests/bytes`. `core.bytes` answers with a span,
and this package has to turn that span back into a byte range of the original
so it can cut a `StringSlice` out of it. It does that from lengths: a left trim
keeps a suffix, so the start of the answer is however much was lost, and a
right trim keeps a prefix, so the end of the answer is however much was kept.
An error either way is an off by one that lands in the middle of a rune, and
`s[byte=a:b]` aborts on that rather than returning nonsense, so a wrong answer
here is a crash and not a silent corruption.

Every row is asserted as an owned `String`, so a failure prints the text.
"""

from std.testing import assert_equal, assert_true

from core.strings import (
    trim,
    trim_func,
    trim_left,
    trim_left_func,
    trim_prefix,
    trim_right,
    trim_right_func,
    trim_space,
    trim_suffix,
)


@fieldwise_init
struct Case(Copyable, Movable):
    """A string, a cutset or affix, and what should be left."""

    var s: String
    var arg: String
    var want: String


def test_trim() raises:
    """Go's `trimTests` for `Trim`."""
    var cases = List[Case]()
    cases.append(Case("abba", "a", "bb"))
    cases.append(Case("abba", "ab", ""))
    cases.append(Case("<tag>", "<>", "tag"))
    cases.append(Case("* listitem", " *", "listitem"))
    cases.append(Case('("quote")', '()"' + chr(0x201D) + chr(0x201C), "quote"))
    cases.append(Case("  \t\r\n x\t\t\r\r\n\n ", " \t\r\n ", "x"))
    cases.append(Case("", "", ""))
    cases.append(Case("abba", "", "abba"))
    cases.append(Case("", "123", ""))
    cases.append(Case("", "a", ""))
    cases.append(Case("abc", "abc", ""))
    for row in cases:
        assert_equal(String(trim(row.s, row.arg)), row.want)


def test_trim_left_and_right() raises:
    """Go's `trimTests` for `TrimLeft` and `TrimRight`.

    The pair that the offset arithmetic can get backwards, so both directions
    are asserted on the same input.
    """
    assert_equal(String(trim_left("abba", "a")), "bba")
    assert_equal(String(trim_right("abba", "a")), "abb")
    assert_equal(String(trim_left("abba", "b")), "abba")
    assert_equal(String(trim_right("abba", "b")), "abba")
    assert_equal(String(trim_left("<tag>", "<>")), "tag>")
    assert_equal(String(trim_right("<tag>", "<>")), "<tag")
    assert_equal(String(trim_left("* listitem", " *")), "listitem")
    assert_equal(String(trim_left("", "123")), "")
    assert_equal(String(trim_right("", "123")), "")
    assert_equal(String(trim_left("abba", "")), "abba")
    assert_equal(String(trim_right("abba", "")), "abba")
    assert_equal(String(trim_left("abc", "abc")), "")
    assert_equal(String(trim_right("abc", "abc")), "")


def test_trim_cuts_runes_and_not_bytes() raises:
    """A cutset is a set of characters, so a multi byte one comes off whole.

    This is the row that would pass on a byte at a time implementation only by
    accident, and the row where an off by one lands inside a character and
    takes the abort rather than returning half of it.
    """
    assert_equal(String(trim("☺☻hello☻☺", "☺☻")), "hello")
    assert_equal(String(trim_left("☺☻hello", "☺☻")), "hello")
    assert_equal(String(trim_right("hello☻☺", "☺☻")), "hello")
    # The cutset is a set, so the order it is written in does not matter and a
    # rune not present changes nothing.
    assert_equal(String(trim("☺☻hello☻☺", "☻x☺")), "hello")


def test_trim_prefix_and_suffix() raises:
    """Go's `TestTrimPrefix` and `TestTrimSuffix`.

    A whole string and not a set, and no repetition: one copy comes off and
    the rest stays, which is the difference from `trim_left`.
    """
    assert_equal(String(trim_prefix("aabb", "a")), "abb")
    assert_equal(String(trim_suffix("aabb", "b")), "aab")
    assert_equal(String(trim_prefix("abba", "ab")), "ba")
    assert_equal(String(trim_suffix("abba", "ba")), "ab")
    # No match leaves the string alone rather than raising, which is what makes
    # this usable without asking `has_prefix` first.
    assert_equal(String(trim_prefix("abba", "x")), "abba")
    assert_equal(String(trim_suffix("abba", "x")), "abba")
    assert_equal(String(trim_prefix("abba", "")), "abba")
    assert_equal(String(trim_suffix("abba", "")), "abba")
    assert_equal(String(trim_prefix("", "a")), "")
    assert_equal(String(trim_suffix("", "a")), "")


def test_trim_space() raises:
    """Go's `trimSpaceTests`.

    White space is the Unicode property and not the six ASCII bytes, so the
    non-breaking space and the ideographic space come off. U+200B ZERO WIDTH
    SPACE does not, because Unicode does not call it white space however much
    it looks like one, and Go agrees.
    """
    assert_equal(String(trim_space("")), "")
    assert_equal(String(trim_space("  a")), "a")
    assert_equal(String(trim_space("b  ")), "b")
    assert_equal(String(trim_space("abc")), "abc")
    assert_equal(String(trim_space(" \t\r\n \t\t\r\r\n\n ")), "")
    assert_equal(String(trim_space(" \t\r\n x \t\t\r\r\n\n ")), "x")
    # The three that are white space and are not the space bar. Written with
    # `chr` rather than as literals, because two of them are invisible in a
    # source file and the third is easy to mistake for an ordinary space.
    var nel = chr(0x85)  # NEL
    var nbsp = chr(0xA0)  # NO-BREAK SPACE
    var ideographic = chr(0x3000)  # IDEOGRAPHIC SPACE
    assert_equal(String(trim_space(nel + "x" + nbsp)), "x")
    assert_equal(String(trim_space(ideographic + "x" + ideographic)), "x")
    # U+200B ZERO WIDTH SPACE is not White_Space, however much it looks like
    # one, so it stays where it is. Go answers the same way.
    var zwsp = chr(0x200B)
    assert_equal(String(trim_space(zwsp + "x" + zwsp)), zwsp + "x" + zwsp)


def test_trim_func() raises:
    """Go's `TestTrimFunc`, on a predicate the tables cannot express."""

    @parameter
    def is_digit(r: Int32) -> Bool:
        return r >= Int32(ord("0")) and r <= Int32(ord("9"))

    assert_equal(String(trim_func[is_digit]("123abc456")), "abc")
    assert_equal(String(trim_left_func[is_digit]("123abc456")), "abc456")
    assert_equal(String(trim_right_func[is_digit]("123abc456")), "123abc")
    assert_equal(String(trim_func[is_digit]("abc")), "abc")
    assert_equal(String(trim_func[is_digit]("123")), "")
    assert_equal(String(trim_func[is_digit]("")), "")


def test_trimming_the_same_string_twice() raises:
    """Two slices of one string in one call, which is the `ImmOrigin` bound.

    With the `Origin` bound `core.bytes` uses, this does not compile: two spans
    over the same mutable origin cannot both be arguments to one call, and a
    caller trimming a string of its own characters is doing exactly that. It is
    a silly thing to want and it is a normal thing to hit, since the second
    argument is often a field of the same object as the first.
    """
    var s = String("aabbaa")
    assert_equal(String(trim(s, s)), "")
    assert_equal(String(trim_left(s, s)), "")
    assert_equal(String(trim_prefix(s, s)), "")
