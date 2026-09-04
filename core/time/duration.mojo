"""How long something took, in nanoseconds. Go's `Duration`.

A count of nanoseconds held in a machine word, which puts the largest interval
this can describe at about 290 years either side of zero. That is the same
limit Go has and for the same reason, and it is the reason there is no unit
above `HOUR`: a day is not always 24 hours and a month is not any fixed number
of days, so a constant for either would be a lie that only shows itself twice a
year.

The arithmetic is Go's, which means it rounds towards zero rather than towards
negative infinity. `divide.mojo` says why that is worth stating and where the
difference shows.
"""

from .divide import _quo, _rem

comptime _MAX = 9_223_372_036_854_775_807
"""The largest duration, and what an overflowing `round` answers."""

comptime _MIN = -_MAX - 1
"""The most negative duration.

Written as one less than the negation of `_MAX` because the honest literal
cannot be written: the positive number it would be negated from is itself out
of range. Its magnitude being one larger than `_MAX`'s is what makes `__abs__`
a special case rather than a negation.
"""


struct Duration(
    Absable, Copyable, Equatable, ImplicitlyCopyable, Movable, Writable
):
    """An elapsed time, as a signed count of nanoseconds.

    ```mojo
    from core.time import MILLISECOND, SECOND, Duration

    var timeout = 5 * SECOND
    print(timeout // MILLISECOND)  # => 5000
    print(timeout)  # => 5s
    ```

    Build one from the constants rather than from a bare number, because the
    number on its own says nothing: `Duration(5)` is five nanoseconds and
    `5 * SECOND` is what somebody writing five seconds meant. The constants are
    capitals here where Go spells them `time.Second`, on the same rule that
    gave `core.io` its seek constants their capitals.
    """

    var value: Int
    """The count of nanoseconds, which is the whole of the value.

    Public because a duration is a number and pretending otherwise would mean
    an accessor for every way of getting at it. `nanoseconds` is the name Go
    gives the same thing.
    """

    def __init__(out self, nanoseconds: Int):
        """Hold a count of nanoseconds."""
        self.value = nanoseconds

    def __eq__(self, other: Self) -> Bool:
        """Whether these are the same length of time."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether these are different lengths of time."""
        return self.value != other.value

    def __lt__(self, other: Self) -> Bool:
        """Whether this is the shorter of the two, signs included."""
        return self.value < other.value

    def __le__(self, other: Self) -> Bool:
        """Whether this is no longer than the other."""
        return self.value <= other.value

    def __gt__(self, other: Self) -> Bool:
        """Whether this is the longer of the two, signs included."""
        return self.value > other.value

    def __ge__(self, other: Self) -> Bool:
        """Whether this is no shorter than the other."""
        return self.value >= other.value

    def __neg__(self) -> Self:
        """The same length of time, the other way round."""
        return Self(-self.value)

    def __add__(self, other: Self) -> Self:
        """The two run end to end."""
        return Self(self.value + other.value)

    def __sub__(self, other: Self) -> Self:
        """What is left of this one after the other."""
        return Self(self.value - other.value)

    def __mul__(self, n: Int) -> Self:
        """This one `n` times over, which is how `5 * SECOND` is written."""
        return Self(self.value * n)

    def __rmul__(self, n: Int) -> Self:
        """`n * SECOND`, which is the order Go writes it in."""
        return Self(self.value * n)

    def __floordiv__(self, other: Self) -> Int:
        """How many of `other` fit in this, rounding towards zero.

        ```mojo
        from core.time import MILLISECOND, SECOND

        print(SECOND // MILLISECOND)  # => 1000
        ```

        Go's `d / time.Millisecond` gives another `Duration`, because both
        sides are the same type and Go's division has to answer in it. The
        answer is a count rather than a length of time, so it is an `Int` here.
        """
        return _quo(self.value, other.value)

    def __floordiv__(self, n: Int) -> Self:
        """This one cut into `n` parts, rounding towards zero."""
        return Self(_quo(self.value, n))

    def __abs__(self) -> Self:
        """The magnitude, ignoring which way round it is. Go's `Abs`.

        The most negative duration answers with the largest positive one, which
        is one nanosecond short of its true magnitude. Two's complement has no
        room for the honest answer and the alternative is raising from a
        function nobody expects to fail.
        """
        if self.value >= 0:
            return self
        if self.value == _MIN:
            return Self(_MAX)
        return Self(-self.value)

    def nanoseconds(self) -> Int:
        """The whole value, as a count of nanoseconds."""
        return self.value

    def microseconds(self) -> Int:
        """The value in whole microseconds, rounding towards zero."""
        return _quo(self.value, 1_000)

    def milliseconds(self) -> Int:
        """The value in whole milliseconds, rounding towards zero."""
        return _quo(self.value, 1_000_000)

    def seconds(self) -> Float64:
        """The value in seconds, fraction included.

        The whole part and the fraction are divided separately and added at the
        end, rather than dividing the nanosecond count by a billion, so that
        converting the answer back to an integer rounds the way an integer
        division would have. Go splits it for the same reason and says so.
        """
        var sec = _quo(self.value, 1_000_000_000)
        var nsec = _rem(self.value, 1_000_000_000)
        return Float64(sec) + Float64(nsec) / 1e9

    def minutes(self) -> Float64:
        """The value in minutes, fraction included."""
        var minute = _quo(self.value, 60_000_000_000)
        var nsec = _rem(self.value, 60_000_000_000)
        return Float64(minute) + Float64(nsec) / 6e10

    def hours(self) -> Float64:
        """The value in hours, fraction included."""
        var hour = _quo(self.value, 3_600_000_000_000)
        var nsec = _rem(self.value, 3_600_000_000_000)
        return Float64(hour) + Float64(nsec) / 3.6e12

    def truncate(self, m: Self) -> Self:
        """This one rounded towards zero to a multiple of `m`.

        A zero or negative `m` gives the duration back unchanged, which is Go's
        rule. It is the answer that lets a caller pass a configured granularity
        through without checking it first.
        """
        if m.value <= 0:
            return self
        return Self(self.value - _rem(self.value, m.value))

    def round(self, m: Self) -> Self:
        """This one rounded to the nearest multiple of `m`, halves away from
        zero.

        A zero or negative `m` gives the duration back unchanged. A result too
        large to hold gives the largest duration in that direction rather than
        wrapping round to the other sign, which is the one answer that is
        wrong in a way nobody would notice.
        """
        if m.value <= 0:
            return self
        var r = _rem(self.value, m.value)
        if self.value < 0:
            r = -r
            if _less_than_half(r, m.value):
                return Self(self.value + r)
            var down = self.value - m.value + r
            if down < self.value:
                return Self(down)
            return Self(_MIN)
        if _less_than_half(r, m.value):
            return Self(self.value - r)
        var up = self.value + m.value - r
        if up > self.value:
            return Self(up)
        return Self(_MAX)

    def write_to[W: Writer](self, mut writer: W):
        """The duration in Go's own notation, as `Duration.String` writes it.

        ```mojo
        from core.time import HOUR, MILLISECOND, MINUTE, SECOND

        print(72 * HOUR + 3 * MINUTE + 500 * MILLISECOND)  # => 72h3m0.5s
        ```

        Leading units that would be zero are left out and trailing zeros in the
        fraction go too. Anything shorter than a second moves to the largest
        unit that leaves a non zero leading digit, so a duration reads as
        `1.5ms` rather than as `0.0015s`. Zero is `0s`.
        """
        writer.write(self._text())

    def _text(self) -> String:
        """The notation above, built backwards into a fixed buffer.

        Backwards because every unit is decided by what is left after the
        smaller ones have been taken off, so the last character is the first
        thing known. The buffer is 32 bytes because the longest duration there
        is spells out as `2540400h10m10.000000000s`, which is 24.
        """
        var buf = List[UInt8](length=32, fill=0)
        var w = 32
        var u = UInt64(self.value)
        var negative = self.value < 0
        if negative:
            u = UInt64(0) - u

        if u < 1_000_000_000:
            # Shorter than a second, so the unit is whichever one puts a digit
            # in front of the decimal point.
            var prec: Int
            w -= 1
            buf[w] = UInt8(ord("s"))
            w -= 1
            if u == 0:
                buf[w] = UInt8(ord("0"))
                return String(from_utf8_lossy=Span(buf)[w:32])
            elif u < 1_000:
                prec = 0
                buf[w] = UInt8(ord("n"))
            elif u < 1_000_000:
                prec = 3
                # Two bytes, because the micro sign is U+00B5 and this buffer
                # holds UTF-8 rather than characters.
                w -= 1
                buf[w] = 0xC2
                buf[w + 1] = 0xB5
            else:
                prec = 6
                buf[w] = UInt8(ord("m"))
            var fraction = _fmt_frac(buf, w, u, prec)
            w = fraction[0]
            u = fraction[1]
            w = _fmt_int(buf, w, u)
        else:
            w -= 1
            buf[w] = UInt8(ord("s"))
            var fraction = _fmt_frac(buf, w, u, 9)
            w = fraction[0]
            u = fraction[1]

            # Whole seconds now.
            w = _fmt_int(buf, w, u % 60)
            u //= 60

            # Whole minutes now, and hours after that. It stops at hours
            # because a day is not always 24 of them.
            if u > 0:
                w -= 1
                buf[w] = UInt8(ord("m"))
                w = _fmt_int(buf, w, u % 60)
                u //= 60
                if u > 0:
                    w -= 1
                    buf[w] = UInt8(ord("h"))
                    w = _fmt_int(buf, w, u)

        if negative:
            w -= 1
            buf[w] = UInt8(ord("-"))
        return String(from_utf8_lossy=Span(buf)[w:32])


def _less_than_half(x: Int, y: Int) -> Bool:
    """Whether `x + x < y`, for two values already known to be positive.

    The addition is done unsigned so that a sum too large for a signed word
    wraps into a large unsigned number rather than into a negative one, which
    is what would make the comparison answer backwards for the two largest
    durations. Go writes it the same way.
    """
    return UInt64(x) + UInt64(x) < UInt64(y)


def _fmt_frac(
    mut buf: List[UInt8], w: Int, v: UInt64, prec: Int
) -> Tuple[Int, UInt64]:
    """`prec` digits of fraction written backwards into `buf` before `w`.

    Trailing zeros are left out, and so is the decimal point when every digit
    of the fraction was one. Answers with the new write position and what is
    left of the value.
    """
    var at = w
    var left = v
    var printing = False
    for _ in range(prec):
        var digit = left % 10
        printing = printing or digit != 0
        if printing:
            at -= 1
            buf[at] = UInt8(digit) + UInt8(ord("0"))
        left //= 10
    if printing:
        at -= 1
        buf[at] = UInt8(ord("."))
    return (at, left)


def _fmt_int(mut buf: List[UInt8], w: Int, v: UInt64) -> Int:
    """`v` in decimal, written backwards into `buf` before `w`.

    Answers with the new write position. Zero writes one digit rather than
    nothing, which is what makes `0s` and `1m0s` come out right.
    """
    var at = w
    var left = v
    if left == 0:
        at -= 1
        buf[at] = UInt8(ord("0"))
    else:
        while left > 0:
            at -= 1
            buf[at] = UInt8(left % 10) + UInt8(ord("0"))
            left //= 10
    return at


comptime NANOSECOND = Duration(1)
"""One nanosecond, the unit everything here is counted in."""

comptime MICROSECOND = Duration(1_000)
"""One microsecond, a thousand nanoseconds."""

comptime MILLISECOND = Duration(1_000_000)
"""One millisecond, a thousand microseconds."""

comptime SECOND = Duration(1_000_000_000)
"""One second, a thousand milliseconds."""

comptime MINUTE = Duration(60_000_000_000)
"""One minute, sixty seconds."""

comptime HOUR = Duration(3_600_000_000_000)
"""One hour, sixty minutes.

The largest unit there is. A day is 23, 24 or 25 hours long depending on where
you are and what the government did to the clocks, so a `DAY` constant would be
wrong twice a year in most of the world. `Time.add_date` is what adds a day.
"""
