"""A `Time` in a location, which is the join between the instant and the clock.

Every number here came from running Go against the same four vendored zone
files, so a row that passes is a row Go agrees with. The differ area
`time-zones` does the same comparison over two hundred thousand random instants
and is the stronger check; what is here is the handful of cases that are worth
naming, so that a failure says which property broke rather than printing a
diff.

The four locations are read from the embedded copies of Go's slim test files
rather than from the host, because a test that loads `/usr/share/zoneinfo` gives
a different answer on a machine with a different tzdata release, and on a
machine with no zone files at all it gives none.
"""

from std.testing import assert_equal, assert_true

from tests.generated.tzif import (
    BERLIN_2020B,
    DUBLIN_2021A,
    NUUK_2021A,
    bytes_of,
)

from core.time import (
    HOUR,
    MARCH,
    OCTOBER,
    Location,
    date,
    fixed_zone,
    load_location_from_tz_data,
    unix,
)


def test_a_location_changes_the_reading_and_not_the_instant() raises:
    """Go's `In`, which is the whole point of the type.

    The same instant read two ways. Nothing about which moment it is changes,
    which is why `unix` is the same on both sides and only the fields move.
    """
    var berlin = _berlin()
    var t = unix(1603981800, 0)
    var local = t.in_location(berlin)

    assert_equal(local.unix(), 1603981800)
    assert_equal(t.unix(), 1603981800)
    assert_true(local == t)

    var year, month, day = local.date()
    assert_equal(year, 2020)
    assert_equal(month, OCTOBER)
    assert_equal(day, 29)

    var hour, minute, sec = local.clock()
    assert_equal(hour, 15)
    assert_equal(minute, 30)
    assert_equal(sec, 0)

    # An hour earlier in UTC, which is the offset the file declares for that
    # week of the year.
    assert_equal(t.clock()[0], 14)


def test_utc_takes_the_location_back_off() raises:
    """Go's `UTC`, which is `In(UTC)` and nothing else."""
    var t = unix(1603981800, 0).in_location(_berlin()).utc()
    assert_equal(String(t), "2020-10-29 14:30:00 +0000 UTC")
    assert_equal(t.zone()[0], "UTC")
    assert_equal(t.zone()[1], 0)
    assert_true(not t.location().table)


def test_zone_names_what_was_in_force() raises:
    """Go's `Zone`, at instants either side of a change.

    Both rows are Berlin, so the pair is the one thing a fixed offset cannot
    do: the same location answering differently in July and in October.
    """
    var berlin = _berlin()

    var summer = unix(1593604800, 0).in_location(berlin)
    assert_equal(summer.zone()[0], "CEST")
    assert_equal(summer.zone()[1], 7200)

    var winter = unix(1603981800, 0).in_location(berlin)
    assert_equal(winter.zone()[0], "CET")
    assert_equal(winter.zone()[1], 3600)


def test_zone_bounds_are_the_window_the_answer_holds_for() raises:
    """Go's `ZoneBounds`, including the two ends where there is no bound.

    The start is the instant that zone came in and the end is the instant the
    next one does, so the reading is good for exactly the half open range
    between them.
    """
    var berlin = _berlin()
    var start, end = unix(1603981800, 0).in_location(berlin).zone_bounds()
    assert_equal(start.unix(), 1603587600)
    assert_equal(end.unix(), 1609372800)

    # The first zone of a file has nothing before it, and Go leaves the zero
    # `Time` there rather than naming an instant.
    var nuuk_start, nuuk_end = (
        unix(-2674255436, 0).in_location(_nuuk()).zone_bounds()
    )
    assert_true(nuuk_start.is_zero())
    assert_equal(nuuk_end.unix(), -1686083584)

    # A fixed zone never changes, so neither end is bounded.
    var fixed_start, fixed_end = (
        unix(1603981800, 0).in_location(fixed_zone("CET", 3600)).zone_bounds()
    )
    assert_true(fixed_start.is_zero())
    assert_true(fixed_end.is_zero())


def test_an_hour_that_never_happened_lands_after_the_gap() raises:
    """The wall clock reading daylight saving skipped.

    Berlin went from 02:00 to 03:00 on 2020-03-29, so 02:30 that morning names
    no instant at all. Go returns the instant one hour later rather than
    raising, and the reading that comes back is 03:30 and not the 02:30 that
    was asked for. This is the row the two step correction in `date` exists
    for: the first lookup answers with the zone that was in force before the
    change and the correction moves to the one after it.
    """
    var t = date(2020, MARCH, 29, 2, 30, 0, 0, _berlin())
    assert_equal(t.unix(), 1585445400)
    assert_equal(String(t), "2020-03-29 03:30:00 +0200 CEST")


def test_an_hour_that_happened_twice_takes_the_second() raises:
    """The wall clock reading daylight saving repeated.

    Berlin went from 03:00 back to 02:00 on 2020-10-25, so 02:30 that morning
    names two instants an hour apart. Go's `Date` says which one it picks is
    not guaranteed, and what it does pick is the later of the two. That is
    pinned here rather than left open, because the two libraries have to agree
    on it for the differ area to run clean.
    """
    var t = date(2020, OCTOBER, 25, 2, 30, 0, 0, _berlin())
    assert_equal(t.unix(), 1603589400)
    assert_equal(String(t), "2020-10-25 02:30:00 +0100 CET")


def test_printing_writes_the_offset_and_the_zone() raises:
    """Go's `String`, which ends in the offset and the abbreviation.

    The last two rows are the reason `_write_offset` divides the way it does.
    An offset that is not a whole number of minutes drops the seconds towards
    zero, so Nuuk's old local mean time at -12416 seconds prints as -0326 and
    not -0327, and Dublin's at -1521 prints as -0025 and not -0026.
    """
    assert_equal(
        String(unix(1603981800, 0).in_location(_berlin())),
        "2020-10-29 15:30:00 +0100 CET",
    )
    assert_equal(
        String(unix(1609502400, 0).in_location(_dublin())),
        "2021-01-01 12:00:00 +0000 GMT",
    )
    assert_equal(
        String(unix(-2674255436, 0).in_location(_nuuk())),
        "1885-04-03 19:49:08 -0326 LMT",
    )
    assert_equal(
        String(unix(-2496333658, 0).in_location(_dublin())),
        "1890-11-23 05:33:41 -0025 DMT",
    )


def test_the_location_survives_arithmetic() raises:
    """Adding to a `Time` moves the instant and keeps the clock it is read on.

    Go's `Add` and `AddDate` both return a `Time` in the same location, and
    `AddDate` is the one that would be wrong in a way nobody notices: it works
    in wall clock fields, so a location that got lost would silently do the
    arithmetic in UTC and land an hour out.
    """
    var t = unix(1603981800, 0).in_location(_berlin())

    var later = t + HOUR
    assert_equal(later.unix(), 1603985400)
    assert_equal(String(later), "2020-10-29 16:30:00 +0100 CET")

    var next_month = t.add_date(0, 1, 0)
    assert_equal(next_month.unix(), 1606660200)
    assert_equal(String(next_month), "2020-11-29 15:30:00 +0100 CET")


def test_a_copied_time_shares_one_zone_table() raises:
    """The property that lets a `Time` hold a location at all.

    A `Time` is copied constantly, and a copy that duplicated the zone table
    would turn every one of those into two allocations. What happens instead is
    an atomic increment, and this checks it by address.
    """
    var berlin = _berlin()
    var t = unix(1603981800, 0).in_location(berlin)
    var copy = t
    var moved = t + HOUR

    assert_true(_same_table(t.location(), berlin))
    assert_true(_same_table(copy.location(), berlin))
    assert_true(_same_table(moved.location(), berlin))


def test_a_time_nobody_gave_a_location_reads_utc() raises:
    """The default, which is what every `Time` in the rest of the suite is.

    Go's zero `Time` has a nil location and reads UTC, and an empty `Location`
    here does the same thing without a pointer that can be null.
    """
    var t = unix(1603981800, 0)
    assert_true(not t.location().table)
    assert_equal(t.zone()[0], "UTC")
    assert_equal(t.zone()[1], 0)
    assert_equal(String(t), "2020-10-29 14:30:00 +0000 UTC")

    var start, end = t.zone_bounds()
    assert_true(start.is_zero())
    assert_true(end.is_zero())


def _berlin() raises -> Location:
    """Europe/Berlin, from Go's 2020b slim file."""
    var data = bytes_of(BERLIN_2020B)
    return load_location_from_tz_data("Europe/Berlin", Span(data))


def _nuuk() raises -> Location:
    """America/Nuuk, from Go's 2021a slim file."""
    var data = bytes_of(NUUK_2021A)
    return load_location_from_tz_data("America/Nuuk", Span(data))


def _dublin() raises -> Location:
    """Europe/Dublin, from Go's 2021a slim file."""
    var data = bytes_of(DUBLIN_2021A)
    return load_location_from_tz_data("Europe/Dublin", Span(data))


def _same_table(a: Location, b: Location) -> Bool:
    """Whether these two locations point at one table."""
    if not a.table or not b.table:
        return False
    return Int(Pointer(to=a.table.value()[])) == Int(
        Pointer(to=b.table.value()[])
    )
