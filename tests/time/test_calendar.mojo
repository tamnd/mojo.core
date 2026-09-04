"""The Gregorian calendar, against Go's own tables.

Three of Go's tables land here: `daysInTests`, `isoWeekTests` and
`yearDayTests`. Between them they cover the three places the calendar is easy
to get wrong, which are the length of February, the week a year starts and ends
in, and the day number of a date late in a leap year.

The rest of this file is what those tables are too small to reach. `days_in`
and `days_before` are closed forms found by search rather than table lookups,
so each is checked against the running sum it is meant to reproduce, over the
whole four hundred year period the leap rule cycles over. The ISO week
numbering is checked against its own definition day by day for a century and a
half, because the only rows that would fail are the ones at the seam between
two years and no hand written table is sure to contain them.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.time import (
    APRIL,
    AUGUST,
    DECEMBER,
    FEBRUARY,
    FRIDAY,
    JANUARY,
    JULY,
    JUNE,
    MARCH,
    MAY,
    MONDAY,
    NOVEMBER,
    OCTOBER,
    SATURDAY,
    SECONDS_PER_DAY,
    SECONDS_PER_HOUR,
    SECONDS_PER_MINUTE,
    SECONDS_PER_WEEK,
    SEPTEMBER,
    SUNDAY,
    THURSDAY,
    TUESDAY,
    WEDNESDAY,
    Month,
    Weekday,
    date,
    days_before,
    days_in,
    is_leap,
)

from tests.generated.time import (
    days_in_tests_rows,
    iso_week_tests_rows,
    year_day_tests_rows,
)


def test_days_in_matches_go() raises:
    """Go's `TestDaysIn`."""
    for row in days_in_tests_rows():
        assert_equal(days_in(Month(row.month), row.year), row.di)


def test_days_in_agrees_with_the_calendar_over_four_centuries() raises:
    """Every month of 1600 through 1999, against the definition.

    Go's table has fourteen rows. The closed form in `days_in` is an
    alternation with a correction at August, and a table that small would let a
    sign error in the correction through for exactly one month, so the whole
    period the leap rule cycles over is checked as well.
    """
    var lengths: List[Int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    for year in range(1600, 2000):
        for m in range(1, 13):
            var want = lengths[m - 1]
            if m == 2 and is_leap(year):
                want = 29
            assert_equal(days_in(Month(m), year), want)


def test_the_leap_rule_is_the_gregorian_one() raises:
    """The three cases the rule is made of, at the years that separate them.

    1900 is the one people get wrong: divisible by four and by one hundred but
    not by four hundred, so not a leap year. 2000 is the exception to the
    exception.
    """
    assert_true(is_leap(2024))
    assert_false(is_leap(2023))
    assert_false(is_leap(1900))
    assert_true(is_leap(2000))
    assert_false(is_leap(2100))
    assert_true(is_leap(2400))


def test_the_leap_rule_holds_for_a_year_before_the_common_era() raises:
    """Year zero and the negative years, which the calendar arithmetic reaches.

    Proleptic Gregorian numbering makes year zero a leap year, and `is_leap`
    tests bits rather than dividing, so the negative years are the ones worth
    naming.
    """
    assert_true(is_leap(0))
    assert_false(is_leap(-1))
    assert_true(is_leap(-4))
    assert_false(is_leap(-100))
    assert_true(is_leap(-400))


def test_days_before_is_the_running_sum() raises:
    """The closed form against the addition it replaces.

    `days_before` is a division that was found by search rather than derived,
    so the only convincing test is the sum it is meant to equal, for all
    thirteen arguments including the one past the end that gives the length of
    a common year.
    """
    var lengths: List[Int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    var total = 0
    for m in range(1, 14):
        assert_equal(days_before(Month(m)), total)
        if m <= 12:
            total += lengths[m - 1]
    assert_equal(days_before(Month(13)), 365)


def test_iso_week_matches_go() raises:
    """Go's `TestISOWeek`, the table part."""
    for row in iso_week_tests_rows():
        var t = date(row.year, Month(row.month), row.day, 0, 0, 0, 0)
        var y, w = t.iso_week()
        assert_equal(y, row.yex)
        assert_equal(w, row.wex)


def test_january_four_is_always_in_week_one() raises:
    """Go's `TestISOWeek`, the invariant part.

    The ISO definition can be stated as `January 4 is in week 1`, and every
    other week number follows from it. Checking the definition over a century
    and a half catches an off by one that a table of interesting years would
    step over.
    """
    for year in range(1950, 2100):
        var t = date(year, JANUARY, 4, 0, 0, 0, 0)
        var y, w = t.iso_week()
        assert_equal(y, year)
        assert_equal(w, 1)


def test_iso_week_numbers_run_without_a_gap() raises:
    """Consecutive days give consecutive weeks, over the same period.

    A year has 52 or 53 ISO weeks, and the ones with 53 are exactly the ones
    where the extra week has to come from somewhere. Walking the days in order
    and insisting each week number is either the one before or the one after it
    is the check that the borrowing at both ends of a year lines up.
    """
    var t = date(1950, JANUARY, 1, 0, 0, 0, 0)
    var end = date(2100, JANUARY, 1, 0, 0, 0, 0)
    var py, pw = t.iso_week()
    while t < end:
        t = t.add_date(0, 0, 1)
        var y, w = t.iso_week()
        if y == py:
            assert_true(w == pw or w == pw + 1)
        else:
            assert_equal(y, py + 1)
            assert_equal(w, 1)
            assert_true(pw == 52 or pw == 53)
        py = y
        pw = w


def test_year_day_matches_go() raises:
    """Go's `TestYearDay`."""
    for row in year_day_tests_rows():
        var t = date(row.year, Month(row.month), row.day, 0, 0, 0, 0)
        assert_equal(t.year_day(), row.yday)


def test_the_last_day_of_a_year_is_its_length() raises:
    """December 31 numbered, which is 365 or 366 and nothing else."""
    for year in range(1900, 2100):
        var t = date(year, DECEMBER, 31, 0, 0, 0, 0)
        assert_equal(t.year_day(), 366 if is_leap(year) else 365)


def test_the_month_names_are_go_s() raises:
    """All twelve, because a table of names is copied by hand once."""
    assert_equal(String(JANUARY), "January")
    assert_equal(String(FEBRUARY), "February")
    assert_equal(String(MARCH), "March")
    assert_equal(String(APRIL), "April")
    assert_equal(String(MAY), "May")
    assert_equal(String(JUNE), "June")
    assert_equal(String(JULY), "July")
    assert_equal(String(AUGUST), "August")
    assert_equal(String(SEPTEMBER), "September")
    assert_equal(String(OCTOBER), "October")
    assert_equal(String(NOVEMBER), "November")
    assert_equal(String(DECEMBER), "December")


def test_the_weekday_names_are_go_s() raises:
    """All seven, for the same reason."""
    assert_equal(String(SUNDAY), "Sunday")
    assert_equal(String(MONDAY), "Monday")
    assert_equal(String(TUESDAY), "Tuesday")
    assert_equal(String(WEDNESDAY), "Wednesday")
    assert_equal(String(THURSDAY), "Thursday")
    assert_equal(String(FRIDAY), "Friday")
    assert_equal(String(SATURDAY), "Saturday")


def test_an_out_of_range_month_prints_a_marker() raises:
    """Go's `%!Month(...)`, including the unsigned rendering of a negative one.

    Go's `Month.String` converts the value with `uint64` before printing it, so
    month -3 prints as a twenty digit number rather than as -3. That is
    surprising enough that it would look like a bug here if it were not written
    down, so it is written down.
    """
    assert_equal(String(Month(0)), "%!Month(0)")
    assert_equal(String(Month(13)), "%!Month(13)")
    assert_equal(String(Month(-3)), "%!Month(18446744073709551613)")


def test_an_out_of_range_weekday_prints_a_marker() raises:
    """The same, for `Weekday`."""
    assert_equal(String(Weekday(7)), "%!Weekday(7)")
    assert_equal(String(Weekday(-1)), "%!Weekday(18446744073709551615)")


def test_month_arithmetic_does_not_wrap_to_a_valid_month() raises:
    """Adding to a `Month` counts, it does not wrap round the year.

    Go's `Month` is an integer type and `November + 2` is 13, not January. A
    reader who expected modular arithmetic would find that out here rather than
    from a date that came out a year early.
    """
    assert_equal((NOVEMBER + 2).value, 13)
    assert_equal((JANUARY - 1).value, 0)
    assert_equal(String(NOVEMBER + 2), "%!Month(13)")


def test_weekday_of_a_known_date() raises:
    """Two dates whose weekday is not in dispute.

    January 1 of the year 1 is a Monday in the proleptic Gregorian calendar,
    which is the fact the whole day numbering is anchored to, and the day this
    was written is the other end of the same arithmetic.
    """
    assert_equal(date(1, JANUARY, 1, 0, 0, 0, 0).weekday(), MONDAY)
    assert_equal(date(2024, MARCH, 9, 0, 0, 0, 0).weekday(), SATURDAY)
    assert_equal(date(2000, FEBRUARY, 29, 0, 0, 0, 0).weekday(), TUESDAY)


def test_the_second_constants_are_the_obvious_products() raises:
    """The four spans, each against the one below it."""
    assert_equal(SECONDS_PER_MINUTE, 60)
    assert_equal(SECONDS_PER_HOUR, 60 * SECONDS_PER_MINUTE)
    assert_equal(SECONDS_PER_DAY, 24 * SECONDS_PER_HOUR)
    assert_equal(SECONDS_PER_WEEK, 7 * SECONDS_PER_DAY)
