"""The TZ string parser, against Go's four tables.

All four are written inside the test functions in Go rather than at the top of
the file, so the harvester cannot reach them and they are transcribed here by
hand. They are small and they are the whole of what Go checks about this
parser, so the transcription is the table and not a sample of it.

The rows are laid out as they are in Go: input first, then what should come
back. Where Go writes an arithmetic expression for an expected offset, such as
`-7 * 60 * 60`, so does this, because the number it works out to says nothing
and the expression says which side of UTC the zone is on.
"""

from std.testing import assert_equal, assert_true

from core.time.tzset import (
    _OMEGA,
    _RULE_DOY,
    _RULE_JULIAN,
    _RULE_MONTH_WEEK_DAY,
    _Rule,
    _tzset,
    _tzset_name,
    _tzset_offset,
    _tzset_rule,
)


def test_tzset_matches_go() raises:
    """Go's `TestTzset`.

    Seven of the eight rows are the same Los Angeles string read at seven
    instants, which between them are either side of both changes in a year and
    the exact second of each. That is the table that says whether the
    comparisons at the bottom of `_tzset` are the right way round, since an
    inclusive bound written exclusive passes every row except the two that land
    on the second itself.
    """
    var la = "PST8PDT,M3.2.0,M11.1.0"
    _check_tzset(
        la, 0, 2159200800, "PDT", -7 * 60 * 60, 2152173600, 2172733200, True
    )
    _check_tzset(
        la, 0, 2152173599, "PST", -8 * 60 * 60, 2145916800, 2152173600, False
    )
    _check_tzset(
        la, 0, 2152173600, "PDT", -7 * 60 * 60, 2152173600, 2172733200, True
    )
    _check_tzset(
        la, 0, 2152173601, "PDT", -7 * 60 * 60, 2152173600, 2172733200, True
    )
    _check_tzset(
        la, 0, 2172733199, "PDT", -7 * 60 * 60, 2152173600, 2172733200, True
    )
    _check_tzset(
        la, 0, 2172733200, "PST", -8 * 60 * 60, 2172733200, 2177452800, False
    )
    _check_tzset(
        la, 0, 2172733201, "PST", -8 * 60 * 60, 2172733200, 2177452800, False
    )

    # Korea, which has no daylight time. The zone runs from the file's last
    # transition to the end of time, and this is the row that says the
    # `last_tx_sec` argument is used rather than ignored.
    _check_tzset(
        "KST-9",
        592333200,
        1677246697,
        "KST",
        9 * 60 * 60,
        592333200,
        _OMEGA,
        False,
    )


def test_an_empty_tz_string_is_not_a_tz_string() raises:
    """Go's one failing row of `TestTzset`."""
    var name, off, start, end, is_dst, ok = _tzset("", 0, 0)
    assert_true(not ok)
    assert_equal(name, "")
    assert_equal(off, 0)
    assert_equal(start, 0)
    assert_equal(end, 0)
    assert_true(not is_dst)


def test_tzset_name_matches_go() raises:
    """Go's `TestTzsetName`."""
    _check_name("", "", "", False)
    _check_name("X", "", "", False)
    _check_name("PST", "PST", "", True)
    _check_name("PST8PDT", "PST", "8PDT", True)
    _check_name("PST-08", "PST", "-08", True)
    _check_name("<A+B>+08", "A+B", "+08", True)


def test_tzset_offset_matches_go() raises:
    """Go's `TestTzsetOffset`."""
    _check_offset("", 0, "", False)
    _check_offset("X", 0, "", False)
    _check_offset("+", 0, "", False)
    _check_offset("+08", 8 * 60 * 60, "", True)
    _check_offset("-01:02:03", -1 * 60 * 60 - 2 * 60 - 3, "", True)
    _check_offset("01", 1 * 60 * 60, "", True)
    _check_offset("100", 100 * 60 * 60, "", True)
    _check_offset("1000", 0, "", False)
    _check_offset("8PDT", 8 * 60 * 60, "PDT", True)


def test_tzset_rule_matches_go() raises:
    """Go's `TestTzsetRule`."""
    _check_rule("", _Rule(), "", False)
    _check_rule("X", _Rule(), "", False)
    _check_rule("J10", _Rule(_RULE_JULIAN, 10, 0, 0, 2 * 60 * 60), "", True)
    _check_rule("20", _Rule(_RULE_DOY, 20, 0, 0, 2 * 60 * 60), "", True)
    _check_rule(
        "M1.2.3", _Rule(_RULE_MONTH_WEEK_DAY, 3, 2, 1, 2 * 60 * 60), "", True
    )
    _check_rule(
        "30/03:00:00", _Rule(_RULE_DOY, 30, 0, 0, 3 * 60 * 60), "", True
    )
    _check_rule(
        "M4.5.6/03:00:00",
        _Rule(_RULE_MONTH_WEEK_DAY, 6, 5, 4, 3 * 60 * 60),
        "",
        True,
    )
    _check_rule("M4.5.7/03:00:00", _Rule(), "", False)
    _check_rule(
        "M4.5.6/-04",
        _Rule(_RULE_MONTH_WEEK_DAY, 6, 5, 4, -4 * 60 * 60),
        "",
        True,
    )


def test_the_default_rules_are_the_ones_tzcode_uses() raises:
    """A string with two names and no rules is North America's rule.

    Go writes `,M3.2.0,M11.1.0` into the string and parses it. This spells the
    two rules out instead, so the equivalence has to be asserted rather than
    read off, and this is where. The instant is the second Sunday of March 2024
    at ten in the morning UTC, which is one second after two in the morning
    Pacific.
    """
    var with_rules = _tzset("PST8PDT,M3.2.0,M11.1.0", 0, 1_710_064_801)
    var without = _tzset("PST8PDT", 0, 1_710_064_801)
    assert_equal(without[0], with_rules[0])
    assert_equal(without[1], with_rules[1])
    assert_equal(without[2], with_rules[2])
    assert_equal(without[3], with_rules[3])
    assert_equal(without[4], with_rules[4])
    assert_true(without[5])
    assert_equal(without[0], "PDT")


def test_a_southern_hemisphere_rule_reads_the_year_the_other_way() raises:
    """Daylight time that spans the new year, which is the swap in `_tzset`.

    New Zealand: standard time is twelve hours east, daylight time thirteen,
    and it runs from the last Sunday of September to the first Sunday of April.
    The rule written first ends daylight time rather than starting it, so
    without the swap January would come out as standard time. January is the
    middle of their summer.
    """
    var tz = "NZST-12NZDT,M9.5.0,M4.1.0/3"
    var name, off, _s, _e, is_dst, ok = _tzset(tz, 0, 1_704_067_200)
    assert_true(ok)
    assert_equal(name, "NZDT")
    assert_equal(off, 13 * 60 * 60)
    assert_true(is_dst)

    # July, the middle of their winter.
    var wname, woff, _ws, _we, wis_dst, wok = _tzset(tz, 0, 1_720_000_000)
    assert_true(wok)
    assert_equal(wname, "NZST")
    assert_equal(woff, 12 * 60 * 60)
    assert_true(not wis_dst)


def test_a_rule_before_1970_is_read_the_same_way() raises:
    """A negative Unix second, which is where Go's division and Mojo's differ.

    The year and the second within it are worked out from the instant, and the
    remainder that gives the second within the day has to take the sign of the
    instant rather than the sign of a day. Nineteen sixty is inside daylight
    time in Los Angeles, and under Mojo's own remainder this row lands in the
    wrong year.
    """
    var name, off, _s, _e, is_dst, ok = _tzset(
        "PST8PDT,M3.2.0,M11.1.0", 0, -300_000_000
    )
    assert_true(ok)
    assert_equal(name, "PDT")
    assert_equal(off, -7 * 60 * 60)
    assert_true(is_dst)


def _check_tzset(
    tz: StringSlice,
    last_tx: Int,
    sec: Int,
    name: StringSlice,
    off: Int,
    start: Int,
    end: Int,
    is_dst: Bool,
) raises:
    """One row of Go's `TestTzset`, which is expected to parse."""
    var got_name, got_off, got_start, got_end, got_is_dst, ok = _tzset(
        tz, last_tx, sec
    )
    assert_true(ok)
    assert_equal(got_name, name)
    assert_equal(got_off, off)
    assert_equal(got_start, start)
    assert_equal(got_end, end)
    assert_equal(got_is_dst, is_dst)


def _check_name(
    s: StringSlice, name: StringSlice, rest: StringSlice, ok: Bool
) raises:
    """One row of Go's `TestTzsetName`."""
    var got_name, got_rest, got_ok = _tzset_name(s)
    assert_equal(got_ok, ok)
    assert_equal(got_name, name)
    assert_equal(got_rest, rest)


def _check_offset(s: StringSlice, off: Int, rest: StringSlice, ok: Bool) raises:
    """One row of Go's `TestTzsetOffset`."""
    var got_off, got_rest, got_ok = _tzset_offset(s)
    assert_equal(got_ok, ok)
    assert_equal(got_off, off)
    assert_equal(got_rest, rest)


def _check_rule(s: StringSlice, r: _Rule, rest: StringSlice, ok: Bool) raises:
    """One row of Go's `TestTzsetRule`."""
    var got_rule, got_rest, got_ok = _tzset_rule(s)
    assert_equal(got_ok, ok)
    assert_true(got_rule == r)
    assert_equal(got_rest, rest)
