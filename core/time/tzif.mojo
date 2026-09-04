"""Reading a compiled zone file. Go's `LoadLocationFromTZData`.

The format is TZif, described in tzfile(5), and it is what `/etc/localtime` and
everything under `/usr/share/zoneinfo` is written in. A file is a header saying
how many of each thing follows, then the transition times, then which zone each
transition moves to, then the zones, then the abbreviation text they point into,
then two sections nothing here reads, then optionally a TZ string on a line of
its own.

Version 2 and later write the whole body twice, once with 32 bit transition
times and once with 64 bit ones, and the second copy is the one to read: the
first stops in 2038 and the second does not. So this skips a block whose length
it works out from the first header, reads the header again, and parses from
there. Version 1 has only the 32 bit copy. Nothing else is accepted: a version
byte this does not know is refused rather than guessed at.

## What is not read

Leap seconds, and the two arrays saying whether each transition was recorded in
standard time or in UTC. The leap second table is skipped because nothing in
this library models a leap second, which is the same choice Go makes and which
`calendar.mojo` explains. The other two Go reads and never looks at, and its own
comment says it does not know what they are for, so they are skipped here.

## Failure

One error, `ErrBadZoneData`, for everything. The file is either a zone file or
it is not, and a caller who passed a JPEG is not helped by being told which
field ran out of bytes. What matters is that this raises rather than reading
past the end of the data, which is what Go's issue 29437 was about: a header
claiming zero zones used to produce a location that crashed on first use.
"""

from core.errors import Report
from core.errors.codes import ErrBadZoneData

from .tzset import _ALPHA
from .zone import Location, Zone, ZoneTrans


comptime _NEWLINE = UInt8(ord("\n"))

comptime _N_UTC_LOCAL = 0
"""How many entries say whether a transition was recorded in UTC. Skipped."""

comptime _N_STD_WALL = 1
"""How many entries say whether a transition was recorded in standard time.
Skipped."""

comptime _N_LEAP = 2
"""How many leap second corrections follow. Skipped."""

comptime _N_TIME = 3
"""How many transitions follow."""

comptime _N_ZONE = 4
"""How many zones follow."""

comptime _N_CHAR = 5
"""How many bytes of abbreviation text follow."""


struct _Data[o: Origin](Copyable, Movable):
    """A read position in the file, with a flag for having run off the end.

    Go's `dataIO`. Every read moves forward, and a read that cannot be satisfied
    sets the flag and gives back nothing, so the parsing below can read the
    whole file and ask once at the end whether any of it worked. That shape is
    worth keeping: the alternative is a check after each of about twenty reads.
    """

    var p: Span[UInt8, Self.o]
    """What has not been read yet."""

    var failed: Bool
    """Whether a read has run past the end."""

    def __init__(out self, p: Span[UInt8, Self.o]):
        """Start at the front of `p`."""
        self.p = p
        self.failed = False

    def read(mut self, n: Int) -> Span[UInt8, Self.o]:
        """The next `n` bytes, or nothing if there are not that many."""
        if n < 0 or len(self.p) < n:
            self.p = self.p[0:0]
            self.failed = True
            return self.p
        var head = self.p[0:n]
        self.p = self.p[n : len(self.p)]
        return head

    def big4(mut self) -> Tuple[UInt32, Bool]:
        """The next four bytes as a big endian number."""
        var p = self.read(4)
        if len(p) < 4:
            self.failed = True
            return (UInt32(0), False)
        return (
            UInt32(p[3])
            | (UInt32(p[2]) << 8)
            | (UInt32(p[1]) << 16)
            | (UInt32(p[0]) << 24),
            True,
        )

    def big8(mut self) -> Tuple[UInt64, Bool]:
        """The next eight bytes as a big endian number."""
        var hi, hi_ok = self.big4()
        var lo, lo_ok = self.big4()
        if not hi_ok or not lo_ok:
            self.failed = True
            return (UInt64(0), False)
        return ((UInt64(hi) << 32) | UInt64(lo), True)

    def next_byte(mut self) -> Tuple[UInt8, Bool]:
        """The next byte on its own."""
        var p = self.read(1)
        if len(p) < 1:
            self.failed = True
            return (UInt8(0), False)
        return (p[0], True)

    def rest(mut self) -> Span[UInt8, Self.o]:
        """Everything left, leaving nothing behind."""
        var tail = self.p
        self.p = self.p[0:0]
        return tail


def load_location_from_tz_data[
    o: Origin
](name: StringSlice, data: Span[UInt8, o]) raises -> Location:
    """A location built from the contents of a compiled zone file.

    ```mojo
    from core.time import fixed_zone
    ```

    Go's `LoadLocationFromTZData`. `name` is what to call the result and is not
    read out of the file, because a zone file does not carry its own name: the
    name of `/usr/share/zoneinfo/Europe/Berlin` is the path it was found at.

    Raises `ErrBadZoneData` if the data is not a zone file this can read.
    """
    var d = _Data(data)

    if String(from_utf8_lossy=d.read(4)) != "TZif":
        raise _bad_data()

    # A version byte and fifteen bytes of padding. Version 1 writes a zero here
    # and later versions write the digit, which is the only thing this has to
    # care about: what versions 3 and 4 added are leap second rules and TZ
    # string forms, neither of which changes the layout read below.
    var header = d.read(16)
    if len(header) != 16:
        raise _bad_data()
    var version: Int
    if header[0] == 0:
        version = 1
    elif header[0] == UInt8(ord("2")):
        version = 2
    elif header[0] == UInt8(ord("3")):
        version = 3
    else:
        raise _bad_data()

    var n = _counts(d)
    var is_64 = False
    if version > 1:
        # Skip the 32 bit copy of the whole body, and the four byte magic and
        # sixteen byte header that come before the copy that matters.
        var skip = (
            n[_N_TIME] * 4
            + n[_N_TIME]
            + n[_N_ZONE] * 6
            + n[_N_CHAR]
            + n[_N_LEAP] * 8
            + n[_N_STD_WALL]
            + n[_N_UTC_LOCAL]
            + 4
            + 16
        )
        _ = d.read(skip)
        is_64 = True
        # The counts are written again, and the two copies are allowed to
        # disagree, so the second set is the one everything below uses.
        n = _counts(d)

    var size = 8 if is_64 else 4

    var tx_times = _Data(d.read(n[_N_TIME] * size))
    var tx_zones = d.read(n[_N_TIME])
    var zone_data = _Data(d.read(n[_N_ZONE] * 6))
    var abbrev = d.read(n[_N_CHAR])
    _ = d.read(n[_N_LEAP] * (size + 4))
    _ = d.read(n[_N_STD_WALL])
    _ = d.read(n[_N_UTC_LOCAL])
    if d.failed:
        raise _bad_data()

    # The TZ string, if there is one, is a line of its own at the very end.
    var extend = String()
    var tail = d.rest()
    if (
        len(tail) > 2
        and tail[0] == _NEWLINE
        and tail[len(tail) - 1] == _NEWLINE
    ):
        extend = String(from_utf8_lossy=tail[1 : len(tail) - 1])

    # A file with no zones in it has nothing in it. Refused here rather than
    # later, because the fake transition added below would otherwise name a
    # zone that does not exist. That was Go's issue 29437.
    if n[_N_ZONE] == 0:
        raise _bad_data()

    var zones = List[Zone]()
    for _i in range(n[_N_ZONE]):
        var raw_offset, offset_ok = zone_data.big4()
        if not offset_ok:
            raise _bad_data()

        var dst, dst_ok = zone_data.next_byte()
        if not dst_ok:
            raise _bad_data()

        var at, at_ok = zone_data.next_byte()
        if not at_ok or Int(at) >= len(abbrev):
            raise _bad_data()

        zones.append(
            Zone(
                _abbrev_at(abbrev, Int(at)),
                Int(Int32(raw_offset)),
                dst != 0,
            )
        )

    var txs = List[ZoneTrans]()
    for i in range(n[_N_TIME]):
        var when: Int
        if is_64:
            var got, ok = tx_times.big8()
            if not ok:
                raise _bad_data()
            when = Int(Int64(got))
        else:
            var got, ok = tx_times.big4()
            if not ok:
                raise _bad_data()
            when = Int(Int32(got))
        if Int(tx_zones[i]) >= len(zones):
            raise _bad_data()
        txs.append(ZoneTrans(when, Int(tx_zones[i])))

    if len(txs) == 0:
        # A location that never changes, such as `Etc/GMT0`, records no
        # transitions at all. One covering all of time makes the lookup in
        # `zone.mojo` the same code for that file as for every other.
        txs.append(ZoneTrans(_ALPHA, 0))

    var loc = Location(name, zones^, txs^, extend)
    loc._fill_cache()
    return loc^


def _counts[o: Origin](mut d: _Data[o]) -> List[Int]:
    """The six big endian counts that make up a header.

    A read that fails leaves `d` marked and gives a zero back, which the caller
    notices when it asks `d` at the end. That is why this does not raise: these
    six reads and the twenty after them are checked together.
    """
    var n = List[Int]()
    for _i in range(6):
        var got, ok = d.big4()
        n.append(Int(got) if ok else 0)
    return n^


def _abbrev_at[o: Origin](abbrev: Span[UInt8, o], at: Int) -> String:
    """The zone abbreviation starting at `at`, which ends at the first NUL.

    Go's `byteString`. The abbreviations are one run of bytes with a NUL after
    each, and a zone points at a byte within that run rather than at a whole
    entry, so `EST` and `ST` can share the same three bytes and often do.

    Built lossily, so a file with a byte that is not UTF-8 in an abbreviation
    loads with a replacement character in the name rather than failing. Go does
    no decoding at all here and takes the bytes as they are, and refusing a file
    Go accepts would be the larger difference of the two.
    """
    var end = at
    while end < len(abbrev) and abbrev[end] != 0:
        end += 1
    return String(from_utf8_lossy=abbrev[at:end])


def _bad_data() -> Error:
    """The one raise this file makes, carrying `ErrBadZoneData`.

    Go's message, unchanged, so that a program logging it says what a Go program
    logging it says.
    """
    return (
        Report("malformed time zone information")
        .with_code(ErrBadZoneData)
        .error()
    )
