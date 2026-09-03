"""A decimal number wide enough to hold any float exactly. Go's `decimal.go`.

Not a general purpose big decimal: the only operations are assignment, a binary
shift and rounding, which between them are everything a float conversion needs.
Every float64 is a whole number times a power of two, so shifting a decimal by
the exponent turns the binary value into decimal digits with nothing lost, and
that is the slow path both `parse_float` and `format_float` fall back to when
the fast one declines to answer.

Eight hundred digits is Go's size and it is chosen for the same reason: the
longest exact decimal expansion of a float64 is the smallest subnormal, which
is 1074 bits below the point and about 750 significant digits, and 800 leaves
room. Anything past the end sets `trunc`, which rounding reads.

`_Digits` and `_format_base10` at the bottom are the short buffer the two fast
formatters write into. Go keeps them in `ftoa.go`, which the Dragonbox and
fixed precision files then import from. Doing that here would make three files
that import each other, so they live with the other digit buffer instead.

Nothing here is public.
"""

from core.strconv.itoa import _SMALLS
from core.strconv.tables import _CHEAT_DELTA, _CHEAT_DIGITS, _CHEAT_START


comptime _ZERO = UInt8(ord("0"))
comptime _NINE = UInt8(ord("9"))
comptime _FIVE = UInt8(ord("5"))

comptime _DIGITS_MAX = 800
"""How many digits a `_Decimal` holds. Go's `len(a.d)`."""

comptime _MAX_SHIFT = 60
"""The largest shift one pass can do. Go's `maxShift`, which is the word size
less four, because a pass has to hold `9 << k` in a machine word."""

comptime _DIGITS_SHORT = 32
"""How many digits the two fast formatters can produce. Neither ever needs more
than twenty, which is what a `UInt64` holds. Go uses 32 for one and 24 for the
other; one size does for both here, and the extra bytes are on the stack."""


struct _Decimal(Copyable, Movable):
    """Digits, a decimal point and two flags. Go's `decimal`.

    `d[0:nd]` are the significant digits as ASCII, most significant first, with
    no leading zero and no trailing zero. `dp` is where the point sits relative
    to the start of them, so the value is `0.d * 10^dp`. `neg` is the sign and
    `trunc` says whether nonzero digits fell off the end.
    """

    var d: InlineArray[UInt8, _DIGITS_MAX]
    var nd: Int
    var dp: Int
    var neg: Bool
    var trunc: Bool

    def __init__(out self):
        self.d = InlineArray[UInt8, _DIGITS_MAX](fill=0)
        self.nd = 0
        self.dp = 0
        self.neg = False
        self.trunc = False

    def assign(mut self, v: UInt64):
        """The value of `v`, exactly. Go's `Assign`.

        The digits come out least significant first, so they go into a small
        buffer backwards and are copied forwards, which is the same shape as
        `_append_digits` in `itoa.mojo` and for the same reason.
        """
        var buf = InlineArray[UInt8, 24](fill=0)
        var n = 0
        var u = v
        while u > 0:
            var q = u // 10
            buf[n] = UInt8((u - 10 * q).cast[DType.uint8]()) + _ZERO
            n += 1
            u = q

        self.nd = 0
        while n > 0:
            n -= 1
            self.d[self.nd] = buf[n]
            self.nd += 1
        self.dp = self.nd
        _trim(self)

    def shift(mut self, k: Int):
        """Multiply by `2^k`, or divide by `2^-k`. Go's `Shift`.

        Broken into passes of at most `_MAX_SHIFT` bits, because a wider one
        would overflow the word the digits are carried through.
        """
        if self.nd == 0:
            return
        if k > 0:
            var left = k
            while left > _MAX_SHIFT:
                _left_shift(self, _MAX_SHIFT)
                left -= _MAX_SHIFT
            _left_shift(self, left)
        elif k < 0:
            var left = k
            while left < -_MAX_SHIFT:
                _right_shift(self, _MAX_SHIFT)
                left += _MAX_SHIFT
            _right_shift(self, -left)

    def round(mut self, nd: Int):
        """Keep `nd` digits, rounding half to even. Go's `Round`.

        `nd` of zero rounds to the left of every digit, which is how `0.09`
        becomes `0.1` rather than nothing.
        """
        if nd < 0 or nd >= self.nd:
            return
        if _should_round_up(self, nd):
            self.round_up(nd)
        else:
            self.round_down(nd)

    def round_down(mut self, nd: Int):
        """Keep `nd` digits, throwing the rest away. Go's `RoundDown`."""
        if nd < 0 or nd >= self.nd:
            return
        self.nd = nd
        _trim(self)

    def round_up(mut self, nd: Int):
        """Keep `nd` digits, adding one to the last. Go's `RoundUp`.

        All nines becomes a single one with the point moved, which is the only
        case where rounding changes how many digits there are.
        """
        if nd < 0 or nd >= self.nd:
            return

        var i = nd - 1
        while i >= 0:
            var c = self.d[i]
            if c < _NINE:
                self.d[i] = c + 1
                self.nd = i + 1
                return
            i -= 1

        self.d[0] = UInt8(ord("1"))
        self.nd = 1
        self.dp += 1

    def rounded_integer(self) -> UInt64:
        """The whole part, rounded. Go's `RoundedInteger`.

        No guard against overflow beyond the one Go has, which is that a
        decimal point past twenty digits is more than a `UInt64` holds. Every
        caller has already shifted the value into range.
        """
        if self.dp > 20:
            return UInt64.MAX
        var n = UInt64(0)
        var i = 0
        while i < self.dp and i < self.nd:
            n = n * 10 + UInt64((self.d[i] - _ZERO).cast[DType.uint64]())
            i += 1
        while i < self.dp:
            n *= 10
            i += 1
        if _should_round_up(self, self.dp):
            n += 1
        return n


def _trim(mut a: _Decimal):
    """Drop trailing zeros. Go's `trim`.

    They carry no information, because the decimal point is tracked separately,
    and leaving them would make two spellings of the same number.
    """
    while a.nd > 0 and a.d[a.nd - 1] == _ZERO:
        a.nd -= 1
    if a.nd == 0:
        a.dp = 0


def _right_shift(mut a: _Decimal, k: Int):
    """Divide by `2^k`, for `k` at most `_MAX_SHIFT`. Go's `rightShift`.

    One digit is read and one written on each pass, with the remainder carried
    in the low `k` bits of `n`. Dividing lengthens a number, so the extra digits
    at the end are written after the read runs out.
    """
    var r = 0
    var w = 0
    var n = UInt64(0)
    var shift = UInt64(k)

    # Enough leading digits to make the first shift produce something.
    while (n >> shift) == 0:
        if r >= a.nd:
            if n == 0:
                # The value is zero, which no caller should reach here with.
                a.nd = 0
                return
            while (n >> shift) == 0:
                n *= 10
                r += 1
            break
        n = n * 10 + UInt64((a.d[r] - _ZERO).cast[DType.uint64]())
        r += 1
    a.dp -= r - 1

    var mask = (UInt64(1) << shift) - 1

    while r < a.nd:
        var c = UInt64((a.d[r] - _ZERO).cast[DType.uint64]())
        var dig = n >> shift
        n &= mask
        a.d[w] = UInt8(dig.cast[DType.uint8]()) + _ZERO
        w += 1
        n = n * 10 + c
        r += 1

    while n > 0:
        var dig = n >> shift
        n &= mask
        if w < _DIGITS_MAX:
            a.d[w] = UInt8(dig.cast[DType.uint8]()) + _ZERO
            w += 1
        elif dig > 0:
            a.trunc = True
        n *= 10

    a.nd = w
    _trim(a)


def _prefix_is_less_than(a: _Decimal, k: Int) -> Bool:
    """Whether the digits of `a` come before the cutoff for a shift of `k`.

    Go's `prefixIsLessThan`, with the cutoff looked up here rather than passed
    in. A number that runs out of digits is less than the cutoff, because the
    cutoff continues and it does not.
    """
    var digits = _CHEAT_DIGITS.as_bytes()
    var start = Int(materialize[_CHEAT_START]()[k])
    var stop = Int(materialize[_CHEAT_START]()[k + 1])
    for i in range(stop - start):
        if i >= a.nd:
            return True
        var c = digits[start + i]
        if a.d[i] != c:
            return a.d[i] < c
    return False


def _left_shift(mut a: _Decimal, k: Int):
    """Multiply by `2^k`, for `k` at most `_MAX_SHIFT`. Go's `leftShift`.

    Multiplying adds a known number of digits, so where the answer ends is
    known before it starts and the digits can be written from the end
    backwards. Which of the two possible lengths it is comes from comparing the
    leading digits against `5^k`.
    """
    var delta = Int(materialize[_CHEAT_DELTA]()[k])
    if _prefix_is_less_than(a, k):
        delta -= 1

    var r = a.nd - 1
    var w = a.nd + delta
    var n = UInt64(0)
    var shift = UInt64(k)

    while r >= 0:
        n += UInt64((a.d[r] - _ZERO).cast[DType.uint64]()) << shift
        var quo = n // 10
        var rem = n - 10 * quo
        w -= 1
        if w < _DIGITS_MAX:
            a.d[w] = UInt8(rem.cast[DType.uint8]()) + _ZERO
        elif rem != 0:
            a.trunc = True
        n = quo
        r -= 1

    while n > 0:
        var quo = n // 10
        var rem = n - 10 * quo
        w -= 1
        if w < _DIGITS_MAX:
            a.d[w] = UInt8(rem.cast[DType.uint8]()) + _ZERO
        elif rem != 0:
            a.trunc = True
        n = quo

    a.nd += delta
    if a.nd >= _DIGITS_MAX:
        a.nd = _DIGITS_MAX
    a.dp += delta
    _trim(a)


def _should_round_up(a: _Decimal, nd: Int) -> Bool:
    """Whether chopping `a` at `nd` digits should round the last one up.

    Go's `shouldRoundUp`. Exactly halfway rounds to even, unless digits were
    discarded, in which case the value is a little above halfway and rounds up.
    """
    if nd < 0 or nd >= a.nd:
        return False
    if a.d[nd] == _FIVE and nd + 1 == a.nd:
        if a.trunc:
            return True
        return nd > 0 and (a.d[nd - 1] - _ZERO) % 2 != 0
    return a.d[nd] >= _FIVE


struct _Digits(Copyable, Movable):
    """Digits and a decimal point, without the shifting. Go's `decimalSlice`.

    What the formatters hand to the printers. `d[0:nd]` are the significant
    digits and `dp` is where the point goes, the same meaning they have in
    `_Decimal`, but there is no arithmetic on them and the buffer is short,
    because whatever produced them has already decided how many there are.
    """

    var d: InlineArray[UInt8, _DIGITS_SHORT]
    var nd: Int
    var dp: Int

    def __init__(out self):
        self.d = InlineArray[UInt8, _DIGITS_SHORT](fill=0)
        self.nd = 0
        self.dp = 0


def _format_base10(
    mut a: InlineArray[UInt8, _DIGITS_SHORT], end: Int, u: UInt64
) -> Int:
    """`u` in base ten, written backwards from `end`, and where it starts. Go's
    `formatBase10`.

    Backwards because the last digit is the one arithmetic produces first. Two
    digits per division, from the same table `itoa.mojo` uses; Go's nine digit
    chunking is left out here for the reason it is left out there.

    Go passes a slice and this takes the index its end would have been at,
    because the callers want the digits to land at two different places: the
    shortest formatter fills from the back of the whole buffer and shifts down,
    the fixed one fills exactly the width it asked for and expects zero back.
    """
    var pairs = _SMALLS.as_bytes()
    var i = end
    var v = u
    while v >= 100:
        var q = v // 100
        var d = Int(v - q * 100) * 2
        i -= 2
        a[i] = pairs[d]
        a[i + 1] = pairs[d + 1]
        v = q
    var d = Int(v) * 2
    i -= 1
    a[i] = pairs[d + 1]
    if v >= 10:
        i -= 1
        a[i] = pairs[d]
    return i
