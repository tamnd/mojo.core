"""The Gregorian calendar, as arithmetic. Go's `Month`, `Weekday` and the
absolute time conversions under them.

No leap seconds, here or in Go or in POSIX. A minute is sixty seconds
everywhere in this package, which means an interval spanning one of the twenty
seven leap seconds so far is one second shorter here than a caesium clock would
have made it. That is not a deviation from Go, it is what every clock this can
reach already does.

## Why the epoch is in the year -292277022400

Every presentation question, from `year` down to `second`, is division and
remainder by a positive constant, and it wants the division that rounds down so
that the remainder is never negative. Go's rounds towards zero, and so does the
hardware, and so does everything except Python. Rather than adjust the result
of every division for a negative numerator, Go moves to an epoch far enough
back that no time anyone cares about is negative, and then the two divisions
agree and the adjustment is not needed anywhere.

The epoch is March 1 of the year -292277022400. March, because a year that
starts in March puts the leap day at the end of it, where it does not disturb
the day numbering of any other month. That year, because the number is a
multiple of 400 so the calendar's 400 year cycle starts there, and because the
distance from it to 1970 is just inside what a signed word holds in seconds.

A count of seconds from that instant is called an absolute time here, as it is
in Go. A count from the year 1 is an internal time, which is what `Time` holds.
A count from 1970 is a Unix time, which is what the platform hands over.

## The divisions

The conversion from days to a date is Neri and Schneider's, "Euclidean affine
functions and their application to calendar algorithms", which Go adopted in
1.22. The short version is that each step of the calendar, days into years and
days into months, can be written as one multiply, one shift and one mask, with
no table and no loop over centuries. The magic constants below are theirs and
each one is derived rather than fitted. Go's own comment in `time.go` carries
the derivation and is worth reading before changing a line here.
"""

from .divide import _quo


comptime SECONDS_PER_MINUTE = 60
"""Seconds in a minute. Never sixty one: leap seconds are not modelled."""

comptime SECONDS_PER_HOUR = 60 * SECONDS_PER_MINUTE
"""Seconds in an hour."""

comptime SECONDS_PER_DAY = 24 * SECONDS_PER_HOUR
"""Seconds in a day, meaning a day of the calendar with no clock change in it.
"""

comptime SECONDS_PER_WEEK = 7 * SECONDS_PER_DAY
"""Seconds in a week."""

comptime _MARCH_THRU_DECEMBER = 306
"""Days from March 1 to the end of the year, which is the same number in a leap
year and a common one because the leap day is in February."""

comptime _ABSOLUTE_YEARS = 292_277_022_400
"""Years from the absolute epoch to the year zero. A multiple of 400."""

comptime _ABSOLUTE_TO_INTERNAL = -9_223_371_966_606_163_200
"""Seconds to add to an absolute time to get an internal one.

`-(292277022400 * 365.2425 + 306) * 86400`, which Go writes as that expression
because Go computes constants as exact rationals and 365.2425 is the mean
length of a Gregorian year. Mojo has no such arithmetic, so the number is
written out and the expression is here to check it against.
"""

comptime _INTERNAL_TO_ABSOLUTE = -_ABSOLUTE_TO_INTERNAL
"""Seconds to add to an internal time to get an absolute one."""

comptime _UNIX_TO_INTERNAL = 62_135_596_800
"""Seconds from the year 1 to the year 1970, which is `(1969*365 + 1969/4 -
1969/100 + 1969/400) * 86400`."""

comptime _INTERNAL_TO_UNIX = -_UNIX_TO_INTERNAL
"""Seconds to add to an internal time to get a Unix one."""

comptime _UNIX_TO_ABSOLUTE = _UNIX_TO_INTERNAL + _INTERNAL_TO_ABSOLUTE
"""Seconds to add to a Unix time to get an absolute one."""

comptime _ABSOLUTE_TO_UNIX = -_UNIX_TO_ABSOLUTE
"""Seconds to add to an absolute time to get a Unix one."""


struct Month(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """A month of the year, January being 1. Go's `Month`.

    ```mojo
    from core.time import MARCH

    print(MARCH)  # => March
    ```

    Numbered from one rather than from zero, unlike `Weekday`, because that is
    how a date is written and how Go has it. A value outside one to twelve is
    not rejected, because `date` normalises its arguments and month thirteen of
    2024 is a way of writing January 2025 that Go supports on purpose.
    """

    var value: Int
    """The number of the month, one for January."""

    def __init__(out self, value: Int):
        """Hold a month number."""
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        """Whether these are the same month."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether these are different months."""
        return self.value != other.value

    def __add__(self, n: Int) -> Self:
        """`n` months later, without normalising.

        The answer can be month zero or month fourteen. `date` is where a
        number outside the year gets folded back in, so that adding a month to
        December and adding twelve to January go the same way.
        """
        return Self(self.value + n)

    def __sub__(self, n: Int) -> Self:
        """`n` months earlier, without normalising."""
        return Self(self.value - n)

    def write_to[W: Writer](self, mut writer: W):
        """The English name, or Go's marker for a number that is not a month.

        A negative month prints as a very large number rather than as a
        negative one, because Go's marker converts to unsigned before writing
        the digits and this matches it. It looks like a bug and it is Go's
        answer for the same input, which is worth more here than tidiness in a
        message that only appears when a month is already wrong.
        """
        if 1 <= self.value <= 12:
            writer.write(materialize[_MONTH_NAMES]()[self.value - 1])
        else:
            writer.write("%!Month(", UInt64(self.value), ")")


struct Weekday(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """A day of the week, Sunday being 0. Go's `Weekday`.

    ```mojo
    from core.time import TUESDAY

    print(TUESDAY)  # => Tuesday
    ```

    Sunday is zero because that is where Go starts, which is where C's `tm_wday`
    starts. ISO 8601 starts its week on Monday and `iso_week` knows that; this
    type does not, and reading `Weekday(1)` as the first day of the week is the
    mistake to avoid.
    """

    var value: Int
    """The number of the day, zero for Sunday."""

    def __init__(out self, value: Int):
        """Hold a weekday number."""
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        """Whether these are the same day of the week."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether these are different days of the week."""
        return self.value != other.value

    def write_to[W: Writer](self, mut writer: W):
        """The English name, or Go's marker for a number that is not a day.

        A negative day prints as a very large number, for the reason `Month`
        does.
        """
        if 0 <= self.value <= 6:
            writer.write(materialize[_DAY_NAMES]()[self.value])
        else:
            writer.write("%!Weekday(", UInt64(self.value), ")")


comptime JANUARY = Month(1)
"""January."""

comptime FEBRUARY = Month(2)
"""February, the only month whose length moves."""

comptime MARCH = Month(3)
"""March, which is where the absolute year starts."""

comptime APRIL = Month(4)
"""April."""

comptime MAY = Month(5)
"""May."""

comptime JUNE = Month(6)
"""June."""

comptime JULY = Month(7)
"""July."""

comptime AUGUST = Month(8)
"""August."""

comptime SEPTEMBER = Month(9)
"""September."""

comptime OCTOBER = Month(10)
"""October."""

comptime NOVEMBER = Month(11)
"""November."""

comptime DECEMBER = Month(12)
"""December."""

comptime SUNDAY = Weekday(0)
"""Sunday, which is day zero."""

comptime MONDAY = Weekday(1)
"""Monday."""

comptime TUESDAY = Weekday(2)
"""Tuesday."""

comptime WEDNESDAY = Weekday(3)
"""Wednesday, which is what March 1 of the absolute year was."""

comptime THURSDAY = Weekday(4)
"""Thursday, the day whose week decides the ISO year."""

comptime FRIDAY = Weekday(5)
"""Friday."""

comptime SATURDAY = Weekday(6)
"""Saturday."""

comptime _MONTH_NAMES: Array[StaticString, 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
]
"""The English month names, in Go's spelling and Go's order.

English rather than the locale's, because Go's layout language spells a format
by writing out a date in these words and a program that formatted with them and
parsed with somebody else's would be broken in a way that depended on where it
ran.
"""

comptime _DAY_NAMES: Array[StaticString, 7] = [
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
]
"""The English day names, from Sunday, for the same reason as the months."""


def is_leap(year: Int) -> Bool:
    """Whether `year` has a February 29. Go's `isLeap`.

    The rule is that a year divisible by four is a leap year unless it is
    divisible by one hundred, unless it is also divisible by four hundred. The
    arithmetic below is that rule as two bit tests, which works because the
    bottom two bits being clear is divisibility by four, and for a multiple of
    twenty five the bottom four bits being clear is divisibility by four
    hundred. Cassio Neri's trick, and Go's implementation.
    """
    var mask = 3
    if year % 25 == 0:
        mask = 0xF
    return year & mask == 0


def days_in(m: Month, year: Int) -> Int:
    """How many days are in that month of that year. Go's `daysIn`.

    February is the special case and everything else alternates thirty one and
    thirty, with the alternation inverting at August. The arithmetic below is
    that alternation: the bottom bit of the month number gives the swing, and
    the fourth bit turns it round from August onwards.
    """
    if m == FEBRUARY:
        return 29 if is_leap(year) else 28
    return 30 + ((m.value + (m.value >> 3)) & 1)


def days_before(m: Month) -> Int:
    """Days in a common year before the first of that month. Go's `daysBefore`.

    `days_before(JANUARY)` is zero and `days_before(Month(13))` is 365. The
    closed form is a brute force search over small coefficients that happens to
    reproduce the running sum exactly, which Go's comment explains and which is
    faster than a twelve entry table lookup only because the table would have
    to be materialised.
    """
    var adjust = -2 if m.value >= 3 else 0
    return _quo(214 * m.value - 211, 7) + adjust


def norm(hi: Int, lo: Int, base: Int) -> Tuple[Int, Int]:
    """`hi` and `lo` rewritten so that `lo` is in `[0, base)`. Go's `norm`.

    The two together still name the same value: `hi * base + lo` does not
    change. This is how `date` accepts October 32 and answers November 1, and
    how it accepts month zero and answers December of the year before.
    """
    var high = hi
    var low = lo
    if low < 0:
        var n = _quo(-low - 1, base) + 1
        high -= n
        low += n * base
    if low >= base:
        var n = _quo(low, base)
        high += n
        low -= n * base
    return (high, low)


def date_to_abs_days(year: Int, month: Month, day: Int) -> UInt64:
    """Days from the absolute epoch to that date. Go's `dateToAbsDays`.

    The date may be out of range in every field, and the day may be negative,
    because this is what `date` normalises through. The arithmetic runs in
    unsigned words and relies on wrapping around zero for a year before the
    absolute epoch, exactly as Go's does.
    """
    var amonth = month.value
    var jan_feb = 1 if amonth < 3 else 0

    # A year that starts in March puts January and February at the end of the
    # year before, which is what makes the leap day the last day of the year
    # and the day numbering below independent of it.
    amonth += 12 * jan_feb
    var y = UInt64(year) - UInt64(jan_feb) + UInt64(_ABSOLUTE_YEARS)

    # Days from March 1 to the first of this month, which is the 153 day cycle
    # of 31, 30, 31, 30, 31 repeated. Go uses the shifted form of the same
    # expression, which saves an instruction and is the one its comment
    # derives.
    var ayday = Int((979 * UInt64(amonth) - 2919) >> 5)

    var century = y // 100
    var cyear = Int(y % 100)
    var cday = 1461 * cyear // 4
    var century_days = 146097 * century // 4

    return century_days + UInt64(cday + ayday + day - 1)


def split_days(days: UInt64) -> Tuple[UInt64, Int, Int]:
    """Absolute days as a century, a year within it, and a day within that.

    Go's `absDays.split`. The day is counted from March 1, so it runs from zero
    to 365 and February is at the end of it. The two multiplications are the
    Neri and Schneider forms of the divisions in the comment at the top of this
    file.
    """
    var d = 4 * days + 3
    var century = d // 146097

    # This is `(d % 146097) / 4 * 4 + 3` with the shifts cancelled, which is
    # what makes it a mask rather than a division.
    var cd = UInt64(UInt32(d % 146097)) | 3

    var product = 2939745 * cd
    var cyear = Int(product >> 32)
    var ayday = Int((product & 0xFFFF_FFFF) // 2939745 // 4)
    return (century, cyear, ayday)


def split_yday(ayday: Int) -> Tuple[Int, Int]:
    """A March based day of the year as a March based month and a day of the
    month.

    Go's `absYday.split`. The month is three for March through fourteen for
    February, and the day of the month is counted from one.
    """
    var d = 2141 * ayday + 197913
    return (d >> 16, 1 + ((d & 0xFFFF) // 2141))


def jan_feb_of(ayday: Int) -> Int:
    """One if that March based day falls in January or February, zero if not.

    Those two months are where the absolute year and the calendar year disagree
    about which year it is, so every conversion out of absolute time needs this
    bit.
    """
    return 1 if ayday >= _MARCH_THRU_DECEMBER else 0


def month_of(amonth: Int, jan_feb: Int) -> Month:
    """The calendar month for a March based month number."""
    return Month(amonth - 12 * jan_feb)


def leap_of(century: UInt64, cyear: Int) -> Int:
    """One if that century and year within it is a leap year, zero if not.

    The same rule as `is_leap`, written against the split year because that is
    the form the date conversion already has in hand: divisibility by one
    hundred is the year within the century being zero, and by four hundred is
    that plus the century being divisible by four.
    """
    var by4 = 1 if cyear % 4 == 0 else 0
    var by100 = 1 if cyear != 0 else 0
    var by400 = 1 if century % 4 == 0 else 0
    return by4 & (by100 | by400)


def year_of(century: UInt64, cyear: Int, jan_feb: Int) -> Int:
    """The calendar year for a century, a year within it, and the January or
    February bit."""
    return Int(century) * 100 - _ABSOLUTE_YEARS + cyear + jan_feb


def yday_of(ayday: Int, jan_feb: Int, leap: Int) -> Int:
    """The day of the calendar year, counted from one, for a March based one.

    March 1 is day 60 of a common year and day 61 of a leap year, which is
    where the 31 and 28 come from. The leap day is only added for a day that is
    after it, which is what the mask against the January or February bit says.
    """
    return ayday + (1 + 31 + 28) + (leap & ~jan_feb) - 365 * jan_feb


def date_of(days: UInt64) -> Tuple[Int, Month, Int]:
    """Absolute days as a calendar year, month and day. Go's `absDays.date`."""
    var century, cyear, ayday = split_days(days)
    var amonth, day = split_yday(ayday)
    var jan_feb = jan_feb_of(ayday)
    return (year_of(century, cyear, jan_feb), month_of(amonth, jan_feb), day)


def year_yday(days: UInt64) -> Tuple[Int, Int]:
    """Absolute days as a calendar year and a day within it, counted from one.

    Go's `absDays.yearYday`.
    """
    var century, cyear, ayday = split_days(days)
    var jan_feb = jan_feb_of(ayday)
    return (
        year_of(century, cyear, jan_feb),
        yday_of(ayday, jan_feb, leap_of(century, cyear)),
    )


def weekday_of(days: UInt64) -> Weekday:
    """The day of the week for a count of absolute days.

    March 1 of the absolute year was a Wednesday, the same way March 1 of 2000
    was, because the calendar repeats every four hundred years and so do the
    days of the week within it.
    """
    return Weekday(Int((days + UInt64(WEDNESDAY.value)) % 7))


def clock_of(abs_sec: UInt64) -> Tuple[Int, Int, Int]:
    """The hour, minute and second within the day of an absolute time."""
    var rest = Int(abs_sec % SECONDS_PER_DAY)
    var hour = rest // SECONDS_PER_HOUR
    rest -= hour * SECONDS_PER_HOUR
    var minute = rest // SECONDS_PER_MINUTE
    rest -= minute * SECONDS_PER_MINUTE
    return (hour, minute, rest)
