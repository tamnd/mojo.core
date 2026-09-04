"""Reading an instant back out of the way one was written. Go's `Parse`.

`format` takes an instant and an example of the answer and writes the answer.
This takes the same example and an answer somebody else wrote and hands back the
instant. The scanner is the one in `format.mojo` walked the same way, so the two
directions can never disagree about what a piece of the layout is; what is added
here is the reading half of each piece, the arithmetic that turns the pieces into
a date, and the checks that say when they do not add up.

## What a layout accepts that it would never write

Reading is looser than writing on purpose, because the string being read was
usually written by something else.

A layout with no fraction in it still reads one directly after the seconds, and
truncates it to nanoseconds, so `2006-01-02 15:04:05` reads a value with three
decimal places in it. A `.9` fraction is optional and a `.0` fraction is not,
which is the only place the two forms differ once you are reading. A run of
spaces in the layout matches a run of spaces of any length in the value, so
`Jan _2` reads `Jan  9` and `Jan 9` alike. Month and weekday names are matched
without regard to case, and the weekday is checked and then thrown away, because
the date already says which day of the week it was.

Anything the layout does not mention is January 1 of the year 0 at midnight,
which is before the zero `Time`, so `parse("3:04pm", "9:41pm")` is a real instant
in the year 0 and not an error.

## The two digit year

`06` reads 69 through 99 as the nineteen hundreds and 00 through 68 as the two
thousands. Go picked 69 because Unix time starts in the last days of 1969 in the
zones west of Greenwich, and the pivot is a fixed number rather than one relative
to the current year, so this rule does not change under anybody's feet.

## Zones

A zone abbreviation is read by shape and not by name, because zone names are
human writing and no table has all of them. Three capitals is a zone; four or
five is a zone when the last is a `T`; `ChST`, `MeST` and `WITA` are written down
one at a time because they are the exceptions; and `GMT` may carry an hour on the
end of it.

When the value gives a numeric offset and that is the offset the matching
location was using at that instant, the answer is in that location rather than in
a zone fabricated to hold the number. That is what makes writing an instant with
`format` and reading it back land in the same place it started. `parse` matches
against the host's own zone and `parse_in_location` against the one it is given,
which is the whole difference between them apart from what an absent zone means.

## What is not here

Go's second and faster path for RFC 3339 alone, which is an optimisation and not
a behaviour. There is one path here and it reads everything the other one reads.
"""

from core.errors import Report, capture
from core.errors.codes import ErrParseDuration, ErrParseTime

from .calendar import (
    _DAY_NAMES,
    _MONTH_NAMES,
    FEBRUARY,
    JANUARY,
    Month,
    days_before,
    days_in,
    is_leap,
)
from .duration import Duration
from .format import (
    _at,
    _digits_len,
    _has,
    _is_digit,
    _is_offset,
    _next_std_chunk,
    _STD_DAY,
    _STD_FRAC_SECOND0,
    _STD_FRAC_SECOND9,
    _STD_HOUR,
    _STD_HOUR12,
    _STD_ISO8601_COLON_SECONDS_TZ,
    _STD_ISO8601_COLON_TZ,
    _STD_ISO8601_SECONDS_TZ,
    _STD_ISO8601_SHORT_TZ,
    _STD_ISO8601_TZ,
    _STD_LONG_MONTH,
    _STD_LONG_WEEKDAY,
    _STD_LONG_YEAR,
    _STD_LOWER_PM,
    _STD_MASK,
    _STD_MINUTE,
    _STD_MONTH,
    _STD_NUM_COLON_SECONDS_TZ,
    _STD_NUM_COLON_TZ,
    _STD_NUM_MONTH,
    _STD_NUM_SECONDS_TZ,
    _STD_NUM_SHORT_TZ,
    _STD_NUM_TZ,
    _STD_PM,
    _STD_SECOND,
    _STD_TZ,
    _STD_UNDER_DAY,
    _STD_UNDER_YEAR_DAY,
    _STD_WEEKDAY,
    _STD_YEAR,
    _STD_ZERO_DAY,
    _STD_ZERO_HOUR12,
    _STD_ZERO_MINUTE,
    _STD_ZERO_MONTH,
    _STD_ZERO_SECOND,
    _STD_ZERO_YEAR_DAY,
)
from .load import local
from .time import Time, date
from .zone import Location, fixed_zone, utc


def _quote(s: StringSlice) -> String:
    """`s` in double quotes, with anything unprintable written as `\\xNN`.

    Go's `quote` in `format.go`, which exists there because `time` cannot depend
    on `strconv` and cannot therefore call `strconv.Quote`. The same is true
    here: `core.time` depends on `core.errors` and `core.syscall` and on nothing
    else, and `core.strconv.quote` is on the other side of that line.

    Go escapes a rune it will not print one byte at a time, so working in bytes
    rather than runes gives the same answer for every input including a byte
    that is not valid UTF-8 at all.
    """
    var hex = String("0123456789abcdef")
    var out = String('"')
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 0x80 or c < ord(" "):
            out += "\\x"
            out += hex[byte = (c >> 4) : (c >> 4) + 1]
            out += hex[byte = (c & 0xF) : (c & 0xF) + 1]
        else:
            if c == ord('"') or c == ord("\\"):
                out += "\\"
            out += chr(c)
    out += '"'
    return out^


struct ParseError(Copyable, Movable, Writable):
    """A time string that did not match its layout. Go's `ParseError`, read
    rather than raised.

    `parse` raises with all five of these on the record, and this reads them
    back, the same arrangement `core.strconv.NumError` has and for the same
    reason: `core.errors` carries a code and named fields, there is no error
    value to return, so the shape of the failure travels as fields and is
    rebuilt here.

    ```mojo
    from core.time import ParseError, parse

    def main():
        try:
            _ = parse("2006-01-02", "not a date")
        except e:
            var failure = ParseError.of(e)
            if failure:
                print(failure.value().layout_elem)  # 2006
                print(failure.value().value_elem)  # not a date
    ```

    The usual questions do not need this type. `errors.matches(e, ErrParseTime)`
    asks whether the string was the problem and `errors.field(e, "value")` asks
    what the string was. This is for the caller who wants all five at once,
    usually to build a message of their own.
    """

    var layout: String
    """The whole layout that was being read with, not the piece that failed."""

    var value: String
    """The whole string that was being read, not the part that failed."""

    var layout_elem: String
    """The piece of the layout that could not be satisfied, such as `2006`.

    Empty when the failure was not about one piece: text left over at the end,
    or a date that does not exist.
    """

    var value_elem: String
    """What was left of the value when that piece was reached."""

    var message: String
    """Why, when the reason is not simply that the piece did not match.

    Empty for an ordinary mismatch, and then `error` builds the longer sentence
    that names both elements. Otherwise it begins with a colon and a space, the
    way Go's does, because it is written directly onto the end of the value.
    """

    def __init__(
        out self,
        var layout: String,
        var value: String,
        var layout_elem: String,
        var value_elem: String,
        var message: String,
    ):
        """Hold the five pieces. Built by `of`, not by hand."""
        self.layout = layout^
        self.value = value^
        self.layout_elem = layout_elem^
        self.value_elem = value_elem^
        self.message = message^

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as a `ParseError`, or nothing if it did not come from `parse`.

        Go's `err.(*time.ParseError)`. Nothing comes back when the error was
        raised somewhere else, which is the case a type assertion covers by
        failing and this covers by being empty.
        """
        var record = capture(e)
        if not record.matches(ErrParseTime):
            return None
        var layout = record.field("layout")
        var value = record.field("value")
        if not layout or not value:
            return None
        return Self(
            layout.value(),
            value.value(),
            record.field("layout_elem").or_else(String()),
            record.field("value_elem").or_else(String()),
            record.field("message").or_else(String()),
        )

    def error(self) -> String:
        """The message Go's `Error` builds, character for character.

        `parsing time "not a date" as "2006-01-02": cannot parse "not a date" as
        "2006"`, or the shorter form ending in the reason when there is one.
        """
        if self.message == "":
            return String(
                "parsing time ",
                _quote(self.value),
                " as ",
                _quote(self.layout),
                ": cannot parse ",
                _quote(self.value_elem),
                " as ",
                _quote(self.layout_elem),
            )
        return String("parsing time ", _quote(self.value), self.message)

    def write_to[W: Writer](self, mut writer: W):
        """The message, so a `ParseError` prints as the failure it describes."""
        writer.write(self.error())


def _parse_error(
    layout: StringSlice,
    value: StringSlice,
    layout_elem: String,
    value_elem: String,
    message: String,
) -> Error:
    """The raise every failure in `_parse` makes. Go's `newParseError`.

    One place, so the message and the five fields cannot drift apart and
    `ParseError.of` has exactly one shape to read.
    """
    var text = ParseError(
        String(layout),
        String(value),
        String(layout_elem),
        String(value_elem),
        String(message),
    )
    return (
        Report(text.error())
        .with_code(ErrParseTime)
        .with_field("layout", text.layout)
        .with_field("value", text.value)
        .with_field("layout_elem", text.layout_elem)
        .with_field("value_elem", text.value_elem)
        .with_field("message", text.message)
        .error()
    )


def _fold(c: Int) -> Int:
    """A letter with its case removed, and anything else left alone."""
    return c | (ord("a") - ord("A"))


def _match_fold(b: Span[UInt8, _], i: Int, want: StringSlice) -> Bool:
    """Whether `want` sits at `i` ignoring the case of the letters.

    Go's `match`, which folds only when the two bytes already differ, so a byte
    that is not a letter still has to be equal. That is what keeps `Jan` from
    matching `jaN` and `ja\\x6e` alike but not `ja1`.
    """
    var w = want.as_bytes()
    if i + len(w) > len(b):
        return False
    for j in range(len(w)):
        var c1 = Int(b[i + j])
        var c2 = Int(w[j])
        if c1 != c2:
            c1 = _fold(c1)
            c2 = _fold(c2)
            if c1 != c2 or c1 < ord("a") or c1 > ord("z"):
                return False
    return True


def _lookup_month(b: Span[UInt8, _], i: Int, short: Bool) -> Tuple[Int, Int]:
    """The month named at `i`, counting from one, and the position after it.

    Go's `lookup(shortMonthNames, ...)` and `lookup(longMonthNames, ...)`. The
    position is -1 when no name is there. The long names are tried in order and
    the first that matches wins, which is Go's rule and is unambiguous because
    no month name is a prefix of another.
    """
    var names = materialize[_MONTH_NAMES]()
    for m in range(12):
        var name = String(names[m])
        var width = 3 if short else name.byte_length()
        if _match_fold(b, i, name[byte=0:width]):
            return (m + 1, i + width)
    return (0, -1)


def _lookup_day(b: Span[UInt8, _], i: Int, short: Bool) -> Int:
    """The position after the weekday named at `i`, or -1 if none is.

    The day itself is thrown away, as Go throws it away: the date says which day
    of the week it was, and a value that disagrees is not checked against it.
    """
    var names = materialize[_DAY_NAMES]()
    for d in range(7):
        var name = String(names[d])
        var width = 3 if short else name.byte_length()
        if _match_fold(b, i, name[byte=0:width]):
            return i + width
    return -1


def _cut_space(b: Span[UInt8, _], i: Int) -> Int:
    """The position after any run of spaces at `i`."""
    var at = i
    while at < len(b) and _at(b, at) == ord(" "):
        at += 1
    return at


def _skip(
    v: Span[UInt8, _], vi: Int, l: Span[UInt8, _], li: Int, lend: Int
) -> Tuple[Int, Bool]:
    """The literal text `l[li:lend]` taken off the front of `v` at `vi`.

    Go's `skip`. A space in the layout matches a run of spaces of any length in
    the value, including none at all once the value has run out, which is why
    `Jan _2` reads a value with two spaces in it. Everything else has to match
    exactly.

    The position reached is returned even when the match failed, because that is
    where the error message points.
    """
    var at = vi
    var pi = li
    while pi < lend:
        if _at(l, pi) == ord(" "):
            if at < len(v) and _at(v, at) != ord(" "):
                return (at, False)
            pi = _cut_space(l, pi)
            at = _cut_space(v, at)
            continue
        if at >= len(v) or _at(v, at) != _at(l, pi):
            return (at, False)
        pi += 1
        at += 1
    return (at, True)


def _leading_int(b: Span[UInt8, _], i: Int) -> Tuple[UInt64, Int, Bool]:
    """The run of digits at `i` as a number, and the position after it.

    Go's `leadingInt`. The ceiling is 1<<63 rather than the largest signed
    value, because a duration string may be a negative one and the sign is not
    read until the digits are. The flag is false only on overflow, so a run of
    no digits at all is a successful zero and the caller compares positions to
    find out whether anything was read.
    """
    var at = i
    var x = UInt64(0)
    var limit = UInt64(1) << 63
    while at < len(b):
        var c = _at(b, at)
        if c < ord("0") or c > ord("9"):
            break
        if x > limit // 10:
            return (UInt64(0), at, False)
        x = x * 10 + UInt64(c - ord("0"))
        if x > limit:
            return (UInt64(0), at, False)
        at += 1
    return (x, at, True)


def _atoi(b: Span[UInt8, _], i: Int, end: Int) -> Tuple[Int, Bool]:
    """`b[i:end]` as a signed decimal number. Go's `atoi` in `format.go`.

    Every byte has to be part of the number, so this refuses trailing text where
    `_leading_int` would stop at it.
    """
    var at = i
    var negative = False
    if at < end and (_at(b, at) == ord("-") or _at(b, at) == ord("+")):
        negative = _at(b, at) == ord("-")
        at += 1
    var got = _leading_int(b[at:end], 0)
    if not got[2] or got[1] != end - at:
        return (0, False)
    var x = Int(got[0])
    return (-x if negative else x, True)


def _getnum(b: Span[UInt8, _], i: Int, fixed: Bool) -> Tuple[Int, Int]:
    """One or two digits at `i` as a number, and the position after them.

    Go's `getnum`. `fixed` is what a layout written `01` asks for and means both
    digits are required; a layout written `1` takes either. The position is -1
    when there is no number there at all.
    """
    if not _is_digit(b, i):
        return (0, -1)
    if not _is_digit(b, i + 1):
        if fixed:
            return (0, -1)
        return (_at(b, i) - ord("0"), i + 1)
    return ((_at(b, i) - ord("0")) * 10 + _at(b, i + 1) - ord("0"), i + 2)


def _getnum3(b: Span[UInt8, _], i: Int, fixed: Bool) -> Tuple[Int, Int]:
    """One to three digits at `i` as a number, and the position after them.

    Go's `getnum3`, which the day of the year is the only user of. `fixed` is
    what `002` asks for and means all three are required.
    """
    var n = 0
    var count = 0
    while count < 3 and _is_digit(b, i + count):
        n = n * 10 + _at(b, i + count) - ord("0")
        count += 1
    if count == 0 or (fixed and count != 3):
        return (0, -1)
    return (n, i + count)


def _comma_or_period(c: Int) -> Bool:
    """Whether `c` is one of the two characters a fraction may begin with."""
    return c == ord(".") or c == ord(",")


def _parse_nanoseconds(
    b: Span[UInt8, _], i: Int, nbytes: Int
) -> Tuple[Int, String, Int]:
    """The fraction of a second written at `i` in `nbytes` bytes, in
    nanoseconds.

    Go's `parseNanoseconds`. The count includes the leading dot or comma, so
    `.5` is two bytes and a scale of eight. More than nine digits are truncated
    rather than rounded, which is what Go does and what makes reading a value
    with more precision than a nanosecond lossy in the direction of zero.

    The three answers are the nanoseconds, the field that was out of range if
    one was, and 1 for a fraction that was read at all or 0 for text that was
    not one.
    """
    if not _comma_or_period(_at(b, i)):
        return (0, String(), 0)
    var count = nbytes
    if count > 10:
        count = 10
    var got = _atoi(b, i + 1, i + count)
    if not got[1]:
        return (0, String(), 0)
    if got[0] < 0:
        return (0, String("fractional second"), 1)
    var ns = got[0]
    for _ in range(10 - count):
        ns *= 10
    return (ns, String(), 1)


def _parse_signed_offset(b: Span[UInt8, _], i: Int) -> Int:
    """The length of a signed hour offset such as `+03` written at `i`.

    Go's `parseSignedOffset`. Zero when there is not one, which includes an hour
    above 23, because this is only ever asked about text that might be part of a
    zone abbreviation and a bigger number is somebody else's.
    """
    if i >= len(b):
        return 0
    var sign = _at(b, i)
    if sign != ord("-") and sign != ord("+"):
        return 0
    var got = _leading_int(b, i + 1)
    if not got[2] or got[1] == i + 1:
        return 0
    if got[0] > 23:
        return 0
    return got[1] - i


def _parse_gmt(b: Span[UInt8, _], i: Int) -> Int:
    """The length of a `GMT` zone at `i`, hour offset and all. Go's `parseGMT`.

    `GMT` on its own is three characters and `GMT+3` is five. The text is known
    to begin `GMT` before this is called.
    """
    if i + 3 >= len(b):
        return 3
    return 3 + _parse_signed_offset(b, i + 3)


def _parse_time_zone(b: Span[UInt8, _], i: Int) -> Int:
    """The length of the zone abbreviation at `i`, or zero if none is there.

    Go's `parseTimeZone`, comment and all: zone abbreviations are human writing
    and cannot be checked precisely, so this is a rule about shape. A run of
    three capitals is a zone. A run of four or five is a zone when the last is a
    `T`. `ChST` and `MeST` are the only two with a lower case letter in them and
    `WITA` is the only four letter one that does not end in `T`, so all three
    are written out. `GMT` is special because it can carry an hour.
    """
    if len(b) - i < 3:
        return 0
    if _has(b, i, "ChST") or _has(b, i, "MeST"):
        return 4
    if _has(b, i, "GMT"):
        return _parse_gmt(b, i)
    if _at(b, i) == ord("+") or _at(b, i) == ord("-"):
        return _parse_signed_offset(b, i)
    var upper = 0
    while upper < 6 and i + upper < len(b):
        var c = _at(b, i + upper)
        if c < ord("A") or c > ord("Z"):
            break
        upper += 1
    if upper == 3:
        return 3
    if upper == 4:
        if _at(b, i + 3) == ord("T") or _has(b, i, "WITA"):
            return 4
        return 0
    if upper == 5 and _at(b, i + 4) == ord("T"):
        return 5
    return 0


def _two(b: Span[UInt8, _], i: Int) -> Int:
    """Exactly two digits at `i` as a number, or -1 if there are not two."""
    if not _is_digit(b, i) or not _is_digit(b, i + 1):
        return -1
    return (_at(b, i) - ord("0")) * 10 + _at(b, i + 1) - ord("0")


def _parse_offset(
    b: Span[UInt8, _], i: Int, kind: Int
) -> Tuple[Int, Int, String]:
    """A numeric zone offset in the spelling `kind` asks for.

    Go's five zone cases, which differ only in where the digits sit and which
    colons have to be there. The answers are the offset in seconds east of UTC,
    the position after it or -1 if the text is not an offset, and the field that
    was out of range if one was.

    The range tests are Go's and use `>` rather than `>=`, because people do
    write an offset of exactly 24 hours or 60 minutes and refusing those would
    reject strings that already exist.
    """
    var hh = -1
    var mm = 0
    var ss = 0
    var end = 0
    if kind == _STD_ISO8601_COLON_TZ or kind == _STD_NUM_COLON_TZ:
        if i + 6 > len(b) or _at(b, i + 3) != ord(":"):
            return (0, -1, String())
        hh = _two(b, i + 1)
        mm = _two(b, i + 4)
        end = i + 6
    elif kind == _STD_ISO8601_SHORT_TZ or kind == _STD_NUM_SHORT_TZ:
        if i + 3 > len(b):
            return (0, -1, String())
        hh = _two(b, i + 1)
        end = i + 3
    elif (
        kind == _STD_ISO8601_COLON_SECONDS_TZ
        or kind == _STD_NUM_COLON_SECONDS_TZ
    ):
        if (
            i + 9 > len(b)
            or _at(b, i + 3) != ord(":")
            or _at(b, i + 6) != ord(":")
        ):
            return (0, -1, String())
        hh = _two(b, i + 1)
        mm = _two(b, i + 4)
        ss = _two(b, i + 7)
        end = i + 9
    elif kind == _STD_ISO8601_SECONDS_TZ or kind == _STD_NUM_SECONDS_TZ:
        if i + 7 > len(b):
            return (0, -1, String())
        hh = _two(b, i + 1)
        mm = _two(b, i + 3)
        ss = _two(b, i + 5)
        end = i + 7
    else:
        if i + 5 > len(b):
            return (0, -1, String())
        hh = _two(b, i + 1)
        mm = _two(b, i + 3)
        end = i + 5
    if hh < 0 or mm < 0 or ss < 0:
        return (0, -1, String())

    var out_of_range = String()
    if hh > 24:
        out_of_range = String("time zone offset hour")
    if mm > 60:
        out_of_range = String("time zone offset minute")
    if ss > 60:
        out_of_range = String("time zone offset second")

    var offset = (hh * 60 + mm) * 60 + ss
    var sign = _at(b, i)
    if sign == ord("-"):
        offset = -offset
    elif sign != ord("+"):
        return (0, -1, String())
    return (offset, end, out_of_range)


def _matching(loc: Optional[Location]) -> Location:
    """The location a zone in the value is matched against.

    `parse_in_location` names one and `parse` does not, and an absent one means
    the host's own zone. It is loaded here rather than by the caller so that a
    layout with no zone in it never reads `/etc/localtime` at all, which matters
    because `local()` reads the file every time it is called.
    """
    if loc:
        return loc.value()
    return local()


def _parse(
    layout: StringSlice,
    value: StringSlice,
    default_loc: Location,
    match_loc: Optional[Location],
) raises -> Time:
    """Go's unexported `parse`, which both public entry points are a call to.

    `default_loc` is where an instant with no zone information in it lands and
    `match_loc` is what a zone offset or abbreviation is compared against. For
    `parse` those are UTC and the host's zone; for `parse_in_location` they are
    both the location given.
    """
    var lb = layout.as_bytes()
    var vb = value.as_bytes()
    var li = 0
    var vi = 0

    var year = 0
    var month = -1
    var day = -1
    var yday = -1
    var hour = 0
    var minute = 0
    var sec = 0
    var nsec = 0
    var am_set = False
    var pm_set = False

    var zone_offset = -1
    var zone_name = String()
    var zone_loc = Optional[Location](None)

    while True:
        var chunk = _next_std_chunk(layout, li)
        var prefix_end = chunk[0]
        var std = chunk[1]
        var suffix_start = chunk[2]

        var skipped = _skip(vb, vi, lb, li, prefix_end)
        if not skipped[1]:
            raise _parse_error(
                layout,
                value,
                String(layout[byte=li:prefix_end]),
                String(value[byte = skipped[0] :]),
                String(),
            )
        vi = skipped[0]

        if std == 0:
            if vi != len(vb):
                var left = String(value[byte=vi:])
                raise _parse_error(
                    layout,
                    value,
                    String(),
                    left,
                    String(": extra text: ", _quote(left)),
                )
            break

        var std_str = String(layout[byte=prefix_end:suffix_start])
        li = suffix_start
        var hold = vi
        var kind = std & _STD_MASK
        var ok = True
        var out_of_range = String()

        if kind == _STD_YEAR:
            if vi + 2 > len(vb):
                ok = False
            else:
                var got = _atoi(vb, vi, vi + 2)
                ok = got[1]
                if ok:
                    # Unix time starts in the last days of 1969 west of
                    # Greenwich, which is why the pivot is 69 and not 50.
                    year = got[0] + (1900 if got[0] >= 69 else 2000)
                    vi += 2
        elif kind == _STD_LONG_YEAR:
            if vi + 4 > len(vb) or not _is_digit(vb, vi):
                ok = False
            else:
                var got = _atoi(vb, vi, vi + 4)
                ok = got[1]
                if ok:
                    year = got[0]
                    vi += 4
        elif kind == _STD_MONTH or kind == _STD_LONG_MONTH:
            var got = _lookup_month(vb, vi, kind == _STD_MONTH)
            ok = got[1] >= 0
            if ok:
                month = got[0]
                vi = got[1]
        elif kind == _STD_NUM_MONTH or kind == _STD_ZERO_MONTH:
            var got = _getnum(vb, vi, kind == _STD_ZERO_MONTH)
            ok = got[1] >= 0
            if ok:
                month = got[0]
                vi = got[1]
                if month <= 0 or month > 12:
                    out_of_range = String("month")
        elif kind == _STD_WEEKDAY or kind == _STD_LONG_WEEKDAY:
            var after = _lookup_day(vb, vi, kind == _STD_WEEKDAY)
            ok = after >= 0
            if ok:
                vi = after
        elif (
            kind == _STD_DAY or kind == _STD_UNDER_DAY or kind == _STD_ZERO_DAY
        ):
            if kind == _STD_UNDER_DAY:
                if vi < len(vb) and _at(vb, vi) == ord(" "):
                    vi += 1
            var got = _getnum(vb, vi, kind == _STD_ZERO_DAY)
            ok = got[1] >= 0
            if ok:
                # Any one or two digit day is taken here. Whether it exists is
                # settled at the end, once the month and the year are known.
                day = got[0]
                vi = got[1]
        elif kind == _STD_UNDER_YEAR_DAY or kind == _STD_ZERO_YEAR_DAY:
            if kind == _STD_UNDER_YEAR_DAY:
                for _ in range(2):
                    if vi < len(vb) and _at(vb, vi) == ord(" "):
                        vi += 1
            var got = _getnum3(vb, vi, kind == _STD_ZERO_YEAR_DAY)
            ok = got[1] >= 0
            if ok:
                yday = got[0]
                vi = got[1]
        elif kind == _STD_HOUR:
            var got = _getnum(vb, vi, False)
            ok = got[1] >= 0
            if ok:
                hour = got[0]
                vi = got[1]
                if hour < 0 or hour >= 24:
                    out_of_range = String("hour")
        elif kind == _STD_HOUR12 or kind == _STD_ZERO_HOUR12:
            var got = _getnum(vb, vi, kind == _STD_ZERO_HOUR12)
            ok = got[1] >= 0
            if ok:
                hour = got[0]
                vi = got[1]
                if hour < 0 or hour > 12:
                    out_of_range = String("hour")
        elif kind == _STD_MINUTE or kind == _STD_ZERO_MINUTE:
            var got = _getnum(vb, vi, kind == _STD_ZERO_MINUTE)
            ok = got[1] >= 0
            if ok:
                minute = got[0]
                vi = got[1]
                if minute < 0 or minute >= 60:
                    out_of_range = String("minute")
        elif kind == _STD_SECOND or kind == _STD_ZERO_SECOND:
            var got = _getnum(vb, vi, kind == _STD_ZERO_SECOND)
            ok = got[1] >= 0
            if ok:
                sec = got[0]
                vi = got[1]
                if sec < 0 or sec >= 60:
                    out_of_range = String("second")
                elif (
                    vi + 2 <= len(vb)
                    and _comma_or_period(_at(vb, vi))
                    and _is_digit(vb, vi + 1)
                ):
                    # A fraction the layout never asked for. The layout is
                    # consulted first, because if it does ask for one the piece
                    # after this reads it and this must not.
                    var next_kind = _next_std_chunk(layout, li)[1] & _STD_MASK
                    if (
                        next_kind != _STD_FRAC_SECOND0
                        and next_kind != _STD_FRAC_SECOND9
                    ):
                        var n = 2
                        while n < len(vb) - vi and _is_digit(vb, vi + n):
                            n += 1
                        var frac = _parse_nanoseconds(vb, vi, n)
                        nsec = frac[0]
                        out_of_range = frac[1]
                        ok = frac[2] == 1
                        vi += n
        elif kind == _STD_PM or kind == _STD_LOWER_PM:
            var upper = kind == _STD_PM
            if vi + 2 > len(vb):
                ok = False
            elif _has(vb, vi, "PM" if upper else "pm"):
                pm_set = True
                vi += 2
            elif _has(vb, vi, "AM" if upper else "am"):
                am_set = True
                vi += 2
            else:
                ok = False
        elif kind == _STD_TZ:
            if _has(vb, vi, "UTC"):
                # `UTC` is UTC wherever it is read, which is the one zone
                # abbreviation that does not depend on the location.
                zone_loc = Optional[Location](utc())
                vi += 3
            else:
                var n = _parse_time_zone(vb, vi)
                ok = n > 0
                if ok:
                    zone_name = String(value[byte = vi : vi + n])
                    vi += n
        elif _is_offset(kind):
            if _is_iso(kind) and vi < len(vb) and _at(vb, vi) == ord("Z"):
                # `Z` where digits could have been, which the five spellings
                # written with a `Z` accept and the five written with a `-` do
                # not.
                zone_loc = Optional[Location](utc())
                vi += 1
            else:
                var got = _parse_offset(vb, vi, kind)
                ok = got[1] >= 0
                if ok:
                    zone_offset = got[0]
                    vi = got[1]
                    out_of_range = got[2]
        elif kind == _STD_FRAC_SECOND0:
            # `.0` is not optional and wants exactly the digits it asked for.
            var want = 1 + _digits_len(std)
            if vi + want > len(vb):
                ok = False
            else:
                var frac = _parse_nanoseconds(vb, vi, want)
                nsec = frac[0]
                out_of_range = frac[1]
                ok = frac[2] == 1
                vi += want
        elif kind == _STD_FRAC_SECOND9:
            # `.9` is optional, and when it is there it takes every digit it
            # can see rather than the number it asked for, so that reading is
            # never stricter than the seconds case above.
            if (
                vi + 2 <= len(vb)
                and _comma_or_period(_at(vb, vi))
                and _is_digit(vb, vi + 1)
            ):
                var n = 1
                while vi + n + 1 < len(vb) and _is_digit(vb, vi + n + 1):
                    n += 1
                var frac = _parse_nanoseconds(vb, vi, 1 + n)
                nsec = frac[0]
                out_of_range = frac[1]
                ok = frac[2] == 1
                vi += 1 + n

        if out_of_range != "":
            raise _parse_error(
                layout,
                value,
                std_str,
                String(value[byte=vi:]),
                String(": ", out_of_range, " out of range"),
            )
        if not ok:
            raise _parse_error(
                layout, value, std_str, String(value[byte=hold:]), String()
            )

    if pm_set and hour < 12:
        hour += 12
    elif am_set and hour == 12:
        hour = 0

    if yday >= 0:
        var d = 0
        var m = 0
        var n = yday
        if is_leap(year):
            if n == 31 + 29:
                m = FEBRUARY.value
                d = 29
            elif n > 31 + 29:
                n -= 1
        if n < 1 or n > 365:
            raise _parse_error(
                layout,
                value,
                String(),
                String(value[byte=vi:]),
                String(": day-of-year out of range"),
            )
        if m == 0:
            m = (n - 1) // 31 + 1
            if days_before(Month(m + 1)) < n:
                m += 1
            d = n - days_before(Month(m))
        if month >= 0 and month != m:
            raise _parse_error(
                layout,
                value,
                String(),
                String(value[byte=vi:]),
                String(": day-of-year does not match month"),
            )
        month = m
        if day >= 0 and day != d:
            raise _parse_error(
                layout,
                value,
                String(),
                String(value[byte=vi:]),
                String(": day-of-year does not match day"),
            )
        day = d
    else:
        if month < 0:
            month = JANUARY.value
        if day < 0:
            day = 1

    if day < 1 or day > days_in(Month(month), year):
        raise _parse_error(
            layout,
            value,
            String(),
            String(value[byte=vi:]),
            String(": day out of range"),
        )

    if zone_loc:
        return date(
            year, Month(month), day, hour, minute, sec, nsec, zone_loc.value()
        )

    if zone_offset != -1:
        var t = date(year, Month(month), day, hour, minute, sec, nsec, utc())
        var shifted = Time(
            internal_sec=t.sec - zone_offset, nsec=t.nsec, loc=utc()
        )
        # An offset that is the one the matching location was using at this
        # instant means the value came from that location, and answering with it
        # rather than with a fabricated zone is what makes a round trip through
        # `format` land where it started.
        var against = _matching(match_loc)
        var got = against.lookup(shifted.unix())
        if got[1] == zone_offset and (zone_name == "" or got[0] == zone_name):
            return Time(
                internal_sec=shifted.sec, nsec=shifted.nsec, loc=against
            )
        return Time(
            internal_sec=shifted.sec,
            nsec=shifted.nsec,
            loc=fixed_zone(zone_name, zone_offset),
        )

    if zone_name != "":
        var t = date(year, Month(month), day, hour, minute, sec, nsec, utc())
        var against = _matching(match_loc)
        var found = against.lookup_name(zone_name, t.unix())
        if found[1]:
            return Time(internal_sec=t.sec - found[0], nsec=t.nsec, loc=against)
        # An abbreviation nothing recognises still names a zone, so it is kept
        # with an offset of zero. That reads and writes back identically and
        # names a different instant than the writer meant, which is the trade Go
        # documents and the reason to prefer a numeric offset.
        var offset = 0
        if zone_name.byte_length() > 3 and zone_name[byte=0:3] == "GMT":
            var digits = zone_name.as_bytes()
            offset = _atoi(digits, 3, len(digits))[0] * 3600
        return Time(
            internal_sec=t.sec,
            nsec=t.nsec,
            loc=fixed_zone(zone_name, offset),
        )

    return date(year, Month(month), day, hour, minute, sec, nsec, default_loc)


def _is_iso(kind: Int) -> Bool:
    """Whether the piece is one of the five zone spellings written with a `Z`.

    Those are the ones that accept a bare `Z` in place of the digits.
    """
    return (
        kind == _STD_ISO8601_TZ
        or kind == _STD_ISO8601_SECONDS_TZ
        or kind == _STD_ISO8601_SHORT_TZ
        or kind == _STD_ISO8601_COLON_TZ
        or kind == _STD_ISO8601_COLON_SECONDS_TZ
    )


def parse(layout: StringSlice, value: StringSlice) raises -> Time:
    """The instant `value` names, read the way `layout` says it was written.

    ```mojo
    from core.time import RFC3339, parse

    def main():
        print(parse(RFC3339, "2024-03-09T14:05:06Z"))
        # => 2024-03-09 14:05:06 +0000 UTC
    ```

    Go's `Parse`, and the other direction from `Time.format`. The layout is the
    reference instant `01/02 03:04:05PM '06 -0700` written the way `value` is
    written, so the nineteen named layouts work here exactly as they do there.

    Anything the layout does not mention is zero, or one where zero is
    impossible, so `parse("3:04pm", "9:41pm")` is a quarter to ten at night on
    January 1 of the year 0. A value with no zone in it is read as UTC. A value
    with an offset or an abbreviation in it is read in the host's own zone when
    that zone was using it at that instant, and otherwise in a zone fabricated
    to hold it. Use `parse_in_location` to compare against something other than
    the host.

    Raises with `ErrParseTime` when the value does not say what the layout said
    it would, and `ParseError.of` reads the five pieces of that failure back.
    """
    return _parse(layout, value, utc(), None)


def parse_in_location(
    layout: StringSlice, value: StringSlice, loc: Location
) raises -> Time:
    """`parse`, with `loc` standing in for the host's zone. Go's
    `ParseInLocation`.

    ```mojo
    from core.time import load_location, parse_in_location

    def main():
        var berlin = load_location("Europe/Berlin")
        var layout = "2006-01-02 15:04 MST"
        print(parse_in_location(layout, "2024-07-01 12:00 CEST", berlin))
        # => 2024-07-01 12:00:00 +0200 CEST
    ```

    Two differences from `parse`, both of them the same difference. A value with
    no zone information is read in `loc` rather than in UTC, and a value with an
    offset or an abbreviation is matched against `loc` rather than against the
    host. Everything else is identical.
    """
    return _parse(layout, value, loc, loc)


def _unit(u: StringSlice) -> Tuple[Int, Bool]:
    """The number of nanoseconds in the unit `u` names. Go's `unitMap`.

    The micro is spelled three ways, `us` and the micro sign U+00B5 and the
    Greek mu U+03BC, because both characters are in use and neither is easy to
    type. Go accepts all three and so does this.
    """
    if u == "ns":
        return (1, True)
    if u == "us" or u == "µs" or u == "μs":
        return (1_000, True)
    if u == "ms":
        return (1_000_000, True)
    if u == "s":
        return (1_000_000_000, True)
    if u == "m":
        return (60_000_000_000, True)
    if u == "h":
        return (3_600_000_000_000, True)
    return (0, False)


def _duration_error(message: StringSlice, value: StringSlice) -> Error:
    """The raise `parse_duration` makes, in Go's words and Go's order."""
    return (
        Report(String("time: ", message, " ", _quote(value)))
        .with_code(ErrParseDuration)
        .with_field("duration", String(value))
        .error()
    )


def parse_duration(s: StringSlice) raises -> Duration:
    """The length of time `s` spells out. Go's `ParseDuration`.

    ```mojo
    from core.time import parse_duration

    def main():
        print(parse_duration("2h45m"))  # => 2h45m0s
        print(parse_duration("-1.5h"))  # => -1h30m0s
    ```

    A duration is an optional sign and then one or more numbers, each with an
    optional fraction and a unit after it, which add up. The units are `ns`,
    `us` (or `µs`), `ms`, `s`, `m` and `h`. There is no unit for a day, because a
    day is not always the same length once a zone is involved and this type has
    no zone.

    `0` on its own is the one string with no unit that is accepted, since zero of
    anything is the same zero. Everything else without a unit is refused, and so
    is a total that does not fit a signed count of nanoseconds, which is about
    292 years.
    """
    var b = s.as_bytes()
    var i = 0
    var total = UInt64(0)
    var negative = False
    var limit = UInt64(1) << 63

    if len(b) > 0 and (_at(b, 0) == ord("-") or _at(b, 0) == ord("+")):
        negative = _at(b, 0) == ord("-")
        i = 1

    # A bare zero is a duration with no unit on it, which is the one string that
    # does not need one.
    if len(b) - i == 1 and _at(b, i) == ord("0"):
        return Duration(0)
    if i >= len(b):
        raise _duration_error("invalid duration", s)

    while i < len(b):
        if not (_at(b, i) == ord(".") or _is_digit(b, i)):
            raise _duration_error("invalid duration", s)

        var whole = _leading_int(b, i)
        if not whole[2]:
            raise _duration_error("invalid duration", s)
        var had_whole = whole[1] != i
        i = whole[1]

        # The fraction is accumulated as a numerator and the power of ten under
        # it, because dividing as the digits arrive would lose the low ones.
        var frac = UInt64(0)
        var scale = Float64(1)
        var had_frac = False
        if i < len(b) and _at(b, i) == ord("."):
            i += 1
            var start = i
            var overflowed = False
            while i < len(b) and _is_digit(b, i):
                if not overflowed:
                    if frac > (limit - 1) // 10:
                        overflowed = True
                    else:
                        var next = frac * 10 + UInt64(_at(b, i) - ord("0"))
                        if next > limit:
                            overflowed = True
                        else:
                            frac = next
                            scale *= 10
                i += 1
            had_frac = i != start
        if not had_whole and not had_frac:
            raise _duration_error("invalid duration", s)

        var start = i
        while i < len(b):
            var c = _at(b, i)
            if c == ord(".") or (ord("0") <= c <= ord("9")):
                break
            i += 1
        if i == start:
            raise _duration_error("missing unit in duration", s)
        var name = s[byte=start:i]
        var unit = _unit(name)
        if not unit[1]:
            raise _duration_error(
                String("unknown unit ", _quote(name), " in duration"), s
            )

        var scaled = whole[0]
        if scaled > limit // UInt64(unit[0]):
            raise _duration_error("invalid duration", s)
        scaled *= UInt64(unit[0])
        if frac > 0:
            # A float is needed here and only here: a fraction of an hour has to
            # come out right to the nanosecond, and the numerator times the unit
            # would not fit an integer word before the division.
            scaled += UInt64(Float64(frac) * (Float64(unit[0]) / scale))
            if scaled > limit:
                raise _duration_error("invalid duration", s)
        total += scaled
        if total > limit:
            raise _duration_error("invalid duration", s)

    if negative:
        # The largest magnitude a signed count of nanoseconds holds is one more
        # going down than going up, so the negative limit is spelled here rather
        # than negated, which would not fit on the way through.
        if total == limit:
            return Duration(-9_223_372_036_854_775_807 - 1)
        return Duration(-Int(total))
    if total > limit - 1:
        raise _duration_error("invalid duration", s)
    return Duration(Int(total))
