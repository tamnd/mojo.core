"""Writing an instant out as bytes and reading it back, against what Go writes
and reads for the same instant.

Every hex string, every piece of text and every message here came from running
Go over the same value, so a row that passes is a row that crosses between the
two languages: bytes this library writes are bytes Go's `UnmarshalBinary` takes,
and the other way round.

Two things here are host dependent and are handled rather than avoided. The
binary form records a zone offset and no zone name, so what comes back out is
UTC, the host's own zone, or a nameless fixed zone, depending on what the host
is set to. A row that reads bytes back therefore checks the Unix second, the
nanosecond and the offset, which are the same everywhere, and checks the zone
name only for the UTC marker, which is the one case with an answer. The zones
that need a name come from the Europe/Berlin fixture rather than from the host's
database, for the reason `test_parse.mojo` gives.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from tests.generated.tzif import BERLIN_2020B, bytes_of

from core.errors import matches
from core.errors.codes import ErrMarshalTime, ErrUnmarshalTime
from core.time import (
    DECEMBER,
    JANUARY,
    JULY,
    MARCH,
    Location,
    Time,
    date,
    fixed_zone,
    load_location_from_tz_data,
    unix,
    utc,
)


def _berlin() raises -> Location:
    """Europe/Berlin as of tzdata 2020b, from the fixture rather than the host.
    """
    var data = bytes_of(BERLIN_2020B)
    return load_location_from_tz_data("Europe/Berlin", Span(data))


def _hex(b: List[UInt8]) -> String:
    """`b` as lower case hex, the form the expectations are written in."""
    comptime digits = "0123456789abcdef"
    var out = List[UInt8](capacity=len(b) * 2)
    for i in range(len(b)):
        out.append(digits.as_bytes()[Int(b[i] >> 4)])
        out.append(digits.as_bytes()[Int(b[i] & 0xF)])
    return String(from_utf8_lossy=Span(out))


def _text(t: Time) raises -> String:
    """`t` through `marshal_text`, as a string."""
    var out = t.marshal_text()
    return String(from_utf8_lossy=Span(out))


def _json(t: Time) raises -> String:
    """`t` through `marshal_json`, as a string."""
    var out = t.marshal_json()
    return String(from_utf8_lossy=Span(out))


def _read_binary(hex: String) raises -> Time:
    """The instant the hex spells, through `unmarshal_binary`."""
    var data = bytes_of(hex)
    var t = Time()
    t.unmarshal_binary(Span(data))
    return t


def _read_text(s: String) raises -> Time:
    """The instant `s` spells, through `unmarshal_text`."""
    var t = Time()
    t.unmarshal_text(s.as_bytes())
    return t


# The instant most rows use, and the one Go's own tests reach for: a Tuesday
# afternoon with every field different from every other.
comptime _REF_UNIX = 1_709_993_106
comptime _REF_NSEC = 78_901_234


def test_marshal_binary_utc() raises:
    """The plain case, fifteen bytes with the UTC marker at the end."""
    var t = date(2024, MARCH, 9, 14, 5, 6, _REF_NSEC, utc())
    assert_equal(_hex(t.marshal_binary()), "010000000edd7e639204b3eff2ffff")


def test_marshal_binary_named_zone() raises:
    """A zone with a name writes the offset that was in force, not the name.

    Berlin in July and Berlin in January are the same location and two
    different offsets, and the bytes differ only in those last two.
    """
    var berlin = _berlin()
    var summer = date(2024, JULY, 1, 12, 0, 0, 0, berlin)
    var winter = date(2024, JANUARY, 1, 12, 0, 0, 0, berlin)
    assert_equal(
        _hex(summer.marshal_binary()), "010000000ede147520000000000078"
    )
    assert_equal(
        _hex(winter.marshal_binary()), "010000000edd24923000000000003c"
    )


def test_marshal_binary_seconds_in_the_offset() raises:
    """An offset that is not a whole minute is version 2 and sixteen bytes.

    Berlin before the railways kept local mean time, 53 minutes and 28 seconds
    east, and the 28 is the sixteenth byte. Every zone file starts with an entry
    like this one, so the long form is ordinary rather than exotic.
    """
    var t = date(1800, JANUARY, 1, 0, 0, 0, 0, _berlin())
    var out = t.marshal_binary()
    assert_equal(len(out), 16)
    assert_equal(_hex(out), "020000000d37cfa9f80000000000351c")


def test_marshal_binary_fixed_zone() raises:
    """A fixed zone writes its offset and loses its name."""
    var minus = date(2024, MARCH, 9, 14, 5, 6, 0, fixed_zone("", -27000))
    var xyz = date(2024, MARCH, 9, 14, 5, 6, 0, fixed_zone("XYZ", 3600))
    assert_equal(_hex(minus.marshal_binary()), "010000000edd7ecd0a00000000fe3e")
    assert_equal(_hex(xyz.marshal_binary()), "010000000edd7e558200000000003c")


def test_marshal_binary_edges() raises:
    """The zero instant, the Unix epoch, and an instant before the year 1.

    The seconds are counted from the year 1, so year 0 is the row where the
    eight of them are negative and the sign has to survive both directions.
    """
    assert_equal(
        _hex(Time().marshal_binary()), "01000000000000000000000000ffff"
    )
    assert_equal(
        _hex(unix(0, 0).utc().marshal_binary()),
        "010000000e7791f70000000000ffff",
    )
    assert_equal(
        _hex(date(0, JANUARY, 1, 0, 0, 0, 0, utc()).marshal_binary()),
        "01fffffffffe1d7b0000000000ffff",
    )
    assert_equal(
        _read_binary("01fffffffffe1d7b0000000000ffff").unix(), -62_167_219_200
    )


def test_marshal_binary_offset_too_large() raises:
    """An offset past what two bytes of minutes can hold has no binary form."""
    var t = date(2024, MARCH, 9, 14, 5, 6, 0, fixed_zone("", 32768 * 60))
    with assert_raises(contains="unexpected zone offset"):
        _ = t.marshal_binary()

    try:
        _ = t.marshal_binary()
    except e:
        assert_true(matches(e, ErrMarshalTime))


def test_append_binary_returns_the_count() raises:
    """`append_binary` appends and says how many bytes, leaving what was
    there."""
    var buf = List[UInt8]()
    buf.append(0xAA)
    var t = date(2024, MARCH, 9, 14, 5, 6, _REF_NSEC, utc())
    assert_equal(t.append_binary(buf), 15)
    assert_equal(len(buf), 16)
    assert_equal(buf[0], 0xAA)
    assert_equal(_hex(buf), "aa010000000edd7e639204b3eff2ffff")


def test_append_binary_writes_nothing_when_it_fails() raises:
    """A list handed to a failing call is the list it was."""
    var buf = List[UInt8]()
    buf.append(0xAA)
    var t = date(2024, MARCH, 9, 14, 5, 6, 0, fixed_zone("", 32768 * 60))
    with assert_raises(contains="unexpected zone offset"):
        _ = t.append_binary(buf)
    assert_equal(len(buf), 1)


def test_unmarshal_binary_utc() raises:
    """The UTC marker comes back as UTC, name and all."""
    var t = _read_binary("010000000edd7e639204b3eff2ffff")
    assert_equal(t.unix(), _REF_UNIX)
    assert_equal(t.nanosecond(), _REF_NSEC)
    assert_equal(t.zone()[0], "UTC")
    assert_equal(t.zone()[1], 0)


def test_unmarshal_binary_offset() raises:
    """An offset that is not the marker comes back as an offset.

    Whether the zone has a name depends on the host: an offset that matches
    what the host was using at that instant gives the host's zone. The offset
    is the same either way and is what the bytes actually recorded.
    """
    var t = _read_binary("010000000edd7e558200000000003c")
    assert_equal(t.unix(), 1_709_989_506)
    assert_equal(t.nanosecond(), 0)
    assert_equal(t.zone()[1], 3600)


def test_unmarshal_binary_round_trip() raises:
    """Every instant above survives being written and read back."""
    var berlin = _berlin()
    var values = List[Time]()
    values.append(date(2024, MARCH, 9, 14, 5, 6, _REF_NSEC, utc()))
    values.append(date(2024, JULY, 1, 12, 0, 0, 0, berlin))
    values.append(date(2024, JANUARY, 1, 12, 0, 0, 0, berlin))
    values.append(date(1800, JANUARY, 1, 0, 0, 0, 0, berlin))
    values.append(date(2024, MARCH, 9, 14, 5, 6, 0, fixed_zone("", -27000)))
    values.append(Time())
    values.append(unix(0, 0).utc())

    for want in values:
        var data = want.marshal_binary()
        var got = Time()
        got.unmarshal_binary(Span(data))
        assert_equal(got.unix(), want.unix())
        assert_equal(got.nanosecond(), want.nanosecond())
        assert_equal(got.zone()[1], want.zone()[1])


def test_unmarshal_binary_refuses() raises:
    """The three ways the bytes can be wrong, with the message Go uses."""
    var rows = List[Tuple[String, String]]()
    rows.append(("", "no data"))
    rows.append(("030000000edd7e639204b3eff2ffff", "unsupported version"))
    rows.append(("010000000edd7e639204b3eff2ff", "invalid length"))
    rows.append(("010000000edd7e639204b3eff2ffff00", "invalid length"))
    rows.append(("020000000edd7e639204b3eff2ffff", "invalid length"))

    for row in rows:
        var hex, want = row
        with assert_raises(contains=want):
            _ = _read_binary(hex)

        try:
            _ = _read_binary(hex)
        except e:
            assert_true(matches(e, ErrUnmarshalTime))


def test_unmarshal_binary_writes_nothing_when_it_fails() raises:
    """A value handed to a failing call is the value it was."""
    var t = date(2024, MARCH, 9, 14, 5, 6, 0, utc())
    var data = bytes_of("030000000edd7e639204b3eff2ffff")
    with assert_raises(contains="unsupported version"):
        t.unmarshal_binary(Span(data))
    assert_equal(t.unix(), _REF_UNIX)


def test_gob_is_the_binary_form() raises:
    """`gob_encode` and `gob_decode` are the other two names for the pair."""
    var t = date(2024, MARCH, 9, 14, 5, 6, _REF_NSEC, utc())
    assert_equal(_hex(t.gob_encode()), _hex(t.marshal_binary()))

    var data = t.gob_encode()
    var got = Time()
    got.gob_decode(Span(data))
    assert_equal(got.unix(), _REF_UNIX)
    assert_equal(got.nanosecond(), _REF_NSEC)


def test_marshal_text() raises:
    """RFC 3339, with as many digits of fraction as the value has."""
    var berlin = _berlin()
    assert_equal(
        _text(date(2024, MARCH, 9, 14, 5, 6, _REF_NSEC, utc())),
        "2024-03-09T14:05:06.078901234Z",
    )
    assert_equal(
        _text(date(2024, JULY, 1, 12, 0, 0, 0, berlin)),
        "2024-07-01T12:00:00+02:00",
    )
    assert_equal(
        _text(date(2024, JANUARY, 1, 12, 0, 0, 0, berlin)),
        "2024-01-01T12:00:00+01:00",
    )
    assert_equal(
        _text(date(1800, JANUARY, 1, 0, 0, 0, 0, berlin)),
        "1800-01-01T00:00:00+00:53",
    )
    assert_equal(
        _text(date(2024, MARCH, 9, 14, 5, 6, 0, fixed_zone("", -27000))),
        "2024-03-09T14:05:06-07:30",
    )
    assert_equal(_text(Time()), "0001-01-01T00:00:00Z")


def test_marshal_text_year_edges() raises:
    """Year 0 and year 9999 are inside the range and are written."""
    assert_equal(
        _text(date(0, JANUARY, 1, 0, 0, 0, 0, utc())), "0000-01-01T00:00:00Z"
    )
    assert_equal(
        _text(date(9999, DECEMBER, 31, 23, 59, 59, 999_999_999, utc())),
        "9999-12-31T23:59:59.999999999Z",
    )


def test_marshal_json_is_the_text_in_quotes() raises:
    """No escaping, because RFC 3339 has nothing JSON would escape."""
    assert_equal(
        _json(date(2024, MARCH, 9, 14, 5, 6, _REF_NSEC, utc())),
        '"2024-03-09T14:05:06.078901234Z"',
    )
    assert_equal(_json(Time()), '"0001-01-01T00:00:00Z"')


def test_marshal_text_refuses() raises:
    """The two instants with no RFC 3339 spelling, and the name in front.

    Go names the method in the message and so does this, which is how a caller
    who sees it in a log knows which of the three it came out of.
    """
    var early = date(-1, JANUARY, 1, 0, 0, 0, 0, utc())
    var late = date(10000, JANUARY, 1, 0, 0, 0, 0, utc())
    var day_east = date(2024, MARCH, 9, 14, 5, 6, 0, fixed_zone("", 24 * 3600))
    var day_west = date(2024, MARCH, 9, 14, 5, 6, 0, fixed_zone("", -24 * 3600))

    with assert_raises(
        contains="Time.marshal_text: year outside of range [0,9999]"
    ):
        _ = early.marshal_text()
    with assert_raises(
        contains="Time.marshal_text: year outside of range [0,9999]"
    ):
        _ = late.marshal_text()
    with assert_raises(
        contains="Time.marshal_json: year outside of range [0,9999]"
    ):
        _ = early.marshal_json()

    with assert_raises(
        contains="Time.marshal_text: timezone hour outside of range [0,23]"
    ):
        _ = day_east.marshal_text()
    with assert_raises(
        contains="Time.marshal_text: timezone hour outside of range [0,23]"
    ):
        _ = day_west.marshal_text()

    try:
        _ = late.marshal_text()
    except e:
        assert_true(matches(e, ErrMarshalTime))


def test_append_text() raises:
    """`append_text` appends, says how many bytes, and names itself when it
    fails."""
    var buf = List[UInt8]()
    buf.append(UInt8(ord("[")))
    var t = date(2024, MARCH, 9, 14, 5, 6, 0, utc())
    assert_equal(t.append_text(buf), 20)
    assert_equal(String(from_utf8_lossy=Span(buf)), "[2024-03-09T14:05:06Z")

    var late = date(10000, JANUARY, 1, 0, 0, 0, 0, utc())
    with assert_raises(
        contains="Time.append_text: year outside of range [0,9999]"
    ):
        _ = late.append_text(buf)
    assert_equal(len(buf), 21)


def test_unmarshal_text() raises:
    """What Go's reader takes, including the comma the RFC allows as a decimal
    point."""
    var t = _read_text("2024-03-09T14:05:06.078901234Z")
    assert_equal(t.unix(), _REF_UNIX)
    assert_equal(t.nanosecond(), _REF_NSEC)

    var comma = _read_text("2024-03-09T14:05:06,078Z")
    assert_equal(comma.unix(), _REF_UNIX)
    assert_equal(comma.nanosecond(), 78_000_000)

    var offset = _read_text("2024-07-01T12:00:00+02:00")
    assert_equal(offset.unix(), 1_719_828_000)
    assert_equal(offset.zone()[1], 7200)


def test_unmarshal_text_refuses() raises:
    """RFC 3339 and nothing else, with the layout named in the message."""
    var rows = List[Tuple[String, String]]()
    rows.append(("2024-03-09t14:05:06Z", 'cannot parse "t14:05:06Z" as "T"'))
    rows.append(("2024-03-09T14:05:06z", 'cannot parse "z" as "Z07:00"'))
    rows.append(("2024-03-09T14:05:06", 'cannot parse "" as "Z07:00"'))
    rows.append(
        ("2024-03-09T14:05:06+25:00", "time zone offset hour out of range")
    )
    rows.append(("", 'cannot parse "" as "2006"'))
    rows.append(("nonsense", 'cannot parse "nonsense" as "2006"'))

    for row in rows:
        var value, want = row
        with assert_raises(contains=want):
            _ = _read_text(value)


def test_unmarshal_json() raises:
    """A quoted timestamp, and a null that changes nothing."""
    var t = Time()
    t.unmarshal_json('"2024-03-09T14:05:06Z"'.as_bytes())
    assert_equal(t.unix(), _REF_UNIX)

    t.unmarshal_json("null".as_bytes())
    assert_equal(t.unix(), _REF_UNIX)


def test_unmarshal_json_refuses() raises:
    """Anything that is not a quoted string, before the timestamp is looked
    at."""
    var rows = List[String]()
    rows.append("2024-03-09T14:05:06Z")
    rows.append('"2024-03-09T14:05:06Z')
    rows.append('2024-03-09T14:05:06Z"')
    rows.append('"')
    rows.append("")

    for value in rows:
        var t = Time()
        with assert_raises(contains="input is not a JSON string"):
            t.unmarshal_json(value.as_bytes())

        try:
            t.unmarshal_json(value.as_bytes())
        except e:
            assert_true(matches(e, ErrUnmarshalTime))


def test_unmarshal_json_keeps_the_value_when_the_inside_is_wrong() raises:
    """A quoted string that is not RFC 3339 raises and leaves the value alone.

    Go clears the value here, because its `UnmarshalText` assigns the zero time
    before it looks at the error. `docs/deviations.md` has the row.
    """
    var t = date(2024, MARCH, 9, 14, 5, 6, 0, utc())
    with assert_raises(contains='cannot parse "nonsense" as "2006"'):
        t.unmarshal_json('"nonsense"'.as_bytes())
    assert_equal(t.unix(), _REF_UNIX)


def test_go_string() raises:
    """The `date` call that would build the value again."""
    assert_equal(
        date(2024, MARCH, 9, 14, 5, 6, _REF_NSEC, utc()).go_string(),
        "date(2024, MARCH, 9, 14, 5, 6, 78901234, utc())",
    )
    assert_equal(
        date(2024, JULY, 1, 12, 0, 0, 0, _berlin()).go_string(),
        'date(2024, JULY, 1, 12, 0, 0, 0, location("Europe/Berlin"))',
    )
    assert_equal(
        date(2024, MARCH, 9, 14, 5, 6, 0, fixed_zone("XYZ", 3600)).go_string(),
        'date(2024, MARCH, 9, 14, 5, 6, 0, location("XYZ"))',
    )
    assert_equal(
        date(2024, MARCH, 9, 14, 5, 6, 0, fixed_zone("", -27000)).go_string(),
        'date(2024, MARCH, 9, 14, 5, 6, 0, location(""))',
    )
    assert_equal(Time().go_string(), "date(1, JANUARY, 1, 0, 0, 0, 0, utc())")


def test_go_string_quotes_the_name() raises:
    """A name with a quote in it is escaped, so the call is still one
    argument."""
    assert_equal(
        date(2024, MARCH, 9, 14, 5, 6, 0, fixed_zone('a"b', 0)).go_string(),
        'date(2024, MARCH, 9, 14, 5, 6, 0, location("a\\"b"))',
    )


def test_is_dst() raises:
    """The flag the zone file carries, not a guess from the offset."""
    var berlin = _berlin()
    assert_true(date(2024, JULY, 1, 12, 0, 0, 0, berlin).is_dst())
    assert_false(date(2024, JANUARY, 1, 12, 0, 0, 0, berlin).is_dst())
    assert_false(date(2024, JULY, 1, 12, 0, 0, 0, utc()).is_dst())
    assert_false(
        date(2024, JULY, 1, 12, 0, 0, 0, fixed_zone("CEST", 7200)).is_dst()
    )


def test_local_is_in_location_local() raises:
    """`local` moves the zone and not the instant."""
    var t = date(2024, MARCH, 9, 14, 5, 6, _REF_NSEC, utc())
    var here = t.local()
    assert_equal(here.unix(), t.unix())
    assert_equal(here.nanosecond(), t.nanosecond())
    assert_true(here == t)
