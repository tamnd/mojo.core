"""Durations, against Go's own tables.

Nine of Go's tables drive this file. The interesting one is `durationTests`,
which is the notation `Duration.String` writes: the unit is chosen from the
magnitude, trailing zeros in the fraction go, and the whole thing is built
backwards into a fixed buffer. It is the one part of the type that is a small
program rather than an arithmetic identity, and it is where Go's rows earn
their place.

The three conversion tables that answer in whole units are compared exactly.
The three that answer in a float are compared exactly too, because Go's
expected values come out of this harvest as their bits and the arithmetic
either produces the same double or it does not.
"""

from std.testing import assert_equal, assert_true

from core.time import (
    HOUR,
    MICROSECOND,
    MILLISECOND,
    MINUTE,
    NANOSECOND,
    SECOND,
    Duration,
)

from tests.generated.time import (
    duration_abs_tests_rows,
    duration_round_tests_rows,
    duration_tests_rows,
    duration_truncate_tests_rows,
    hour_duration_tests_rows,
    min_duration_tests_rows,
    ms_duration_tests_rows,
    ns_duration_tests_rows,
    sec_duration_tests_rows,
    us_duration_tests_rows,
)


def test_the_constants_are_a_thousand_apart() raises:
    """The six units, each against the one below it.

    A typo in one of the six zeros in `MICROSECOND` would be caught by almost
    every other test in this file, but not in a way that said what was wrong.
    """
    assert_equal(NANOSECOND.value, 1)
    assert_equal(MICROSECOND.value, 1_000 * NANOSECOND.value)
    assert_equal(MILLISECOND.value, 1_000 * MICROSECOND.value)
    assert_equal(SECOND.value, 1_000 * MILLISECOND.value)
    assert_equal(MINUTE.value, 60 * SECOND.value)
    assert_equal(HOUR.value, 60 * MINUTE.value)


def test_string_matches_go() raises:
    """Go's `TestDurationString`.

    The negation of every positive row is checked as well, exactly as Go's test
    does, which is what pins the minus sign to the front rather than to
    whichever unit happened to be written first.
    """
    for row in duration_tests_rows():
        assert_equal(String(Duration(row.d)), row.str)
        if row.d > 0:
            assert_equal(String(-Duration(row.d)), "-" + row.str)


def test_truncate_matches_go() raises:
    """Go's `TestDurationTruncate`."""
    for row in duration_truncate_tests_rows():
        assert_equal(Duration(row.d).truncate(Duration(row.m)).value, row.want)


def test_round_matches_go() raises:
    """Go's `TestDurationRound`."""
    for row in duration_round_tests_rows():
        assert_equal(Duration(row.d).round(Duration(row.m)).value, row.want)


def test_abs_matches_go() raises:
    """Go's `TestDurationAbs`."""
    for row in duration_abs_tests_rows():
        assert_equal(abs(Duration(row.d)).value, row.want)


def test_the_whole_unit_conversions_match_go() raises:
    """Go's `TestDurationNanoseconds`, `Microseconds` and `Milliseconds`."""
    for row in ns_duration_tests_rows():
        assert_equal(Duration(row.d).nanoseconds(), row.want)
    for row in us_duration_tests_rows():
        assert_equal(Duration(row.d).microseconds(), row.want)
    for row in ms_duration_tests_rows():
        assert_equal(Duration(row.d).milliseconds(), row.want)


def test_the_fractional_conversions_match_go() raises:
    """Go's `TestDurationSeconds`, `Minutes` and `Hours`."""
    for row in sec_duration_tests_rows():
        assert_equal(Duration(row.d).seconds(), row.want)
    for row in min_duration_tests_rows():
        assert_equal(Duration(row.d).minutes(), row.want)
    for row in hour_duration_tests_rows():
        assert_equal(Duration(row.d).hours(), row.want)


def test_arithmetic_rounds_towards_zero() raises:
    """The half of this package Mojo's operators would get wrong.

    Mojo's `//` rounds towards negative infinity, so `Duration(-7) // 2` under
    the language's own division is -4 and under Go's is -3. Every one of these
    would pass with either division if the operand were positive, which is why
    each is written the other way round.
    """
    assert_equal((Duration(-7) // 2).value, -3)
    assert_equal(Duration(-1500) // MICROSECOND, -1)
    assert_equal(Duration(-2500).microseconds(), -2)
    assert_equal(Duration(-1_999_999_999).milliseconds(), -1999)
    assert_equal(Duration(-1_500_000_000).seconds(), -1.5)


def test_truncate_and_round_leave_a_useless_modulus_alone() raises:
    """Go's rule for a zero or negative `m`, which is to give the value back.

    Worth its own test because the alternative, raising, is what a library
    would do if it had not thought about the caller who passes a configured
    granularity straight through.
    """
    var d = 90 * SECOND
    assert_equal(d.truncate(Duration(0)), d)
    assert_equal(d.round(Duration(0)), d)
    assert_equal(d.truncate(Duration(-1)), d)
    assert_equal(d.round(Duration(-1)), d)


def test_round_saturates_rather_than_wrapping() raises:
    """The one case where the honest answer does not fit.

    Rounding the largest duration up to the next whole hour is a value a
    machine word cannot hold. Go answers with the largest duration rather than
    wrapping round to a large negative one, and so does this, in both
    directions.
    """
    var most = Duration(9_223_372_036_854_775_807)
    var least = Duration(-9_223_372_036_854_775_807 - 1)
    assert_equal(most.round(HOUR), most)
    assert_equal(least.round(HOUR), least)


def test_abs_of_the_most_negative_duration_is_one_short() raises:
    """The other place two's complement has no room for the right answer.

    The magnitude of the most negative duration is one larger than the largest
    positive one. Go answers with the largest positive one and says so, and
    this does the same rather than raising from a function nobody expects to
    fail.
    """
    var least = Duration(-9_223_372_036_854_775_807 - 1)
    assert_equal(abs(least).value, 9_223_372_036_854_775_807)


def test_multiplication_reads_the_way_it_is_written() raises:
    """`5 * SECOND` and `SECOND * 5` are the same duration.

    Go only has the first spelling, because a Go constant is untyped and the
    multiplication is the same expression either way. Both are written here so
    that neither is the one that compiles by accident.
    """
    assert_equal(5 * SECOND, SECOND * 5)
    assert_equal((5 * SECOND).value, 5_000_000_000)


def test_dividing_two_durations_gives_a_count() raises:
    """The return type that is not Go's.

    `d / time.Millisecond` in Go is another `Duration`, because both sides have
    the same type and Go's division has to answer in it, and the answer is a
    count of milliseconds wearing the wrong type. Here it is an `Int`.
    """
    assert_equal(SECOND // MILLISECOND, 1000)
    assert_equal((90 * MINUTE) // HOUR, 1)
    assert_equal((-90 * MINUTE) // HOUR, -1)


def test_comparisons_order_by_signed_length() raises:
    """A negative duration is shorter than a zero one, not longer."""
    assert_true(Duration(-1) < Duration(0))
    assert_true(Duration(0) < NANOSECOND)
    assert_true(-HOUR < -MINUTE)
    assert_true(HOUR > MINUTE)
    assert_true(HOUR >= HOUR)
    assert_true(HOUR <= HOUR)
    assert_true(HOUR != MINUTE)
