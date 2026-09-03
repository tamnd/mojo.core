"""Taking things off the ends. Go's `trimTests`, `trimSpaceTests` and
`trimFuncTests`.

A cutset is a set of runes and not a substring, which is the one thing about
these functions that surprises people: `trim(s, "ab")` removes any run of `a`s
and `b`s in any order, and `trim_prefix(s, "ab")` removes the two bytes `ab`
once. Go's table has both in it and so does this one, next to each other, which
is the arrangement that makes the difference obvious.

Everything here returns a span into the input rather than a copy, so the checks
are on the contents and there is nothing to free. Go's `trimNilTests` are about
whether the result is nil or an empty non-nil slice, a distinction this library
does not have; the rows that are only about that are left out and the rest are
here as ordinary rows.
"""

from std.testing import assert_equal

from core.bytes import (
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
from core.unicode import is_digit, is_space, is_upper
from core.unicode.utf8 import RUNE_ERROR

from tests.bytes._fixtures import SPACE, enc, expect, quote

comptime THAI_ZERO = "\\xe0\\xb9\\x90"
"""U+0E50 THAI DIGIT ZERO. A digit that is not ASCII and is three bytes."""

comptime THAI_ONE = "\\xe0\\xb9\\x91"
"""U+0E51 THAI DIGIT ONE."""

comptime THAI_TWO = "\\xe0\\xb9\\x92"
"""U+0E52 THAI DIGIT TWO."""

comptime TURNED_A = "\\xe2\\xb1\\xaf"
"""U+2C6F LATIN CAPITAL LETTER TURNED A. An upper case rune outside ASCII."""


@fieldwise_init
struct TrimCase(Copyable, Movable):
    """Go's `TrimTest`: which function, an input, its argument, the answer."""

    var f: String
    var input: String
    var arg: String
    var want: String


def trim_cases() -> List[TrimCase]:
    """Go's `trimTests`.

    The `☺\\xc0` row at the end is the one that says a cutset is matched as
    runes: the trailing byte does not decode, so it is not the smiling face and
    is not removed.
    """
    var out = List[TrimCase]()
    out.append(TrimCase("trim", "abba", "a", "bb"))
    out.append(TrimCase("trim", "abba", "ab", ""))
    out.append(TrimCase("trim_left", "abba", "ab", ""))
    out.append(TrimCase("trim_right", "abba", "ab", ""))
    out.append(TrimCase("trim_left", "abba", "a", "bba"))
    out.append(TrimCase("trim_left", "abba", "b", "abba"))
    out.append(TrimCase("trim_right", "abba", "a", "abb"))
    out.append(TrimCase("trim_right", "abba", "b", "abba"))
    out.append(TrimCase("trim", "<tag>", "<>", "tag"))
    out.append(TrimCase("trim", "* listitem", " *", "listitem"))
    out.append(TrimCase("trim", '"quote"', '"', "quote"))
    out.append(
        TrimCase(
            "trim",
            TURNED_A * 2 + "\\xc9\\x90\\xc9\\x90" + TURNED_A * 2,
            TURNED_A,
            "\\xc9\\x90\\xc9\\x90",
        )
    )
    out.append(TrimCase("trim", "\\x80test\\xff", "\\xff", "test"))
    out.append(TrimCase("trim", " Ġ ", " ", "Ġ"))
    out.append(TrimCase("trim", " Ġİ0", "0 ", "Ġİ"))
    # The empty argument and the empty input.
    out.append(TrimCase("trim", "abba", "", "abba"))
    out.append(TrimCase("trim", "", "123", ""))
    out.append(TrimCase("trim", "", "", ""))
    out.append(TrimCase("trim_left", "abba", "", "abba"))
    out.append(TrimCase("trim_left", "", "123", ""))
    out.append(TrimCase("trim_left", "", "", ""))
    out.append(TrimCase("trim_right", "abba", "", "abba"))
    out.append(TrimCase("trim_right", "", "123", ""))
    out.append(TrimCase("trim_right", "", "", ""))
    out.append(TrimCase("trim_right", "☺\\xc0", "☺", "☺\\xc0"))
    # A prefix and a suffix are byte sequences, not sets.
    out.append(TrimCase("trim_prefix", "aabb", "a", "abb"))
    out.append(TrimCase("trim_prefix", "aabb", "b", "aabb"))
    out.append(TrimCase("trim_suffix", "aabb", "a", "aabb"))
    out.append(TrimCase("trim_suffix", "aabb", "b", "aab"))
    return out^


def test_trim() raises:
    """Go's `TestTrim`, all five functions off one table."""
    var cases = trim_cases()
    for row in cases:
        var s = enc(row.input)
        var arg = enc(row.arg)
        var got: String
        if row.f == "trim":
            got = quote(trim(Span(s), Span(arg)))
        elif row.f == "trim_left":
            got = quote(trim_left(Span(s), Span(arg)))
        elif row.f == "trim_right":
            got = quote(trim_right(Span(s), Span(arg)))
        elif row.f == "trim_prefix":
            got = quote(trim_prefix(Span(s), Span(arg)))
        else:
            got = quote(trim_suffix(Span(s), Span(arg)))
        assert_equal(got, expect(row.want))


def test_a_cutset_is_a_set_and_a_prefix_is_a_sequence() raises:
    """The distinction the two halves of the table are about, on one input.

    `trim_left(s, "ab")` takes off `aab` because every one of those runes is in
    the set; `trim_prefix(s, "ab")` takes off nothing, because `s` does not
    start with `a` followed by `b`.
    """
    var s = enc("aabxy")
    var arg = enc("ab")
    assert_equal(quote(trim_left(Span(s), Span(arg))), expect("xy"))
    assert_equal(quote(trim_prefix(Span(s), Span(arg))), expect("aabxy"))


def test_trim_space() raises:
    """Go's `trimSpaceTests`.

    The rows ending in bytes that do not decode are the ones that matter: a
    trailing `\\xc0` is not white space and is not removed, and an
    implementation that scanned backwards a byte at a time rather than a rune
    at a time would eat into it.
    """
    var cases = List[TrimCase]()
    cases.append(TrimCase("", "", "", ""))
    cases.append(TrimCase("", "  a", "", "a"))
    cases.append(TrimCase("", "b  ", "", "b"))
    cases.append(TrimCase("", "abc", "", "abc"))
    cases.append(TrimCase("", SPACE + "abc" + SPACE, "", "abc"))
    cases.append(TrimCase("", " ", "", ""))
    cases.append(TrimCase("", "\\xe3\\x80\\x80 ", "", ""))
    cases.append(TrimCase("", " \\xe3\\x80\\x80", "", ""))
    cases.append(TrimCase("", " \t\r\n \t\t\r\r\n\n ", "", ""))
    cases.append(TrimCase("", " \t\r\n x\t\t\r\r\n\n ", "", "x"))
    cases.append(
        TrimCase(
            "",
            " \\xe2\\x80\\x80\t\r\n x\t\t\r\r\ny\n \\xe3\\x80\\x80",
            "",
            "x\t\t\r\r\ny",
        )
    )
    cases.append(TrimCase("", "1 \t\r\n2", "", "1 \t\r\n2"))
    cases.append(TrimCase("", " x\\x80", "", "x\\x80"))
    cases.append(TrimCase("", " x\\xc0", "", "x\\xc0"))
    cases.append(TrimCase("", "x \\xc0\\xc0 ", "", "x \\xc0\\xc0"))
    cases.append(TrimCase("", "x \\xc0", "", "x \\xc0"))
    cases.append(TrimCase("", "x \\xc0 ", "", "x \\xc0"))
    cases.append(TrimCase("", "x ☺\\xc0\\xc0 ", "", "x ☺\\xc0\\xc0"))
    cases.append(TrimCase("", "x ☺ ", "", "x ☺"))
    for row in cases:
        var s = enc(row.input)
        assert_equal(quote(trim_space(Span(s))), expect(row.want))


@fieldwise_init
struct FuncCase(Copyable, Movable):
    """Go's `TrimFuncTest`: an input and what the three cuts leave of it."""

    var input: String
    var trimmed: String
    var left: String
    var right: String


def check[f: def(Int32) capturing[_] -> Bool](rows: List[FuncCase]) raises:
    """Run one predicate over its rows through all three `_func` cuts."""
    for row in rows:
        var s = enc(row.input)
        assert_equal(quote(trim_func[f](Span(s))), expect(row.trimmed))
        assert_equal(quote(trim_left_func[f](Span(s))), expect(row.left))
        assert_equal(quote(trim_right_func[f](Span(s))), expect(row.right))


def test_trim_func_over_space() raises:
    """Go's `trimFuncTests` rows for `isSpace`, including the two empty ones."""

    @parameter
    def space(r: Int32) -> Bool:
        return is_space(r)

    var rows = List[FuncCase]()
    rows.append(
        FuncCase(
            SPACE + " hello " + SPACE,
            "hello",
            "hello " + SPACE,
            SPACE + " hello",
        )
    )
    rows.append(FuncCase("", "", "", ""))
    rows.append(FuncCase(" ", "", "", ""))
    check[space](rows)


def test_trim_func_over_digits() raises:
    """Go's `isDigit` row. The digits at both ends are Thai and three bytes
    each, so the offsets cannot be counted in characters."""

    @parameter
    def digit(r: Int32) -> Bool:
        return is_digit(r)

    var rows = List[FuncCase]()
    rows.append(
        FuncCase(
            THAI_ZERO + THAI_TWO + "12hello34" + THAI_ZERO + THAI_ONE,
            "hello",
            "hello34" + THAI_ZERO + THAI_ONE,
            THAI_ZERO + THAI_TWO + "12hello",
        )
    )
    check[digit](rows)


def test_trim_func_over_upper_case() raises:
    """Go's `isUpper` row, where the upper case runes are a mix of ASCII and
    U+2C6F and the run in the middle has to survive."""

    @parameter
    def upper(r: Int32) -> Bool:
        return is_upper(r)

    var rows = List[FuncCase]()
    rows.append(
        FuncCase(
            TURNED_A * 4 + "ABCDhelloEF" + TURNED_A * 2 + "GH" + TURNED_A * 2,
            "hello",
            "helloEF" + TURNED_A * 2 + "GH" + TURNED_A * 2,
            TURNED_A * 4 + "ABCDhello",
        )
    )
    check[upper](rows)


def test_trim_func_over_the_negated_predicates() raises:
    """Go's `not(isSpace)` and `not(isDigit)` rows.

    Negating the predicate keeps what the other one removed, so these are the
    rows that catch a cut which stops at the wrong end of the run.
    """

    @parameter
    def not_space(r: Int32) -> Bool:
        return not is_space(r)

    var spaces = List[FuncCase]()
    spaces.append(
        FuncCase(
            "hello" + SPACE + "hello",
            SPACE,
            SPACE + "hello",
            "hello" + SPACE,
        )
    )
    check[not_space](spaces)

    @parameter
    def not_digit(r: Int32) -> Bool:
        return not is_digit(r)

    var digits = List[FuncCase]()
    var run = THAI_ZERO + THAI_TWO + "1234" + THAI_ZERO + THAI_ONE
    digits.append(
        FuncCase("hello" + run + "helo", run, run + "helo", "hello" + run)
    )
    check[not_digit](digits)


def test_trim_func_over_what_does_not_decode() raises:
    """Go's `isValidRune` rows, and Go's predicate for it.

    Go writes `r != utf8.RuneError`, which is not the same as asking whether
    the rune is a code point: a real U+FFFD in the input answers the same as a
    byte that did not decode, and that is deliberate on both sides, since a
    caller trimming damage cannot tell those apart and does not want to.
    """

    @parameter
    def decodes(r: Int32) -> Bool:
        return r != RUNE_ERROR

    var good = List[FuncCase]()
    good.append(
        FuncCase(
            "ab\\xc0a\\xc0cd", "\\xc0a\\xc0", "\\xc0a\\xc0cd", "ab\\xc0a\\xc0"
        )
    )
    check[decodes](good)

    @parameter
    def does_not_decode(r: Int32) -> Bool:
        return r == RUNE_ERROR

    var bad = List[FuncCase]()
    bad.append(FuncCase("\\xc0a\\xc0", "a", "a\\xc0", "\\xc0a"))
    check[does_not_decode](bad)
