"""Reading an instant back out of a layout, against what Go reads for the same
pair of strings.

Every expected number and message here came from running Go over the same layout
and the same value, so a row that passes is a row Go agrees with.

Almost everything goes through `parse_in_location` with UTC rather than through
`parse`. Not because the two differ in what they read, but because `parse`
compares a zone in the value against the host's own zone, so what it answers for
`+0000` depends on where the machine running the test thinks it is. Naming the
location makes the row mean the same thing on all three platforms in the matrix.
The rows that use `parse` are the ones with no zone in them at all, or with a
`Z`, which never consult a location.

An instant is checked by its Unix second and its nanosecond rather than by
printing it, because those two are what the value said and printing it would be
a test of `format` wearing a different hat.
"""

from std.testing import assert_equal, assert_raises, assert_true

from tests.generated.tzif import BERLIN_2020B, bytes_of

from core.errors import matches
from core.errors.codes import ErrParseDuration, ErrParseTime
from core.time import (
    ANSIC,
    DATE_ONLY,
    DATE_TIME,
    HOUR,
    KITCHEN,
    LAYOUT,
    MARCH,
    MINUTE,
    NANOSECOND,
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
    Duration,
    Location,
    ParseError,
    Time,
    date,
    load_location_from_tz_data,
    parse,
    parse_duration,
    parse_in_location,
    utc,
)


def _berlin() raises -> Location:
    """Europe/Berlin, out of the vendored 2020b file the other tests use."""
    var data = bytes_of(BERLIN_2020B)
    return load_location_from_tz_data("Europe/Berlin", Span(data))


def _read(layout: String, value: String) raises -> Time:
    """`value` read by `layout` against UTC, which is the deterministic one."""
    return parse_in_location(layout, value, utc())


def _rows() -> List[Tuple[String, String]]:
    """An empty table of a layout and a value, for the tests below to fill."""
    return List[Tuple[String, String]]()


def _check(layout: String, value: String, want_unix: Int) raises:
    """One layout and one value against the second Go reads out of them."""
    var got = _read(layout, value)
    assert_true(
        got.unix() == want_unix,
        String(
            "parse(",
            layout,
            ", ",
            value,
            ") gave unix ",
            got.unix(),
            ", want ",
            want_unix,
        ),
    )


def _refuse(layout: String, value: String, want: String) raises:
    """One layout and one value that Go refuses, and the reason it gives."""
    with assert_raises(contains=want):
        _ = _read(layout, value)


comptime _REF = 1_709_993_106
"""Saturday 9 March 2024 at 14:05:06 UTC, which almost every row below is."""

comptime _YEAR_ZERO = -62_167_219_200
"""Midnight on 1 January of the year 0, which is what an empty layout reads as.

Before the zero `Time` rather than equal to it, because the zero `Time` is the
year 1. Go says so in the documentation for `Parse` and means it.
"""


def test_the_named_layouts_read_back_what_they_wrote() raises:
    """Each of the nineteen constants, over the instant `format` wrote with it.

    The four `STAMP` layouts and `KITCHEN` and `TIME_ONLY` do not write a year,
    so they read back into the year 0 rather than into 2024, which is the point
    of listing the expected second for every one rather than comparing against
    the instant that went in.
    """
    var t = date(2024, MARCH, 9, 14, 5, 6, 78901234)
    var rows = List[Tuple[String, Int]]()
    rows.append((LAYOUT, _REF))
    rows.append((ANSIC, _REF))
    rows.append((UNIX_DATE, _REF))
    rows.append((RUBY_DATE, _REF))
    rows.append((RFC822, _REF - 6))
    rows.append((RFC822Z, _REF - 6))
    rows.append((RFC850, _REF))
    rows.append((RFC1123, _REF))
    rows.append((RFC1123Z, _REF))
    rows.append((RFC3339, _REF))
    rows.append((RFC3339_NANO, _REF))
    rows.append((KITCHEN, -62_167_168_500))
    rows.append((STAMP, -62_161_293_294))
    rows.append((STAMP_MILLI, -62_161_293_294))
    rows.append((STAMP_MICRO, -62_161_293_294))
    rows.append((STAMP_NANO, -62_161_293_294))
    rows.append((DATE_TIME, _REF))
    rows.append((DATE_ONLY, 1_709_942_400))
    rows.append((TIME_ONLY, -62_167_168_494))
    for row in rows:
        _check(row[0], t.format(row[0]), row[1])


def test_the_fraction_survives_the_round_trip() raises:
    """The three layouts that carry a fraction carry as much of it as they ask.

    `STAMP_MILLI` keeps three digits and drops the rest, which is truncation and
    not rounding: 078901234 becomes 078000000 and never 079000000.
    """
    var t = date(2024, MARCH, 9, 14, 5, 6, 78901234)
    var rows = List[Tuple[String, Int]]()
    rows.append((RFC3339_NANO, 78901234))
    rows.append((STAMP_MILLI, 78000000))
    rows.append((STAMP_MICRO, 78901000))
    rows.append((STAMP_NANO, 78901234))
    rows.append((DATE_TIME, 0))
    for row in rows:
        var got = _read(row[0], t.format(row[0]))
        assert_equal(got.nanosecond(), row[1])


def test_every_piece_reads_what_it_writes() raises:
    """One row per spelling of a field, each on its own so the failure names it.

    A layout of one piece leaves everything else at the start of the year 0,
    which is why the expected seconds are the enormous negative numbers they
    are, and why they differ from each other by exactly the field being read.
    """
    var rows = List[Tuple[String, String, Int]]()
    rows.append(("2006", "2024", 1_704_067_200))
    rows.append(("06", "24", 1_704_067_200))
    rows.append(("January", "March", -62_162_035_200))
    rows.append(("Jan", "Mar", -62_162_035_200))
    rows.append(("1", "3", -62_162_035_200))
    rows.append(("1", "12", -62_138_275_200))
    rows.append(("01", "03", -62_162_035_200))
    rows.append(("Monday", "Saturday", _YEAR_ZERO))
    rows.append(("Mon", "Sat", _YEAR_ZERO))
    rows.append(("2", "9", -62_166_528_000))
    rows.append(("_2", " 9", -62_166_528_000))
    rows.append(("_2", "9", -62_166_528_000))
    rows.append(("02", "09", -62_166_528_000))
    rows.append(("15", "14", -62_167_168_800))
    rows.append(("15", "4", -62_167_204_800))
    rows.append(("3", "2", -62_167_212_000))
    rows.append(("03", "02", -62_167_212_000))
    rows.append(("4", "5", -62_167_218_900))
    rows.append(("04", "05", -62_167_218_900))
    rows.append(("5", "6", -62_167_219_194))
    rows.append(("05", "06", -62_167_219_194))
    rows.append(("3PM", "2PM", -62_167_168_800))
    rows.append(("3PM", "2AM", -62_167_212_000))
    rows.append(("3pm", "2pm", -62_167_168_800))
    rows.append(("2006-002", "2024-069", 1_709_942_400))
    rows.append(("2006-__2", "2024- 69", 1_709_942_400))
    rows.append(("2006-__2", "2024-069", 1_709_942_400))
    for row in rows:
        _check(row[0], row[1], row[2])


def test_the_two_digit_year_pivots_at_sixty_nine() raises:
    """69 is 1969 and 68 is 2068, and the pivot does not move with the clock."""
    var rows = List[Tuple[String, Int]]()
    rows.append(("69", -31_536_000))
    rows.append(("99", 915_148_800))
    rows.append(("00", 946_684_800))
    rows.append(("68", 3_092_601_600))
    for row in rows:
        _check("06", row[0], row[1])


def test_a_name_is_read_without_regard_to_case() raises:
    """`march`, `MARCH` and `March` are all March, and so are the short ones."""
    for value in ["March", "march", "MARCH", "mArCh"]:
        _check("January", value, -62_162_035_200)
    for value in ["Mar", "mar", "MAR", "mAr"]:
        _check("Jan", value, -62_162_035_200)


def test_the_weekday_is_read_and_then_thrown_away() raises:
    """A weekday that disagrees with the date is not an error.

    The date says which day of the week it was, so there is nothing for the
    weekday to add and Go does not check the two against each other. 9 March
    2024 was a Saturday and this reads it as a Monday without complaint.
    """
    var got = _read("Mon 2006-01-02", "Mon 2024-03-09")
    assert_equal(got.unix(), 1_709_942_400)


def test_a_weekday_that_is_not_a_day_at_all_is_refused() raises:
    """The name is still checked for being a name, which is all `Mon` does."""
    _refuse("Mon", "Xyz", 'cannot parse "Xyz" as "Mon"')


def test_a_run_of_spaces_matches_a_run_of_any_length() raises:
    """One space in the layout takes however many the value has, and none.

    This is what lets `Jan _2` read both what `format` writes for the ninth of
    the month and what it writes for the nineteenth.
    """
    _check("Jan _2", "Mar  9", -62_161_344_000)
    _check("Jan _2", "Mar 9", -62_161_344_000)
    _check("Jan  _2", "Mar 9", -62_161_344_000)


def test_a_fraction_the_layout_never_asked_for() raises:
    """A fraction after the seconds is read even when the layout has none.

    Go accepts it because a string written elsewhere usually has one, and a
    comma counts as well as a dot. More than nine digits are truncated.
    """
    var rows = List[Tuple[String, Int]]()
    rows.append(("14:05:06.078", 78_000_000))
    rows.append(("14:05:06,078", 78_000_000))
    rows.append(("14:05:06.078901234", 78_901_234))
    rows.append(("14:05:06.0789012345678", 78_901_234))
    rows.append(("14:05:06", 0))
    for row in rows:
        var got = _read("15:04:05", row[0])
        assert_equal(got.nanosecond(), row[1])


def test_the_nines_fraction_is_optional_and_the_zeros_one_is_not() raises:
    """`.999` reads a value with no fraction and `.000` refuses one.

    The only place the two forms differ once you are reading rather than
    writing, and the reason `RFC3339_NANO` reads a string `RFC3339` wrote.
    """
    assert_equal(_read("15:04:05.999", "14:05:06").nanosecond(), 0)
    assert_equal(_read("15:04:05.999", "14:05:06.078").nanosecond(), 78_000_000)
    assert_equal(_read("15:04:05.000", "14:05:06.078").nanosecond(), 78_000_000)
    _refuse("15:04:05.000", "14:05:06", 'cannot parse "" as ".000"')


def test_the_nines_fraction_takes_more_digits_than_it_asked_for() raises:
    """`.999` reads nine digits, because the seconds case would have.

    Reading is never made stricter by naming a width, which is Go's comment on
    this case and the reason it is worth a row.
    """
    assert_equal(
        _read("15:04:05.999", "14:05:06.078901234").nanosecond(), 78_901_234
    )


def test_the_ten_zone_spellings() raises:
    """Each numeric offset spelling, by the offset it produces.

    Read against UTC, so an offset of zero is UTC itself and every other offset
    is a zone fabricated to hold the number, with no name.
    """
    var rows = List[Tuple[String, String, Int]]()
    rows.append(("2006-01-02 15:04:05 -0700", "-0730", -27000))
    rows.append(("2006-01-02 15:04:05 -07", "-07", -25200))
    rows.append(("2006-01-02 15:04:05 -07:00", "-07:30", -27000))
    rows.append(("2006-01-02 15:04:05 -070000", "-073000", -27000))
    rows.append(("2006-01-02 15:04:05 -07:00:00", "-07:30:00", -27000))
    rows.append(("2006-01-02 15:04:05 Z0700", "-0730", -27000))
    rows.append(("2006-01-02 15:04:05 Z07", "-07", -25200))
    rows.append(("2006-01-02 15:04:05 Z07:00", "-07:30", -27000))
    rows.append(("2006-01-02 15:04:05 Z070000", "-073000", -27000))
    rows.append(("2006-01-02 15:04:05 Z07:00:00", "-07:30:00", -27000))
    for row in rows:
        var got = _read(row[0], String("2024-03-09 14:05:06 ", row[1]))
        assert_equal(got.zone()[1], row[2])
        assert_equal(got.zone()[0], "")


def test_the_five_z_spellings_take_a_bare_z() raises:
    """`Z` where the digits would be is UTC, and the five with a sign refuse it.

    The letter is in those five spellings for exactly this, and it is why
    `RFC3339` reads what `RFC3339` writes at an offset of zero.
    """
    for layout in [
        String("2006-01-02 15:04:05 Z0700"),
        String("2006-01-02 15:04:05 Z07"),
        String("2006-01-02 15:04:05 Z07:00"),
        String("2006-01-02 15:04:05 Z070000"),
        String("2006-01-02 15:04:05 Z07:00:00"),
    ]:
        var got = _read(layout, "2024-03-09 14:05:06 Z")
        assert_equal(got.unix(), _REF)
        assert_equal(got.zone()[0], "UTC")
    _refuse(
        "2006-01-02 15:04:05 -0700",
        "2024-03-09 14:05:06 Z",
        'cannot parse "Z" as "-0700"',
    )


def test_an_offset_of_zero_read_against_utc_is_utc_itself() raises:
    """A fabricated zone is only fabricated when the location does not fit.

    UTC was using an offset of zero at that instant, so the answer keeps UTC
    rather than inventing a nameless zone that happens to agree with it.
    """
    var got = _read("2006-01-02 15:04:05 -0700", "2024-03-09 14:05:06 +0000")
    assert_equal(got.zone()[0], "UTC")
    assert_equal(got.unix(), _REF)


def test_a_zone_abbreviation_is_read_by_shape() raises:
    """Three capitals, or four or five ending in `T`, and the three exceptions.

    None of these names is in a table anywhere. `MST` accepts them because of
    how they look, keeps the name, and gives the zone an offset of zero, since
    nothing here knows what `AEDST` is worth.
    """
    for name in [
        String("XYZ"),
        String("ChST"),
        String("MeST"),
        String("WITA"),
        String("AEST"),
        String("AEDST"),
    ]:
        var got = _read(
            "2006-01-02 15:04:05 MST", String("2024-03-09 14:05:06 ", name)
        )
        assert_equal(got.zone()[0], name)
        assert_equal(got.zone()[1], 0)
        assert_equal(got.unix(), _REF)


def test_a_shape_that_is_not_a_zone() raises:
    """Two capitals is too few and six is too many."""
    _refuse(
        "2006-01-02 15:04:05 MST",
        "2024-03-09 14:05:06 AB",
        'cannot parse "AB" as "MST"',
    )
    _refuse(
        "2006-01-02 15:04:05 MST",
        "2024-03-09 14:05:06 ABCDEF",
        'cannot parse "ABCDEF" as "MST"',
    )


def test_utc_is_utc_wherever_it_is_read() raises:
    """The one abbreviation that does not depend on the location it is read
    against."""
    var got = _read("2006-01-02 15:04:05 MST", "2024-03-09 14:05:06 UTC")
    assert_equal(got.zone()[0], "UTC")
    assert_equal(got.unix(), _REF)


def test_gmt_may_carry_an_hour() raises:
    """`GMT+3` is a zone name of five characters worth three hours east.

    The only abbreviation with a number in it, and the offset comes out of the
    name rather than out of any table, which is why it is the one unrecognised
    name that does not land at zero.
    """
    var rows = List[Tuple[String, Int]]()
    rows.append(("GMT", 0))
    rows.append(("GMT+3", 10800))
    rows.append(("GMT-11", -39600))
    for row in rows:
        var got = _read(
            "2006-01-02 15:04:05 MST", String("2024-03-09 14:05:06 ", row[0])
        )
        assert_equal(got.zone()[0], row[0])
        assert_equal(got.zone()[1], row[1])
        assert_equal(got.unix(), _REF)


def test_a_signed_number_is_a_zone_name_and_not_an_offset() raises:
    """`MST` reading `+07` keeps `+07` as a name and an offset of zero.

    It looks like an offset and it is not one, because the piece that was asked
    for was the abbreviation. Go does the same and it is the trap that makes
    `-0700` the spelling to reach for.
    """
    var got = _read("2006-01-02 15:04:05 MST", "2024-03-09 14:05:06 +07")
    assert_equal(got.zone()[0], "+07")
    assert_equal(got.zone()[1], 0)
    assert_equal(got.unix(), _REF)


def test_an_offset_the_location_was_using_keeps_the_location() raises:
    """Berlin was two hours east that day, so `+0200` reads as Berlin.

    This is what makes a round trip through `format` land where it started
    rather than in a nameless zone that happens to agree. The abbreviation gets
    there the other way, through the location's own table of names.
    """
    var berlin = _berlin()
    var rows = _rows()
    rows.append(("2006-01-02 15:04 -0700", "2024-07-01 12:00 +0200"))
    rows.append(("2006-01-02 15:04 MST", "2024-07-01 12:00 CEST"))
    for row in rows:
        var got = parse_in_location(row[0], row[1], berlin)
        assert_equal(got.unix(), 1_719_828_000)
        assert_equal(got.zone()[0], "CEST")
        assert_equal(got.zone()[1], 7200)


def test_a_value_with_no_zone_lands_in_the_location_it_was_read_in() raises:
    """The whole of the difference between `parse` and `parse_in_location`."""
    var got = parse_in_location(
        "2006-01-02 15:04", "2024-07-01 12:00", _berlin()
    )
    assert_equal(got.unix(), 1_719_828_000)
    assert_equal(got.zone()[0], "CEST")


def test_parse_reads_a_value_with_no_zone_as_utc() raises:
    """`parse` itself, on the rows whose answer no host can change.

    A value with no zone information is UTC and a `Z` is UTC, neither of which
    consults the host, so these say the same thing wherever they run.
    """
    assert_equal(parse(DATE_TIME, "2024-03-09 14:05:06").unix(), _REF)
    assert_equal(parse(DATE_ONLY, "2024-03-09").unix(), 1_709_942_400)
    assert_equal(parse(RFC3339, "2024-03-09T14:05:06Z").unix(), _REF)
    assert_equal(parse(RFC3339, "2024-03-09T14:05:06Z").zone()[0], "UTC")


def test_the_day_of_the_year() raises:
    """`002` and `__2` both read a day of the year, and 2024 was a leap year.

    Day 60 of a leap year is 29 February and day 366 is 31 December, and the
    same numbers in a common year mean different dates, which is why the year
    has to be read before the day of the year can be turned into one.
    """
    _check("2006-002", "2024-060", 1_709_164_800)
    _check("2006-002", "2024-366", 1_735_603_200)
    _check("2006-002", "2023-060", 1_677_628_800)
    _check("2006-01-002", "2024-03-069", 1_709_942_400)


def test_a_day_of_the_year_that_does_not_fit() raises:
    """Zero is not a day, 366 is not a day of a common year, and a day of the
    year that disagrees with a month or a day the value also gave is refused.

    The last two are only reachable from a layout that says the same thing
    twice, which nothing sensible writes, and Go checks them anyway because a
    layout is whatever the caller assembled.
    """
    _refuse("2006-002", "2024-000", "day-of-year out of range")
    _refuse("2006-002", "2023-366", "day-of-year out of range")
    _refuse("2006-01-002", "2024-02-069", "day-of-year does not match month")
    _refuse(
        "2006-01-02-002", "2024-03-10-069", "day-of-year does not match day"
    )
    _check("2006-01-02-002", "2024-03-09-069", 1_709_942_400)
    _check("2006-002-02", "2024-069-09", 1_709_942_400)


def test_what_the_layout_leaves_out() raises:
    """Everything unmentioned is zero, or one where zero is impossible.

    So a layout of nothing at all against a value of nothing at all is midnight
    on 1 January of the year 0, which is before the zero `Time` and is a real
    instant rather than an error.
    """
    _check("", "", _YEAR_ZERO)
    _check("3:04pm", "9:41pm", -62_167_141_140)


def test_the_traps_the_layout_language_has_either_way() raises:
    """`the 2nd` has a day of the month in it here as much as it does in
    `format`, because both directions walk the same scanner."""
    _check("the 2nd", "the 9nd", -62_166_528_000)


def test_a_field_outside_its_range() raises:
    """Each range check, by the word Go puts in the message."""
    var rows = List[Tuple[String, String, String]]()
    rows.append(("2006-01-02", "2024-13-09", "month out of range"))
    rows.append(("15:04", "25:00", "hour out of range"))
    rows.append(("15:04", "14:60", "minute out of range"))
    rows.append(("15:04:05", "14:05:60", "second out of range"))
    rows.append(("2006-01-02", "2024-02-30", "day out of range"))
    rows.append(
        (
            "2006-01-02T15:04:05Z07:00",
            "2024-03-09T14:05:06+25:00",
            "time zone offset hour out of range",
        )
    )
    for row in rows:
        _refuse(row[0], row[1], row[2])


def test_the_last_day_of_february() raises:
    """29 February exists in 2024 and does not in 2023, and the check happens
    after everything has been read, because the year may come last."""
    _check("2006-01-02", "2024-02-29", 1_709_164_800)
    _refuse("2006-01-02", "2023-02-29", "day out of range")
    _check("02-01-2006", "29-02-2024", 1_709_164_800)
    _refuse("02-01-2006", "29-02-2023", "day out of range")


def test_a_fixed_width_field_wants_its_width() raises:
    """`01` takes two digits and `1` takes either, which is the whole of the
    difference between the two spellings when reading."""
    _refuse("2006-01-02", "2024-3-09", 'cannot parse "3-09" as "01"')
    _check("2006-1-02", "2024-3-09", 1_709_942_400)
    _refuse("02", "9", 'cannot parse "9" as "02"')
    _check("2", "9", -62_166_528_000)


def test_text_left_over_at_the_end() raises:
    """Everything in the value has to be accounted for, and what is left is
    quoted back."""
    _refuse("2006-01-02", "2024-03-09x", 'extra text: "x"')
    _refuse("", "x", 'extra text: "x"')


def test_text_that_is_not_there_at_all() raises:
    """The value ran out before the layout did."""
    _refuse("2006", "", 'cannot parse "" as "2006"')
    _refuse("2006-01-02", "not a date", 'cannot parse "not a date" as "2006"')


def test_the_message_is_the_one_go_writes() raises:
    """Character for character, including the quoting of both strings."""
    try:
        _ = _read("2006-01-02", "not a date")
        assert_true(False, "a string that is not a date was read as one")
    except e:
        assert_equal(
            String(e),
            (
                'parsing time "not a date" as "2006-01-02": cannot parse "not a'
                ' date" as "2006"'
            ),
        )


def test_the_message_for_a_reason_rather_than_a_piece() raises:
    """The shorter form, which names the value and then says what was wrong."""
    try:
        _ = _read("2006-01-02", "2024-13-09")
        assert_true(False, "month thirteen was read as a month")
    except e:
        assert_equal(String(e), 'parsing time "2024-13-09": month out of range')


def test_the_failure_reads_back_as_a_parse_error() raises:
    """All five fields off the record, which is Go's `*ParseError` arriving."""
    try:
        _ = _read("2006-01-02", "not a date")
        assert_true(False, "a string that is not a date was read as one")
    except e:
        assert_true(matches(e, ErrParseTime), "not an ErrParseTime")
        var failure = ParseError.of(e)
        assert_true(Bool(failure), "no ParseError on the record")
        var got = failure.value().copy()
        assert_equal(got.layout, "2006-01-02")
        assert_equal(got.value, "not a date")
        assert_equal(got.layout_elem, "2006")
        assert_equal(got.value_elem, "not a date")
        assert_equal(got.message, "")
        assert_equal(String(got), got.error())


def test_a_parse_error_of_something_else_is_nothing() raises:
    """`of` is a type assertion and answers the way a failed one does."""
    try:
        _ = parse_duration("nonsense")
        assert_true(False, "nonsense was read as a duration")
    except e:
        assert_true(
            not ParseError.of(e), "a duration failure read as a ParseError"
        )


def test_a_quoted_string_escapes_what_it_cannot_print() raises:
    """The quoting in the message is Go's, which writes a byte it will not
    print as a hex escape rather than as the character it stands for."""
    try:
        _ = _read("2006", "20\x01a")
        assert_true(False, "a control character was read as a year")
    except e:
        assert_true(
            String(e).find("\\x01") >= 0,
            String("the control character was not escaped: ", e),
        )


def test_parse_duration_reads_what_go_reads() raises:
    """One row per shape a duration string comes in."""
    var rows = List[Tuple[String, Int]]()
    rows.append(("0", 0))
    rows.append(("-0", 0))
    rows.append(("+0", 0))
    rows.append(("5s", 5_000_000_000))
    rows.append(("-5s", -5_000_000_000))
    rows.append(("+5s", 5_000_000_000))
    rows.append(("1.5h", 5_400_000_000_000))
    rows.append(("-1.5h", -5_400_000_000_000))
    rows.append(("2h45m", 9_900_000_000_000))
    rows.append(("1h1m1s", 3_661_000_000_000))
    rows.append(("300ms", 300_000_000))
    rows.append((".5s", 500_000_000))
    rows.append(("0.5s", 500_000_000))
    rows.append(("5.s", 5_000_000_000))
    rows.append(("1.0s", 1_000_000_000))
    rows.append(("10.5s", 10_500_000_000))
    for row in rows:
        var got = parse_duration(row[0])
        assert_true(
            got.value == row[1],
            String(
                "parse_duration(",
                row[0],
                ") gave ",
                got.value,
                ", want ",
                row[1],
            ),
        )


def test_the_units_including_both_spellings_of_the_micro() raises:
    """`us`, the micro sign and the Greek mu all mean the same thousand."""
    var rows = List[Tuple[String, Duration]]()
    rows.append(("1ns", NANOSECOND))
    rows.append(("1us", Duration(1_000)))
    rows.append(("1µs", Duration(1_000)))
    rows.append(("1μs", Duration(1_000)))
    rows.append(("1ms", Duration(1_000_000)))
    rows.append(("1s", Duration(1_000_000_000)))
    rows.append(("1m", MINUTE))
    rows.append(("1h", HOUR))
    for row in rows:
        assert_equal(parse_duration(row[0]).value, row[1].value)


def test_parse_duration_at_the_limits() raises:
    """The two ends of a signed count of nanoseconds, and one step past each.

    The negative end is one further from zero than the positive one, which is
    why the largest magnitude that reads is a negative number.
    """
    assert_equal(
        parse_duration("9223372036854775807ns").value,
        9_223_372_036_854_775_807,
    )
    assert_equal(
        parse_duration("-9223372036854775808ns").value,
        -9_223_372_036_854_775_807 - 1,
    )
    with assert_raises(contains='invalid duration "9223372036854775808ns"'):
        _ = parse_duration("9223372036854775808ns")
    with assert_raises(contains="invalid duration"):
        _ = parse_duration("100000000000000000000ns")


def test_parse_duration_refuses() raises:
    """Each of the three messages, by the string that produces it."""
    var rows = _rows()
    rows.append(("", 'time: invalid duration ""'))
    rows.append(("s", 'time: invalid duration "s"'))
    rows.append(("-", 'time: invalid duration "-"'))
    rows.append((".s", 'time: invalid duration ".s"'))
    rows.append(("1", 'time: missing unit in duration "1"'))
    rows.append(("1.5", 'time: missing unit in duration "1.5"'))
    rows.append(("1d", 'time: unknown unit "d" in duration "1d"'))
    rows.append(("1e9", 'time: unknown unit "e" in duration "1e9"'))
    rows.append(("2h 45m", 'time: unknown unit "h " in duration "2h 45m"'))
    for row in rows:
        with assert_raises(contains=row[1]):
            _ = parse_duration(row[0])


def test_a_duration_failure_carries_the_string_it_was_given() raises:
    """The code and the field, which is what a caller reports without having to
    read the English."""
    try:
        _ = parse_duration("1d")
        assert_true(False, "a day was read as a unit")
    except e:
        assert_true(matches(e, ErrParseDuration), "not an ErrParseDuration")
