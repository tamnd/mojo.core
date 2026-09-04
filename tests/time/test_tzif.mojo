"""The TZif reader, against Go's four slim files and its own malformed input.

The four files are the ones Go's own `TestLoadLocationFromTZDataSlim` reads, and
the rows are Go's rows: a wall clock reading in the loaded location, and the
zone name and offset the resulting instant is in. They are vendored under
`tests/data/go-time`, pinned by digest, and embedded by a generator, because
nothing in this suite opens a file at run time.

The instant each row works out to is written next to it as well, because a name
and an offset alone would still match if the wall clock conversion were out by
an hour in one direction and the zone table were out by an hour in the other.
Those numbers came from running Go against these same files.
"""

from std.testing import assert_equal, assert_raises, assert_true

from tests.generated.tzif import (
    BERLIN_2020B,
    DUBLIN_2021A,
    GAZA_2021A,
    NUUK_2021A,
    bytes_of,
)

from core.time import APRIL, OCTOBER, Month, date
from core.time.tzif import _abbrev_at, load_location_from_tz_data


def test_slim_files_load_and_answer_what_go_says() raises:
    """Go's `TestLoadLocationFromTZDataSlim`, written the way Go writes it.

    The first three rows are the same wall clock reading in three locations, so
    the three instants differ from each other only by the offsets the files
    themselves declare. That is what makes them worth having together: a reader
    that lost a sign or an hour would put two of them on the same instant.
    """
    var berlin = bytes_of(BERLIN_2020B)
    var nuuk = bytes_of(NUUK_2021A)
    var gaza = bytes_of(GAZA_2021A)
    var dublin = bytes_of(DUBLIN_2021A)
    _check_zone_at(
        "Europe/Berlin",
        Span(berlin),
        2020,
        OCTOBER,
        29,
        15,
        30,
        0,
        1603981800,
        "CET",
        3600,
    )
    _check_zone_at(
        "America/Nuuk",
        Span(nuuk),
        2020,
        OCTOBER,
        29,
        15,
        30,
        0,
        1603996200,
        "-03",
        -10800,
    )
    _check_zone_at(
        "Asia/Gaza",
        Span(gaza),
        2020,
        OCTOBER,
        29,
        15,
        30,
        0,
        1603978200,
        "EET",
        7200,
    )
    _check_zone_at(
        "Europe/Dublin",
        Span(dublin),
        2021,
        APRIL,
        2,
        11,
        12,
        13,
        1617358333,
        "IST",
        3600,
    )


def test_dublins_daylight_flag_runs_backwards() raises:
    """Ireland marks its winter as the saving clock, not its summer.

    The one location in tzdata built this way, and the reason the reader takes
    the flag out of the file rather than working it out from which offset is
    larger. In July Dublin is on IST at one hour east and the file says that is
    standard; in January it is on GMT at zero and the file says that is the
    saving clock. A reader that inferred the flag would have both backwards.
    """
    var data = bytes_of(DUBLIN_2021A)
    var loc = load_location_from_tz_data("Europe/Dublin", Span(data))

    # 2021-07-01 12:00:00 UTC.
    var summer_name, summer_off, _ss, _se, summer_dst = loc.lookup(1625140800)
    assert_equal(summer_name, "IST")
    assert_equal(summer_off, 3600)
    assert_true(not summer_dst)

    # 2021-01-01 12:00:00 UTC.
    var winter_name, winter_off, _ws, _we, winter_dst = loc.lookup(1609502400)
    assert_equal(winter_name, "GMT")
    assert_equal(winter_off, 0)
    assert_true(winter_dst)


def test_a_slim_file_answers_past_its_last_transition() raises:
    """The join between the table and the rule, which is what slim files are.

    Berlin's explicit transitions stop in 1996. An instant in 2035 is past
    every one of them and can only be answered by the TZ string on the last
    line, so a reader that dropped the string returns the last transition's
    zone all year and gets this row wrong in summer.
    """
    var data = bytes_of(BERLIN_2020B)
    var loc = load_location_from_tz_data("Europe/Berlin", Span(data))

    # 2035-06-29 12:00:00 UTC, which is inside central European summer time.
    var name, off, _s, _e, is_dst = loc.lookup(2066731200)
    assert_equal(name, "CEST")
    assert_equal(off, 7200)
    assert_true(is_dst)

    # 2034-12-29 12:00:00 UTC, which is not.
    var wname, woff, _ws, _we, wis_dst = loc.lookup(2051006400)
    assert_equal(wname, "CET")
    assert_equal(woff, 3600)
    assert_true(not wis_dst)


def test_the_name_comes_from_the_caller_not_the_file() raises:
    """A zone file does not record what it is called.

    The name of `/usr/share/zoneinfo/Europe/Berlin` is the path it was found
    at, so whatever is passed in is what comes back, including a name that has
    nothing to do with the contents.
    """
    var data = bytes_of(BERLIN_2020B)
    var loc = load_location_from_tz_data("somewhere else", Span(data))
    assert_equal(String(loc), "somewhere else")


def test_data_that_is_not_a_zone_file_is_refused() raises:
    """Every way in should raise rather than read past the end.

    Go's issue 29437 was a file whose header claimed zero zones, which used to
    load and then crash the first time anybody asked it a question. The empty
    and truncated rows are the same concern reached earlier.
    """
    var empty = List[UInt8]()
    with assert_raises(contains="malformed time zone information"):
        _ = load_location_from_tz_data("empty", Span(empty))

    var not_tzif: List[UInt8] = [
        UInt8(ord("J")),
        UInt8(ord("P")),
        UInt8(ord("E")),
        UInt8(ord("G")),
    ]
    with assert_raises(contains="malformed time zone information"):
        _ = load_location_from_tz_data("jpeg", Span(not_tzif))

    # The magic and nothing else, so the sixteen byte header runs off the end.
    var magic_only: List[UInt8] = [
        UInt8(ord("T")),
        UInt8(ord("Z")),
        UInt8(ord("i")),
        UInt8(ord("f")),
    ]
    with assert_raises(contains="malformed time zone information"):
        _ = load_location_from_tz_data("stub", Span(magic_only))

    # A real file cut in half, so the counts in its header describe more data
    # than is there. Cutting only the last byte would not do: that byte is the
    # newline closing the TZ string, and losing it drops the extend string and
    # loads the rest, which is what Go does too.
    var whole = bytes_of(BERLIN_2020B)
    var truncated = List[UInt8]()
    for i in range(len(whole) // 2):
        truncated.append(whole[i])
    with assert_raises(contains="malformed time zone information"):
        _ = load_location_from_tz_data("short", Span(truncated))


def test_a_version_byte_nobody_knows_is_refused() raises:
    """Version 4 exists and is not read here, so it is refused rather than
    guessed at.

    Reading a version 4 file as if it were version 3 would work for most files
    and go quietly wrong on the ones that use what version 4 added, which is
    the worst of the available outcomes.
    """
    var whole = bytes_of(BERLIN_2020B)
    var bumped = List[UInt8]()
    for i in range(len(whole)):
        bumped.append(whole[i])
    bumped[4] = UInt8(ord("4"))
    with assert_raises(contains="malformed time zone information"):
        _ = load_location_from_tz_data("v4", Span(bumped))


def test_abbreviations_are_read_to_the_first_nul() raises:
    """Go's `byteString`, including the overlap it allows.

    The abbreviation text is one run of bytes with a NUL after each name, and a
    zone points at a byte inside the run rather than at a whole entry, so a
    suffix of one name can be another name. Starting at index 1 of `EST` is
    `ST`, and that is not a trick: tzdata files really do share bytes this way.
    """
    var text: List[UInt8] = [
        UInt8(ord("E")),
        UInt8(ord("S")),
        UInt8(ord("T")),
        UInt8(0),
        UInt8(ord("U")),
        UInt8(ord("T")),
        UInt8(ord("C")),
        UInt8(0),
    ]
    assert_equal(_abbrev_at(Span(text), 0), "EST")
    assert_equal(_abbrev_at(Span(text), 1), "ST")
    assert_equal(_abbrev_at(Span(text), 4), "UTC")
    assert_equal(_abbrev_at(Span(text), 3), "")


def _check_zone_at[
    o: Origin
](
    name: StringSlice,
    data: Span[UInt8, o],
    year: Int,
    month: Month,
    day: Int,
    hour: Int,
    minute: Int,
    sec: Int,
    want_unix: Int,
    want_name: StringSlice,
    want_offset: Int,
) raises:
    """One row of Go's `slimTests`, through `date` in the loaded location."""
    var loc = load_location_from_tz_data(name, data)
    assert_equal(String(loc), name)
    var t = date(year, month, day, hour, minute, sec, 0, loc)
    assert_equal(t.unix(), want_unix)
    var got_name, got_offset = t.zone()
    assert_equal(got_name, want_name)
    assert_equal(got_offset, want_offset)
