"""The layout language, and writing an instant out with it.

A layout is not a pattern of letters standing for fields. It is one particular
instant, written the way the answer should be written. That instant is January
2 2006 at 3:04:05 in the afternoon, seven hours west of UTC, and the reason it
is that one and not another is that its parts written in order are the numbers
one to seven: `01/02 03:04:05PM '06 -0700`.

So the layout for a date like `2024-03-09` is the reference date written the
same way, `2006-01-02`, and everything in the layout that is not a piece of the
reference instant is copied through as it stands.

```mojo
from core.time import MARCH, date

var t = date(2024, MARCH, 9, 14, 5, 6, 0)
print(t.format("Mon Jan 2 15:04:05 2006"))  # => Sat Mar 9 14:05:06 2024
```

## The pieces

Each field has a spelling for each way of writing it, and the spelling is the
reference instant's own value in that form.

- The year is `2006` in full or `06` in two digits.
- The month is `1` or `01` in digits, `Jan` or `January` in words.
- The day of the month is `2`, `02` for a leading zero, or `_2` for a leading
  space. The day of the year is `002` or `__2`.
- The day of the week is `Mon` or `Monday`. It is never read back out of a
  layout to work out a date, only written.
- The hour is `15` on a 24 hour clock, or `3` or `03` on a twelve hour clock,
  which is only unambiguous next to `PM` or `pm`.
- The minute is `4` or `04`, the second is `5` or `05`.
- The fraction of a second is a run of zeros or a run of nines after a dot or a
  comma. `.000` writes three digits whatever they are, and `.999` writes up to
  three and leaves out both the trailing zeros and the dot itself when there is
  nothing to write.
- The zone offset is `-0700`, `-07:00`, `-07`, `-070000` or `-07:00:00`, and
  the same five spelled with a `Z` in place of the sign write a bare `Z` when
  the offset is zero, which is what ISO 8601 asks for. The zone's name is
  `MST`, and an instant whose zone has no name falls back to `-0700`.

Anything else is literal, which is why `2006-01-02` gives dashes and
`January 2, 2006` gives a comma and spaces.

## What is not here

Reading a layout back, which is `parse` and its `ParseError`, is the other half
of this file in Go and is its own piece of work here. So are the marshalling
methods, which are `format` and `parse` against RFC 3339 with the edge cases
that RFC 3339 cannot express checked by hand, and `go_string`, which writes a
`Time` as the source that would build it.

Go keeps a second, faster path for RFC 3339 alone, on the grounds that it is
over half of all the layouts anybody writes. It is the same output either way
and there is one path here.
"""

from .calendar import (
    JANUARY,
    clock_of,
    date_of,
    weekday_of,
    year_yday,
)
from .divide import _quo

comptime LAYOUT = "01/02 03:04:05PM '06 -0700"
"""The reference instant itself, whose parts in order are the numbers one to
seven. Go's `Layout`, and the thing to look at when a layout has to be worked
out from scratch."""

comptime ANSIC = "Mon Jan _2 15:04:05 2006"
"""What C's `asctime` writes. Go's `ANSIC`."""

comptime UNIX_DATE = "Mon Jan _2 15:04:05 MST 2006"
"""What the `date` command writes. Go's `UnixDate`."""

comptime RUBY_DATE = "Mon Jan 02 15:04:05 -0700 2006"
"""What Ruby's `Time#to_s` writes. Go's `RubyDate`."""

comptime RFC822 = "02 Jan 06 15:04 MST"
"""The date of an email, as RFC 822 wrote it. Go's `RFC822`.

Two digit years and a zone abbreviation, both of which RFC 1123 fixed and
neither of which anything new should be written in."""

comptime RFC822Z = "02 Jan 06 15:04 -0700"
"""RFC 822 with a numeric zone. Go's `RFC822Z`."""

comptime RFC850 = "Monday, 02-Jan-06 15:04:05 MST"
"""The date of a Usenet article. Go's `RFC850`."""

comptime RFC1123 = "Mon, 02 Jan 2006 15:04:05 MST"
"""The date of an email, as RFC 1123 fixed it. Go's `RFC1123`."""

comptime RFC1123Z = "Mon, 02 Jan 2006 15:04:05 -0700"
"""RFC 1123 with a numeric zone. Go's `RFC1123Z`.

The one to send. HTTP asks for this date and a numeric zone is the only kind
that means one thing everywhere."""

comptime RFC3339 = "2006-01-02T15:04:05Z07:00"
"""The date of a machine talking to another machine. Go's `RFC3339`.

Sorts as text in the same order as it does in time, says its offset in digits,
and is what to reach for when the format is a choice rather than something a
protocol already settled."""

comptime RFC3339_NANO = "2006-01-02T15:04:05.999999999Z07:00"
"""RFC 3339 with the fraction of a second. Go's `RFC3339Nano`.

The trailing zeros go, so the width of the result varies and a column of them
does not line up. `.000000000` in place of the nines is the fixed width
version."""

comptime KITCHEN = "3:04PM"
"""The time on a kitchen clock. Go's `Kitchen`."""

comptime STAMP = "Jan _2 15:04:05"
"""The stamp on a log line, with no year and no zone. Go's `Stamp`."""

comptime STAMP_MILLI = "Jan _2 15:04:05.000"
"""`STAMP` to the millisecond. Go's `StampMilli`."""

comptime STAMP_MICRO = "Jan _2 15:04:05.000000"
"""`STAMP` to the microsecond. Go's `StampMicro`."""

comptime STAMP_NANO = "Jan _2 15:04:05.000000000"
"""`STAMP` to the nanosecond. Go's `StampNano`."""

comptime DATE_TIME = "2006-01-02 15:04:05"
"""A date and a time with a space between them. Go's `DateTime`."""

comptime DATE_ONLY = "2006-01-02"
"""A date on its own. Go's `DateOnly`."""

comptime TIME_ONLY = "15:04:05"
"""A time of day on its own. Go's `TimeOnly`."""


# The pieces of the reference instant, one number each.
#
# The numbers are Go's, which are the positions in the `iota` block its
# constants are declared by, and they are kept rather than renumbered so that
# the two files can be read side by side. Nothing outside this file sees one,
# and only two things about the number matter: the three flags say which fields
# have to be computed before the piece can be written, and the fractional
# second pieces carry a digit count and a separator in the bits above
# `_STD_ARG_SHIFT`.
comptime _STD_NEED_DATE = 1 << 8
comptime _STD_NEED_YDAY = 1 << 9
comptime _STD_NEED_CLOCK = 1 << 10
comptime _STD_ARG_SHIFT = 16
comptime _STD_SEPARATOR_SHIFT = 28
comptime _STD_MASK = (1 << _STD_ARG_SHIFT) - 1

comptime _STD_LONG_MONTH = 1 + _STD_NEED_DATE  # "January"
comptime _STD_MONTH = 2 + _STD_NEED_DATE  # "Jan"
comptime _STD_NUM_MONTH = 3 + _STD_NEED_DATE  # "1"
comptime _STD_ZERO_MONTH = 4 + _STD_NEED_DATE  # "01"
comptime _STD_LONG_WEEKDAY = 5 + _STD_NEED_DATE  # "Monday"
comptime _STD_WEEKDAY = 6 + _STD_NEED_DATE  # "Mon"
comptime _STD_DAY = 7 + _STD_NEED_DATE  # "2"
comptime _STD_UNDER_DAY = 8 + _STD_NEED_DATE  # "_2"
comptime _STD_ZERO_DAY = 9 + _STD_NEED_DATE  # "02"
comptime _STD_UNDER_YEAR_DAY = 10 + _STD_NEED_YDAY  # "__2"
comptime _STD_ZERO_YEAR_DAY = 11 + _STD_NEED_YDAY  # "002"
comptime _STD_HOUR = 12 + _STD_NEED_CLOCK  # "15"
comptime _STD_HOUR12 = 13 + _STD_NEED_CLOCK  # "3"
comptime _STD_ZERO_HOUR12 = 14 + _STD_NEED_CLOCK  # "03"
comptime _STD_MINUTE = 15 + _STD_NEED_CLOCK  # "4"
comptime _STD_ZERO_MINUTE = 16 + _STD_NEED_CLOCK  # "04"
comptime _STD_SECOND = 17 + _STD_NEED_CLOCK  # "5"
comptime _STD_ZERO_SECOND = 18 + _STD_NEED_CLOCK  # "05"
comptime _STD_LONG_YEAR = 19 + _STD_NEED_DATE  # "2006"
comptime _STD_YEAR = 20 + _STD_NEED_DATE  # "06"
comptime _STD_PM = 21 + _STD_NEED_CLOCK  # "PM"
comptime _STD_LOWER_PM = 22 + _STD_NEED_CLOCK  # "pm"
comptime _STD_TZ = 23  # "MST"
comptime _STD_ISO8601_TZ = 24  # "Z0700"
comptime _STD_ISO8601_SECONDS_TZ = 25  # "Z070000"
comptime _STD_ISO8601_SHORT_TZ = 26  # "Z07"
comptime _STD_ISO8601_COLON_TZ = 27  # "Z07:00"
comptime _STD_ISO8601_COLON_SECONDS_TZ = 28  # "Z07:00:00"
comptime _STD_NUM_TZ = 29  # "-0700"
comptime _STD_NUM_SECONDS_TZ = 30  # "-070000"
comptime _STD_NUM_SHORT_TZ = 31  # "-07"
comptime _STD_NUM_COLON_TZ = 32  # "-07:00"
comptime _STD_NUM_COLON_SECONDS_TZ = 33  # "-07:00:00"
comptime _STD_FRAC_SECOND0 = 34  # ".0", trailing zeros kept
comptime _STD_FRAC_SECOND9 = 35  # ".9", trailing zeros dropped

comptime _STD_0X: Array[Int, 6] = [
    _STD_ZERO_MONTH,
    _STD_ZERO_DAY,
    _STD_ZERO_HOUR12,
    _STD_ZERO_MINUTE,
    _STD_ZERO_SECOND,
    _STD_YEAR,
]
"""What `01` through `06` mean, in that order. Go's `std0x`."""


def _put(mut dst: List[UInt8], s: StringSlice):
    """`s` onto the end of `dst`, as its bytes."""
    dst.extend(s.as_bytes())


def _at(b: Span[UInt8, _], i: Int) -> Int:
    """The byte at `i`, widened so it can be compared against `ord`."""
    return Int(b[i])


def _has(b: Span[UInt8, _], i: Int, want: StringSlice) -> Bool:
    """Whether `want` sits at `i`, with room for all of it."""
    var w = want.as_bytes()
    if i + len(w) > len(b):
        return False
    for j in range(len(w)):
        if b[i + j] != w[j]:
            return False
    return True


def _starts_lower(b: Span[UInt8, _], i: Int) -> Bool:
    """Whether a lower case letter starts at `i`.

    Go's `startsWithLowerCase`, and what keeps `Monday` from being read as
    `Mon` followed by the literal text `day`.
    """
    if i >= len(b):
        return False
    return ord("a") <= _at(b, i) <= ord("z")


def _is_digit(b: Span[UInt8, _], i: Int) -> Bool:
    """Whether a digit sits at `i`."""
    if i >= len(b):
        return False
    return ord("0") <= _at(b, i) <= ord("9")


def _std_frac_second(code: Int, n: Int, sep: Int) -> Int:
    """A fractional second piece carrying its digit count and separator.

    Both ride in the bits above the piece itself, which is what keeps the
    switch in `_append_format` a switch over pieces rather than over pieces
    times ten widths times two separators.
    """
    var std = code | ((n & 0xFFF) << _STD_ARG_SHIFT)
    if sep == ord("."):
        return std
    return std | (1 << _STD_SEPARATOR_SHIFT)


def _digits_len(std: Int) -> Int:
    """How many digits of a fraction the piece asks for."""
    return (std >> _STD_ARG_SHIFT) & 0xFFF


def _separator(std: Int) -> StringSlice[StaticConstantOrigin]:
    """The character the fraction is introduced by."""
    if (std >> _STD_SEPARATOR_SHIFT) == 0:
        return "."
    return ","


def _next_std_chunk(layout: StringSlice, start: Int) -> Tuple[Int, Int, Int]:
    """The first piece of the reference instant at or after `start`.

    Three offsets into `layout`: where the literal text before the piece ends,
    which piece it is, and where the text after the piece begins. Go's
    `nextStdChunk` cuts the layout into three strings instead, and offsets are
    the same answer without a slice of a slice and the origin that would come
    with it.

    A piece of zero means there is none left, and then the first offset is the
    end of the layout and everything from `start` is literal.
    """
    var b = layout.as_bytes()
    var n = len(b)
    for i in range(start, n):
        var c = _at(b, i)
        if c == ord("J"):  # January, Jan
            if _has(b, i, "Jan"):
                if _has(b, i, "January"):
                    return (i, _STD_LONG_MONTH, i + 7)
                if not _starts_lower(b, i + 3):
                    return (i, _STD_MONTH, i + 3)
        elif c == ord("M"):  # Monday, Mon, MST
            if _has(b, i, "Mon"):
                if _has(b, i, "Monday"):
                    return (i, _STD_LONG_WEEKDAY, i + 6)
                if not _starts_lower(b, i + 3):
                    return (i, _STD_WEEKDAY, i + 3)
            if _has(b, i, "MST"):
                return (i, _STD_TZ, i + 3)
        elif c == ord("0"):  # 01 through 06, and 002
            if i + 1 < n and ord("1") <= _at(b, i + 1) <= ord("6"):
                var which = _at(b, i + 1) - ord("1")
                return (i, materialize[_STD_0X]()[which], i + 2)
            if _has(b, i, "002"):
                return (i, _STD_ZERO_YEAR_DAY, i + 3)
        elif c == ord("1"):  # 15, 1
            if _has(b, i, "15"):
                return (i, _STD_HOUR, i + 2)
            return (i, _STD_NUM_MONTH, i + 1)
        elif c == ord("2"):  # 2006, 2
            if _has(b, i, "2006"):
                return (i, _STD_LONG_YEAR, i + 4)
            return (i, _STD_DAY, i + 1)
        elif c == ord("_"):  # _2, _2006, __2
            if i + 1 < n and _at(b, i + 1) == ord("2"):
                # `_2006` is a literal underscore and then the year, not a day
                # written after a space. The prefix keeps the underscore.
                if _has(b, i + 1, "2006"):
                    return (i + 1, _STD_LONG_YEAR, i + 5)
                return (i, _STD_UNDER_DAY, i + 2)
            if _has(b, i, "__2"):
                return (i, _STD_UNDER_YEAR_DAY, i + 3)
        elif c == ord("3"):
            return (i, _STD_HOUR12, i + 1)
        elif c == ord("4"):
            return (i, _STD_MINUTE, i + 1)
        elif c == ord("5"):
            return (i, _STD_SECOND, i + 1)
        elif c == ord("P"):  # PM
            if _has(b, i, "PM"):
                return (i, _STD_PM, i + 2)
        elif c == ord("p"):  # pm
            if _has(b, i, "pm"):
                return (i, _STD_LOWER_PM, i + 2)
        elif c == ord("-"):  # -070000, -07:00:00, -0700, -07:00, -07
            if _has(b, i, "-070000"):
                return (i, _STD_NUM_SECONDS_TZ, i + 7)
            if _has(b, i, "-07:00:00"):
                return (i, _STD_NUM_COLON_SECONDS_TZ, i + 9)
            if _has(b, i, "-0700"):
                return (i, _STD_NUM_TZ, i + 5)
            if _has(b, i, "-07:00"):
                return (i, _STD_NUM_COLON_TZ, i + 6)
            if _has(b, i, "-07"):
                return (i, _STD_NUM_SHORT_TZ, i + 3)
        elif c == ord("Z"):  # Z070000, Z07:00:00, Z0700, Z07:00, Z07
            if _has(b, i, "Z070000"):
                return (i, _STD_ISO8601_SECONDS_TZ, i + 7)
            if _has(b, i, "Z07:00:00"):
                return (i, _STD_ISO8601_COLON_SECONDS_TZ, i + 9)
            if _has(b, i, "Z0700"):
                return (i, _STD_ISO8601_TZ, i + 5)
            if _has(b, i, "Z07:00"):
                return (i, _STD_ISO8601_COLON_TZ, i + 6)
            if _has(b, i, "Z07"):
                return (i, _STD_ISO8601_SHORT_TZ, i + 3)
        elif c == ord(".") or c == ord(","):  # .000, .999, ,000, ,999
            if i + 1 < n and (
                _at(b, i + 1) == ord("0") or _at(b, i + 1) == ord("9")
            ):
                var digit = _at(b, i + 1)
                var j = i + 1
                while j < n and _at(b, j) == digit:
                    j += 1
                # A run of digits that keeps going is a number somebody wrote
                # in the layout, not a fraction, so the whole thing stays
                # literal.
                if not _is_digit(b, j):
                    var code = _STD_FRAC_SECOND0
                    if digit == ord("9"):
                        code = _STD_FRAC_SECOND9
                    return (i, _std_frac_second(code, j - (i + 1), c), j)
    return (n, 0, n)


def _append_int(mut dst: List[UInt8], value: Int, width: Int):
    """`value` in decimal, zero padded to `width` digits, minus sign first.

    Go's `appendInt`. A number too long for the width is written in full rather
    than truncated, which keeps the year 10000 from printing as `0000`, and the
    sign is not counted towards the width, so the year -1 is five characters.
    """
    var digits = String()
    _append_padded(digits, value, width)
    _put(dst, digits)


def _append_nano(mut dst: List[UInt8], nsec: Int, std: Int):
    """The fraction of a second the piece asks for, separator and all.

    Go's `appendNano`. Nine digits are computed and the first however many are
    kept, so `.000` is the millisecond and `.000000` the microsecond. The nines
    form drops the trailing zeros, and when that leaves nothing it drops the
    separator too rather than writing a dot with no digits after it.
    """
    var trim = (std & _STD_MASK) == _STD_FRAC_SECOND9
    var n = _digits_len(std)
    if trim and (n == 0 or nsec == 0):
        return

    var padded = String()
    _append_padded(padded, nsec, 9)

    var end = n
    if trim:
        while end > 0 and padded[byte=end - 1] == "0":
            end -= 1
        if end == 0:
            return

    _put(dst, _separator(std))
    _put(dst, padded[byte=0:end])


def _append_padded(mut out: String, value: Int, width: Int):
    """The same padding onto a `String`, which is what `_append_int` is written
    in terms of and what the two callers holding a `String` rather than a list
    of bytes reach for."""
    var digits = String(abs(value))
    if value < 0:
        out += "-"
    for _ in range(width - digits.byte_length()):
        out += "0"
    out += digits


def _append_format(
    mut dst: List[UInt8],
    layout: StringSlice,
    days: UInt64,
    abs_sec: UInt64,
    nsec: Int,
    name: StringSlice,
    offset: Int,
) -> Int:
    """One instant written out by one layout, and how many bytes that took.

    Go's `Time.appendFormat`. The instant arrives already broken into the two
    counts the calendar is entered by and the zone it is being read against,
    because this file does not know what a `Time` is: `time.mojo` owns that
    type and calls in here, which is the only direction the two can point.

    The date and the clock are worked out at the first piece that needs them
    and not before, so a layout of nothing but literal text does no calendar
    arithmetic at all.
    """
    var start = len(dst)
    var b = layout.as_bytes()

    var year = -1
    var month = JANUARY
    var day = 0
    var yday = -1
    var hour = -1
    var minute = 0
    var sec = 0

    var i = 0
    while i < len(b):
        var chunk = _next_std_chunk(layout, i)
        var prefix_end = chunk[0]
        var std = chunk[1]
        if prefix_end > i:
            dst.extend(b[i:prefix_end])
        if std == 0:
            break
        i = chunk[2]

        if year < 0 and (std & _STD_NEED_DATE) != 0:
            var ymd = date_of(days)
            year = ymd[0]
            month = ymd[1]
            day = ymd[2]
        if yday < 0 and (std & _STD_NEED_YDAY) != 0:
            yday = year_yday(days)[1]
        if hour < 0 and (std & _STD_NEED_CLOCK) != 0:
            var hms = clock_of(abs_sec)
            hour = hms[0]
            minute = hms[1]
            sec = hms[2]

        var kind = std & _STD_MASK
        if kind == _STD_YEAR:
            _append_int(dst, abs(year) % 100, 2)
        elif kind == _STD_LONG_YEAR:
            _append_int(dst, year, 4)
        elif kind == _STD_MONTH:
            _put(dst, _short(String(month)))
        elif kind == _STD_LONG_MONTH:
            _put(dst, String(month))
        elif kind == _STD_NUM_MONTH:
            _append_int(dst, month.value, 0)
        elif kind == _STD_ZERO_MONTH:
            _append_int(dst, month.value, 2)
        elif kind == _STD_WEEKDAY:
            _put(dst, _short(String(weekday_of(days))))
        elif kind == _STD_LONG_WEEKDAY:
            _put(dst, String(weekday_of(days)))
        elif kind == _STD_DAY:
            _append_int(dst, day, 0)
        elif kind == _STD_UNDER_DAY:
            if day < 10:
                _put(dst, " ")
            _append_int(dst, day, 0)
        elif kind == _STD_ZERO_DAY:
            _append_int(dst, day, 2)
        elif kind == _STD_UNDER_YEAR_DAY:
            if yday < 100:
                _put(dst, " ")
                if yday < 10:
                    _put(dst, " ")
            _append_int(dst, yday, 0)
        elif kind == _STD_ZERO_YEAR_DAY:
            _append_int(dst, yday, 3)
        elif kind == _STD_HOUR:
            _append_int(dst, hour, 2)
        elif kind == _STD_HOUR12:
            _append_int(dst, _twelve(hour), 0)
        elif kind == _STD_ZERO_HOUR12:
            _append_int(dst, _twelve(hour), 2)
        elif kind == _STD_MINUTE:
            _append_int(dst, minute, 0)
        elif kind == _STD_ZERO_MINUTE:
            _append_int(dst, minute, 2)
        elif kind == _STD_SECOND:
            _append_int(dst, sec, 0)
        elif kind == _STD_ZERO_SECOND:
            _append_int(dst, sec, 2)
        elif kind == _STD_PM:
            _put(dst, "PM" if hour >= 12 else "AM")
        elif kind == _STD_LOWER_PM:
            _put(dst, "pm" if hour >= 12 else "am")
        elif _is_offset(kind):
            _append_offset(dst, kind, offset)
        elif kind == _STD_TZ:
            if name.byte_length() != 0:
                _put(dst, name)
            else:
                # A zone with no name still has to print something, and Go
                # prints the offset in the `-0700` form rather than leaving a
                # hole where the abbreviation was asked for.
                _append_offset(dst, _STD_NUM_TZ, offset)
        elif kind == _STD_FRAC_SECOND0 or kind == _STD_FRAC_SECOND9:
            _append_nano(dst, nsec, std)

    return len(dst) - start


def _short(var name: String) -> String:
    """The first three bytes of a month or a day name.

    Go slices the full name, and the names are ASCII so three bytes are three
    letters. The guard is for the marker a number that is not a month prints
    as, which is longer than three bytes anyway but is not worth trusting.
    """
    if name.byte_length() <= 3:
        return name^
    return String(name[byte=0:3])


def _twelve(hour: Int) -> Int:
    """The hour on a twelve hour clock. Noon is 12PM and midnight is 12AM."""
    var h = hour % 12
    if h == 0:
        return 12
    return h


def _is_offset(kind: Int) -> Bool:
    """Whether the piece is one of the ten spellings of a numeric offset."""
    return (
        kind == _STD_ISO8601_TZ
        or kind == _STD_ISO8601_COLON_TZ
        or kind == _STD_ISO8601_SECONDS_TZ
        or kind == _STD_ISO8601_SHORT_TZ
        or kind == _STD_ISO8601_COLON_SECONDS_TZ
        or kind == _STD_NUM_TZ
        or kind == _STD_NUM_COLON_TZ
        or kind == _STD_NUM_SECONDS_TZ
        or kind == _STD_NUM_SHORT_TZ
        or kind == _STD_NUM_COLON_SECONDS_TZ
    )


def _append_offset(mut dst: List[UInt8], kind: Int, offset: Int):
    """The zone offset in the spelling the piece asked for.

    The five `Z` spellings write a bare `Z` at an offset of zero, which is what
    ISO 8601 says and is the reason the letter is in the layout at all. The
    five that begin with a sign always write digits.

    `_quo` rather than `//`, because an offset west of UTC is negative and the
    seconds of it have to be dropped towards zero the way Go's division does.
    Rounding the other way turns Kiritimati's old `-1029` into `-1030`.
    """
    var iso = (
        kind == _STD_ISO8601_TZ
        or kind == _STD_ISO8601_COLON_TZ
        or kind == _STD_ISO8601_SECONDS_TZ
        or kind == _STD_ISO8601_SHORT_TZ
        or kind == _STD_ISO8601_COLON_SECONDS_TZ
    )
    if offset == 0 and iso:
        _put(dst, "Z")
        return

    var minutes = _quo(offset, 60)
    var seconds = offset
    if minutes < 0:
        _put(dst, "-")
        minutes = -minutes
        seconds = -seconds
    else:
        _put(dst, "+")

    var colon = (
        kind == _STD_ISO8601_COLON_TZ
        or kind == _STD_NUM_COLON_TZ
        or kind == _STD_ISO8601_COLON_SECONDS_TZ
        or kind == _STD_NUM_COLON_SECONDS_TZ
    )
    var short = kind == _STD_NUM_SHORT_TZ or kind == _STD_ISO8601_SHORT_TZ

    _append_int(dst, minutes // 60, 2)
    if colon:
        _put(dst, ":")
    if not short:
        _append_int(dst, minutes % 60, 2)

    if (
        kind == _STD_ISO8601_SECONDS_TZ
        or kind == _STD_NUM_SECONDS_TZ
        or kind == _STD_NUM_COLON_SECONDS_TZ
        or kind == _STD_ISO8601_COLON_SECONDS_TZ
    ):
        if colon:
            _put(dst, ":")
        _append_int(dst, seconds % 60, 2)
