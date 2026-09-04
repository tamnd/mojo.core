"""Go's `TestMatch`, against Go's own table.

The table's `err` column is Go's error text rather than a value, since there is
no error value to carry across: `tools/testgen` writes `Error()` for a row that
has one and the empty string for a row that does not. That turns out to be a
stronger check than comparing sentinels, because it also pins the message this
library raises to the message Go raises.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import matches
from core.path import ErrBadPattern, is_match

from tests.generated.path import match_tests_rows


def test_match() raises:
    """Go's `TestMatch`."""
    for row in match_tests_rows():
        var what = "is_match(" + row.pattern + ", " + row.s + ")"
        try:
            var got = is_match(row.pattern, row.s)
            assert_equal(row.err, "", what + " did not raise")
            assert_equal(got, row.matched, what)
        except e:
            assert_equal(String(e), row.err, what)
            assert_true(matches(e, ErrBadPattern), what + " code")


def test_a_bad_pattern_is_reported_whatever_the_name_is() raises:
    """The rule the last few rows of Go's table are about.

    A pattern that cannot match anything is still read to the end, so that
    `is_match("a[", "x")` is an error rather than a quiet `False`. Whoever wrote
    the pattern has a bug either way, and the answer that says so is the useful
    one.
    """
    for name in ["", "a", "ab", "x", "a/b", "zzzzz"]:
        try:
            var got = is_match("a[", name)
            raise Error("is_match(a[, ", name, ") returned ", got)
        except e:
            assert_true(matches(e, ErrBadPattern))


def test_a_star_stops_at_a_slash() raises:
    """Not a Go test, and the one thing that makes these patterns not globs.

    `*` and `?` are about one element of a path. Go's table has three rows that
    say so and they are easy to read as coincidences, so this says it directly.
    """
    assert_true(is_match("*", "abc"))
    assert_false(is_match("*", "a/c"))
    assert_false(is_match("a*c", "a/c"))
    assert_false(is_match("a?c", "a/c"))
    assert_true(is_match("*/*", "a/c"))


def test_the_whole_name_has_to_match() raises:
    """Also not a Go test. A pattern is anchored at both ends.

    This is the difference between `is_match` and a search, and it is the mistake
    that makes a pattern look like it does not work: `is_match("b", "abc")` is
    false and there is no way to spell "contains" here except `*b*`.
    """
    assert_false(is_match("b", "abc"))
    assert_false(is_match("ab", "abc"))
    assert_false(is_match("bc", "abc"))
    assert_true(is_match("*b*", "abc"))
    assert_true(is_match("abc", "abc"))
