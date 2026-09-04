"""Writing an instant out by a layout, against what Go writes for the same one.

Every expected string here came from running Go over the same four instants and
the same layouts, so a row that passes is a row Go agrees with character for
character. The four are chosen for what they make visible: one in UTC, one in a
named zone seven hours west, one in a zone with no name whose offset has
seconds in it, and one whose every field is a single digit.

The layouts that are not layouts at all are as much of the point as the ones
that are. `the 2nd` has a day of the month hiding in it and `Janet` does not
have a month hiding in it, and a formatter that got either backwards would pass
every row that only used the named layouts.
"""

from std.testing import assert_equal, assert_true

from core.time import (
    ANSIC,
    DATE_ONLY,
    DATE_TIME,
    JANUARY,
    KITCHEN,
    LAYOUT,
    MARCH,
    RFC822,
    RFC822Z,
    RFC850,
    RFC1123,
    RFC1123Z,
    RFC3339,
    RFC3339_NANO,
    RUBY_DATE,
    STAMP,
    STAMP_MICRO,
    STAMP_MILLI,
    STAMP_NANO,
    TIME_ONLY,
    UNIX_DATE,
    Time,
    date,
    fixed_zone,
)


def _utc() -> Time:
    """Saturday 9 March 2024, 14:05:06 and a bit, in UTC."""
    return date(2024, MARCH, 9, 14, 5, 6, 78901234)


def _mst() -> Time:
    """The same wall clock reading seven hours west, in a zone with a name."""
    return date(
        2024, MARCH, 9, 14, 5, 6, 78901234, fixed_zone("MST", -7 * 3600)
    )


def _odd() -> Time:
    """The same reading in a nameless zone 3208 seconds east of UTC.

    Berlin's local mean time before the railways, which is the shape of the
    first zone in most zone files: no name, and an offset that is not a whole
    number of minutes.
    """
    return date(2024, MARCH, 9, 14, 5, 6, 0, fixed_zone("", 3208))


def _small() -> Time:
    """Tuesday 2 January 2024 at 03:04:05, every field one digit wide."""
    return date(2024, JANUARY, 2, 3, 4, 5, 0)


def _check(t: Time, layout: String, want: String) raises:
    """One layout against one instant, saying which layout if it fails."""
    var got = t.format(layout)
    assert_true(
        got == want,
        String("format(", layout, ") gave ", got, ", want ", want),
    )


def _rows() -> List[Tuple[String, String]]:
    """An empty table, for the tests below to fill."""
    return List[Tuple[String, String]]()


def test_the_named_layouts() raises:
    """The nineteen constants, on an instant in a named zone.

    A named zone rather than UTC because six of the nineteen ask for the zone
    and UTC is the one reading where the numeric forms and the `Z` forms give
    the same answer, so it would hide half of what these say.
    """
    var t = _mst()
    var rows = _rows()
    rows.append((LAYOUT, "03/09 02:05:06PM '24 -0700"))
    rows.append((ANSIC, "Sat Mar  9 14:05:06 2024"))
    rows.append((UNIX_DATE, "Sat Mar  9 14:05:06 MST 2024"))
    rows.append((RUBY_DATE, "Sat Mar 09 14:05:06 -0700 2024"))
    rows.append((RFC822, "09 Mar 24 14:05 MST"))
    rows.append((RFC822Z, "09 Mar 24 14:05 -0700"))
    rows.append((RFC850, "Saturday, 09-Mar-24 14:05:06 MST"))
    rows.append((RFC1123, "Sat, 09 Mar 2024 14:05:06 MST"))
    rows.append((RFC1123Z, "Sat, 09 Mar 2024 14:05:06 -0700"))
    rows.append((RFC3339, "2024-03-09T14:05:06-07:00"))
    rows.append((RFC3339_NANO, "2024-03-09T14:05:06.078901234-07:00"))
    rows.append((KITCHEN, "2:05PM"))
    rows.append((STAMP, "Mar  9 14:05:06"))
    rows.append((STAMP_MILLI, "Mar  9 14:05:06.078"))
    rows.append((STAMP_MICRO, "Mar  9 14:05:06.078901"))
    rows.append((STAMP_NANO, "Mar  9 14:05:06.078901234"))
    rows.append((DATE_TIME, "2024-03-09 14:05:06"))
    rows.append((DATE_ONLY, "2024-03-09"))
    rows.append((TIME_ONLY, "14:05:06"))
    for row in rows:
        _check(t, row[0], row[1])


def test_the_named_layouts_in_utc() raises:
    """The four of the nineteen that read differently at an offset of zero.

    `Z` is not the name of a zone and not an abbreviation for one. It is what
    ISO 8601 writes where the digits of an offset would go when there are no
    digits to write, and only the layouts spelled with a `Z` use it.
    """
    var t = _utc()
    _check(t, RFC3339, "2024-03-09T14:05:06Z")
    _check(t, RFC3339_NANO, "2024-03-09T14:05:06.078901234Z")
    _check(t, RFC1123, "Sat, 09 Mar 2024 14:05:06 UTC")
    _check(t, RFC1123Z, "Sat, 09 Mar 2024 14:05:06 +0000")


def test_every_piece_of_the_reference_instant() raises:
    """Each field in each of its spellings, one row each.

    The day of the year is 69 rather than anything memorable, which is what
    makes `002` and `__2` worth having next to each other: one pads with a zero
    to three places and the other pads with a space.
    """
    var t = _utc()
    var rows = _rows()
    rows.append(("2006", "2024"))
    rows.append(("06", "24"))
    rows.append(("1", "3"))
    rows.append(("01", "03"))
    rows.append(("Jan", "Mar"))
    rows.append(("January", "March"))
    rows.append(("2", "9"))
    rows.append(("02", "09"))
    rows.append(("_2", " 9"))
    rows.append(("002", "069"))
    rows.append(("__2", " 69"))
    rows.append(("Mon", "Sat"))
    rows.append(("Monday", "Saturday"))
    rows.append(("15", "14"))
    rows.append(("3", "2"))
    rows.append(("03", "02"))
    rows.append(("4", "5"))
    rows.append(("04", "05"))
    rows.append(("5", "6"))
    rows.append(("05", "06"))
    rows.append(("PM", "PM"))
    rows.append(("pm", "pm"))
    rows.append(("MST", "UTC"))
    for row in rows:
        _check(t, row[0], row[1])


def test_the_single_digit_forms_when_the_field_is_one_digit() raises:
    """The same spellings against an instant where the padding shows.

    March 9 in the afternoon has a two digit month and a two digit hour of its
    own, so the difference between `1` and `01` and between `15` and `03` only
    appears on a date like this one.
    """
    var t = _small()
    var rows = _rows()
    rows.append(("1", "1"))
    rows.append(("01", "01"))
    rows.append(("2", "2"))
    rows.append(("02", "02"))
    rows.append(("_2", " 2"))
    rows.append(("002", "002"))
    rows.append(("__2", "  2"))
    rows.append(("15", "03"))
    rows.append(("3", "3"))
    rows.append(("03", "03"))
    rows.append(("4", "4"))
    rows.append(("04", "04"))
    rows.append(("5", "5"))
    rows.append(("05", "05"))
    rows.append(("Mon", "Tue"))
    rows.append(("Monday", "Tuesday"))
    rows.append(("Jan", "Jan"))
    rows.append(("January", "January"))
    rows.append(("PM", "AM"))
    rows.append(("pm", "am"))
    rows.append(
        ("Mon Jan _2 15:04:05 MST 2006", "Tue Jan  2 03:04:05 UTC 2024")
    )
    for row in rows:
        _check(t, row[0], row[1])


def test_the_zone_in_its_ten_spellings() raises:
    """Five with a sign and five with a `Z`, west of UTC.

    Away from zero the two families agree, which is the row of this test: the
    `Z` in the layout only means anything at an offset of zero and is a numeric
    offset everywhere else.
    """
    var t = _mst()
    var rows = _rows()
    rows.append(("-0700", "-0700"))
    rows.append(("-07:00", "-07:00"))
    rows.append(("-07", "-07"))
    rows.append(("-070000", "-070000"))
    rows.append(("-07:00:00", "-07:00:00"))
    rows.append(("Z0700", "-0700"))
    rows.append(("Z07:00", "-07:00"))
    rows.append(("Z07", "-07"))
    rows.append(("Z070000", "-070000"))
    rows.append(("Z07:00:00", "-07:00:00"))
    for row in rows:
        _check(t, row[0], row[1])


def test_the_zone_at_an_offset_of_zero() raises:
    """The five `Z` spellings collapse and the five signed ones do not."""
    var t = _utc()
    var rows = _rows()
    rows.append(("-0700", "+0000"))
    rows.append(("-07:00", "+00:00"))
    rows.append(("-07", "+00"))
    rows.append(("-070000", "+000000"))
    rows.append(("-07:00:00", "+00:00:00"))
    rows.append(("Z0700", "Z"))
    rows.append(("Z07:00", "Z"))
    rows.append(("Z07", "Z"))
    rows.append(("Z070000", "Z"))
    rows.append(("Z07:00:00", "Z"))
    for row in rows:
        _check(t, row[0], row[1])


def test_an_offset_that_is_not_a_whole_number_of_minutes() raises:
    """3208 seconds east, which is 53 minutes and 28 seconds.

    The seconds are dropped by every spelling that has nowhere to put them, so
    `-0700` gives `+0053` and the whole 28 seconds are gone. Only the two long
    forms say them, and `-07` says neither them nor the minutes.
    """
    var t = _odd()
    var rows = _rows()
    rows.append(("-0700", "+0053"))
    rows.append(("-07:00", "+00:53"))
    rows.append(("-07", "+00"))
    rows.append(("-070000", "+005328"))
    rows.append(("-07:00:00", "+00:53:28"))
    rows.append(("Z0700", "+0053"))
    rows.append(("Z07:00", "+00:53"))
    for row in rows:
        _check(t, row[0], row[1])


def test_a_zone_with_no_name_prints_its_offset_instead() raises:
    """`MST` asks for an abbreviation the zone does not have.

    Something has to be written where the layout asked for something, so the
    offset is written in the `-0700` form. It is why the default notation of an
    instant in a zone like this says `+0053 +0053`, once for the offset the
    layout asks for and once for the name it does not have.
    """
    var t = _odd()
    _check(t, "MST", "+0053")
    assert_equal(String(t), "2024-03-09 14:05:06 +0053 +0053")


def test_the_fraction_of_a_second() raises:
    """Zeros keep the width and nines take as much as there is.

    The empty answer for `.9` is the one to look at. The nanoseconds are
    078901234, the first digit of them is a zero, and the nines form drops
    trailing zeros, so one digit of it is nothing at all, separator included.
    """
    var t = _utc()
    var rows = _rows()
    rows.append((".0", ".0"))
    rows.append((".00", ".07"))
    rows.append((".000", ".078"))
    rows.append((".9", ""))
    rows.append((".99", ".07"))
    rows.append((".999", ".078"))
    rows.append((".999999999", ".078901234"))
    rows.append((".000000000", ".078901234"))
    rows.append((",000", ",078"))
    rows.append((",999", ",078"))
    rows.append(("15:04:05.9999", "14:05:06.0789"))
    for row in rows:
        _check(t, row[0], row[1])


def test_the_fraction_of_a_second_that_is_zero() raises:
    """The nines form writes nothing at all and the zeros form writes zeros."""
    var t = _odd()
    var rows = _rows()
    rows.append((".0", ".0"))
    rows.append((".000", ".000"))
    rows.append((".000000000", ".000000000"))
    rows.append((".9", ""))
    rows.append((".999", ""))
    rows.append((",999", ""))
    rows.append(("15:04:05.9999", "14:05:06"))
    for row in rows:
        _check(t, row[0], row[1])


def test_text_that_is_not_a_piece_is_copied_through() raises:
    """The traps, both ways round.

    `Janet` starts with `Jan` and is not a month, because a lower case letter
    after it means the layout was in the middle of a word. `the 2nd` does not
    look like it has a field in it and does, because a bare `2` is the day of
    the month wherever it appears.
    """
    var t = _utc()
    var rows = _rows()
    rows.append(("", ""))
    rows.append(("hello, world", "hello, world"))
    rows.append(("Janet", "Janet"))
    rows.append(("Monkey", "Monkey"))
    rows.append(("January 2, 2006", "March 9, 2024"))
    rows.append(("the 2nd", "the 9nd"))
    for row in rows:
        _check(t, row[0], row[1])


def test_an_underscore_before_a_year_is_an_underscore() raises:
    """`_2` is a padded day and `_2006` is not a padded anything.

    The underscore is only a request for a leading space when what follows it
    is the day, so `_2006` is a literal underscore and then the year. The
    second row is the same two characters meaning the other thing.
    """
    var t = _utc()
    _check(t, "_2006", "_2024")
    _check(t, "2006_2", "2024 9")


def test_a_run_of_digits_that_keeps_going_is_not_a_fraction() raises:
    """`.001` has three digits after the dot and is not three digits of a
    fraction.

    A fraction is a run of zeros or a run of nines and nothing else, so the run
    here ends at the `1` and the whole thing is not a fraction at all. What is
    left is a literal `.0` and then `01`, which is the month. Go answers the
    same way and for the same reason.
    """
    _check(_utc(), ".001", ".003")
    _check(_small(), ".001", ".001")


def test_the_default_notation_is_the_layout_it_says_it_is() raises:
    """`write_to` and the layout it is documented as using agree.

    They are the same code now, which is the point of the row: the notation an
    instant prints in was written by hand before the layout language existed
    and is written by the layout language since.
    """
    var stamp = "2006-01-02 15:04:05.999999999 -0700 MST"
    assert_equal(String(_utc()), _utc().format(stamp))
    assert_equal(String(_mst()), _mst().format(stamp))
    assert_equal(String(_small()), _small().format(stamp))
    assert_equal(String(_utc()), "2024-03-09 14:05:06.078901234 +0000 UTC")
    assert_equal(String(_mst()), "2024-03-09 14:05:06.078901234 -0700 MST")
    assert_equal(String(_small()), "2024-01-02 03:04:05 +0000 UTC")


def test_append_format_adds_to_what_is_there() raises:
    """The count comes back and the list keeps what it already had."""
    var out = List[UInt8]()
    out.extend("at ".as_bytes())
    var n = _utc().append_format(out, TIME_ONLY)

    assert_equal(n, 8)
    assert_equal(String(from_utf8_lossy=Span(out)), "at 14:05:06")

    var more = _utc().append_format(out, " on 2006-01-02")
    assert_equal(more, 14)
    assert_equal(String(from_utf8_lossy=Span(out)), "at 14:05:06 on 2024-03-09")


def test_a_layout_with_nothing_in_it_appends_nothing() raises:
    """The empty layout is not a failure and writes no bytes."""
    var out = List[UInt8]()
    assert_equal(_utc().append_format(out, ""), 0)
    assert_equal(len(out), 0)
