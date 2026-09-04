"""Our side of the `time-zones` differ area.

One line per instant, holding every answer this package gives about it in a
real time zone: the calendar fields, the zone name and offset, both zone
bounds, the printed form, the wall clock reading turned back into an instant by
`date`, and the same date a month later. The Go program in
`tools/differ/go/timezones` prints the same line from Go's `time`, and the two
files have to be read together, because the whole check is that the formatting
is identical and only the answers can differ.

The four locations are the four slim TZif files vendored under
`tests/data/go-time`, read here through `load_location_from_tz_data` from the
hex tables the test generator emits. Neither side touches the host's zone
database, so the check gives the same answer on a machine with no
`/usr/share/zoneinfo` at all.

`--count` is how many instants to print and `--seed` picks the stream. The
instant is a splitmix64 word folded into 1880 to 2120, which reaches the local
mean time zone at the front of every file and the trailing POSIX rule at the
back of the slim ones.
"""

from std.sys import argv

from core.time import Location, Time, date, load_location_from_tz_data, unix

from tests.generated.tzif import (
    BERLIN_2020B,
    DUBLIN_2021A,
    GAZA_2021A,
    NUUK_2021A,
    bytes_of,
)

comptime _CHUNK = 4096
"""How many lines to hold before writing. A print per line turns a check that
takes seconds into one that takes minutes."""

comptime _GAP = UInt64(2862933555777941757)
"""The stride between one instant's seed and the next. Knuth's multiplier, used
here only because two adjacent seeds have to land far apart."""

comptime _FIRST = -2840140800
"""1880-01-01, before anything any of these four files describes."""

comptime _LAST = 4733510400
"""2120-01-01, past the last transition every one of them records."""


def _flag(name: String, fallback: Int) raises -> Int:
    """One `--name value` argument, or `fallback` when it is not there."""
    var args = argv()
    for index in range(len(args)):
        if String(args[index]) == name and index + 1 < len(args):
            return Int(String(args[index + 1]))
    return fallback


def _mix(state: UInt64) -> UInt64:
    """One splitmix64 step. The same three lines are in the Go program."""
    var z = state + 0x9E3779B97F4A7C15
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    return z ^ (z >> 31)


def _pad(value: Int, width: Int) -> String:
    """`value` in decimal, zero padded to `width`, as Go's `%0*d`."""
    var digits = String(abs(value))
    var out = String("-") if value < 0 else String()
    for _ in range(width - digits.byte_length()):
        out += "0"
    out += digits
    return out


def _bound(t: Time) -> String:
    """A bound as the line writes it: the Unix second, or `none`.

    Go leaves the zero `Time` where a zone has no bound on that side and so
    does this, and the word is written out rather than printing the zero
    time's Unix second, because that number looks like an answer and is not
    one.
    """
    if t.is_zero():
        return String("none")
    return String(t.unix())


def main() raises:
    var count = _flag("--count", 10000)
    var seed = _flag("--seed", 1)

    # The order is the order the Go program has them in, since the low bits of
    # each word pick between them by index.
    var berlin = bytes_of(BERLIN_2020B)
    var nuuk = bytes_of(NUUK_2021A)
    var gaza = bytes_of(GAZA_2021A)
    var dublin = bytes_of(DUBLIN_2021A)
    var names: List[String] = [
        String("Europe/Berlin"),
        String("America/Nuuk"),
        String("Asia/Gaza"),
        String("Europe/Dublin"),
    ]
    var locs: List[Location] = [
        load_location_from_tz_data(names[0], Span(berlin)),
        load_location_from_tz_data(names[1], Span(nuuk)),
        load_location_from_tz_data(names[2], Span(gaza)),
        load_location_from_tz_data(names[3], Span(dublin)),
    ]

    var out = String()
    for i in range(count):
        var w = _mix(UInt64(seed) + UInt64(i) * _GAP + 1)
        var which = Int(w & 3)
        var sec = _FIRST + Int((w >> 2) % UInt64(_LAST - _FIRST))

        var t = unix(sec, 0).in_location(locs[which])
        var name, offset = t.zone()
        var start, end = t.zone_bounds()
        var year, month, day = t.date()
        var hour, minute, second = t.clock()

        # The wall clock reading put back through `date`, which is the inverse
        # of everything above it and the one that goes wrong on the hours
        # daylight saving skips or repeats.
        var back = date(
            year, month, day, hour, minute, second, 0, locs[which]
        )

        out += names[which]
        out += " "
        out += String(sec)
        out += " "
        out += _pad(year, 4)
        out += "-"
        out += _pad(month.value, 2)
        out += "-"
        out += _pad(day, 2)
        out += " "
        out += _pad(hour, 2)
        out += ":"
        out += _pad(minute, 2)
        out += ":"
        out += _pad(second, 2)
        out += " "
        out += String(t.weekday())
        out += " "
        out += String(t.year_day())
        out += " "
        out += name
        out += " "
        out += String(offset)
        out += " "
        out += _bound(start)
        out += " "
        out += _bound(end)
        out += " "
        out += String(back.unix())
        out += " | "
        out += String(t)
        out += " | "
        out += String(t.add_date(0, 1, 0))
        out += "\n"

        if i % _CHUNK == _CHUNK - 1:
            print(out, end="")
            out = String()

    print(out, end="")
