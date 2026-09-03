"""Decimal digits, for printing a `Float`. Go's `decimal.go`.

This is not a number type anybody outside the package uses, and Go's is
unexported for the same reason. It holds a run of ASCII digits and a decimal
exponent, and the only two things it can do are take a binary mantissa apart
into digits and round that run to fewer of them.

The observation the file rests on is Go's, borrowed in turn from
`strconv/decimal.go`: ten is divisible by two, so halving a decimal number is
exact in decimal, and a binary fraction can therefore be written out in decimal
with no loss at all. It does not work the other way round, which is why there
is no left shift here. A left shift is done on the binary side before the
digits are produced.

`core.strconv` has a `_Decimal` of its own with the same idea in it. They are
not the same type: that one carries a fixed eight hundred byte buffer sized for
a `Float64` and can shift both ways, and this one grows and only shifts right,
because a `Float` mantissa has no ceiling.
"""

from .arith import _MojoInt, _W, Word
from .nat import _clone, _lsh, _rsh, _trailing_zero_bits
from .natconv import _DIGIT_0, _utoa

comptime _MAX_SHIFT = _W - 4
"""The widest right shift one pass can do. Go's `maxShift`.

A digit is worth ten of the one below it, so the working value in `_rsh` can
reach `(1 << s - 1) * 10 + 9`, and that has to stay inside a `Word`. Four bits
of headroom is what covers the ten.
"""


struct _Decimal(Copyable, Movable):
    """An unsigned number as decimal digits. Go's `decimal`.

    The value is `0.mant` times ten to the `exp`, so the digits are a fraction
    with the point in front of them and the most significant one first. Zero is
    no digits and an exponent of zero, which is what the default gives.
    """

    var mant: List[UInt8]
    """The digits as ASCII, most significant first, with no trailing zero."""

    var exp: _MojoInt
    """Where the decimal point sits, counted in digits from the front."""

    def __init__(out self):
        """Zero, ready to use."""
        self.mant = List[UInt8]()
        self.exp = 0

    def at(self, i: _MojoInt) -> UInt8:
        """The `i`th digit, or a zero for one that is not there. Go's
        `decimal.at`."""
        if 0 <= i and i < len(self.mant):
            return self.mant[i]
        return _DIGIT_0

    def set[o: ImmOrigin](mut self, m: Span[Word, o], shift: _MojoInt) raises:
        """Set this to `m` shifted by `shift` bits, left when positive and
        right when negative. Go's `decimal.init`.

        The shift left is done in binary, where it is a shift. The shift right
        is done in decimal, in passes of `_MAX_SHIFT` bits, because that is the
        direction binary cannot do without losing digits.
        """
        if len(m) == 0:
            self.mant.resize(0, UInt8(0))
            self.exp = 0
            return

        var value = _clone(m)
        var left = shift

        # Trailing zero bits in the mantissa are worth nothing and each one is
        # a bit the slow decimal shift below would otherwise have to do, so
        # they come off in binary first.
        if left < 0:
            var ntz = _trailing_zero_bits(Span(value))
            var s = -left
            if s >= ntz:
                s = ntz
            var narrowed = _rsh(Span(value), s)
            value = narrowed^
            left += s

        if left > 0:
            var widened = _lsh(Span(value), left)
            value = widened^
            left = 0

        var digits = _utoa(Span(value), 10)
        var n = len(digits)
        self.exp = n
        # The exponent tracks the point, so a trailing zero carries no
        # information and is dropped rather than stored.
        while n > 0 and digits[n - 1] == _DIGIT_0:
            n -= 1
        self.mant.resize(0, UInt8(0))
        for i in range(n):
            self.mant.append(digits[i])

        while left < -_MAX_SHIFT:
            self._rsh(_MAX_SHIFT)
            left += _MAX_SHIFT
        if left < 0:
            self._rsh(-left)

    def _rsh(mut self, s: _MojoInt):
        """Halve this `s` times, with `s` at most `_MAX_SHIFT`. Go's `rsh`.

        Division by a power of two done as shift and subtract, one digit read
        and one digit written at a time, which is why the source and the
        destination can be the same run of bytes.
        """
        var shift = Word(s)
        var mask = (Word(1) << shift) - 1

        # Take in leading digits until there is something above the point.
        var r = 0
        var n = Word(0)
        while (n >> shift) == 0 and r < len(self.mant):
            var ch = Word(self.mant[r])
            r += 1
            n = n * 10 + ch - Word(_DIGIT_0)
        if n == 0:
            # The number is zero, which the caller does not do, but a zero here
            # would loop below rather than produce one.
            self.mant.resize(0, UInt8(0))
            return
        while (n >> shift) == 0:
            r += 1
            n *= 10
        self.exp += 1 - r

        var w = 0
        while r < len(self.mant):
            var ch = Word(self.mant[r])
            r += 1
            var d = n >> shift
            n &= mask
            self.mant[w] = UInt8(d) + _DIGIT_0
            w += 1
            n = n * 10 + ch - Word(_DIGIT_0)

        # Whatever is left of the working value is more digits, and the first
        # of them may still fit in the space the input took.
        while n > 0 and w < len(self.mant):
            var d = n >> shift
            n &= mask
            self.mant[w] = UInt8(d) + _DIGIT_0
            w += 1
            n = n * 10

        self.mant.resize(w, UInt8(0))

        while n > 0:
            var d = n >> shift
            n &= mask
            self.mant.append(UInt8(d) + _DIGIT_0)
            n = n * 10

        self._trim()

    def string(self) -> String:
        """This written out in full, with no exponent. Go's `decimal.String`.

        For reading while debugging; nothing in the package prints through it.
        """
        if len(self.mant) == 0:
            return String("0")

        var buf = List[UInt8]()
        if self.exp <= 0:
            # 0.00ddd
            buf.append(_DIGIT_0)
            buf.append(UInt8(ord(".")))
            for _ in range(-self.exp):
                buf.append(_DIGIT_0)
            for i in range(len(self.mant)):
                buf.append(self.mant[i])
        elif self.exp < len(self.mant):
            # dd.ddd
            for i in range(self.exp):
                buf.append(self.mant[i])
            buf.append(UInt8(ord(".")))
            for i in range(self.exp, len(self.mant)):
                buf.append(self.mant[i])
        else:
            # ddd00
            for i in range(len(self.mant)):
                buf.append(self.mant[i])
            for _ in range(self.exp - len(self.mant)):
                buf.append(_DIGIT_0)
        return String(from_utf8_lossy=Span(buf))

    def _should_round_up(self, n: _MojoInt) -> Bool:
        """Whether cutting this to `n` digits rounds up. Go's `shouldRoundUp`.

        `n` has to be a digit that is there.
        """
        if self.mant[n] == UInt8(ord("5")) and n + 1 == len(self.mant):
            # Exactly half, so it goes to the even neighbour. There are no
            # trailing zeros, which is what makes the length test enough.
            return n > 0 and ((self.mant[n - 1] - _DIGIT_0) & 1) != 0
        return self.mant[n] >= UInt8(ord("5"))

    def round(mut self, n: _MojoInt):
        """Cut this to `n` digits, to nearest and ties to even. Go's
        `decimal.round`.

        A negative `n`, or one at or past the digits there are, leaves the
        value alone.
        """
        if n < 0 or n >= len(self.mant):
            return
        if self._should_round_up(n):
            self.round_up(n)
        else:
            self.round_down(n)

    def round_up(mut self, n_in: _MojoInt):
        """Cut this to `n` digits, always upwards. Go's `decimal.roundUp`."""
        if n_in < 0 or n_in >= len(self.mant):
            return
        var n = n_in

        # Adding one to a nine carries, so the digit that actually changes is
        # the first one below nine.
        while n > 0 and self.mant[n - 1] >= UInt8(ord("9")):
            n -= 1

        if n == 0:
            # Every digit was a nine, so the number becomes a one with the
            # point moved along.
            self.mant[0] = UInt8(ord("1"))
            self.mant.resize(1, UInt8(0))
            self.exp += 1
            return

        self.mant[n - 1] += 1
        self.mant.resize(n, UInt8(0))
        # There is no trailing zero to trim, since the digit just went up.

    def round_down(mut self, n: _MojoInt):
        """Cut this to `n` digits, always downwards. Go's `decimal.roundDown`.
        """
        if n < 0 or n >= len(self.mant):
            return
        self.mant.resize(n, UInt8(0))
        self._trim()

    def _trim(mut self):
        """Drop trailing zero digits, which say nothing. Go's `trim`."""
        var i = len(self.mant)
        while i > 0 and self.mant[i - 1] == _DIGIT_0:
            i -= 1
        self.mant.resize(i, UInt8(0))
        if i == 0:
            self.exp = 0
