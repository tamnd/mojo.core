"""The TZ string, which is how a zone file says what happens after it ends.

A compiled zone file is a list of transitions, and the list stops somewhere.
Older files stopped in 2037 because that is as far as a 32 bit Unix second
reaches. Newer ones, the slim files tzdata has produced by default since 2020b,
stop much earlier than that and carry a rule instead, because most of the world
has a rule and writing out forty years of a rule that fits on one line is a
waste of a file. Either way, a lookup past the last transition has to work from
the rule rather than from the list.

The rule is a POSIX TZ string: `PST8PDT,M3.2.0,M11.1.0` says standard time is
eight hours west and called PST, daylight time is called PDT and is an hour
further east because no offset is given, it starts on the second Sunday of the
third month and ends on the first Sunday of the eleventh. The functions here
parse that and answer the same question a transition list answers.

Go calls the whole thing `tzset` after the C function that reads `TZ`, and so
does this. What is not here is reading `TZ` itself, which belongs with the local
zone rather than with the parsing.

## The southern hemisphere

The two rules in the string are written as if the first started daylight time
and the second ended it, and south of the equator the year does not work that
way: daylight time spans the new year, so the rule that fires first in the
calendar year is the one that ends it. `_tzset` detects that by the end coming
before the start and swaps the two, names and offsets and flags together, which
leaves the labels reading oddly and the answers right. Go's comment says the
same thing in fewer words and this is the one place worth knowing about before
reading the code.
"""

from .calendar import (
    Month,
    SECONDS_PER_DAY,
    SECONDS_PER_HOUR,
    SECONDS_PER_MINUTE,
    _INTERNAL_TO_ABSOLUTE,
    _UNIX_TO_INTERNAL,
    days_before,
    days_in,
    is_leap,
    year_yday,
)
from .divide import _quo, _rem


comptime _ALPHA = -9_223_372_036_854_775_807 - 1
"""The beginning of time, for a zone transition. Go's `alpha`.

Not a real instant. It is what `lookup` gives as the start of the first zone,
meaning there is nothing before it to ask about.
"""

comptime _OMEGA = 9_223_372_036_854_775_807
"""The end of time, for a zone transition. Go's `omega`."""

comptime _RULE_JULIAN = 0
"""A day of the year counted from one, where February 29 is not counted.

`J60` is March 1 in every year, leap or not, which is the point of the form.
"""

comptime _RULE_DOY = 1
"""A day of the year counted from zero, where February 29 is counted.

`59` is February 29 in a leap year and March 1 in a common one, which is the
opposite of the Julian form and is why both exist.
"""

comptime _RULE_MONTH_WEEK_DAY = 2
"""The nth weekday of a month, which is how a real rule is written.

`M3.2.0` is the second Sunday of March. Week five means the last one, which is
the fourth or the fifth depending on the year.
"""

comptime _ZERO = UInt8(ord("0"))
comptime _NINE = UInt8(ord("9"))
comptime _PLUS = UInt8(ord("+"))
comptime _MINUS = UInt8(ord("-"))
comptime _COMMA = UInt8(ord(","))
comptime _SEMICOLON = UInt8(ord(";"))
comptime _COLON = UInt8(ord(":"))
comptime _DOT = UInt8(ord("."))
comptime _SLASH = UInt8(ord("/"))
comptime _LESS = UInt8(ord("<"))
comptime _GREATER = UInt8(ord(">"))
comptime _J = UInt8(ord("J"))
comptime _M = UInt8(ord("M"))


struct _Rule(Copyable, Equatable, ImplicitlyCopyable, Movable):
    """One of the two transition rules in a TZ string. Go's `rule`.

    Which of the five fields mean anything depends on `kind`. A Julian or a day
    of year rule uses `day` alone, and a month and weekday rule uses `day` as a
    weekday and needs `week` and `mon` as well. `time` is always the second
    within the day that the change happens at, and is two in the morning unless
    the string says otherwise.
    """

    var kind: Int
    """Which of the three forms this is."""

    var day: Int
    """A day of the year, or a day of the week for a month and weekday rule."""

    var week: Int
    """Which week of the month, one to five, five meaning the last."""

    var mon: Int
    """The month, one for January."""

    var time: Int
    """Seconds into the day at which the change happens."""

    def __init__(out self):
        """The rule a failed parse gives back, which means nothing."""
        self.kind = _RULE_JULIAN
        self.day = 0
        self.week = 0
        self.mon = 0
        self.time = 0

    def __init__(out self, kind: Int, day: Int, week: Int, mon: Int, time: Int):
        """Hold the five fields."""
        self.kind = kind
        self.day = day
        self.week = week
        self.mon = mon
        self.time = time

    def __eq__(self, other: Self) -> Bool:
        """Whether every field matches."""
        return (
            self.kind == other.kind
            and self.day == other.day
            and self.week == other.week
            and self.mon == other.mon
            and self.time == other.time
        )

    def __ne__(self, other: Self) -> Bool:
        """Whether any field differs."""
        return not (self == other)


def _tzset_num[
    o: ImmOrigin
](s: StringSlice[o], low: Int, high: Int) -> Tuple[
    Int, StringSlice[o].Immutable, Bool
]:
    """A decimal number at the front of `s`, with the rest and whether it read.

    Go's `tzsetNum`. The number has to be between `low` and `high`, and the
    range is checked while the digits are read rather than after, so a string
    of forty digits cannot overflow on the way to being rejected.
    """
    var raw = s.as_bytes()
    var n = len(raw)
    var empty = s[byte=0:0]
    if n == 0:
        return (0, empty, False)
    var num = 0
    for i in range(n):
        var c = raw[i]
        if c < _ZERO or c > _NINE:
            if i == 0 or num < low:
                return (0, empty, False)
            return (num, s[byte=i:n], True)
        num = num * 10 + Int(c - _ZERO)
        if num > high:
            return (0, empty, False)
    if num < low:
        return (0, empty, False)
    return (num, s[byte=n:n], True)


def _tzset_name[
    o: ImmOrigin
](s: StringSlice[o]) -> Tuple[
    StringSlice[o].Immutable, StringSlice[o].Immutable, Bool
]:
    """A zone abbreviation at the front of `s`, with the rest. Go's `tzsetName`.

    Two spellings. A bare name runs until a digit or a sign or a comma and has
    to be at least three characters, which is what stops `X` being a name. A
    name in angle brackets runs to the closing bracket and may contain anything,
    which is how `<A+B>` names a zone with a sign in its name.

    Go walks the bare form by rune and this walks it by byte. The two agree
    because every character it stops at is ASCII, and a byte of a longer rune is
    at least 0x80 and so is none of them.
    """
    var raw = s.as_bytes()
    var n = len(raw)
    var empty = s[byte=0:0]
    if n == 0:
        return (empty, empty, False)
    if raw[0] != _LESS:
        for i in range(n):
            var c = raw[i]
            if (
                (c >= _ZERO and c <= _NINE)
                or c == _COMMA
                or c == _MINUS
                or c == _PLUS
            ):
                if i < 3:
                    return (empty, empty, False)
                return (s[byte=0:i], s[byte=i:n], True)
        if n < 3:
            return (empty, empty, False)
        return (s[byte=0:n], s[byte=n:n], True)
    for i in range(n):
        if raw[i] == _GREATER:
            return (s[byte=1:i], s[byte = i + 1 : n], True)
    return (empty, empty, False)


def _tzset_offset[
    o: ImmOrigin
](s: StringSlice[o]) -> Tuple[Int, StringSlice[o].Immutable, Bool]:
    """An offset at the front of `s`, in seconds, with the rest.

    Go's `tzsetOffset`. The form is `[+-]hh[:mm[:ss]]`. The hours go up to 168
    rather than to 24, which POSIX does not allow and tzcode does, and the sign
    is the one written in the string rather than the one this library uses: see
    `_tzset`, which negates it.
    """
    var raw = s.as_bytes()
    var n = len(raw)
    var empty = s[byte=0:0]
    if n == 0:
        return (0, empty, False)
    var neg = False
    var rest = s[byte=0:n]
    if raw[0] == _PLUS:
        rest = s[byte=1:n]
    elif raw[0] == _MINUS:
        rest = s[byte=1:n]
        neg = True

    var hours, after_hours, hours_ok = _tzset_num(rest, 0, 24 * 7)
    if not hours_ok:
        return (0, empty, False)
    var off = hours * SECONDS_PER_HOUR
    if not _starts_with(after_hours, _COLON):
        return (-off if neg else off, after_hours, True)

    var mins, after_mins, mins_ok = _tzset_num(_tail(after_hours), 0, 59)
    if not mins_ok:
        return (0, empty, False)
    off += mins * SECONDS_PER_MINUTE
    if not _starts_with(after_mins, _COLON):
        return (-off if neg else off, after_mins, True)

    var secs, after_secs, secs_ok = _tzset_num(_tail(after_mins), 0, 59)
    if not secs_ok:
        return (0, empty, False)
    off += secs
    return (-off if neg else off, after_secs, True)


def _tzset_rule[
    o: ImmOrigin
](s: StringSlice[o]) -> Tuple[_Rule, StringSlice[o].Immutable, Bool]:
    """One transition rule at the front of `s`, with the rest.

    Go's `tzsetRule`. The three forms are `Jn`, `n` and `Mm.w.d`, and any of
    them may be followed by `/` and a time, which defaults to two in the
    morning because that is what tzcode defaults it to.
    """
    var raw = s.as_bytes()
    var n = len(raw)
    var empty = s[byte=0:0]
    if n == 0:
        return (_Rule(), empty, False)

    var r = _Rule()
    var rest: StringSlice[o].Immutable
    if raw[0] == _J:
        var jday, after, ok = _tzset_num(s[byte=1:n], 1, 365)
        if not ok:
            return (_Rule(), empty, False)
        r.kind = _RULE_JULIAN
        r.day = jday
        rest = after
    elif raw[0] == _M:
        var mon, after_mon, mon_ok = _tzset_num(s[byte=1:n], 1, 12)
        if not mon_ok or not _starts_with(after_mon, _DOT):
            return (_Rule(), empty, False)
        var week, after_week, week_ok = _tzset_num(_tail(after_mon), 1, 5)
        if not week_ok or not _starts_with(after_week, _DOT):
            return (_Rule(), empty, False)
        var day, after_day, day_ok = _tzset_num(_tail(after_week), 0, 6)
        if not day_ok:
            return (_Rule(), empty, False)
        r.kind = _RULE_MONTH_WEEK_DAY
        r.day = day
        r.week = week
        r.mon = mon
        rest = after_day
    else:
        var day, after, ok = _tzset_num(s, 0, 365)
        if not ok:
            return (_Rule(), empty, False)
        r.kind = _RULE_DOY
        r.day = day
        rest = after

    if not _starts_with(rest, _SLASH):
        r.time = 2 * SECONDS_PER_HOUR
        return (r, rest, True)
    var offset, after_offset, offset_ok = _tzset_offset(_tail(rest))
    if not offset_ok:
        return (_Rule(), empty, False)
    r.time = offset
    return (r, after_offset, True)


def _tzrule_time(year: Int, r: _Rule, off: Int) -> Int:
    """Seconds from the start of `year` to the moment `r` fires. Go's
    `tzruleTime`.

    `off` is the offset in force just before the change, which is what turns a
    local wall clock time into the same instant counted from the start of the
    year in UTC.
    """
    var s: Int
    if r.kind == _RULE_JULIAN:
        s = (r.day - 1) * SECONDS_PER_DAY
        if is_leap(year) and r.day >= 60:
            s += SECONDS_PER_DAY
    elif r.kind == _RULE_DOY:
        s = r.day * SECONDS_PER_DAY
    else:
        # Zeller's congruence, for the day of the week of the first of the
        # month. The month is one to twelve here because the parser checked it,
        # so the shift into a March based year needs no signed division; the
        # year does, and every division below that touches one uses Go's.
        var m1 = (r.mon + 9) % 12 + 1
        var yy0 = year
        if r.mon <= 2:
            yy0 -= 1
        var yy1 = _quo(yy0, 100)
        var yy2 = _rem(yy0, 100)
        var dow = _rem(
            _quo(26 * m1 - 2, 10)
            + 1
            + yy2
            + _quo(yy2, 4)
            + _quo(yy1, 4)
            - 2 * yy1,
            7,
        )
        if dow < 0:
            dow += 7

        # The day of the month of the first `dow` day, then forward a week at a
        # time. Week five means the last one in the month, and the bound stops
        # short rather than running off the end, which is what makes four and
        # five the same date in a month that has only four of that weekday.
        var d = r.day - dow
        if d < 0:
            d += 7
        var i = 1
        while i < r.week:
            if d + 7 >= days_in(Month(r.mon), year):
                break
            d += 7
            i += 1

        d += days_before(Month(r.mon))
        if is_leap(year) and r.mon > 2:
            d += 1
        s = d * SECONDS_PER_DAY

    return s + r.time - off


def _tzset[
    o: ImmOrigin
](s: StringSlice[o], last_tx_sec: Int, sec: Int) -> Tuple[
    String, Int, Int, Int, Bool, Bool
]:
    """What a TZ string says is in force at `sec`. Go's `tzset`.

    The answer is the zone name, its offset in seconds east of UTC, the instant
    the zone came in, the instant it goes out, whether it is daylight time, and
    whether the string parsed at all. `last_tx_sec` is when the file's last
    recorded transition was, and is only used when the string names no daylight
    time, in which case there is nothing after that transition to find.

    The start and end are exact around a change and are the ends of the year
    otherwise, which is all `date` needs and is what Go promises.
    """
    var std_name, after_std, std_ok = _tzset_name(s)
    if not std_ok:
        return _no_zone()
    var written, after_std_off, off_ok = _tzset_offset(after_std)
    if not off_ok:
        return _no_zone()

    # A TZ string counts west, because the number in it is what to add to local
    # time to get UTC. Everything here counts east, because that is what to add
    # to UTC to get local time, so every offset read out of the string is
    # negated on the way in and nowhere else.
    var std_offset = -written

    var rest = after_std_off
    if rest.byte_length() == 0 or rest.as_bytes()[0] == _COMMA:
        return (String(std_name), std_offset, last_tx_sec, _OMEGA, False, True)

    var dst_name, after_dst, dst_ok = _tzset_name(rest)
    var dst_offset = 0
    if dst_ok:
        if after_dst.byte_length() == 0 or after_dst.as_bytes()[0] == _COMMA:
            # No offset given for daylight time means an hour east of standard,
            # which is what it is almost everywhere.
            dst_offset = std_offset + SECONDS_PER_HOUR
            rest = after_dst
        else:
            var raw_off, after_off, ok = _tzset_offset(after_dst)
            dst_offset = -raw_off
            dst_ok = ok
            rest = after_off
    if not dst_ok:
        return _no_zone()

    var start_rule: _Rule
    var end_rule: _Rule
    if rest.byte_length() == 0:
        # tzcode's default when a string names two zones and no rules, which is
        # `,M3.2.0,M11.1.0` written out: the second Sunday of March to the first
        # Sunday of November, changing at two in the morning.
        start_rule = _Rule(_RULE_MONTH_WEEK_DAY, 0, 2, 3, 2 * SECONDS_PER_HOUR)
        end_rule = _Rule(_RULE_MONTH_WEEK_DAY, 0, 1, 11, 2 * SECONDS_PER_HOUR)
    else:
        # POSIX writes a semicolon nowhere and tzcode accepts one, so this does
        # too.
        var lead = rest.as_bytes()[0]
        if lead != _COMMA and lead != _SEMICOLON:
            return _no_zone()
        var first, after_first, first_ok = _tzset_rule(_tail(rest))
        if not first_ok or not _starts_with(after_first, _COMMA):
            return _no_zone()
        var second, after_second, second_ok = _tzset_rule(_tail(after_first))
        if not second_ok or after_second.byte_length() != 0:
            return _no_zone()
        start_rule = first
        end_rule = second

    # Where in the year `sec` falls, and where the year starts.
    var abs_sec = (
        UInt64(sec) + UInt64(_UNIX_TO_INTERNAL) + UInt64(_INTERNAL_TO_ABSOLUTE)
    )
    var year, yday = year_yday(abs_sec // UInt64(SECONDS_PER_DAY))
    var ysec = (yday - 1) * SECONDS_PER_DAY + _rem(sec, SECONDS_PER_DAY)
    var ystart = sec - ysec

    var start_sec = _tzrule_time(year, start_rule, std_offset)
    var end_sec = _tzrule_time(year, end_rule, dst_offset)
    var std_is_dst = False
    var dst_is_dst = True
    if end_sec < start_sec:
        # South of the equator. See the note at the top of this file.
        var t_sec = start_sec
        start_sec = end_sec
        end_sec = t_sec
        var t_name = std_name
        var t_offset = std_offset
        var t_is_dst = std_is_dst
        std_name = dst_name
        std_offset = dst_offset
        std_is_dst = dst_is_dst
        dst_name = t_name
        dst_offset = t_offset
        dst_is_dst = t_is_dst

    if ysec < start_sec:
        return (
            String(std_name),
            std_offset,
            ystart,
            start_sec + ystart,
            std_is_dst,
            True,
        )
    if ysec >= end_sec:
        return (
            String(std_name),
            std_offset,
            end_sec + ystart,
            ystart + 365 * SECONDS_PER_DAY,
            std_is_dst,
            True,
        )
    return (
        String(dst_name),
        dst_offset,
        start_sec + ystart,
        end_sec + ystart,
        dst_is_dst,
        True,
    )


def _no_zone() -> Tuple[String, Int, Int, Int, Bool, Bool]:
    """What `_tzset` gives back when the string is not a TZ string.

    Every field is zero and the last is false, which is Go's, and the caller is
    expected to read the last one rather than the rest.
    """
    return (String(), 0, 0, 0, False, False)


def _starts_with[o: ImmOrigin](s: StringSlice[o], c: UInt8) -> Bool:
    """Whether `s` has anything in it and starts with that byte.

    The two questions together, because the parsing below asks them together
    everywhere and asking them apart is where an empty remainder gets indexed.
    """
    var raw = s.as_bytes()
    return len(raw) > 0 and raw[0] == c


def _tail[o: ImmOrigin](s: StringSlice[o]) -> StringSlice[o].Immutable:
    """Everything after the first byte, which the caller has already looked at.
    """
    return s[byte = 1 : s.byte_length()]
