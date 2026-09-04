"""An instant, to the nanosecond. Go's `Time`.

## Two clocks in one value

A `Time` read from `now` carries two readings of two different clocks. The wall
clock says what a person would call it, and it moves when the machine syncs
with a time server or when somebody sets it by hand, backwards as easily as
forwards. The monotonic clock says nothing about what time it is and only ever
counts up, from a moment the platform declines to describe.

The point of carrying both is that the right one gets used without the caller
choosing. `t2 - t1` between two times that both came from `now` is a monotonic
difference, so it is right even if the clock was set in between, which is the
bug that hides in code that subtracts two wall readings. Anything that asks
what time it is reads the wall clock instead. A `Time` built from a date or
from a Unix second has no monotonic reading, and a subtraction involving one
falls back to the wall clock.

## The fields are not Go's

Go packs the wall clock, the monotonic reading and a flag into two words, and
the packing is lossy on purpose: a time more than 292 years from 1885 does not
fit the packed form and Go drops the monotonic reading when it stores one. The
fields here are separate and nothing is dropped, so a far future `Time` keeps
its monotonic reading where Go's would lose it. `docs/deviations.md` has the
row. Nothing observable turns on it unless a program subtracts two times that
are both centuries away and both came from `now`, which cannot happen without
setting the machine clock.

## What is not here yet

The location. Every method below reads UTC, because a `Location` is a pointer
to a shared immutable table in Go and this language has neither null pointers
nor global mutable storage, so the design costs more than a paragraph. Until
it lands, `hour` on a machine in Tokyo answers what UTC says rather than what
the wall says, which is the one thing to know before using this package. The
layout language, `parse`, timers and marshalling are also still to come.
"""

from core.syscall import CLOCK_MONOTONIC, CLOCK_REALTIME, clock_gettime

from .calendar import (
    Month,
    Weekday,
    SECONDS_PER_DAY,
    SECONDS_PER_HOUR,
    SECONDS_PER_MINUTE,
    THURSDAY,
    _INTERNAL_TO_ABSOLUTE,
    _INTERNAL_TO_UNIX,
    _UNIX_TO_INTERNAL,
    clock_of,
    date_of,
    norm,
    date_to_abs_days,
    weekday_of,
    year_yday,
)
from .duration import (
    Duration,
    NANOSECOND,
    SECOND,
    _MAX,
    _MIN,
    _less_than_half,
)
from .divide import _quo, _rem


struct Time(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """A moment, held as whole seconds and nanoseconds within the second.

    ```mojo
    from core.time import DECEMBER, date

    var t = date(2024, DECEMBER, 25, 9, 30, 0, 0)
    print(t.year(), t.month(), t.day())  # => 2024 December 25
    ```

    The zero value is the first instant of January 1 of the year 1, which is
    what `is_zero` tests for. Go uses that value as its "no time here" marker
    for the same reason a null pointer would be used elsewhere, and so does
    this package.

    Copy one freely. It is four machine words and it holds no reference to
    anything, so passing it about costs nothing and no two copies can disagree.
    """

    var sec: Int
    """Seconds since the first instant of January 1 of the year 1, UTC.

    Not since 1970. The year 1 epoch is what lets the zero value mean the zero
    time, and `unix` is what converts. Negative for a date before the year 1,
    which the calendar arithmetic handles by shifting the epoch again.
    """

    var nsec: Int
    """Nanoseconds within that second, from zero to 999999999.

    Never negative, even when `sec` is. An instant one nanosecond before the
    epoch is second -1 and nanosecond 999999999, not second 0 and nanosecond
    -1, and every function that produces a `Time` normalises to that form.
    """

    var mono: Int
    """The monotonic clock reading, in nanoseconds, or zero if there is none.

    Meaningless on its own: the platform does not say what it counts from, only
    that it counts up. Subtracting two of them is the only use there is.
    """

    var has_mono: Bool
    """Whether `mono` is a reading rather than a leftover zero.

    Separate from `mono` because zero is a reading a monotonic clock can
    legitimately hand back, on a machine that has just started.
    """

    def __init__(
        out self,
        *,
        internal_sec: Int = 0,
        nsec: Int = 0,
        mono: Int = 0,
        has_mono: Bool = False,
    ):
        """Hold an instant, from parts already normalised.

        Called with no arguments for the zero time, which is what a `Time`
        field of a struct wants. Called with arguments only from inside this
        package, because the seconds are counted from the year 1 and nothing
        outside thinks in those terms. `date` and `unix` are the ways in.
        """
        self.sec = internal_sec
        self.nsec = nsec
        self.mono = mono
        self.has_mono = has_mono

    def _abs_sec(self) -> UInt64:
        """This instant as a count of seconds from the absolute epoch.

        The single place the calendar is entered from, and so the single place
        a zone offset will be added when locations land. Everything that
        answers a question about the date goes through here.

        The addition is unsigned so that a `sec` far enough forward to overflow
        a signed word wraps rather than trapping, which is what Go's does and
        what the absolute epoch is arranged to make harmless.
        """
        return UInt64(self.sec) + UInt64(_INTERNAL_TO_ABSOLUTE)

    def _abs_days(self) -> UInt64:
        """This instant as a count of whole days from the absolute epoch."""
        return self._abs_sec() // SECONDS_PER_DAY

    def _strip_mono(self) -> Self:
        """The same instant with the monotonic reading dropped.

        Anything that changes the wall clock reading has to drop it, because
        the two would then describe different instants and the next subtraction
        would silently take the stale one.
        """
        return Self(internal_sec=self.sec, nsec=self.nsec)

    def is_zero(self) -> Bool:
        """Whether this is the zero time, January 1 of the year 1, UTC.

        Go's `IsZero`. The test people reach for to ask whether a `Time` was
        ever set, which works because that instant is far enough from anything
        real to be an unambiguous marker.
        """
        return self.sec == 0 and self.nsec == 0

    def unix(self) -> Int:
        """Seconds since January 1 1970 UTC, rounding down. Go's `Unix`.

        Rounding down rather than towards zero, because the nanoseconds are
        always positive and dropping them is what going down means. An instant
        half a second before the epoch has Unix second -1.
        """
        return self.sec + _INTERNAL_TO_UNIX

    def unix_milli(self) -> Int:
        """Milliseconds since the Unix epoch, rounding down. Go's `UnixMilli`.
        """
        return self.unix() * 1_000 + self.nsec // 1_000_000

    def unix_micro(self) -> Int:
        """Microseconds since the Unix epoch, rounding down. Go's `UnixMicro`.
        """
        return self.unix() * 1_000_000 + self.nsec // 1_000

    def unix_nano(self) -> Int:
        """Nanoseconds since the Unix epoch. Go's `UnixNano`.

        The value is undefined for a date before 1678 or after 2262, because a
        nanosecond count of anything further out does not fit a machine word.
        Go says the same and neither library checks, since the check would cost
        something on every call to catch a mistake nobody makes.
        """
        return self.unix() * 1_000_000_000 + self.nsec

    def date(self) -> Tuple[Int, Month, Int]:
        """The year, month and day this instant falls on. Go's `Date`.

        ```mojo
        from core.time import JULY, date

        var year, month, day = date(2024, JULY, 4, 0, 0, 0, 0).date()
        print(year, month, day)  # => 2024 July 4
        ```

        All three together, because computing one of them computes the other
        two anyway and asking three times does the work three times.
        """
        return date_of(self._abs_days())

    def year(self) -> Int:
        """The year. Go's `Year`."""
        return year_yday(self._abs_days())[0]

    def month(self) -> Month:
        """The month. Go's `Month`."""
        return self.date()[1]

    def day(self) -> Int:
        """The day of the month, from one. Go's `Day`."""
        return self.date()[2]

    def year_day(self) -> Int:
        """The day of the year, from one to 365 or 366. Go's `YearDay`."""
        return year_yday(self._abs_days())[1]

    def weekday(self) -> Weekday:
        """The day of the week. Go's `Weekday`."""
        return weekday_of(self._abs_days())

    def iso_week(self) -> Tuple[Int, Int]:
        """The ISO 8601 year and week number. Go's `ISOWeek`.

        ```mojo
        from core.time import JANUARY, date

        var year, week = date(2021, JANUARY, 1, 0, 0, 0, 0).iso_week()
        print(year, week)  # => 2020 53
        ```

        The ISO year is not always the calendar year, which is what the example
        shows: a week belongs to whichever year its Thursday falls in, so the
        first days of January can be in the last week of the year before, and
        the last days of December can be in week 1 of the year after.

        The arithmetic below is that rule directly. Step from this day to the
        Thursday of its week, then ask what year and what day of the year that
        Thursday is, then divide by seven.
        """
        var days = self._abs_days()

        # `(days - 1).weekday() + 1` is the day of the week counted from Monday
        # as 1, which is the numbering ISO uses and the one Go steps in.
        var from_monday = weekday_of(days - 1).value + 1
        var thursday = days + UInt64(THURSDAY.value - from_monday)

        var year, yday = year_yday(thursday)
        return (year, (yday - 1) // 7 + 1)

    def clock(self) -> Tuple[Int, Int, Int]:
        """The hour, minute and second within the day. Go's `Clock`."""
        return clock_of(self._abs_sec())

    def hour(self) -> Int:
        """The hour within the day, from zero to 23. Go's `Hour`."""
        return Int(self._abs_sec() % SECONDS_PER_DAY) // SECONDS_PER_HOUR

    def minute(self) -> Int:
        """The minute within the hour, from zero to 59. Go's `Minute`."""
        return Int(self._abs_sec() % SECONDS_PER_HOUR) // SECONDS_PER_MINUTE

    def second(self) -> Int:
        """The second within the minute, from zero to 59. Go's `Second`.

        Never 60. A leap second is not represented, here or on any clock the
        platform offers.
        """
        return Int(self._abs_sec() % SECONDS_PER_MINUTE)

    def nanosecond(self) -> Int:
        """The nanosecond within the second. Go's `Nanosecond`."""
        return self.nsec

    def __add__(self, d: Duration) -> Self:
        """This instant `d` later, or earlier for a negative `d`. Go's `Add`.

        ```mojo
        from core.time import HOUR, JUNE, date

        var t = date(2024, JUNE, 1, 23, 0, 0, 0)
        print((t + 2 * HOUR).day())  # => 2
        ```

        The monotonic reading moves with the wall clock, so a time from `now`
        plus a duration is still a monotonic time and subtracting it from
        another one is still exact. It is dropped if moving it would run off
        the end of a machine word, which takes a shift of about 292 years.
        """
        var dsec = _quo(d.value, 1_000_000_000)
        var ns = self.nsec + _rem(d.value, 1_000_000_000)
        if ns >= 1_000_000_000:
            dsec += 1
            ns -= 1_000_000_000
        elif ns < 0:
            dsec -= 1
            ns += 1_000_000_000

        var moved = Self(internal_sec=self.sec + dsec, nsec=ns)
        if not self.has_mono:
            return moved

        var shifted = self.mono + d.value
        if (d.value < 0) != (shifted < self.mono):
            # The shift went the wrong way, which only happens on overflow.
            return moved
        moved.mono = shifted
        moved.has_mono = True
        return moved

    def __sub__(self, other: Self) -> Duration:
        """How long from `other` to this one. Go's `Sub`.

        ```mojo
        from core.time import MAY, SECOND, date

        var start = date(2024, MAY, 1, 12, 0, 0, 0)
        var end = date(2024, MAY, 1, 12, 0, 30, 0)
        print((end - start) // SECOND)  # => 30
        ```

        Monotonic if both sides have a monotonic reading, which is what makes
        this the right way to measure how long something took. A gap too large
        for a duration saturates at the largest one in that direction, because
        the alternative is wrapping round to the opposite sign.
        """
        if self.has_mono and other.has_mono:
            var mono = self.mono - other.mono
            if mono < 0 and other.mono < self.mono:
                return Duration(_MAX)
            if mono > 0 and other.mono > self.mono:
                return Duration(_MIN)
            return Duration(mono)

        var d = Duration(
            (self.sec - other.sec) * 1_000_000_000 + (self.nsec - other.nsec)
        )
        if (other + d)._same_instant(self):
            return d
        if self < other:
            return Duration(_MIN)
        return Duration(_MAX)

    def _same_instant(self, other: Self) -> Bool:
        """Whether the two wall clock readings are the same instant.

        Separate from `__eq__` only so that `__sub__` can use it while
        `__eq__` is being defined in terms of the same fields.
        """
        return self.sec == other.sec and self.nsec == other.nsec

    def __eq__(self, other: Self) -> Bool:
        """Whether these are the same instant. Go's `Equal`.

        ```mojo
        from core.time import APRIL, date

        print(date(2024, APRIL, 1, 0, 0, 0, 0) == date(2024, APRIL, 1, 0, 0, 0, 0))  # => True
        ```

        Go's `==` on a `Time` compares the fields, monotonic reading and
        location pointer included, so two values naming the same instant can
        compare unequal and Go's own documentation warns against using it. This
        is Go's `Equal`, which compares the instant, and it is what `==` means
        here. The deviation is recorded in `docs/deviations.md`, and it is the
        one place this library takes the operator away from Go's meaning on
        purpose.
        """
        if self.has_mono and other.has_mono:
            return self.mono == other.mono
        return self._same_instant(other)

    def __ne__(self, other: Self) -> Bool:
        """Whether these are different instants."""
        return not (self == other)

    def compare(self, other: Self) -> Int:
        """-1, 0 or 1 as this instant is before, at, or after `other`.

        Go's `Compare`. For a sort comparator, where the three way answer is
        what is wanted and two comparisons would be a wasted one.
        """
        if self.has_mono and other.has_mono:
            if self.mono < other.mono:
                return -1
            return 1 if self.mono > other.mono else 0
        if self.sec != other.sec:
            return -1 if self.sec < other.sec else 1
        if self.nsec != other.nsec:
            return -1 if self.nsec < other.nsec else 1
        return 0

    def __lt__(self, other: Self) -> Bool:
        """Whether this instant is before `other`. Go's `Before`."""
        return self.compare(other) < 0

    def __le__(self, other: Self) -> Bool:
        """Whether this instant is at or before `other`."""
        return self.compare(other) <= 0

    def __gt__(self, other: Self) -> Bool:
        """Whether this instant is after `other`. Go's `After`."""
        return self.compare(other) > 0

    def __ge__(self, other: Self) -> Bool:
        """Whether this instant is at or after `other`."""
        return self.compare(other) >= 0

    def add_date(self, years: Int, months: Int, days: Int) -> Self:
        """This date moved by whole calendar units. Go's `AddDate`.

        ```mojo
        from core.time import JANUARY, date

        var t = date(2024, JANUARY, 31, 0, 0, 0, 0)
        print(t.add_date(0, 1, 0).date()[1])  # => March
        ```

        Adding a month to January 31 gives March 2, not February 29, because
        the result is normalised the same way `date` normalises its arguments
        and February 31 is March 2 or 3 depending on the year. Go does the same
        and documents it with the same example. A caller who wants the last day
        of the next month has to ask for day zero of the month after that.

        The units are applied in the order they are given, so a year is added
        before a month and a month before a day, and moving by a year and a
        month is not always the same as moving by thirteen months.
        """
        var year, month, day = self.date()
        var hour, minute, sec = self.clock()
        return date(
            year + years,
            month + months,
            day + days,
            hour,
            minute,
            sec,
            self.nsec,
        )

    def truncate(self, d: Duration) -> Self:
        """This instant rounded down to a multiple of `d` since the zero time.

        Go's `Truncate`. Since the zero time, which is January 1 of the year 1,
        so truncating to an hour lands on the hour and truncating to a week
        lands on a Monday rather than on whatever day of the week is convenient.

        A zero or negative `d` gives the instant back with only its monotonic
        reading stripped, which is Go's rule.
        """
        var stripped = self._strip_mono()
        if d.value <= 0:
            return stripped
        var r = _div(stripped, d)[1]
        return stripped + -r

    def round(self, d: Duration) -> Self:
        """This instant rounded to the nearest multiple of `d` since the zero
        time, halves rounding up.

        Go's `Round`. A zero or negative `d` gives the instant back with only
        its monotonic reading stripped.
        """
        var stripped = self._strip_mono()
        if d.value <= 0:
            return stripped
        var r = _div(stripped, d)[1]
        if _less_than_half(r.value, d.value):
            return stripped + -r
        return stripped + (d - r)

    def write_to[W: Writer](self, mut writer: W):
        """The instant in Go's default notation, as `Time.String` writes it.

        ```mojo
        from core.time import MARCH, date

        print(date(2024, MARCH, 9, 14, 5, 6, 0))  # => 2024-03-09 14:05:06 +0000 UTC
        ```

        The layout is `2006-01-02 15:04:05.999999999 -0700 MST`, which is the
        one Go's own `String` uses. The fraction is left out when it is zero
        and its trailing zeros are dropped otherwise, so a whole second reads
        as `06` and half a second reads as `06.5`.

        The zone is always `+0000 UTC` until locations land, and a time with a
        monotonic reading gets Go's ` m=` suffix so that two of them printed
        next to each other can be told apart.

        Written by hand rather than through the layout language, which is not
        here yet. It moves to `format` when that lands and this docstring goes
        with it.
        """
        var year, month, day = self.date()
        var hour, minute, sec = self.clock()

        var out = String()
        _write_padded(out, year, 4)
        out += "-"
        _write_padded(out, month.value, 2)
        out += "-"
        _write_padded(out, day, 2)
        out += " "
        _write_padded(out, hour, 2)
        out += ":"
        _write_padded(out, minute, 2)
        out += ":"
        _write_padded(out, sec, 2)
        _write_fraction(out, self.nsec)
        out += " +0000 UTC"

        if self.has_mono:
            out += " m="
            var m = self.mono
            if m < 0:
                out += "-"
                m = -m
            else:
                out += "+"
            var whole = m // 1_000_000_000
            out += String(whole)
            out += "."
            _write_padded(out, m % 1_000_000_000, 9)

        writer.write(out)


def _write_padded(mut out: String, value: Int, width: Int):
    """`value` in decimal, zero padded to `width` digits, minus sign first.

    A number too long for the width is written in full rather than truncated,
    which is what Go's `appendInt` does and what keeps the year 10000 from
    printing as `0000`. The sign is not counted towards the width, so the year
    -1 is six characters.
    """
    var digits = String(abs(value))
    if value < 0:
        out += "-"
    for _ in range(width - digits.byte_length()):
        out += "0"
    out += digits


def _write_fraction(mut out: String, nsec: Int):
    """A decimal point and the nanoseconds, or nothing at all if they are zero.

    Trailing zeros go, which is what the `.999999999` in Go's layout asks for,
    as against the `.000000000` that keeps them.
    """
    if nsec == 0:
        return
    var digits = String()
    _write_padded(digits, nsec, 9)
    var end = digits.byte_length()
    while end > 0 and digits[byte=end - 1] == "0":
        end -= 1
    out += "."
    out += digits[byte=0:end]


def _div(t: Time, d: Duration) -> Tuple[Int, Duration]:
    """`t` divided by `d`, as the parity of the quotient and the remainder.

    Go's `div`. The quotient itself is never wanted and would usually not fit,
    so only its bottom bit comes back, which is all `round` needs to break a
    tie. The remainder is what both `round` and `truncate` subtract.

    Three cases, and the first two are the ones that happen. A duration that
    divides a second exactly needs only the nanoseconds. A duration that is a
    whole number of seconds needs only the seconds. The third is the general
    one, where the product of the seconds and a billion does not fit a machine
    word, and it is a long division done in two halves. Go's comment on it says
    nobody will care about these cases, and keeping it is cheaper than working
    out which calls would hit it.
    """
    var negative = False
    var sec = t.sec
    var nsec = t.nsec
    if sec < 0:
        # Work on the magnitude, and put the sign back at the end. The
        # correction there is not a negation, because the remainder of a
        # negative division is measured from the other end of the interval.
        negative = True
        sec = -sec
        nsec = -nsec
        if nsec < 0:
            nsec += 1_000_000_000
            sec -= 1

    var qmod2: Int
    var r: Duration

    if d.value < SECOND.value and SECOND.value % (d.value + d.value) == 0:
        qmod2 = (nsec // d.value) & 1
        r = Duration(nsec % d.value)
    elif d.value % SECOND.value == 0:
        var d1 = d.value // SECOND.value
        qmod2 = (sec // d1) & 1
        r = Duration((sec % d1) * SECOND.value + nsec)
    else:
        # The nanosecond count as a 128 bit number in two halves.
        var usec = UInt64(sec)
        var tmp = (usec >> 32) * 1_000_000_000
        var u1 = tmp >> 32
        var u0 = tmp << 32
        tmp = (usec & 0xFFFF_FFFF) * 1_000_000_000
        var carried = u0
        u0 += tmp
        if u0 < carried:
            u1 += 1
        carried = u0
        u0 += UInt64(nsec)
        if u0 < carried:
            u1 += 1

        # Long division by repeated subtraction of `d` shifted down one bit at
        # a time. The parity of the quotient is whether the last round
        # subtracted.
        var d1 = UInt64(d.value)
        while d1 >> 63 != 1:
            d1 <<= 1
        var d0 = UInt64(0)
        while True:
            qmod2 = 0
            if u1 > d1 or (u1 == d1 and u0 >= d0):
                qmod2 = 1
                carried = u0
                u0 -= d0
                if u0 > carried:
                    u1 -= 1
                u1 -= d1
            if d1 == 0 and d0 == UInt64(d.value):
                break
            d0 >>= 1
            d0 |= (d1 & 1) << 63
            d1 >>= 1
        r = Duration(Int(u0))

    if negative and r.value != 0:
        qmod2 ^= 1
        r = d - r
    return (qmod2, r)


def now() raises -> Time:
    """What time it is, with a monotonic reading attached. Go's `Now`.

    ```mojo
    from core.time import now

    var start = now()
    var elapsed = now() - start
    print(elapsed >= Duration(0))  # => True
    ```

    Two readings of two clocks, so the two are taken microseconds apart rather
    than at the same instant. Go's runtime gets both from one call into the
    kernel's shared page and this cannot, because the shared page is not
    something a syscall exposes. The gap does not affect a difference between
    two times from `now`, which is monotonic on both sides and never mixes the
    two clocks.

    Raises if the platform refuses to read a clock, which it does not do in
    practice. Every function in this library is allowed to raise, so this costs
    a caller nothing.
    """
    var wall = clock_gettime(CLOCK_REALTIME)
    var mono = clock_gettime(CLOCK_MONOTONIC)
    return Time(
        internal_sec=wall.sec + _UNIX_TO_INTERNAL,
        nsec=wall.nsec,
        mono=mono.sec * 1_000_000_000 + mono.nsec,
        has_mono=True,
    )


def since(t: Time) raises -> Duration:
    """How long it has been since `t`. Go's `Since`.

    Monotonic if `t` came from `now`, which is the case worth having: a
    measurement taken this way is right even if the machine's clock was set
    while it ran.
    """
    return now() - t


def until(t: Time) raises -> Duration:
    """How long there is until `t`. Go's `Until`.

    Negative if `t` has already passed, which is the answer a timeout wants
    rather than a zero that hides how late it is.
    """
    return t - now()


def date(
    year: Int,
    month: Month,
    day: Int,
    hour: Int,
    minute: Int,
    sec: Int,
    nsec: Int,
) -> Time:
    """The instant those parts name, in UTC. Go's `Date`.

    ```mojo
    from core.time import FEBRUARY, date

    print(date(2023, FEBRUARY, 30, 0, 0, 0, 0).date())  # => (2023, March, 2)
    ```

    Every argument is normalised rather than rejected, which is what the
    example shows and what makes this the way to do calendar arithmetic. Month
    thirteen is January of the next year, hour 24 is midnight the next day, and
    day zero is the last day of the previous month, which is the trick for
    finding it. Go behaves identically.

    Go takes a `*Location` and panics on nil. This takes none and always
    answers UTC, because locations are not here yet. The package docstring says
    what that costs, and the argument arrives when they land.
    """
    # The month is normalised from zero so that month zero falls into the year
    # before, then put back to counting from one.
    var normal_month = norm(year, month.value - 1, 12)
    var y = normal_month[0]
    var m = Month(normal_month[1] + 1)

    # Then the clock, each unit overflowing into the next largest, ending in
    # the day. The day itself is not normalised here: `date_to_abs_days` takes
    # a day of any size and the calendar sorts it out.
    var normal_sec = norm(sec, nsec, 1_000_000_000)
    var normal_min = norm(minute, normal_sec[0], 60)
    var normal_hour = norm(hour, normal_min[0], 60)
    var normal_day = norm(day, normal_hour[0], 24)

    var abs_days = date_to_abs_days(y, m, normal_day[0])
    var abs_sec = abs_days * SECONDS_PER_DAY + UInt64(
        normal_day[1] * SECONDS_PER_HOUR
        + normal_hour[1] * SECONDS_PER_MINUTE
        + normal_min[1]
    )
    return Time(
        internal_sec=Int(abs_sec - UInt64(_INTERNAL_TO_ABSOLUTE)),
        nsec=normal_sec[1],
    )


def unix(sec: Int, nsec: Int) -> Time:
    """The instant `sec` seconds and `nsec` nanoseconds after the Unix epoch.

    Go's `Unix`. The nanoseconds may be outside the range of a second, in which
    case they are carried into the seconds, so passing the whole count as
    nanoseconds and zero seconds works.
    """
    var s = sec
    var ns = nsec
    if ns < 0 or ns >= 1_000_000_000:
        var n = _quo(ns, 1_000_000_000)
        s += n
        ns -= n * 1_000_000_000
        if ns < 0:
            ns += 1_000_000_000
            s -= 1
    return Time(internal_sec=s + _UNIX_TO_INTERNAL, nsec=ns)


def unix_milli(msec: Int) -> Time:
    """The instant `msec` milliseconds after the Unix epoch. Go's `UnixMilli`.
    """
    return unix(_quo(msec, 1_000), _rem(msec, 1_000) * 1_000_000)


def unix_micro(usec: Int) -> Time:
    """The instant `usec` microseconds after the Unix epoch. Go's `UnixMicro`.
    """
    return unix(_quo(usec, 1_000_000), _rem(usec, 1_000_000) * 1_000)
