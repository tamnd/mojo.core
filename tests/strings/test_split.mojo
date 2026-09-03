"""Cutting a string up. Go's `TestSplit`, `TestFields` and the rest.

Go's tables, transcribed. A whole split is asserted as one string with the
pieces joined by a bar, which no row contains, so a failure prints the shape of
the answer rather than the first place two lists stopped agreeing.

The sequence functions are checked against the list functions rather than
against tables of their own. They are the same walk with the pieces handed over
one at a time instead of collected, so the thing worth asserting is that they
agree, and a table would only be a second place to make the same typo.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.strings import (
    cut,
    cut_prefix,
    cut_suffix,
    fields,
    fields_func,
    fields_func_seq,
    fields_seq,
    lines,
    split,
    split_after,
    split_after_n,
    split_after_seq,
    split_n,
    split_seq,
)

comptime BAR = "|"
"""What `joined` puts between pieces. No table here contains one."""


def joined[o: ImmOrigin](pieces: List[StringSlice[o]]) -> String:
    """The pieces with a bar between them, and `<empty>` for none at all.

    An empty list and a list holding one empty string both join to nothing, and
    those are different answers in half these tables, so the empty list gets a
    name of its own.
    """
    if len(pieces) == 0:
        return "<empty>"
    var out = String()
    for i in range(len(pieces)):
        if i > 0:
            out += BAR
        out += pieces[i]
    return out^


def test_split() raises:
    """Go's `splitTests` with `n` of -1."""
    assert_equal(joined(split("", "")), "<empty>")
    assert_equal(joined(split("abcd", "")), "a|b|c|d")
    assert_equal(joined(split("☺☻☹", "")), "☺|☻|☹")
    assert_equal(joined(split("abcd", "a")), "|bcd")
    assert_equal(joined(split("abcd", "z")), "abcd")
    assert_equal(joined(split("1,2,3,4", ",")), "1|2|3|4")
    assert_equal(joined(split("1....2....3....4", "...")), "1|.2|.3|.4")
    assert_equal(joined(split("☺☻☹", "☹")), "☺☻|")
    assert_equal(joined(split("☺☻☹", "~")), "☺☻☹")


def test_split_n() raises:
    """Go's `splitTests` with a limit.

    Zero pieces is the row worth keeping: Go returns nil rather than an empty
    slice and the distinction is invisible to anyone using the result, but a
    limit of zero meaning nothing rather than everything is a real trap.
    """
    assert_equal(joined(split_n("abcd", "a", 0)), "<empty>")
    assert_equal(joined(split_n("abcd", "", 2)), "a|bcd")
    assert_equal(joined(split_n("abcd", "", 4)), "a|b|c|d")
    assert_equal(joined(split_n("☺☻☹", "", 3)), "☺|☻|☹")
    assert_equal(joined(split_n("☺☻☹", "", 17)), "☺|☻|☹")
    assert_equal(joined(split_n("1 2 3 4", " ", 3)), "1|2|3 4")
    assert_equal(joined(split_n("1 2", " ", 3)), "1|2")


def test_split_after() raises:
    """Go's `splitafterTests`.

    The separator stays on the end of the piece before it, so the pieces
    concatenate back to the input, which is the property `split` gives up.
    """
    assert_equal(joined(split_after("abcd", "a")), "a|bcd")
    assert_equal(joined(split_after("abcd", "z")), "abcd")
    assert_equal(joined(split_after("abcd", "")), "a|b|c|d")
    assert_equal(joined(split_after("1,2,3,4", ",")), "1,|2,|3,|4")
    assert_equal(
        joined(split_after("1....2....3....4", "...")), "1...|.2...|.3...|.4"
    )
    assert_equal(joined(split_after("☺☻☹", "☹")), "☺☻☹|")
    assert_equal(joined(split_after_n("1,2,3,4", ",", 2)), "1,|2,3,4")
    assert_equal(joined(split_after_n("1,2,3,4", ",", 0)), "<empty>")


def test_split_pieces_are_views() raises:
    """A split allocates one list of two word slices and copies no text.

    What the test can see of that is that every piece is a slice of the input,
    which the compiler checked when it typed the origin. What is left is the
    arithmetic: the pieces put back together with the separator have to be the
    string that went in.
    """
    var s = String("alpha,beta,gamma")
    var pieces = split(s, ",")
    var back = String()
    for i in range(len(pieces)):
        if i > 0:
            back += ","
        back += pieces[i]
    assert_equal(back, s)


def test_split_seq_agrees_with_split() raises:
    """The one at a time version walks the same string the same way."""
    var rows = List[Tuple[String, String]]()
    rows.append(("1,2,3,4", ","))
    rows.append(("abcd", ""))
    rows.append(("☺☻☹", "☹"))
    rows.append(("abcd", "z"))
    rows.append(("", ""))
    for row in rows:
        var seen = List[String]()
        for piece in split_seq(row[0], row[1]):
            seen.append(String(piece))
        var want = split(row[0], row[1])
        assert_equal(len(seen), len(want))
        for i in range(len(want)):
            assert_equal(seen[i], String(want[i]))

        var seen_after = List[String]()
        for piece in split_after_seq(row[0], row[1]):
            seen_after.append(String(piece))
        var want_after = split_after(row[0], row[1])
        assert_equal(len(seen_after), len(want_after))
        for i in range(len(want_after)):
            assert_equal(seen_after[i], String(want_after[i]))


def test_cut() raises:
    """Go's `TestCut`.

    Three results and the third is the one that matters: an empty `before` from
    a match at the front and an empty `before` from no match at all are the
    same two strings, and only the flag tells them apart.
    """
    var before, after, found = cut("abc", "b")
    assert_equal(String(before), "a")
    assert_equal(String(after), "c")
    assert_true(found)

    var b2, a2, f2 = cut("abc", "x")
    assert_equal(String(b2), "abc")
    assert_equal(String(a2), "")
    assert_false(f2)

    var b3, a3, f3 = cut("abc", "")
    assert_equal(String(b3), "")
    assert_equal(String(a3), "abc")
    assert_true(f3)

    var b4, a4, f4 = cut("abc", "abc")
    assert_equal(String(b4), "")
    assert_equal(String(a4), "")
    assert_true(f4)

    var b5, a5, f5 = cut("", "")
    assert_equal(String(b5), "")
    assert_equal(String(a5), "")
    assert_true(f5)


def test_cut_prefix_and_suffix() raises:
    """Go's `TestCutPrefix` and `TestCutSuffix`.

    The same thing as `trim_prefix` with the flag `trim_prefix` throws away, so
    a caller who needs to know whether anything came off does not have to call
    `has_prefix` first and search the string twice.
    """
    var rest, found = cut_prefix("abc", "a")
    assert_equal(String(rest), "bc")
    assert_true(found)

    var r2, f2 = cut_prefix("abc", "x")
    assert_equal(String(r2), "abc")
    assert_false(f2)

    var r3, f3 = cut_prefix("abc", "")
    assert_equal(String(r3), "abc")
    assert_true(f3)

    var r4, f4 = cut_suffix("abc", "c")
    assert_equal(String(r4), "ab")
    assert_true(f4)

    var r5, f5 = cut_suffix("abc", "x")
    assert_equal(String(r5), "abc")
    assert_false(f5)

    var r6, f6 = cut_suffix("abc", "")
    assert_equal(String(r6), "abc")
    assert_true(f6)


def test_fields() raises:
    """Go's `fieldsTests`.

    White space is the Unicode property, so U+2000 EN QUAD separates fields and
    a string of nothing but those has no fields at all. Leading and trailing
    space produce no empty pieces, which is the whole difference between
    `fields` and `split(s, " ")`.
    """
    assert_equal(joined(fields("")), "<empty>")
    assert_equal(joined(fields(" ")), "<empty>")
    assert_equal(joined(fields(" \t ")), "<empty>")
    assert_equal(joined(fields("  abc  ")), "abc")
    assert_equal(joined(fields("1 2 3 4")), "1|2|3|4")
    assert_equal(joined(fields("1  2  3  4")), "1|2|3|4")
    assert_equal(joined(fields("1\t2\t3\t4")), "1|2|3|4")
    assert_equal(joined(fields("123")), "123")
    var en_quad = chr(0x2000)
    var em_quad = chr(0x2001)
    assert_equal(joined(fields(en_quad)), "<empty>")
    assert_equal(joined(fields(en_quad + em_quad)), "<empty>")
    assert_equal(
        joined(fields("\n" + en_quad + "1a2" + en_quad + " x")), "1a2|x"
    )
    # Where `split` on a space would answer with five pieces, three of them
    # empty, for the same input.
    assert_equal(joined(split("  abc  ", " ")), "||abc||")


def test_fields_func() raises:
    """Go's `TestFieldsFunc`, on a predicate that is not white space."""

    @parameter
    def is_comma(r: Int32) -> Bool:
        return r == Int32(ord(","))

    assert_equal(joined(fields_func[is_comma]("1,2,3")), "1|2|3")
    assert_equal(joined(fields_func[is_comma](",,,1,,,2,,,")), "1|2")
    assert_equal(joined(fields_func[is_comma](",,,")), "<empty>")
    assert_equal(joined(fields_func[is_comma]("")), "<empty>")


def test_fields_seq_agrees_with_fields() raises:
    """Again the one at a time version against the list version."""

    @parameter
    def is_comma(r: Int32) -> Bool:
        return r == Int32(ord(","))

    var rows = List[String]()
    rows.append("  a  bb   ccc  ")
    rows.append("")
    rows.append("   ")
    rows.append("one")
    for row in rows:
        var seen = List[String]()
        for f in fields_seq(row):
            seen.append(String(f))
        var want = fields(row)
        assert_equal(len(seen), len(want))
        for i in range(len(want)):
            assert_equal(seen[i], String(want[i]))

    var seen_func = List[String]()
    for f in fields_func_seq[is_comma](",,a,b,,c,"):
        seen_func.append(String(f))
    assert_equal(len(seen_func), 3)
    assert_equal(seen_func[0], "a")
    assert_equal(seen_func[1], "b")
    assert_equal(seen_func[2], "c")


def test_lines() raises:
    """Go's `TestLines`.

    Each line keeps its newline, so the lines concatenate back to the input and
    a caller can tell a last line that ended from one that ran out. An empty
    string has no lines at all, which is not the same as having one empty one.
    """
    var seen = List[String]()
    for line in lines("a\nb\nc"):
        seen.append(String(line))
    assert_equal(len(seen), 3)
    assert_equal(seen[0], "a\n")
    assert_equal(seen[1], "b\n")
    assert_equal(seen[2], "c")

    var none = List[String]()
    for line in lines(""):
        none.append(String(line))
    assert_equal(len(none), 0)

    var trailing = List[String]()
    for line in lines("a\n"):
        trailing.append(String(line))
    assert_equal(len(trailing), 1)
    assert_equal(trailing[0], "a\n")

    var blank = List[String]()
    for line in lines("\n\n"):
        blank.append(String(line))
    assert_equal(len(blank), 2)
    assert_equal(blank[0], "\n")
    assert_equal(blank[1], "\n")

    # A lone carriage return is not a line ending here, which is Go's rule.
    var cr = List[String]()
    for line in lines("a\r\nb"):
        cr.append(String(line))
    assert_equal(len(cr), 2)
    assert_equal(cr[0], "a\r\n")
    assert_equal(cr[1], "b")
