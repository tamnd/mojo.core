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

## The location travels with the instant

A `Time` carries a `Location`, and every method that names a field reads the
clock of that location rather than UTC. The instant itself is stored in UTC and
never moves, so `in_location` changes what `hour` answers and changes nothing
about which moment is being talked about, which is Go's rule and the only one
that makes `t1 == t2` mean what it should.

A `Location` here is a counted pointer to a table, so carrying one costs a word
and copying a `Time` costs an atomic increment. The default is the location that
points at no table, which is UTC and allocates nothing, so a `Time` nobody gave
a location to is exactly as cheap as it was before locations existed.

## This module and `parse.mojo` import each other

Every other module in this package is in a strict order, and this pair is the
exception. `unmarshal_text` has to read RFC 3339 back, the reader is `parse`,
and `parse` needs the `Time` that lives here in order to produce one. Mojo
allows two modules of one package to import each other and the package graph
check is about packages rather than modules, so nothing has to move. Go has the
same mutual dependency between `time.go` and `format.go` and cannot notice it,
because a Go package is one namespace with no order inside it.

## What is not here yet

The timers, which want somewhere to run a callback and so want `core.sync`
first.
"""

from core.errors import Report
from core.errors.codes import ErrMarshalTime, ErrUnmarshalTime
from core.syscall import CLOCK_MONOTONIC, CLOCK_REALTIME, clock_gettime

from .calendar import (
    DECEMBER,
    JANUARY,
    _MONTH_NAMES,
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
from .format import RFC3339, RFC3339_NANO, _append_format, _append_int
from .load import local
from .parse import _quote, parse
from .tzset import _ALPHA, _OMEGA
from .zone import Location, fixed_zone


struct Time(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """A moment, held as whole seconds and nanoseconds within the second.

    ```mojo
    from core.time import DECEMBER, date

    var t = date(2024, DECEMBER, 25, 9, 30, 0, 0)
    print(t.year(), t.month(), t.day())  # => 2024 December 25
    ```

    The zero value is the first instant of January 1 of the year 1 UTC, which
    is what `is_zero` tests for. Go uses that value as its "no time here" marker
    for the same reason a null pointer would be used elsewhere, and so does
    this package.

    Copy one freely. The instant is four machine words and the location is a
    counted pointer, so a copy is those words and an atomic increment, and no
    two copies can disagree because the table a location points at is never
    written to after it is built.
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

    var loc: Location
    """Whose wall clock the fields are read against. UTC by default.

    Go holds a `*Location` here and treats nil as UTC. This holds a `Location`,
    which is itself a counted pointer whose empty value is UTC, so the two are
    the same arrangement with the nil case given a name.
    """

    def __init__(
        out self,
        *,
        internal_sec: Int = 0,
        nsec: Int = 0,
        mono: Int = 0,
        has_mono: Bool = False,
        loc: Location = Location(),
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
        self.loc = loc

    def _lookup(self) -> Tuple[String, Int, Int, Int, Bool]:
        """The zone in force here, as `Location.lookup` answers it.

        Go's `Time.loc.lookup(t.unixSec())`. A `Time` in UTC never touches the
        location at all, since the empty `Location` short circuits.
        """
        return self.loc.lookup(self.unix())

    def _offset(self) -> Int:
        """Seconds east of UTC for this instant in this location."""
        return self._lookup()[1]

    def _abs_sec(self) -> UInt64:
        """This instant as a count of seconds from the absolute epoch, in this
        location's clock.

        The single place the calendar is entered from and the single place the
        zone offset is added, so everything that answers a question about the
        date sees the same wall clock and nothing has to remember to shift.

        The addition is unsigned so that a `sec` far enough forward to overflow
        a signed word wraps rather than trapping, which is what Go's does and
        what the absolute epoch is arranged to make harmless.
        """
        return (
            UInt64(self.sec)
            + UInt64(self._offset())
            + UInt64(_INTERNAL_TO_ABSOLUTE)
        )

    def _abs_days(self) -> UInt64:
        """This instant as a count of whole days from the absolute epoch."""
        return self._abs_sec() // SECONDS_PER_DAY

    def _strip_mono(self) -> Self:
        """The same instant with the monotonic reading dropped.

        Anything that changes the wall clock reading has to drop it, because
        the two would then describe different instants and the next subtraction
        would silently take the stale one.
        """
        return Self(internal_sec=self.sec, nsec=self.nsec, loc=self.loc)

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

    def location(self) -> Location:
        """Whose wall clock this instant is read against. Go's `Location`.

        A counted pointer, so this is a cheap copy of the handle rather than a
        copy of the table. Go returns the pointer itself and this is the same
        thing with the counting made explicit.
        """
        return self.loc

    def in_location(self, loc: Location) -> Self:
        """The same instant, read against `loc`. Go's `In`.

        ```mojo
        from core.time import JUNE, date, fixed_zone, utc

        var t = date(2024, JUNE, 1, 12, 0, 0, 0, utc())
        print(t.in_location(fixed_zone("CET", 3600)).hour())  # => 13
        ```

        Nothing about which moment this is changes, which is the whole point:
        `t.in_location(anywhere) == t` is always true, and only the answers to
        `hour`, `day` and the rest move. Go names this `In` and that is a
        keyword here, so it says what it does instead.

        The monotonic reading goes, because Go drops it in `In` and for the
        same reason it drops it everywhere else that touches the wall clock:
        a value that has been moved about should not still claim to be a
        measurement.
        """
        var moved = self._strip_mono()
        moved.loc = loc
        return moved

    def utc(self) -> Self:
        """The same instant, read against UTC. Go's `UTC`."""
        return self.in_location(Location())

    def zone(self) -> Tuple[String, Int]:
        """The name and offset of the zone in force here. Go's `Zone`.

        ```mojo
        from core.time import JUNE, date, fixed_zone

        var name, offset = date(2024, JUNE, 1, 12, 0, 0, 0, fixed_zone("CET", 3600)).zone()
        print(name, offset)  # => CET 3600
        ```

        The offset is seconds east of UTC, so adding it to the Unix second
        gives the wall clock reading.
        """
        var got = self._lookup()
        return (got[0], got[1])

    def zone_bounds(self) -> Tuple[Self, Self]:
        """When the zone in force here began and when it ends. Go's
        `ZoneBounds`.

        Both are read in this instant's own location. A zone that has always
        been in force gives the zero time for the start, and one that never
        ends gives the zero time for the end, which is Go's way of saying
        there is no bound rather than inventing one.
        """
        var got = self._lookup()
        var start = Self()
        var end = Self()
        if got[2] != _ALPHA:
            start = unix(got[2], 0).in_location(self.loc)
        if got[3] != _OMEGA:
            end = unix(got[3], 0).in_location(self.loc)
        return (start, end)

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

        var moved = Self(internal_sec=self.sec + dsec, nsec=ns, loc=self.loc)
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
            self.loc,
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

    def format(self, layout: StringSlice) -> String:
        """This instant written out by `layout`. Go's `Format`.

        ```mojo
        from core.time import DATE_ONLY, MARCH, date

        print(date(2024, MARCH, 9, 14, 5, 6, 0).format(DATE_ONLY))
        # => 2024-03-09
        ```

        The layout is an example rather than a pattern: it is the reference
        instant `01/02 03:04:05PM '06 -0700` written the way the answer should
        be, and `core/time/format.mojo` is where that is explained and where
        the named layouts such as `RFC3339` and `DATE_ONLY` live.
        """
        var out = List[UInt8]()
        _ = self.append_format(out, layout)
        return String(from_utf8_lossy=Span(out))

    def append_format(self, mut dst: List[UInt8], layout: StringSlice) -> Int:
        """`format(layout)` onto the end of `dst`, and how many bytes that
        took. Go's `AppendFormat`, which hands back the grown slice instead.

        The count rather than the list, the same as `strconv.append_int` and
        the rest of the `append_` family: the list is already the caller's and
        a second name for it is the thing that goes stale.
        """
        var name, offset, _, _, _ = self._lookup()
        var abs_sec = (
            UInt64(self.sec) + UInt64(offset) + UInt64(_INTERNAL_TO_ABSOLUTE)
        )
        return _append_format(
            dst,
            layout,
            abs_sec // SECONDS_PER_DAY,
            abs_sec,
            self.nsec,
            name,
            offset,
        )

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

        The zone is this instant's own, so a time in Berlin in June prints
        `+0200 CEST`, and a time with a monotonic reading gets Go's ` m=` suffix
        so that two of them printed next to each other can be told apart.

        The suffix is the only part written by hand. Go leaves it out of the
        layout language too, because there is no piece of the reference instant
        that could stand for a reading no calendar has a place for.
        """
        var out = List[UInt8]()
        _ = self.append_format(out, "2006-01-02 15:04:05.999999999 -0700 MST")

        if self.has_mono:
            out.extend(" m=".as_bytes())
            var m = self.mono
            if m < 0:
                out.extend("-".as_bytes())
                m = -m
            else:
                out.extend("+".as_bytes())
            _append_int(out, m // 1_000_000_000, 0)
            out.extend(".".as_bytes())
            _append_int(out, m % 1_000_000_000, 9)

        writer.write(String(from_utf8_lossy=Span(out)))

    def go_string(self) -> String:
        """The `date` call that would build this instant. Go's `GoString`.

        ```mojo
        from core.time import MARCH, date

        print(date(2024, MARCH, 9, 14, 5, 6, 0).go_string())
        # => date(2024, MARCH, 9, 14, 5, 6, 0, utc())
        ```

        Go writes `time.Date(...)` here because that is what `%#v` should print
        for a value: source that would build it again. This writes the same
        call in this library's spelling, so it can be pasted into a test.

        The location is the part Go could not solve and neither can this. Go
        writes `time.Location("Europe/Berlin")`, which is not a constructor and
        does not compile, and its own comment says the alternatives are all
        worse. `utc()` and `local()` do compile and are used where they apply,
        and anything else gets `location("name")`, which is Go's admission in
        this library's spelling. Go tells its three cases apart by comparing
        pointers and this compares names, so a location that was loaded under
        the name `Local` prints as `local()`, which is what it is.
        """
        var year, month, day = self.date()
        var hour, minute, second = self.clock()

        var out = List[UInt8]()
        out.extend("date(".as_bytes())
        _append_int(out, year, 0)
        out.extend(", ".as_bytes())
        if JANUARY.value <= month.value and month.value <= DECEMBER.value:
            # Upper cased here rather than kept in a second table, because a
            # constant is spelled in capitals in this library and `March` is
            # the name the formatter needs.
            var name = materialize[_MONTH_NAMES]()[Int(month.value) - 1]
            for i in range(len(name.as_bytes())):
                var c = name.as_bytes()[i]
                if UInt8(ord("a")) <= c and c <= UInt8(ord("z")):
                    c -= 32
                out.append(c)
        else:
            # Go guards this too. Reaching it means a month outside one and
            # twelve, which the calendar never produces and a hand built value
            # could.
            _append_int(out, Int(month.value), 0)
        for field in [day, hour, minute, second, self.nsec]:
            out.extend(", ".as_bytes())
            _append_int(out, field, 0)
        out.extend(", ".as_bytes())

        var name = self.loc.name()
        if not self.loc.table:
            out.extend("utc()".as_bytes())
        elif name == "Local":
            out.extend("local()".as_bytes())
        else:
            out.extend("location(".as_bytes())
            out.extend(_quote(name).as_bytes())
            out.extend(")".as_bytes())
        out.extend(")".as_bytes())
        return String(from_utf8_lossy=Span(out))

    def is_dst(self) -> Bool:
        """Whether the zone in force here is a daylight saving one. Go's
        `IsDST`.

        ```mojo
        from core.time import JULY, date, fixed_zone

        print(date(2024, JULY, 1, 12, 0, 0, 0, fixed_zone("CET", 3600)).is_dst())
        # => False
        ```

        The zone file says so, one flag per zone, so this is a fact about what
        the place called it rather than a guess from the offset. A fixed zone is
        never one, whatever it is named, because nobody told it that it was.
        """
        return self._lookup()[4]

    def local(self) -> Self:
        """The same instant, read against the host's own zone. Go's `Local`.

        `in_location(local())`, which is all Go's is. Worth knowing that the
        host's zone is loaded on every call here and once ever in Go, for the
        reason `local` gives: there is nowhere to keep it.
        """
        return self.in_location(local())

    def append_binary(self, mut dst: List[UInt8]) raises -> Int:
        """This instant in Go's binary form, appended to `dst`, and how many
        bytes that took. Go's `AppendBinary`.

        Fifteen bytes, or sixteen. A version byte, then the seconds since the
        year 1 as eight bytes most significant first, then the nanoseconds as
        four, then the zone offset in whole minutes as two. An offset of -1
        minute cannot occur and so is the marker for UTC, which is why a value
        in UTC and a value in a fixed zone of zero are not the same bytes.

        The sixteenth byte appears when the offset is not a whole number of
        minutes, which is version 2 and exists for the local mean time entries
        at the start of most zone files: Kathmandu before 1920 was 5 hours 41
        minutes and 16 seconds east, and the seconds have nowhere else to go.

        Nothing is appended when this raises, so a list that was handed to a
        failing call is the list it was.
        """
        var offset_min = -1
        var offset_sec = 0
        var version = 1

        if self.loc.table:
            var offset = self._offset()
            if offset % 60 != 0:
                version = 2
                offset_sec = _rem(offset, 60)
            offset = _quo(offset, 60)
            if offset < -32768 or offset == -1 or offset > 32767:
                raise (
                    Report("Time.marshal_binary: unexpected zone offset")
                    .with_code(ErrMarshalTime)
                    .with_field("offset", String(self._offset()))
                    .error()
                )
            offset_min = offset

        var start = len(dst)
        dst.append(UInt8(version))
        for shift in reversed(range(0, 64, 8)):
            dst.append(UInt8((UInt64(self.sec) >> UInt64(shift)) & 0xFF))
        for shift in reversed(range(0, 32, 8)):
            dst.append(UInt8((UInt64(self.nsec) >> UInt64(shift)) & 0xFF))
        dst.append(UInt8((UInt64(offset_min) >> 8) & 0xFF))
        dst.append(UInt8(UInt64(offset_min) & 0xFF))
        if version == 2:
            dst.append(UInt8(UInt64(offset_sec) & 0xFF))
        return len(dst) - start

    def marshal_binary(self) raises -> List[UInt8]:
        """This instant in Go's binary form. Go's `MarshalBinary`."""
        var out = List[UInt8](capacity=16)
        _ = self.append_binary(out)
        return out^

    def unmarshal_binary[o: ImmOrigin](mut self, data: Span[UInt8, o]) raises:
        """Set this from Go's binary form. Go's `UnmarshalBinary`.

        The zone comes back as one of three things, which is Go's rule and is
        why a round trip keeps a zone name only by luck. The UTC marker gives
        UTC. An offset that is what the host's own zone was using at that
        instant gives the host's zone, name and all. Anything else gives a
        nameless fixed zone at that offset, which reads every field correctly
        and cannot say what the place was called, because the name was never
        written down.

        Nothing is written to `self` unless the whole input is accepted.
        """
        if len(data) == 0:
            raise (
                Report("Time.unmarshal_binary: no data")
                .with_code(ErrUnmarshalTime)
                .error()
            )

        var version = Int(data[0])
        if version != 1 and version != 2:
            raise (
                Report("Time.unmarshal_binary: unsupported version")
                .with_code(ErrUnmarshalTime)
                .with_field("version", String(version))
                .error()
            )

        var want = 15 if version == 1 else 16
        if len(data) != want:
            raise (
                Report("Time.unmarshal_binary: invalid length")
                .with_code(ErrUnmarshalTime)
                .with_field("length", String(len(data)))
                .error()
            )

        # Every number in these bytes is two's complement, most significant
        # byte first, and the sign is put back by hand rather than by a cast,
        # because widening an unsigned value is a conversion and keeps the
        # magnitude: 0xffff read as sixteen bits and widened is 65535, and what
        # is wanted is -1.
        var sec = _signed(data[1])
        for i in range(2, 9):
            sec = (sec << 8) | Int(data[i])

        var nsec = 0
        for i in range(9, 13):
            nsec = (nsec << 8) | Int(data[i])

        var offset = ((_signed(data[13]) << 8) | Int(data[14])) * 60
        if version == 2:
            offset += _signed(data[15])

        var loc = Location()
        if offset != -60:
            var host = local()
            if host.lookup(sec + _INTERNAL_TO_UNIX)[1] == offset:
                loc = host^
            else:
                loc = fixed_zone("", offset)

        self = Self(internal_sec=sec, nsec=nsec, loc=loc^)

    def gob_encode(self) raises -> List[UInt8]:
        """This instant in the form Go's `encoding/gob` writes. Go's
        `GobEncode`.

        The same bytes as `marshal_binary`. Go keeps both names and says it
        would like to drop these two in a Go 2, and until then a program that
        looks for them by name finds them.
        """
        return self.marshal_binary()

    def gob_decode[o: ImmOrigin](mut self, data: Span[UInt8, o]) raises:
        """Set this from the form Go's `encoding/gob` writes. Go's `GobDecode`.

        The same function as `unmarshal_binary`, under the other name.
        """
        self.unmarshal_binary(data)

    def _append_rfc3339(self, mut dst: List[UInt8]) raises -> Int:
        """This instant as RFC 3339 with nanoseconds, and how many bytes.

        Go's `appendStrictRFC3339`, and the two checks are the whole of why the
        text methods can fail at all. Not every `Time` has an RFC 3339
        spelling: the year has to be four digits, so anything outside 0 to 9999
        is refused rather than written as something no reader will take back,
        and the zone offset hour has to be under 24, which a fixed zone built
        with a whole day in it is not.

        The layout does the work. Go keeps a hand written writer beside the
        layout language because RFC 3339 is over half of all the formats
        anybody names, and the output is the same either way.
        """
        var out = List[UInt8](capacity=40)
        _ = self.append_format(out, RFC3339_NANO)

        if out[4] != UInt8(ord("-")):
            raise (
                Report("year outside of range [0,9999]")
                .with_code(ErrMarshalTime)
                .with_field("year", String(self.date()[0]))
                .error()
            )

        if out[len(out) - 1] != UInt8(ord("Z")):
            # The sign is six back from the end in `-07:00`. A digit there
            # means the hour took three columns, which is an offset of at least
            # a hundred hours and cannot be written at all.
            var sign = out[len(out) - 6]
            var hour = Int(out[len(out) - 5] - UInt8(ord("0"))) * 10 + Int(
                out[len(out) - 4] - UInt8(ord("0"))
            )
            if (
                UInt8(ord("0")) <= sign and sign <= UInt8(ord("9"))
            ) or hour >= 24:
                raise (
                    Report("timezone hour outside of range [0,23]")
                    .with_code(ErrMarshalTime)
                    .with_field("offset", String(self._offset()))
                    .error()
                )

        var start = len(dst)
        dst.extend(out^)
        return len(dst) - start

    def append_text(self, mut dst: List[UInt8]) raises -> Int:
        """This instant as RFC 3339 with nanoseconds, appended to `dst`, and
        how many bytes that took. Go's `AppendText`.

        ```mojo
        from core.time import MARCH, date

        var buf = List[UInt8]()
        _ = date(2024, MARCH, 9, 14, 5, 6, 0).append_text(buf)
        ```

        Nothing is appended when this raises. `_append_rfc3339` says which two
        instants have no RFC 3339 spelling and why.
        """
        try:
            return self._append_rfc3339(dst)
        except e:
            raise Report(String("Time.append_text: ", e)).with_code(
                ErrMarshalTime
            ).error()

    def marshal_text(self) raises -> List[UInt8]:
        """This instant as RFC 3339 with nanoseconds. Go's `MarshalText`."""
        var out = List[UInt8](capacity=40)
        try:
            _ = self._append_rfc3339(out)
        except e:
            raise Report(String("Time.marshal_text: ", e)).with_code(
                ErrMarshalTime
            ).error()
        return out^

    def unmarshal_text[o: ImmOrigin](mut self, data: Span[UInt8, o]) raises:
        """Set this from RFC 3339 text. Go's `UnmarshalText`.

        `parse(RFC3339, text)`, so a zone in the text that matches what the
        host is using gives the host's zone and anything else gives a fixed
        one. Go keeps a hand written reader in front of this, and as of Go 1.27
        every strict check in it is disabled, so the two accept the same
        strings and differ only in speed.

        Nothing is written to `self` unless the text is accepted. Go assigns
        the zero time before it looks at the error, so a value it refused is a
        value it cleared. `docs/deviations.md` has the row.

        Bytes that are not UTF-8 were never a timestamp, and the conversion on
        the way in replaces them, so the failure names the replacement
        character where Go's names the original byte.
        """
        self = parse(RFC3339, String(from_utf8_lossy=data))

    def marshal_json(self) raises -> List[UInt8]:
        """This instant as a quoted RFC 3339 string. Go's `MarshalJSON`.

        The same bytes as `marshal_text` with a quote at each end, which is
        what a JSON string is, and no escaping is needed because RFC 3339 has
        nothing in it that JSON would escape.
        """
        var out = List[UInt8](capacity=42)
        out.append(UInt8(ord('"')))
        try:
            _ = self._append_rfc3339(out)
        except e:
            raise Report(String("Time.marshal_json: ", e)).with_code(
                ErrMarshalTime
            ).error()
        out.append(UInt8(ord('"')))
        return out^

    def unmarshal_json[o: ImmOrigin](mut self, data: Span[UInt8, o]) raises:
        """Set this from a quoted RFC 3339 string. Go's `UnmarshalJSON`.

        A JSON null leaves the value alone, which is what the rest of Go's JSON
        decoding does with one and is not the same as setting it to the zero
        time.

        The quotes are removed and nothing is unescaped, which is Go's
        behaviour and Go's open issue: a JSON string is allowed to spell a
        character as an escape and no RFC 3339 timestamp needs to, so the two
        only disagree on input nobody writes.
        """
        if _bytes_equal(data, "null"):
            return

        if (
            len(data) < 2
            or data[0] != UInt8(ord('"'))
            or data[len(data) - 1] != UInt8(ord('"'))
        ):
            raise (
                Report("Time.unmarshal_json: input is not a JSON string")
                .with_code(ErrUnmarshalTime)
                .error()
            )

        self.unmarshal_text(data[1 : len(data) - 1])


def _signed(b: UInt8) -> Int:
    """`b` read as a signed byte, so 0xff is -1.

    The top byte of every two's complement number in the binary form goes
    through here and the rest are shifted in underneath it, which is what makes
    the whole number signed.
    """
    return Int(b) - 256 if b >= 0x80 else Int(b)


def _bytes_equal[o: ImmOrigin](b: Span[UInt8, o], want: StringSlice) -> Bool:
    """Whether `b` is exactly `want`."""
    var w = want.as_bytes()
    if len(b) != len(w):
        return False
    for i in range(len(b)):
        if b[i] != w[i]:
            return False
    return True


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
    loc: Location = Location(),
) -> Time:
    """The instant those parts name on `loc`'s wall clock. Go's `Date`.

    ```mojo
    from core.time import FEBRUARY, date

    print(date(2023, FEBRUARY, 30, 0, 0, 0, 0).date())  # => (2023, March, 2)
    ```

    Every argument is normalised rather than rejected, which is what the
    example shows and what makes this the way to do calendar arithmetic. Month
    thirteen is January of the next year, hour 24 is midnight the next day, and
    day zero is the last day of the previous month, which is the trick for
    finding it. Go behaves identically.

    Go takes a `*Location` and panics on nil. The location here is optional and
    defaults to UTC, because the empty `Location` already means UTC and there
    is nothing to panic about, so a caller who does not care about zones writes
    the same seven arguments as before.

    A wall clock reading in a location does not always name exactly one
    instant. An hour that daylight saving skipped names none, and an hour it
    repeated names two, and this returns one instant in both cases without
    saying which, exactly as Go does. The instant is found by asking the
    location what the offset was at the reading taken as UTC and correcting once
    if that lands outside the zone the answer came from, which is the two step
    Go's own `Date` does and the reason it is not a single subtraction.
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
    var internal = Int(abs_sec - UInt64(_INTERNAL_TO_ABSOLUTE))

    # The reading taken as if it were UTC, which is what the location is asked
    # about. Go's comment says it hopes the answer is not too close to a
    # transition and corrects when it is, and the correction below is that.
    var wall_unix = internal + _INTERNAL_TO_UNIX
    var got = loc.lookup(wall_unix)
    var offset = got[1]
    if offset != 0:
        var as_utc = wall_unix - offset
        if as_utc < got[2]:
            offset = loc.lookup(got[2] - 1)[1]
        elif as_utc >= got[3]:
            offset = loc.lookup(got[3])[1]
        wall_unix -= offset

    return Time(
        internal_sec=wall_unix + _UNIX_TO_INTERNAL,
        nsec=normal_sec[1],
        loc=loc,
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
