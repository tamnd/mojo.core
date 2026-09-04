"""Instants.

Go's `utctests`, `nanoutctests`, `dateTests`, `subTests` and
`truncateRoundTests` are all here, transcribed by hand rather than harvested,
because every one of them holds a `Time` or a `*Location` in its rows and
neither can be written down as a literal for the extractor to walk. The rows
themselves are Go's, and where an expected value had to be computed rather than
copied it was computed by running Go, not by working it out here.

`dateTests` needed one change beyond transcription. Most of its rows are about
the Pacific time zone and mean nothing without a `Location`, but the block of
fifteen that spell the same instant fifteen different ways is really about
normalisation and is just as sharp in UTC, so that block is kept and the DST
rows are dropped. `subTests` lost its two monotonic rows for the same kind of
reason: they are built from bounds that only Go's internal test package can
see.

What is not tested here is anything to do with a location or a layout, because
neither is written yet, and the wall clock itself, because `now` can only be
checked against the machine it runs on. The monotonic tests below assert the
ordering that makes a monotonic reading worth having, which is what can be
asserted without a second clock to compare against.
"""

from std.testing import (
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from core.time import (
    APRIL,
    AUGUST,
    DECEMBER,
    FEBRUARY,
    HOUR,
    JANUARY,
    MARCH,
    MONDAY,
    NOVEMBER,
    OCTOBER,
    SATURDAY,
    SECOND,
    SEPTEMBER,
    SUNDAY,
    THURSDAY,
    WEDNESDAY,
    Duration,
    Month,
    Time,
    Weekday,
    date,
    now,
    since,
    unix,
    unix_micro,
    unix_milli,
    until,
)

from tests.generated.time import add_date_tests_rows

comptime _MAX_DURATION = 9_223_372_036_854_775_807
comptime _MIN_DURATION = -_MAX_DURATION - 1


def _check(
    t: Time,
    year: Int,
    month: Month,
    day: Int,
    hour: Int,
    minute: Int,
    sec: Int,
    nsec: Int,
    weekday: Weekday,
) raises:
    """One row of `utctests` or `nanoutctests`, checked the way Go's `same` is.

    Both the grouped accessors and the individual ones, because they are
    separate code paths here as they are in Go: `date` and `clock` each split a
    day once and `year` and `hour` each split it again.
    """
    var y, m, d = t.date()
    assert_equal(y, year)
    assert_equal(m, month)
    assert_equal(d, day)

    var h, mi, s = t.clock()
    assert_equal(h, hour)
    assert_equal(mi, minute)
    assert_equal(s, sec)

    assert_equal(t.year(), year)
    assert_equal(t.month(), month)
    assert_equal(t.day(), day)
    assert_equal(t.hour(), hour)
    assert_equal(t.minute(), minute)
    assert_equal(t.second(), sec)
    assert_equal(t.nanosecond(), nsec)
    assert_equal(t.weekday(), weekday)


def test_the_zero_time_is_the_first_of_january_year_one() raises:
    """Go's `TestZeroTime`.

    A default constructed `Time` is not a sentinel, it is a real instant, and
    it is the one the whole internal representation counts from. Everything
    else in the package is arithmetic away from this.
    """
    var zero = Time()
    var y, m, d = zero.date()
    var h, mi, s = zero.clock()
    assert_equal(y, 1)
    assert_equal(m, JANUARY)
    assert_equal(d, 1)
    assert_equal(h, 0)
    assert_equal(mi, 0)
    assert_equal(s, 0)
    assert_equal(zero.nanosecond(), 0)
    assert_equal(zero.year_day(), 1)
    assert_equal(zero.weekday(), MONDAY)
    assert_true(zero.is_zero())
    assert_equal(String(zero), "0001-01-01 00:00:00 +0000 UTC")


def test_unix_utc_matches_go() raises:
    """Go's `TestUnixUTC`, over `utctests`.

    Six seconds counts, three of them negative, which is the point: the
    calendar arithmetic is unsigned underneath and a date before 1970 is the
    case where a sign error shows up.
    """
    _check(unix(0, 0), 1970, JANUARY, 1, 0, 0, 0, 0, THURSDAY)
    _check(unix(1221681866, 0), 2008, SEPTEMBER, 17, 20, 4, 26, 0, WEDNESDAY)
    _check(unix(-1221681866, 0), 1931, APRIL, 16, 3, 55, 34, 0, THURSDAY)
    _check(unix(-11644473600, 0), 1601, JANUARY, 1, 0, 0, 0, 0, MONDAY)
    _check(unix(599529660, 0), 1988, DECEMBER, 31, 0, 1, 0, 0, SATURDAY)
    _check(unix(978220860, 0), 2000, DECEMBER, 31, 0, 1, 0, 0, SUNDAY)


def test_unix_nano_utc_matches_go() raises:
    """Go's `TestUnixNanoUTC`, over `nanoutctests`."""
    _check(
        unix(0, 100_000_000), 1970, JANUARY, 1, 0, 0, 0, 100_000_000, THURSDAY
    )
    _check(
        unix(1221681866, 200_000_000),
        2008,
        SEPTEMBER,
        17,
        20,
        4,
        26,
        200_000_000,
        WEDNESDAY,
    )


def test_unix_survives_a_round_trip() raises:
    """The seconds count goes out the way it came in.

    Go's `TestUnixUTC` checks this alongside the fields, and it is worth
    keeping separate because it is the one assertion that would still pass if
    the whole calendar were wrong.
    """
    var seconds: List[Int] = [
        0,
        1221681866,
        -1221681866,
        -11644473600,
        599529660,
        978220860,
    ]
    for sec in seconds:
        assert_equal(unix(sec, 0).unix(), sec)


def test_the_unix_scales_agree() raises:
    """Milliseconds, microseconds and nanoseconds from one instant.

    The three constructors and the three accessors, against each other and
    against the seconds. `unix_milli` and `unix_micro` divide a possibly
    negative count, which is where Mojo's division would answer one too low.
    """
    var t = date(2008, SEPTEMBER, 17, 20, 4, 26, 123_456_789)
    assert_equal(t.unix(), 1221681866)
    assert_equal(t.unix_milli(), 1221681866123)
    assert_equal(t.unix_micro(), 1221681866123456)
    assert_equal(t.unix_nano(), 1221681866123456789)

    assert_equal(unix_milli(-1500).unix_milli(), -1500)
    assert_equal(unix_micro(-1_500_001).unix_micro(), -1_500_001)
    assert_equal(unix_milli(-1500).nanosecond(), 500_000_000)
    assert_equal(unix_milli(-1500).unix(), -2)


def test_unix_carries_nanoseconds_out_of_range() raises:
    """`unix(0, n)` for an `n` larger than a second, and for a negative one.

    Go documents that the nanoseconds may be outside `[0, 1e9)` and are
    carried, which makes `unix(0, nanos)` a way to build an instant from a
    single nanosecond count. The stored nanoseconds are never negative
    afterwards.
    """
    assert_equal(unix(0, 1_500_000_000).unix(), 1)
    assert_equal(unix(0, 1_500_000_000).nanosecond(), 500_000_000)
    assert_equal(unix(0, -1).unix(), -1)
    assert_equal(unix(0, -1).nanosecond(), 999_999_999)
    assert_equal(String(unix(0, -1)), "1969-12-31 23:59:59.999999999 +0000 UTC")


def test_date_normalises_every_field() raises:
    """Go's `dateTests`, the block that spells one instant fifteen ways.

    Go's rows name Friday November 18 2011 in the Pacific zone; these name the
    same wall clock reading in UTC, which is the same test with the zone taken
    out. A month of zero or thirteen, an hour of -17 or 31, a second of 95, a
    nanosecond of exactly one second, a day of -12 or of 15297: every one of
    them has to fold into the same instant.
    """
    var want = date(2011, NOVEMBER, 18, 7, 56, 35, 0)
    assert_equal(want.unix(), 1321602995)

    assert_equal(date(2011, NOVEMBER, 19, -17, 56, 35, 0), want)
    assert_equal(date(2011, NOVEMBER, 17, 31, 56, 35, 0), want)
    assert_equal(date(2011, NOVEMBER, 18, 6, 116, 35, 0), want)
    assert_equal(date(2011, OCTOBER, 49, 7, 56, 35, 0), want)
    assert_equal(date(2011, NOVEMBER, 18, 7, 55, 95, 0), want)
    assert_equal(date(2011, NOVEMBER, 18, 7, 56, 34, 1_000_000_000), want)
    assert_equal(date(2011, DECEMBER, -12, 7, 56, 35, 0), want)
    assert_equal(date(2012, JANUARY, -43, 7, 56, 35, 0), want)
    assert_equal(date(2012, JANUARY - 2, 18, 7, 56, 35, 0), want)
    assert_equal(date(2010, DECEMBER + 11, 18, 7, 56, 35, 0), want)
    assert_equal(date(1970, JANUARY, 15297, 7, 56, 35, 0), want)


def test_date_reaches_a_negative_unix_time() raises:
    """The last row of Go's `dateTests`, which is a day count run backwards.

    Twenty five thousand days before January 1 1970, which lands in February
    1900, a year that is not a leap year despite being divisible by four. The
    row is here because it is the one that would come out a day off if the leap
    rule were the naive one.
    """
    var t = date(1970, JANUARY, -25508, 0, 0, 0, 0)
    assert_equal(t.unix(), -2203977600)
    assert_equal(String(t), "1900-02-28 00:00:00 +0000 UTC")


def test_add_date_matches_go() raises:
    """Go's `TestAddDate`.

    Four ways of getting from November 18 2011 to March 19 2016, each a
    different mixture of years, months and days, including one that goes
    forward five years and then back six months and sixty days.
    """
    var t0 = date(2011, NOVEMBER, 18, 7, 56, 35, 0)
    var t1 = date(2016, MARCH, 19, 7, 56, 35, 0)
    for row in add_date_tests_rows():
        assert_equal(t0.add_date(row.years, row.months, row.days), t1)


def test_add_date_counts_days_from_the_epoch() raises:
    """The second half of Go's `TestAddDate`.

    Adding the day count of December 31 1899 to the Unix epoch has to arrive
    back at December 31 1899. The count is negative, which is the reason the
    assertion is not circular.
    """
    var t2 = date(1899, DECEMBER, 31, 0, 0, 0, 0)
    var days = t2.unix() // (24 * 60 * 60)
    assert_equal(days, -25568)
    assert_equal(unix(0, 0).add_date(0, 0, days), t2)


def test_add_date_normalises_a_day_past_the_end_of_a_month() raises:
    """Go's documented answer for January 31 plus one month, which is March 3.

    Adding a month to a date that does not exist in the next month does not
    clamp, it carries, and Go's documentation names this exact case. A reader
    who expected February 28 would be surprised, so it is asserted rather than
    left to the tables.
    """
    var t = date(2023, JANUARY, 31, 0, 0, 0, 0)
    var y, m, d = t.add_date(0, 1, 0).date()
    assert_equal(y, 2023)
    assert_equal(m, MARCH)
    assert_equal(d, 3)


def test_add_moves_by_a_duration() raises:
    """The clock arithmetic, including across a leap day."""
    var t = date(2024, FEBRUARY, 28, 23, 0, 0, 0)
    assert_equal(String(t + 2 * HOUR), "2024-02-29 01:00:00 +0000 UTC")
    assert_equal(String(t + -2 * HOUR), "2024-02-28 21:00:00 +0000 UTC")
    assert_equal(
        String(t + Duration(500_000_000)),
        "2024-02-28 23:00:00.5 +0000 UTC",
    )


def test_add_carries_the_nanoseconds_in_both_directions() raises:
    """Crossing a second boundary downwards, which is where the borrow is.

    Adding a negative duration smaller than the stored nanoseconds has to take
    a second off and add a billion nanoseconds back, and the stored value must
    still be in range afterwards.
    """
    var t = unix(10, 100_000_000)
    var back = t + Duration(-200_000_000)
    assert_equal(back.unix(), 9)
    assert_equal(back.nanosecond(), 900_000_000)

    var forward = t + Duration(950_000_000)
    assert_equal(forward.unix(), 11)
    assert_equal(forward.nanosecond(), 50_000_000)


def test_sub_matches_go() raises:
    """Go's `subTests`, minus the two rows built from monotonic bounds.

    The saturating rows are the ones that matter. A `Duration` is nanoseconds
    in a machine word and covers about 292 years, while a `Time` covers
    billions, so most pairs of instants are further apart than a duration can
    say. Go answers with the largest or smallest duration rather than wrapping,
    and the rows below pin both ends.
    """
    assert_equal((Time() - Time()).value, 0)
    assert_equal(
        (
            date(2009, NOVEMBER, 23, 0, 0, 0, 1)
            - date(2009, NOVEMBER, 23, 0, 0, 0, 0)
        ).value,
        1,
    )
    assert_equal(
        date(2009, NOVEMBER, 23, 0, 0, 0, 0)
        - date(2009, NOVEMBER, 24, 0, 0, 0, 0),
        -24 * HOUR,
    )
    assert_equal(
        date(2009, NOVEMBER, 24, 0, 0, 0, 0)
        - date(2009, NOVEMBER, 23, 0, 0, 0, 0),
        24 * HOUR,
    )
    assert_equal(
        date(-2009, NOVEMBER, 24, 0, 0, 0, 0)
        - date(-2009, NOVEMBER, 23, 0, 0, 0, 0),
        24 * HOUR,
    )
    assert_equal(
        (Time() - date(2109, NOVEMBER, 23, 0, 0, 0, 0)).value, _MIN_DURATION
    )
    assert_equal(
        (date(2109, NOVEMBER, 23, 0, 0, 0, 0) - Time()).value, _MAX_DURATION
    )
    assert_equal(
        (Time() - date(-2109, NOVEMBER, 23, 0, 0, 0, 0)).value, _MAX_DURATION
    )
    assert_equal(
        (date(-2109, NOVEMBER, 23, 0, 0, 0, 0) - Time()).value, _MIN_DURATION
    )
    assert_equal(
        (
            date(2290, JANUARY, 1, 0, 0, 0, 0)
            - date(2000, JANUARY, 1, 0, 0, 0, 0)
        ).value,
        9_151_574_400_000_000_000,
    )
    assert_equal(
        (
            date(2300, JANUARY, 1, 0, 0, 0, 0)
            - date(2000, JANUARY, 1, 0, 0, 0, 0)
        ).value,
        _MAX_DURATION,
    )
    assert_equal(
        (
            date(2000, JANUARY, 1, 0, 0, 0, 0)
            - date(2290, JANUARY, 1, 0, 0, 0, 0)
        ).value,
        -9_151_574_400_000_000_000,
    )
    assert_equal(
        (
            date(2000, JANUARY, 1, 0, 0, 0, 0)
            - date(2300, JANUARY, 1, 0, 0, 0, 0)
        ).value,
        _MIN_DURATION,
    )
    assert_equal(
        (
            date(2311, NOVEMBER, 26, 2, 16, 47, 63_535_996)
            - date(2019, AUGUST, 16, 2, 29, 30, 268_436_582)
        ).value,
        9_223_372_036_795_099_414,
    )


def test_truncate_and_round_match_go() raises:
    """Go's `truncateRoundTests`, with the answers taken from Go.

    Go's own test recomputes the expected value in arbitrary precision rather
    than writing it down, which is not something to reproduce here for five
    rows. The five results below came out of the Go toolchain, and the fifth
    row is the interesting one: a modulus of about 85 days applied to an
    instant six hundred years before the epoch, where truncating and rounding
    land on different sides of zero.
    """
    var a = date(-1, JANUARY, 1, 12, 15, 30, 500_000_000)
    assert_equal(a.truncate(Duration(3)).nanosecond(), 499_999_998)
    assert_equal(a.round(Duration(3)).nanosecond(), 500_000_001)

    var b = date(-1, JANUARY, 1, 12, 15, 31, 500_000_000)
    assert_equal(b.truncate(Duration(3)).nanosecond(), 500_000_000)
    assert_equal(b.round(Duration(3)).nanosecond(), 500_000_000)

    var c = date(2012, JANUARY, 1, 12, 15, 30, 500_000_000)
    assert_equal(c.truncate(SECOND).unix(), 1325420130)
    assert_equal(c.truncate(SECOND).nanosecond(), 0)
    assert_equal(c.round(SECOND).unix(), 1325420131)
    assert_equal(c.round(SECOND).nanosecond(), 0)

    var d = date(2012, JANUARY, 1, 12, 15, 31, 500_000_000)
    assert_equal(d.truncate(SECOND).unix(), 1325420131)
    assert_equal(d.round(SECOND).unix(), 1325420132)

    var e = unix(-19012425939, 649146258)
    var m = Duration(7_435_029_458_905_025_217)
    assert_equal(e.truncate(m).unix(), -24960449506)
    assert_equal(e.truncate(m).nanosecond(), 525126085)
    assert_equal(e.round(m).unix(), -17525420047)
    assert_equal(e.round(m).nanosecond(), 430151302)


def test_truncate_and_round_measure_from_the_zero_time() raises:
    """The origin these two count from, which is not the Unix epoch.

    Go documents that `Truncate` rounds down to a multiple of `d` since the
    zero time, so truncating to an hour gives the top of the hour only because
    the zero time is on an hour boundary. Truncating to a modulus that is not a
    divisor of a day shows the difference, and this is the assertion that would
    fail if the origin quietly became 1970.
    """
    var t = date(2011, NOVEMBER, 18, 7, 56, 35, 0)
    assert_equal(String(t.truncate(HOUR)), "2011-11-18 07:00:00 +0000 UTC")
    assert_equal(String(t.round(HOUR)), "2011-11-18 08:00:00 +0000 UTC")
    assert_equal(t.truncate(Duration(0)), t)
    assert_equal(t.round(Duration(-1)), t)


def test_string_writes_only_the_digits_it_needs() raises:
    """The fraction is trimmed and the year is padded to four digits.

    Three separate rules in one method: no fraction at all when the
    nanoseconds are zero, a trimmed fraction when they are not, and a year
    written with a leading minus and four digits when it is before the common
    era or with as many digits as it takes when it is far in the future.
    """
    assert_equal(
        String(date(2011, NOVEMBER, 18, 7, 56, 35, 0)),
        "2011-11-18 07:56:35 +0000 UTC",
    )
    assert_equal(
        String(date(2011, NOVEMBER, 18, 7, 56, 35, 123_456_789)),
        "2011-11-18 07:56:35.123456789 +0000 UTC",
    )
    assert_equal(
        String(date(2011, NOVEMBER, 18, 7, 56, 35, 100_000_000)),
        "2011-11-18 07:56:35.1 +0000 UTC",
    )
    assert_equal(
        String(date(-1, JANUARY, 1, 0, 0, 0, 0)),
        "-0001-01-01 00:00:00 +0000 UTC",
    )
    assert_equal(
        String(date(12345, JANUARY, 1, 0, 0, 0, 0)),
        "12345-01-01 00:00:00 +0000 UTC",
    )


def test_comparison_orders_by_instant() raises:
    """Before, After, Equal and Compare, which is all one ordering."""
    var early = date(2009, NOVEMBER, 23, 0, 0, 0, 0)
    var late = date(2009, NOVEMBER, 24, 0, 0, 0, 0)
    assert_true(early < late)
    assert_true(late > early)
    assert_true(early <= early)
    assert_true(early >= early)
    assert_false(early > late)
    assert_equal(early.compare(late), -1)
    assert_equal(late.compare(early), 1)
    assert_equal(early.compare(early), 0)
    assert_equal(early, early)
    assert_not_equal(early, late)


def test_comparison_looks_at_the_nanoseconds() raises:
    """Two instants in the same second, which the seconds alone cannot order."""
    var a = unix(10, 1)
    var b = unix(10, 2)
    assert_true(a < b)
    assert_equal(a.compare(b), -1)
    assert_not_equal(a, b)


def test_equality_ignores_the_monotonic_reading() raises:
    """The deviation from Go's `==`, which `docs/deviations.md` records.

    Go's `==` compares the struct fields, so an instant that carries a
    monotonic reading is unequal to the same instant without one, and Go's own
    documentation tells you not to use it. Here `==` is Go's `Equal`, which
    compares the instant, so the two are equal.
    """
    var wall = date(2011, NOVEMBER, 18, 7, 56, 35, 0)
    var same = Time(
        internal_sec=wall.sec, nsec=wall.nsec, mono=1234, has_mono=True
    )
    assert_equal(wall, same)
    assert_equal(wall.compare(same), 0)
    assert_false(wall < same)
    assert_false(wall > same)


def test_a_monotonic_difference_ignores_the_wall_clock() raises:
    """Two instants with monotonic readings subtract by those readings.

    This is the whole reason the reading is carried. Both times below claim the
    same wall clock second, which would make the difference zero, and their
    monotonic readings are a second apart, which is the answer. A clock that
    was set backwards between two measurements produces exactly this shape.
    """
    var a = Time(internal_sec=100, nsec=0, mono=1_000_000_000, has_mono=True)
    var b = Time(internal_sec=100, nsec=0, mono=2_000_000_000, has_mono=True)
    assert_equal(b - a, SECOND)
    assert_equal(a - b, -SECOND)
    assert_true(a < b)


def test_a_monotonic_reading_survives_addition_and_not_rounding() raises:
    """Which operations keep the reading and which drop it.

    Adding a duration shifts the monotonic reading with the wall clock, because
    the result is still the same measurement moved by a known amount. Rounding
    and truncating drop it, because the answer is about the wall clock and a
    monotonic reading rounded to the nearest hour means nothing. Go does the
    same, and this is checked through the difference, which is the only thing
    that can see the reading.
    """
    var a = Time(internal_sec=100, nsec=0, mono=1_000_000_000, has_mono=True)
    var moved = a + SECOND
    assert_equal(moved - a, SECOND)

    var rounded = a.round(HOUR)
    var wall_only = Time(internal_sec=rounded.sec, nsec=rounded.nsec)
    assert_equal(rounded - a, wall_only - a)


def test_now_moves_forward() raises:
    """The one thing that can be asserted about the wall clock.

    Its value cannot be checked against anything, but two readings in
    succession must not go backwards and `since` must agree with the
    difference. `until` is the same measurement with the sign the other way
    round, which is why it is checked here rather than on its own.
    """
    var a = now()
    var b = now()
    assert_true(b >= a)
    assert_true(since(a) >= Duration(0))
    assert_true(until(a) <= Duration(0))
    assert_false(a.is_zero())


def test_now_is_somewhere_in_this_century() raises:
    """A range wide enough to never fail and narrow enough to catch an epoch
    mistake.

    Reading the wrong clock, or forgetting to shift from the Unix epoch to the
    internal one, moves the answer by two thousand years, which lands well
    outside this. A test that only checked the clock advanced would not notice.
    """
    var t = now()
    assert_true(t.year() >= 2020)
    assert_true(t.year() < 2200)


def test_the_monotonic_clock_advances() raises:
    """Read until the reading changes, which it must do eventually.

    The obvious version of this test does some arithmetic and asserts the
    elapsed time is positive, and it is flaky twice over: a loop of arithmetic
    whose result is not used is folded away at compile time, and the monotonic
    clock on this platform advances in microseconds, so two readings either
    side of a fast piece of work are often the same. Spinning until the reading
    changes asserts the same thing without either problem. The iteration bound
    is only there so that a stopped clock fails rather than hangs.
    """
    var start = now()
    var elapsed = since(start)
    var spins = 0
    while elapsed == Duration(0) and spins < 10_000_000:
        elapsed = since(start)
        spins += 1
    assert_true(elapsed > Duration(0))
    assert_true(elapsed < 60 * SECOND)


def test_is_zero_is_about_the_instant_and_not_the_fields() raises:
    """A zero time built two ways, and one that is a nanosecond off.

    The zero time is January 1 year 1, so an instant built by naming that date
    is zero even though it did not come from the default constructor.
    """
    assert_true(Time().is_zero())
    assert_true(date(1, JANUARY, 1, 0, 0, 0, 0).is_zero())
    assert_false(date(1, JANUARY, 1, 0, 0, 0, 1).is_zero())
    assert_false(unix(0, 0).is_zero())


def test_the_epoch_and_the_zero_time_are_the_expected_distance_apart() raises:
    """The constant everything converts through, checked once.

    The seconds from January 1 year 1 to January 1 1970 is a number the whole
    package depends on and that no other test states outright. It is 1969
    years, of which 477 are leap years.
    """
    assert_equal(unix(0, 0).unix(), 0)
    assert_equal(Time().unix(), -62135596800)
    assert_equal((1969 * 365 + 477) * 86400, 62135596800)


def test_a_duration_added_to_a_far_instant_does_not_overflow() raises:
    """Adding an hour to an instant a billion years out.

    A `Time` holds seconds and a `Duration` holds nanoseconds, so the addition
    has to split the duration rather than convert the instant, and an
    implementation that converted would wrap here. The check is that the
    calendar still reads back the way it went in.
    """
    var far = date(1_000_000_000, JANUARY, 1, 0, 0, 0, 0)
    var later = far + HOUR
    assert_equal(later.year(), 1_000_000_000)
    assert_equal(later.hour(), 1)
    assert_equal(later - far, HOUR)
