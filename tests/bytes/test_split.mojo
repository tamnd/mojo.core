"""Carving a byte slice up. Go's split, fields, lines and cut tables.

Every split table is run twice: once through the function that returns a list
and once through the iterator that yields the same pieces one at a time. Those
are two implementations of one rule, and Go's own history has bugs that were in
the second and not the first.

The property underneath all of it is that `join(split(s, sep), sep)` is `s`
again. That is what makes an empty piece between two adjacent separators
correct rather than untidy, and it is asserted for every row of the split table
rather than argued for in a comment.
"""

from std.testing import assert_equal, assert_true

from core.bytes import (
    cut,
    cut_prefix,
    cut_suffix,
    fields,
    fields_func,
    fields_func_seq,
    fields_seq,
    join,
    lines,
    split,
    split_after,
    split_after_n,
    split_after_seq,
    split_n,
    split_seq,
)
from core.io import Byte
from core.unicode import is_space

from tests.bytes._fixtures import enc, expect, joined, quote

comptime FACES = "☺☻☹"
"""Go's `faces`. Three runes, three bytes each."""

comptime DOTS = "1....2....3....4"
"""Go's `dots`."""


@fieldwise_init
struct SplitCase(Copyable, Movable):
    """Go's `SplitTest`: an input, a separator, a limit, and the pieces."""

    var s: String
    var sep: String
    var n: Int
    var want: String
    """The pieces with a bar between them, in the notation `expect` reads."""

    var count: Int
    """How many pieces there are, which the bars alone cannot say: one empty
    piece and no pieces at all both print as nothing."""


def split_cases() -> List[SplitCase]:
    """Go's `splittests`."""
    var out = List[SplitCase]()
    out.append(SplitCase("", "", -1, "", 0))
    out.append(SplitCase("abcd", "a", 0, "", 0))
    out.append(SplitCase("abcd", "", 2, "a|bcd", 2))
    out.append(SplitCase("abcd", "a", -1, "|bcd", 2))
    out.append(SplitCase("abcd", "z", -1, "abcd", 1))
    out.append(SplitCase("abcd", "", -1, "a|b|c|d", 4))
    out.append(SplitCase("1,2,3,4", ",", -1, "1|2|3|4", 4))
    out.append(SplitCase(DOTS, "...", -1, "1|.2|.3|.4", 4))
    out.append(SplitCase(FACES, "☹", -1, "☺☻|", 2))
    out.append(SplitCase(FACES, "~", -1, FACES, 1))
    out.append(SplitCase(FACES, "", -1, "☺|☻|☹", 3))
    out.append(SplitCase("1 2 3 4", " ", 3, "1|2|3 4", 3))
    out.append(SplitCase("1 2", " ", 3, "1|2", 2))
    out.append(SplitCase("123", "", 2, "1|23", 2))
    out.append(SplitCase("123", "", 17, "1|2|3", 3))
    out.append(SplitCase("bT", "T", 1 << 60, "b|", 2))
    out.append(SplitCase("\\xff-\\xff", "", -1, "\\xff|-|\\xff", 3))
    out.append(SplitCase("\\xff-\\xff", "-", -1, "\\xff|\\xff", 2))
    return out^


def split_after_cases() -> List[SplitCase]:
    """Go's `splitaftertests`."""
    var out = List[SplitCase]()
    out.append(SplitCase("abcd", "a", -1, "a|bcd", 2))
    out.append(SplitCase("abcd", "z", -1, "abcd", 1))
    out.append(SplitCase("abcd", "", -1, "a|b|c|d", 4))
    out.append(SplitCase("1,2,3,4", ",", -1, "1,|2,|3,|4", 4))
    out.append(SplitCase(DOTS, "...", -1, "1...|.2...|.3...|.4", 4))
    out.append(SplitCase(FACES, "☹", -1, "☺☻☹|", 2))
    out.append(SplitCase(FACES, "~", -1, FACES, 1))
    out.append(SplitCase(FACES, "", -1, "☺|☻|☹", 3))
    out.append(SplitCase("1 2 3 4", " ", 3, "1 |2 |3 4", 3))
    out.append(SplitCase("1 2 3", " ", 3, "1 |2 |3", 3))
    out.append(SplitCase("1 2", " ", 3, "1 |2", 2))
    out.append(SplitCase("123", "", 2, "1|23", 2))
    out.append(SplitCase("123", "", 17, "1|2|3", 3))
    return out^


def test_split_n() raises:
    """Go's `TestSplit` over `split_n`.

    The row with a limit of `1 << 60` is Go's and it is not a joke: a limit
    larger than the input has to behave like no limit, and an implementation
    that counts a loop down from it does not finish.
    """
    var cases = split_cases()
    for row in cases:
        var s = enc(row.s)
        var sep = enc(row.sep)
        var got = split_n(Span(s), Span(sep), row.n)
        assert_equal(joined(got), expect(row.want))
        assert_equal(len(got), row.count)


def test_split_agrees_with_split_n() raises:
    """`split` is `split_n` with no limit, which Go states and does not check.
    """
    var cases = split_cases()
    for row in cases:
        if row.n >= 0:
            continue
        var s = enc(row.s)
        var sep = enc(row.sep)
        assert_equal(joined(split(Span(s), Span(sep))), expect(row.want))


def test_split_seq_yields_the_same_pieces() raises:
    """Go's `collect(SplitSeq(...))` half of `TestSplit`."""
    var cases = split_cases()
    for row in cases:
        if row.n >= 0:
            continue
        var s = enc(row.s)
        var sep = enc(row.sep)
        var got = String("")
        var seen = 0
        for piece in split_seq(Span(s), Span(sep)):
            if seen > 0:
                got += "|"
            seen += 1
            got += quote(piece)
        assert_equal(got, expect(row.want))
        assert_equal(seen, row.count)


def test_join_puts_a_split_back_together() raises:
    """Go's `Join(Split(s, sep), sep) == s`, for every row of the table.

    This is the property that decides what `split` does with adjacent
    separators and with an empty input, and it is the reason a piece of length
    zero is a piece. The rows with a limit are in it too: cutting into three
    pieces instead of four leaves the tail unsplit, and the tail still carries
    the separators that were never consumed.
    """
    var cases = split_cases()
    for row in cases:
        if row.n == 0:
            continue
        var s = enc(row.s)
        var sep = enc(row.sep)
        var pieces = split_n(Span(s), Span(sep), row.n)
        var back = join(pieces, Span(sep))
        assert_equal(quote(Span(back)), quote(Span(s)))


def test_split_after_n() raises:
    """Go's `TestSplitAfter` over `split_after_n`."""
    var cases = split_after_cases()
    for row in cases:
        var s = enc(row.s)
        var sep = enc(row.sep)
        var got = split_after_n(Span(s), Span(sep), row.n)
        assert_equal(joined(got), expect(row.want))
        assert_equal(len(got), row.count)


def test_split_after_keeps_the_separator() raises:
    """The pieces of `split_after` run back together into the input with
    nothing between them, which is the whole difference from `split` written as
    a check rather than as a sentence."""
    var nothing = List[Byte]()
    var cases = split_after_cases()
    for row in cases:
        if row.n >= 0:
            continue
        var s = enc(row.s)
        var sep = enc(row.sep)
        var pieces = split_after(Span(s), Span(sep))
        var back = join(pieces, Span(nothing))
        assert_equal(quote(Span(back)), quote(Span(s)))


def test_split_after_seq_yields_the_same_pieces() raises:
    """Go's `collect(SplitAfterSeq(...))`."""
    var cases = split_after_cases()
    for row in cases:
        if row.n >= 0:
            continue
        var s = enc(row.s)
        var sep = enc(row.sep)
        var got = String("")
        var seen = 0
        for piece in split_after_seq(Span(s), Span(sep)):
            if seen > 0:
                got += "|"
            seen += 1
            got += quote(piece)
        assert_equal(got, expect(row.want))
        assert_equal(seen, row.count)


@fieldwise_init
struct FieldsCase(Copyable, Movable):
    """An input and the pieces it comes apart into."""

    var s: String
    var want: String
    var count: Int


def fields_cases() -> List[FieldsCase]:
    """Go's `fieldstests`.

    The TRADE MARK SIGN row is the one that says a multibyte rune is a field
    and not a separator, and the two smiling faces are a field with no ASCII in
    it at all.
    """
    var out = List[FieldsCase]()
    out.append(FieldsCase("", "", 0))
    out.append(FieldsCase(" ", "", 0))
    out.append(FieldsCase(" \t ", "", 0))
    out.append(FieldsCase("  abc  ", "abc", 1))
    out.append(FieldsCase("1 2 3 4", "1|2|3|4", 4))
    out.append(FieldsCase("1  2  3  4", "1|2|3|4", 4))
    out.append(FieldsCase("1\t\t2\t\t3\t4", "1|2|3|4", 4))
    out.append(FieldsCase("1\r2\r\r3\r4", "1|2|3|4", 4))
    out.append(FieldsCase("\n™\t™\n", "™|™", 2))
    out.append(FieldsCase(FACES, FACES, 1))
    return out^


def test_fields() raises:
    """Go's `TestFields`."""
    var cases = fields_cases()
    for row in cases:
        var s = enc(row.s)
        var got = fields(Span(s))
        assert_equal(joined(got), expect(row.want))
        assert_equal(len(got), row.count)


def test_fields_splits_on_the_space_table_and_not_the_ascii_six() raises:
    """The rule is `unicode.is_space`, which is the White_Space property.

    NEL, NO-BREAK SPACE and IDEOGRAPHIC SPACE all separate fields, so an
    implementation that decoded a rune and then asked `r < 0x80` before
    testing it would join those words. ZERO WIDTH SPACE is the other
    direction: it is named a space and is not one, because White_Space does
    not include it, so it stays inside its field.
    """
    var separates = enc("a\\xc2\\x85b\\xc2\\xa0c\\xe3\\x80\\x80d")
    assert_equal(joined(fields(Span(separates))), expect("a|b|c|d"))

    var joins = enc("a\\xe2\\x80\\x8bb")
    var got = fields(Span(joins))
    assert_equal(len(got), 1)
    assert_equal(joined(got), expect("a\\xe2\\x80\\x8bb"))


def test_fields_seq_yields_the_same_fields() raises:
    """Go's `collect(FieldsSeq(...))`."""
    var cases = fields_cases()
    for row in cases:
        var s = enc(row.s)
        var got = String("")
        var seen = 0
        for field in fields_seq(Span(s)):
            if seen > 0:
                got += "|"
            seen += 1
            got += quote(field)
        assert_equal(got, expect(row.want))
        assert_equal(seen, row.count)


def test_fields_func_over_is_space_agrees_with_fields() raises:
    """The same table through the predicate version, because `fields` is a
    special case of `fields_func` and the two are free to drift apart if
    nothing checks one against the other."""

    @parameter
    def space(r: Int32) -> Bool:
        return is_space(r)

    var cases = fields_cases()
    for row in cases:
        var s = enc(row.s)
        assert_equal(joined(fields_func[space](Span(s))), expect(row.want))


def test_fields_func_over_a_predicate_of_its_own() raises:
    """Go's `FieldsFunc` table, and the iterator beside it.

    `fields_func_seq` is the one iterator in the package that declares neither
    `Iterator` nor `IterableOwned`, because a struct carrying a closure
    parameter cannot. A `for` loop over it still works, which is what the
    second half of this asserts and the reason the missing conformance costs a
    caller here nothing.
    """

    @parameter
    def is_x(r: Int32) -> Bool:
        return r == Int32(ord("X"))

    var cases = List[FieldsCase]()
    cases.append(FieldsCase("", "", 0))
    cases.append(FieldsCase("XX", "", 0))
    cases.append(FieldsCase("XXhiXXX", "hi", 1))
    cases.append(FieldsCase("aXXbXXXcX", "a|b|c", 3))
    cases.append(FieldsCase("abc", "abc", 1))
    for row in cases:
        var s = enc(row.s)
        var got = fields_func[is_x](Span(s))
        assert_equal(joined(got), expect(row.want))
        assert_equal(len(got), row.count)

        var seen = String("")
        var n = 0
        for field in fields_func_seq[is_x](Span(s)):
            if n > 0:
                seen += "|"
            n += 1
            seen += quote(field)
        assert_equal(seen, expect(row.want))
        assert_equal(n, row.count)


def test_lines() raises:
    """Go's `TestLines`. The newline stays on the line it ended.

    A carriage return is not a line ending on its own, so `abc\\r\\nabc` is two
    lines and the `\\r` belongs to the end of the first. The last line has no
    newline only when the input had none, which is how a caller tells a file
    that ended from one that was cut off.
    """
    var cases = List[FieldsCase]()
    cases.append(FieldsCase("", "", 0))
    cases.append(FieldsCase("abc\nabc\n", "abc\n|abc\n", 2))
    cases.append(FieldsCase("abc\r\nabc", "abc\r\n|abc", 2))
    cases.append(FieldsCase("abc\r\n", "abc\r\n", 1))
    cases.append(FieldsCase("\nabc", "\n|abc", 2))
    cases.append(FieldsCase("\nabc\n\n", "\n|abc\n|\n", 3))
    cases.append(FieldsCase("abc", "abc", 1))
    for row in cases:
        var s = enc(row.s)
        var got = String("")
        var seen = 0
        for line in lines(Span(s)):
            if seen > 0:
                got += "|"
            seen += 1
            got += quote(line)
        assert_equal(got, expect(row.want))
        assert_equal(seen, row.count)


def test_lines_concatenate_back_to_the_input() raises:
    """The reason the newline is kept: the lines are the input again."""
    var s = enc("alpha\nbeta\r\n\ngamma")
    var back = String("")
    for line in lines(Span(s)):
        back += quote(line)
    assert_equal(back, quote(Span(s)))


@fieldwise_init
struct CutCase(Copyable, Movable):
    """An input, a separator, the two halves, and whether it was there."""

    var s: String
    var sep: String
    var before: String
    var after: String
    var found: Bool


def test_cut() raises:
    """Go's `TestCut`.

    The row that matters is the second from last: a separator that is not there
    gives all of `s` and an empty second half, not two empty halves, so a
    caller who ignored `found` still has their input rather than nothing.
    """
    var cases = List[CutCase]()
    cases.append(CutCase("abc", "b", "a", "c", True))
    cases.append(CutCase("abc", "a", "", "bc", True))
    cases.append(CutCase("abc", "c", "ab", "", True))
    cases.append(CutCase("abc", "abc", "", "", True))
    cases.append(CutCase("abc", "", "", "abc", True))
    cases.append(CutCase("abc", "d", "abc", "", False))
    cases.append(CutCase("", "d", "", "", False))
    cases.append(CutCase("", "", "", "", True))
    for row in cases:
        var s = enc(row.s)
        var sep = enc(row.sep)
        var before, after, found = cut(Span(s), Span(sep))
        assert_equal(quote(before), expect(row.before))
        assert_equal(quote(after), expect(row.after))
        assert_equal(found, row.found)


def test_cut_prefix() raises:
    """Go's `TestCutPrefix`. An empty prefix is present."""
    var cases = List[CutCase]()
    cases.append(CutCase("abc", "a", "", "bc", True))
    cases.append(CutCase("abc", "abc", "", "", True))
    cases.append(CutCase("abc", "", "", "abc", True))
    cases.append(CutCase("abc", "d", "", "abc", False))
    cases.append(CutCase("abc", "abcd", "", "abc", False))
    cases.append(CutCase("", "d", "", "", False))
    cases.append(CutCase("", "", "", "", True))
    for row in cases:
        var s = enc(row.s)
        var sep = enc(row.sep)
        var after, found = cut_prefix(Span(s), Span(sep))
        assert_equal(quote(after), expect(row.after))
        assert_equal(found, row.found)


def test_cut_suffix() raises:
    """Go's `TestCutSuffix`."""
    var cases = List[CutCase]()
    cases.append(CutCase("abc", "bc", "a", "", True))
    cases.append(CutCase("abc", "abc", "", "", True))
    cases.append(CutCase("abc", "", "abc", "", True))
    cases.append(CutCase("abc", "d", "abc", "", False))
    cases.append(CutCase("abc", "dabc", "abc", "", False))
    cases.append(CutCase("", "d", "", "", False))
    cases.append(CutCase("", "", "", "", True))
    for row in cases:
        var s = enc(row.s)
        var sep = enc(row.sep)
        var before, found = cut_suffix(Span(s), Span(sep))
        assert_equal(quote(before), expect(row.before))
        assert_equal(found, row.found)


def test_cut_is_index_without_the_arithmetic() raises:
    """What `cut` is for, on the input where the offsets are easiest to get
    wrong: a multibyte separator in the middle of multibyte text."""
    var s = enc(FACES)
    var sep = enc("☻")
    var before, after, found = cut(Span(s), Span(sep))
    assert_true(found)
    assert_equal(quote(before), expect("☺"))
    assert_equal(quote(after), expect("☹"))
