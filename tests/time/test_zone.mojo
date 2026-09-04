"""`Location` on its own, away from the file reader.

The rows that go through a real zone file are in `test_tzif.mojo`. What is here
is the behaviour a location has before any file is involved: what an empty one
does, what `fixed_zone` builds, how the cache answers, and the two lookups.

Go has no direct equivalent for most of this, because in Go a `Location` with no
zones is unreachable from outside the package. Here it is the default value of a
public type, so it has to have a defined answer, and the answer is UTC.
"""

from std.testing import assert_equal, assert_true

from core.time.tzset import _ALPHA, _OMEGA
from core.time.zone import Location, Zone, ZoneTrans, fixed_zone, utc


def test_a_location_with_nothing_in_it_is_utc() raises:
    """The default value, which is what a failed load leaves behind.

    Go never lets one of these escape; here it is `Location()` and any program
    can hold one, so it answers UTC at every instant rather than answering
    nothing. A location that silently means UTC is a great deal better than one
    that crashes, and it matches what Go's own zero `Location` does internally.
    """
    var loc = Location()
    assert_equal(String(loc), "UTC")

    var name, off, start, end, is_dst = loc.lookup(0)
    assert_equal(name, "UTC")
    assert_equal(off, 0)
    assert_equal(start, _ALPHA)
    assert_equal(end, _OMEGA)
    assert_true(not is_dst)

    # Far outside anything a zone file covers, and the same answer.
    var fname, foff, _fs, _fe, _fd = loc.lookup(-30_000_000_000)
    assert_equal(fname, "UTC")
    assert_equal(foff, 0)


def test_utc_is_the_empty_location() raises:
    """`utc()` is a function rather than a constant.

    A `Location` holds two lists and a list cannot live at module scope, so
    there is no `UTC` to import. Go has one because its locations are pointers
    to shared immutable tables and this language has neither.
    """
    var loc = utc()
    assert_equal(String(loc), "UTC")
    var name, off, _s, _e, is_dst = loc.lookup(1_700_000_000)
    assert_equal(name, "UTC")
    assert_equal(off, 0)
    assert_true(not is_dst)


def test_a_fixed_zone_is_the_same_at_every_instant() raises:
    """Go's `FixedZone`, which is one zone and no changes.

    The point of the type is that it answers the same thing forever, so the
    instants below are chosen to be as far apart as the type allows.
    """
    var loc = fixed_zone("CET", 3600)
    assert_equal(String(loc), "CET")

    for sec in [_ALPHA + 1, -1_000_000_000, 0, 1_700_000_000, _OMEGA - 1]:
        var name, off, _s, _e, is_dst = loc.lookup(sec)
        assert_equal(name, "CET")
        assert_equal(off, 3600)
        assert_true(not is_dst)


def test_a_fixed_zone_keeps_a_negative_offset() raises:
    """West of UTC is a negative number and stays one.

    Worth a row of its own because the offset makes a round trip through the
    file reader as an unsigned four byte field, and this is the shape of value
    that a missing sign extension turns into four billion.
    """
    var loc = fixed_zone("EST", -5 * 3600)
    var _n, off, _s, _e, _d = loc.lookup(0)
    assert_equal(off, -18000)


def test_lookup_walks_the_transitions() raises:
    """A location built by hand, so the search has something to search.

    Three zones and three changes, which is enough for every branch of the
    binary search: before the first change, exactly on a change, between two,
    and after the last. The instants are round numbers rather than real ones
    because what is being checked is the search and not the calendar.
    """
    var zones: List[Zone] = [
        Zone("A", 0, False),
        Zone("B", 3600, True),
        Zone("C", 7200, False),
    ]
    var txs: List[ZoneTrans] = [
        ZoneTrans(1000, 1),
        ZoneTrans(2000, 2),
        ZoneTrans(3000, 0),
    ]
    var loc = Location("made up", zones^, txs^, "")

    # Before the first change, which is the first standard zone rather than
    # simply the first zone, because zone 0 is used by a transition here.
    var n0, o0, s0, e0, _d0 = loc.lookup(500)
    assert_equal(n0, "A")
    assert_equal(o0, 0)
    assert_equal(s0, _ALPHA)
    assert_equal(e0, 1000)

    # On the first change, which is inclusive at the start.
    var n1, o1, s1, e1, d1 = loc.lookup(1000)
    assert_equal(n1, "B")
    assert_equal(o1, 3600)
    assert_equal(s1, 1000)
    assert_equal(e1, 2000)
    assert_true(d1)

    # One second before the second change, still in B.
    var n2, _o2, _s2, _e2, _d2 = loc.lookup(1999)
    assert_equal(n2, "B")

    # Between the second and third.
    var n3, o3, s3, e3, _d3 = loc.lookup(2500)
    assert_equal(n3, "C")
    assert_equal(o3, 7200)
    assert_equal(s3, 2000)
    assert_equal(e3, 3000)

    # After the last change, which runs to the end of time because there is no
    # extend string on this location.
    var n4, o4, s4, e4, _d4 = loc.lookup(9_999_999)
    assert_equal(n4, "A")
    assert_equal(o4, 0)
    assert_equal(s4, 3000)
    assert_equal(e4, _OMEGA)


def test_the_first_zone_skips_an_unused_placeholder() raises:
    """tzcode's rule, which is why this is not just `zone[0]`.

    A file whose first zone no transition ever names has it there as a
    placeholder, and that placeholder is exactly what should be reported for
    the time before the first change. Here zone 0 is named by nothing, so an
    instant before the first transition is zone 0 and not the first standard
    zone after it.
    """
    var zones: List[Zone] = [
        Zone("LMT", 3208, False),
        Zone("CET", 3600, False),
        Zone("CEST", 7200, True),
    ]
    var txs: List[ZoneTrans] = [ZoneTrans(1000, 1), ZoneTrans(2000, 2)]
    var loc = Location("placeholder", zones^, txs^, "")

    var name, off, _s, _e, _d = loc.lookup(0)
    assert_equal(name, "LMT")
    assert_equal(off, 3208)


def test_lookup_name_finds_a_zone_by_its_abbreviation() raises:
    """Go's `lookupName`, which the parser will need.

    The instant matters because two zones of one location can share a name, so
    the first pass asks which zone was actually in force and only the second
    settles for any zone that matches.
    """
    var zones: List[Zone] = [
        Zone("EST", -18000, False),
        Zone("EDT", -14400, True),
    ]
    var txs: List[ZoneTrans] = [ZoneTrans(1000, 1)]
    var loc = Location("America/Somewhere", zones^, txs^, "")

    var edt_off, edt_ok = loc.lookup_name("EDT", 100_000)
    assert_true(edt_ok)
    assert_equal(edt_off, -14400)

    # Before the change, so the first pass does not find EDT in force and the
    # second pass returns its offset anyway.
    var early_off, early_ok = loc.lookup_name("EDT", 0)
    assert_true(early_ok)
    assert_equal(early_off, -14400)

    var est_off, est_ok = loc.lookup_name("EST", 0)
    assert_true(est_ok)
    assert_equal(est_off, -18000)

    var _off, ok = loc.lookup_name("XYZ", 0)
    assert_true(not ok)


def test_a_copied_location_answers_the_same_way() raises:
    """A `Location` is a value here, not a pointer.

    Copying one copies its two lists, which is the cost of the design and is
    worth a row saying it works. The copy has to be asked for: `Location` is
    `Copyable` and not `ImplicitlyCopyable`, because a `List` is, so the two
    allocations never happen by accident in the way a passed pointer never
    allocates in Go. The copy is independent, and the cache carried across it
    is still valid because it describes an instant rather than a position in a
    list.
    """
    var original = fixed_zone("CET", 3600)
    var copy = original.copy()
    assert_equal(String(copy), "CET")

    var name, off, _s, _e, _d = copy.lookup(1_700_000_000)
    assert_equal(name, "CET")
    assert_equal(off, 3600)

    var oname, ooff, _os, _oe, _od = original.lookup(1_700_000_000)
    assert_equal(oname, "CET")
    assert_equal(ooff, 3600)


def test_two_zones_are_equal_when_all_three_fields_match() raises:
    """`Zone` and `ZoneTrans` are comparable, which the tests above rely on."""
    assert_true(Zone("CET", 3600, False) == Zone("CET", 3600, False))
    assert_true(Zone("CET", 3600, False) != Zone("CET", 3600, True))
    assert_true(Zone("CET", 3600, False) != Zone("CEST", 3600, False))
    assert_true(Zone("CET", 3600, False) != Zone("CET", 7200, False))
    assert_true(ZoneTrans(1, 2) == ZoneTrans(1, 2))
    assert_true(ZoneTrans(1, 2) != ZoneTrans(1, 3))
