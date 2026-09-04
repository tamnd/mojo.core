"""The embedded zone database, against what Go answers from the same archive.

Every expected abbreviation and offset here came from running Go with
`ZONEINFO` pointed at the very archive this package was generated from, so a
row that passes is a row where the two libraries read the same bytes the same
way. Nothing in this file touches the host's own database, which is the whole
point of the package being here.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.errors import matches
from core.errors.codes import ErrBadLocationName, ErrUnknownZone
from core.time import JANUARY, RFC3339, date, unix
from core.time.tzdata import load_location
from core.time.tzdata.data import COUNT, INDEX, NAME_WIDTH, PAD, RECORD

# The instant most rows are read at, the first of July 2024 at ten in the
# morning UTC, which is inside the northern summer and outside the southern one.
comptime _SUMMER = 1_719_828_000


def _name_at(i: Int) -> String:
    """The name in record `i`, with the padding taken off."""
    var index = INDEX.as_bytes()
    var at = i * RECORD
    var end = at + NAME_WIDTH
    while end > at and index[end - 1] == UInt8(PAD):
        end -= 1
    return String(from_utf8_lossy=index[at:end])


def _zone(name: String, when: Int) raises -> Tuple[String, Int, Bool]:
    """The abbreviation, the offset and the daylight flag at `when`."""
    var t = unix(when, 0).in_location(load_location(name))
    var abbrev, offset = t.zone()
    return (abbrev, offset, t.is_dst())


def _check(
    name: String, when: Int, abbrev: String, offset: Int, dst: Bool
) raises:
    """One row of the oracle."""
    var got_abbrev, got_offset, got_dst = _zone(name, when)
    assert_equal(got_abbrev, abbrev)
    assert_equal(got_offset, offset)
    assert_equal(got_dst, dst)


def test_every_name_loads() raises:
    """All 598 of them, which is the only way to know the index is right.

    A record whose offset or length is wrong points at the wrong bytes, and
    the wrong bytes are almost always not a zone file at all, so the reader
    refuses them and this fails rather than passing with a plausible answer.
    """
    assert_equal(COUNT, 598)
    for i in range(COUNT):
        var name = _name_at(i)
        var loc = load_location(name)
        assert_equal(String(loc), name)


def test_the_index_is_sorted() raises:
    """The binary search only works if it is, so the property is checked
    rather than trusted to the generator."""
    for i in range(1, COUNT):
        assert_true(_name_at(i - 1) < _name_at(i))


def test_ordinary_zones() raises:
    """Northern summer and northern winter, in a place that keeps both."""
    _check("Europe/Berlin", _SUMMER, "CEST", 7200, True)
    _check("Europe/Berlin", 1_704_106_800, "CET", 3600, False)
    _check("America/New_York", _SUMMER, "EDT", -14400, True)


def test_offsets_that_are_not_whole_hours() raises:
    """Three quarters of an hour, and a saving of half of one."""
    _check("Asia/Kathmandu", _SUMMER, "+0545", 20700, False)
    _check("Pacific/Chatham", _SUMMER, "+1245", 45900, False)
    _check("Australia/Lord_Howe", _SUMMER, "+1030", 37800, False)
    _check("Asia/Kolkata", _SUMMER, "IST", 19800, False)


def test_dublin_runs_backwards() raises:
    """Ireland's summer is its standard clock and its winter is the saving
    one, so the daylight flag is false in July and true in January."""
    _check("Europe/Dublin", _SUMMER, "IST", 3600, False)
    _check("Europe/Dublin", 1_704_106_800, "GMT", 0, True)


def test_a_zone_with_no_daylight_saving() raises:
    """Brazil stopped in 2019 and the file says so."""
    _check("America/Sao_Paulo", _SUMMER, "-03", -10800, False)
    _check("Africa/Abidjan", _SUMMER, "GMT", 0, False)


def test_local_mean_time_before_the_first_transition() raises:
    """The first entry of a file, which is the place with an offset that is not
    a whole minute."""
    _check("Africa/Abidjan", -2_000_000_000, "LMT", -968, False)
    _check("Europe/Berlin", -2_000_000_000, "CET", 3600, False)


def test_aliases_share_one_file() raises:
    """The database is mostly aliases and the archive stores each as a whole
    copy. They are stored once here, so this is the test that the second name
    still finds it."""
    var kolkata = _zone("Asia/Kolkata", _SUMMER)
    var calcutta = _zone("Asia/Calcutta", _SUMMER)
    assert_equal(kolkata[0], calcutta[0])
    assert_equal(kolkata[1], calcutta[1])

    _check("Etc/UTC", _SUMMER, "UTC", 0, False)
    _check("Etc/Zulu", _SUMMER, "UTC", 0, False)
    _check("Zulu", _SUMMER, "UTC", 0, False)


def test_the_ends_of_the_index() raises:
    """The first name, the last name, the longest and one of the shortest, all
    of which are where an off by one in the binary search shows up."""
    assert_equal(_name_at(0), "Africa/Abidjan")
    assert_equal(_name_at(COUNT - 1), "Zulu")
    _check("America/Argentina/ComodRivadavia", _SUMMER, "-03", -10800, False)
    _check("GB", _SUMMER, "BST", 3600, True)
    _check("Etc/GMT+10", _SUMMER, "-10", -36000, False)


def test_the_day_samoa_skipped() raises:
    """Samoa crossed the date line at the end of 2011, so the last day of that
    year does not exist there and the offset on both sides of the gap is the
    same."""
    _check("Pacific/Apia", 1_325_376_000, "+14", 50400, True)
    _check("Pacific/Apia", 1_325_548_800, "+14", 50400, True)


def test_a_zone_south_of_everything() raises:
    """Troll station keeps its saving time in the southern winter, which is
    when everybody there is awake."""
    _check("Antarctica/Troll", _SUMMER, "+02", 7200, True)


def test_utc_reads_nothing() raises:
    """The two names that are UTC without a lookup."""
    assert_equal(String(load_location("")), "UTC")
    assert_equal(String(load_location("UTC")), "UTC")


def test_unknown_names() raises:
    """A name the database does not have, including the one name a host would
    answer and a database cannot."""
    var rows = List[String]()
    rows.append("Nowhere/Nothing")
    rows.append("Local")
    rows.append("Europe/berlin")
    rows.append("Europe/Berlin ")
    # The byte the records are padded with, which is the one query that would
    # compare equal to a shorter name if the search did not refuse it.
    rows.append("Europe/Berlin!")
    rows.append("Zulu!")

    for name in rows:
        with assert_raises(contains="unknown time zone"):
            _ = load_location(name)

        try:
            _ = load_location(name)
        except e:
            assert_true(matches(e, ErrUnknownZone))


def test_names_that_are_paths() raises:
    """Refused before the lookup, even though there is no file system here for
    one to escape into, so that swapping this for `core.time.load_location`
    does not change the answer."""
    var rows = List[String]()
    rows.append("/etc/localtime")
    rows.append("\\etc\\localtime")
    rows.append("../../etc/passwd")
    rows.append("Europe/../../Europe/Berlin")

    for name in rows:
        with assert_raises(contains="invalid location name"):
            _ = load_location(name)

        try:
            _ = load_location(name)
        except e:
            assert_true(matches(e, ErrBadLocationName))


def test_a_name_longer_than_any_record() raises:
    """Longer than the name field of a record, so the search stops before it
    reads one."""
    with assert_raises(contains="unknown time zone"):
        _ = load_location("America/Argentina/ComodRivadavia_and_then_some")


def test_a_location_answers_the_same_as_a_date_built_in_it() raises:
    """The location is a location like any other, so the rest of the package
    works on it."""
    var berlin = load_location("Europe/Berlin")
    var t = date(2024, JANUARY, 1, 12, 0, 0, 0, berlin)
    assert_equal(t.format(RFC3339), "2024-01-01T12:00:00+01:00")
    assert_false(t.is_dst())
