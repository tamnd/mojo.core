"""Signed multiple precision integers. Go's `int.go`, `intconv.go`,
`intmarsh.go` and the `Int` half of `prime.go`.

An `Int` is a sign and a magnitude, the magnitude being the digit vector the
rest of this package works on. Everything below this file is unsigned, and
every one of the sign rules Go writes out in comments beside its methods is
here beside the same method.

Two shape changes run through the whole file, and both are worth stating once
rather than repeating on fifty methods.

The first is the destination argument. Go writes every operation as a method on
the answer: `z.Add(x, y)` fills `z` and hands it back, so a caller can reuse an
allocation and can write `z.Add(z, y)` to accumulate. Mojo will not let one
value arrive as both the mutable receiver and a borrowed argument, so that
spelling cannot exist here. Each operation is a method on its first operand and
returns a new value: `x.add(y)`. Where Go's method takes no `Int` at all, as
`SetInt64` does, it stays a setter on `self`, because there is nothing to alias
and Go's shape is the natural one.

The second is what happens when Go returns nil or panics. `ModInverse` returns
nil when there is no inverse, `ModSqrt` returns nil when there is no root, and
`Exp` returns nil when it is asked for a negative power of a number with no
inverse. All three raise here, because a Mojo function cannot return the
absence of an `Int` and a caller that ignores an error gets a loud failure
rather than a silent zero. Division by zero and a negative bit index raise for
the same reason: Go panics, and nothing in this library ends the process for a
condition the caller could have tested.

Three method names are Mojo keywords. `And`, `Or` and `Not` cannot be spelled,
so they are `__and__`, `__or__` and `__invert__`, and `Xor` follows them to
`__xor__` for symmetry. `AndNot` has no operator and stays `and_not`.

`Bits` and `SetBits` copy where Go shares. Go documents both as raw access to
the same backing array, which is a view whose owner can move underneath it, and
`docs/deviations.md` records that this library does not hand those out.
"""

from std.os import abort

from core.errors import Report
from core.errors.codes import (
    ErrBase,
    ErrDivideByZero,
    ErrInvalidArgument,
    ErrSyntax,
)
from core.math import inf, ldexp
from core.math.rand import Source

from .arith import _M, _MojoInt, _W, _nlz, Word
from .nat import (
    _add,
    _and,
    _and_not,
    _bit,
    _bit_len,
    _clone,
    _cmp,
    _fill_bytes,
    _lsh,
    _one,
    _or,
    _rsh,
    _set_bit,
    _set_bytes,
    _set_word,
    _sticky,
    _sub,
    _to_bytes,
    _trailing_zero_bits,
    _xor,
    _zero,
)
from .natconv import _itoa, _scan, MaxBase
from .natdiv import _div, _rem
from .natexp import _exp_nn, _sqrt
from .natmul import _mul, _mul_add_ww, _mul_range
from .natrand import _random
from .prime import _jacobi, _probably_prime
from .rounding import Above, Accuracy, Below, Exact

comptime _MINUS_BYTE = UInt8(ord("-"))
"""The byte a negative number starts with."""

comptime _PLUS_BYTE = UInt8(ord("+"))
"""The sign Go accepts and does not print."""

comptime _GOB_VERSION = UInt8(1)
"""The gob encoding this package writes and the only one it reads. Go's
`intGobVersion`."""

comptime _MAX_FLOAT64_SHIFT = 971
"""The largest power of two a fifty three bit mantissa can be scaled by and
still be a finite `Float64`. One more than this and the answer is an infinity.
"""


struct Int(Copyable, Equatable, Movable):
    """A signed integer of any size. Go's `big.Int`.

    ```mojo
    from core.math.big import new_int

    var a = new_int(1)
    for _ in range(100):
        a = a.mul(new_int(10))
    print(a.bit_len())                # 333
    print(a.string()[byte=0:5])       # 10000
    ```

    The zero value is zero, and `Int()` builds it. Unlike Go, a value here is
    the number rather than a pointer to it, so `b = a.copy()` is a second
    integer with the same value and nothing is shared. That removes the whole
    class of mistake Go's documentation warns about when it says shallow copies
    are not supported.

    Every operation returns a new `Int` rather than filling one in. See the
    module documentation for why, and for the three methods whose Go names are
    Mojo keywords.

    Methods here may leak the value through timing, and the implementation is
    large and general, so this is not the type to build cryptography on. That
    is Go's warning about its own `Int` and it applies unchanged.
    """

    var _neg: Bool
    """Whether the number is below zero. Zero is never negative once a method
    has finished with it, which is what the `len(abs) > 0 and neg` at the end of
    almost every method here is arranging."""

    var _abs: List[Word]
    """The magnitude, smallest digit first, with no leading zero digit."""

    def __init__(out self):
        """Zero. Go's zero value for `Int`."""
        self._neg = False
        self._abs = _zero()

    def __init__(out self, x: Int64):
        """The value of `x`. The same as `new_int(x)`, which is Go's name."""
        self._neg = x < 0
        var magnitude = UInt64(x)
        if x < 0:
            magnitude = ~magnitude + 1
        self._abs = _set_word(Word(magnitude))

    @staticmethod
    def _make(neg: Bool, var abs: List[Word]) -> Self:
        """A value from a sign and a magnitude, with zero forced positive.

        Every method here ends in a call to this, which is where Go's repeated
        `z.neg = len(z.abs) > 0 && neg` lives.
        """
        var z = Self()
        z._neg = neg and len(abs) > 0
        z._abs = abs^
        return z^

    def _take_abs(deinit self) -> List[Word]:
        """The magnitude, taken out of a value that is finished with.

        Mojo will not move one field out of a struct and leave the rest behind,
        so a method that consumes the whole value is how the digits are lifted
        without copying them.
        """
        return self._abs^

    def sign(self) -> _MojoInt:
        """`-1`, `0` or `1` as this is below, at or above zero. Go's
        `Int.Sign`."""
        if len(self._abs) == 0:
            return 0
        if self._neg:
            return -1
        return 1

    def set_int64(mut self, x: Int64):
        """Set this to `x`. Go's `Int.SetInt64`."""
        var magnitude = UInt64(x)
        if x < 0:
            magnitude = ~magnitude + 1
        self._abs = _set_word(Word(magnitude))
        self._neg = x < 0

    def set_uint64(mut self, x: UInt64):
        """Set this to `x`. Go's `Int.SetUint64`."""
        self._abs = _set_word(Word(x))
        self._neg = False

    def set(mut self, x: Self):
        """Set this to `x`. Go's `Int.Set`.

        `x.copy()` is the shorter way to say the same thing and is what most
        callers want. This exists so that a variable already in hand can be
        reused, which is the whole point of Go's version.
        """
        self._abs = x._abs.copy()
        self._neg = x._neg

    def bits(self) -> List[Word]:
        """The magnitude as digits, smallest first. Go's `Int.Bits`.

        A copy. Go hands back the number's own array so that code outside the
        package can implement what the package is missing, and documents that
        the two share storage. Handing out a view of storage this value owns is
        the thing this library does not do anywhere, because the owner can move
        or grow and the view would be pointing at freed memory rather than at
        stale but live bytes.
        """
        return self._abs.copy()

    def set_bits[o: ImmOrigin](mut self, abs: Span[Word, o]):
        """Set this to the digits in `abs`, smallest first, and not negative.
        Go's `Int.SetBits`.

        A copy, for the reason `bits` gives.
        """
        var z = _clone(abs)
        self._abs = _normalised(z^)
        self._neg = False

    def abs(self) -> Self:
        """The magnitude of this, as a positive `Int`. Go's `Int.Abs`."""
        return Self._make(False, self._abs.copy())

    def neg(self) -> Self:
        """This with its sign flipped. Go's `Int.Neg`.

        Zero has no sign, so the negative of zero is zero.
        """
        return Self._make(not self._neg, self._abs.copy())

    def add(self, y: Self) -> Self:
        """This plus `y`. Go's `Int.Add`."""
        var neg = self._neg
        if self._neg == y._neg:
            # x + y, and (-x) + (-y) == -(x + y).
            return Self._make(neg, _add(Span(self._abs), Span(y._abs)))

        # The signs differ, so this is a subtraction, and the larger magnitude
        # decides both the digits and the sign.
        if _cmp(Span(self._abs), Span(y._abs)) >= 0:
            return Self._make(neg, _sub(Span(self._abs), Span(y._abs)))
        return Self._make(not neg, _sub(Span(y._abs), Span(self._abs)))

    def sub(self, y: Self) -> Self:
        """This minus `y`. Go's `Int.Sub`."""
        var neg = self._neg
        if self._neg != y._neg:
            # x - (-y) == x + y, and (-x) - y == -(x + y).
            return Self._make(neg, _add(Span(self._abs), Span(y._abs)))

        if _cmp(Span(self._abs), Span(y._abs)) >= 0:
            return Self._make(neg, _sub(Span(self._abs), Span(y._abs)))
        return Self._make(not neg, _sub(Span(y._abs), Span(self._abs)))

    def mul(self, y: Self) -> Self:
        """This times `y`. Go's `Int.Mul`.

        Go recognises the two operands being the same pointer and squares
        instead, which is a real saving because squaring has a loop of its own.
        There are no pointers here, so a caller who is squaring says so with
        `x.mul(x)` and this cannot tell. `_sqr` is reachable through `exp`,
        where it matters most.
        """
        var product = _mul(Span(self._abs), Span(y._abs))
        return Self._make(self._neg != y._neg, product^)

    @staticmethod
    def mul_range(a: Int64, b: Int64) -> Self:
        """The product of every integer from `a` to `b`. Go's `Int.MulRange`.

        An empty range is one and a range containing zero is zero, both of
        which are Go's answers.
        """
        if a > b:
            return Self(Int64(1))
        if a <= 0 and b >= 0:
            return Self()

        # Now the range is entirely on one side of zero. A range below zero is
        # the mirrored range above it, negated once for each factor, so the
        # sign is decided by whether the count of factors is odd.
        var lo = a
        var hi = b
        var neg = False
        if a < 0:
            neg = ((b - a) & 1) == 0
            lo = -b
            hi = -a

        return Self._make(neg, _mul_range(UInt64(lo), UInt64(hi)))

    @staticmethod
    def binomial(n: Int64, k: Int64) raises -> Self:
        """The number of ways to choose `k` things from `n`. Go's
        `Int.Binomial`.

        Zero when `k` is negative or above `n`, which is Go's answer and the
        conventional one.

        The multiplicative formula, one multiplication and one division per
        step, so the running value stays near the answer instead of climbing to
        `n` factorial and coming back down.
        """
        if k > n or k < 0:
            return Self()

        # C(n, k) is C(n, n-k), so take the smaller of the two and halve the
        # work at worst.
        var steps = k
        if steps > n - steps:
            steps = n - steps

        var upper = Self(n)
        var limit = Self(steps)
        var one = Self(Int64(1))
        var i = Self()
        var z = Self(Int64(1))
        while i.cmp(limit) < 0:
            var factor = upper.sub(i)
            var scaled = z.mul(factor)
            i = i.add(one)
            z = scaled.quo(i)
        return z^

    def quo(self, y: Self) raises -> Self:
        """This divided by `y`, truncated towards zero. Go's `Int.Quo`.

        This is what Go's own `/` does on machine integers. `div` is the
        Euclidean one, which rounds so that the remainder is never negative.
        """
        var both = _div(Span(self._abs), Span(y._abs))
        var q = both^.take_q()
        return Self._make(self._neg != y._neg, q^)

    def rem(self, y: Self) raises -> Self:
        """This modulo `y`, with the sign of this. Go's `Int.Rem`.

        The partner of `quo`, and what Go's own `%` does. `mod` is the
        Euclidean one.
        """
        var r = _rem(Span(self._abs), Span(y._abs))
        return Self._make(self._neg, r^)

    def quo_rem(self, y: Self, mut r: Self) raises -> Self:
        """This divided by `y` truncated towards zero, with the remainder left
        in `r`. Go's `Int.QuoRem`.

        `q = x/y` truncated and `r = x - y*q`, which is Daan Leijen's
        T-division. `div_mod` is the Euclidean pair.

        Go returns both. Mojo cannot unpack a tuple of two values that are not
        implicitly copyable, so the remainder is written through an argument the
        caller already has and the quotient is returned.
        """
        var both = _div(Span(self._abs), Span(y._abs))
        var q = List[Word]()
        var remainder = List[Word]()
        both^.unpack(q, remainder)
        r = Self._make(self._neg, remainder^)
        return Self._make(self._neg != y._neg, q^)

    def div(self, y: Self) raises -> Self:
        """This divided by `y`, Euclidean. Go's `Int.Div`.

        Euclidean division rounds whichever way leaves the remainder at or
        above zero, so it disagrees with `quo` exactly when the truncated
        remainder came out negative.
        """
        var r = Self()
        var q = self.quo_rem(y, r)
        if r._neg:
            var one = Self(Int64(1))
            if y._neg:
                return q.add(one)
            return q.sub(one)
        return q^

    def mod(self, y: Self) raises -> Self:
        """This modulo `y`, never negative. Go's `Int.Mod`.

        The partner of `div`. The result is at or above zero and below the
        magnitude of `y`, whatever the signs of the two operands were.
        """
        var m = Self()
        _ = self.quo_rem(y, m)
        if m._neg:
            if y._neg:
                return m.sub(y)
            return m.add(y)
        return m^

    def div_mod(self, y: Self, mut m: Self) raises -> Self:
        """This divided by `y` Euclidean, with the modulus left in `m`. Go's
        `Int.DivMod`.

        `q` is chosen so that `m = x - y*q` lands at or above zero and below the
        magnitude of `y`. Boute's definition, and the pair `div` and `mod`
        compute one at a time.
        """
        var q = self.quo_rem(y, m)
        if m._neg:
            var one = Self(Int64(1))
            if y._neg:
                var lifted = m.sub(y)
                m = lifted^
                return q.add(one)
            var lowered = m.add(y)
            m = lowered^
            return q.sub(one)
        return q^

    def cmp(self, y: Self) -> _MojoInt:
        """`-1`, `0` or `1` as this is below, equal to or above `y`. Go's
        `Int.Cmp`."""
        if self._neg == y._neg:
            var r = _cmp(Span(self._abs), Span(y._abs))
            return -r if self._neg else r
        if self._neg:
            return -1
        return 1

    def cmp_abs(self, y: Self) -> _MojoInt:
        """The same comparison on the two magnitudes, ignoring both signs. Go's
        `Int.CmpAbs`."""
        return _cmp(Span(self._abs), Span(y._abs))

    def __eq__(self, y: Self) -> Bool:
        """Whether these are the same number."""
        return self.cmp(y) == 0

    def __ne__(self, y: Self) -> Bool:
        """Whether these are different numbers."""
        return self.cmp(y) != 0

    def __lt__(self, y: Self) -> Bool:
        """Whether this is below `y`."""
        return self.cmp(y) < 0

    def __le__(self, y: Self) -> Bool:
        """Whether this is below `y` or equal to it."""
        return self.cmp(y) <= 0

    def __gt__(self, y: Self) -> Bool:
        """Whether this is above `y`."""
        return self.cmp(y) > 0

    def __ge__(self, y: Self) -> Bool:
        """Whether this is above `y` or equal to it."""
        return self.cmp(y) >= 0

    def int64(self) -> Int64:
        """The bottom sixty four bits with the sign applied. Go's `Int.Int64`.

        Undefined when the number does not fit, which is Go's word for it.
        `is_int64` is the question to ask first.
        """
        var v = Int64(self._low64())
        return -v if self._neg else v

    def uint64(self) -> UInt64:
        """The bottom sixty four bits of the magnitude. Go's `Int.Uint64`.

        Undefined when the number does not fit. `is_uint64` is the question to
        ask first.
        """
        return self._low64()

    def _low64(self) -> UInt64:
        """The bottom digit, or zero. Go's `low64`."""
        if len(self._abs) == 0:
            return 0
        return UInt64(self._abs[0])

    def is_int64(self) -> Bool:
        """Whether this fits in an `Int64`. Go's `Int.IsInt64`."""
        if len(self._abs) <= 1:
            var w = Int64(self._low64())
            # The one negative value with no positive counterpart is the most
            # negative Int64, whose negation is itself.
            return w >= 0 or (self._neg and w == -w)
        return False

    def is_uint64(self) -> Bool:
        """Whether this fits in a `UInt64`. Go's `Int.IsUint64`."""
        return not self._neg and len(self._abs) <= 1

    def float64(self) -> Tuple[Float64, Accuracy]:
        """The nearest `Float64`, and which side of the true value it fell.
        Go's `Int.Float64`.

        Round to nearest, ties to even, which is what every IEEE 754 operation
        does. A number too large for the type comes back as an infinity, with
        the accuracy saying which way, because an infinity is above every finite
        positive number and below every finite negative one.

        Go reaches this through `Float`, building one from the integer and
        rounding that. There is no need for the detour: the mantissa is the top
        fifty three bits of the magnitude, the guard bit is the one below them,
        and everything under that is the sticky bit.
        """
        var n = _bit_len(Span(self._abs))
        if n == 0:
            return (Float64(0), Exact)

        # Anything that fits in the mantissa outright, and anything in one digit
        # whose low zeros bring it down to that, converts with no rounding.
        if n <= 53 or (
            n < 64 and n - _trailing_zero_bits(Span(self._abs)) <= 53
        ):
            var exact = Float64(self._low64())
            return (-exact if self._neg else exact, Exact)

        var shift = n - 53
        var top = _rsh(Span(self._abs), shift)
        var mantissa = UInt64(top[0])
        var guard = _bit(Span(self._abs), shift - 1)
        var sticky = _sticky(Span(self._abs), shift - 1)

        var up = guard == 1 and (sticky == 1 or (mantissa & 1) == 1)
        if up:
            mantissa += 1
            if mantissa == (UInt64(1) << 53):
                # Carrying out of the top of the mantissa moves the point.
                mantissa >>= 1
                shift += 1

        if shift > _MAX_FLOAT64_SHIFT:
            if self._neg:
                return (inf(-1), Below)
            return (inf(1), Above)

        var value = ldexp(Float64(mantissa), shift)
        if self._neg:
            value = -value

        if guard == 0 and sticky == 0:
            return (value, Exact)
        # Rounding away from zero raises a positive number and lowers a
        # negative one, and rounding towards zero does the opposite.
        if up:
            return (value, Below if self._neg else Above)
        return (value, Above if self._neg else Below)

    def set_string(mut self, s: String, base: _MojoInt) raises:
        """Set this to the number written in `s` in the given base. Go's
        `Int.SetString`.

        The whole of `s` has to be a number, not merely the front of one. A base
        of zero lets a prefix decide: `0b` for two, `0o` or a leading zero for
        eight, `0x` for sixteen, and ten otherwise, with underscores allowed
        between digits. Any other base has to be between two and `MaxBase`, and
        then no prefix and no underscore is accepted.

        Go returns a boolean and leaves the value undefined on failure. This
        raises and leaves the value alone, so a failed parse cannot be mistaken
        for a successful one.
        """
        self._set_from_bytes(s.as_bytes(), base)

    @staticmethod
    def must_set_string(s: String, base: _MojoInt) -> Self:
        """The number written in `s` in the given base, or an abort.

        Not in Go, which has no `MustSetString` because a Go program can write
        `x, _ := new(big.Int).SetString(...)` at package level and carry on. A
        constant here has to be built inside a function, and `set_string`
        raises, so without this every file wanting a written down modulus or
        curve order would have to be raising to hold one.

        This is for a number the programmer wrote down, and the linter refuses
        it on anything but a literal. `set_string` is the sibling that raises,
        and is the one for a number that came from outside the program.
        """
        var z = Self()
        try:
            z.set_string(s, base)
        except e:
            abort("big: must_set_string could not parse " + s)
        return z^

    def _set_from_bytes[
        o: ImmOrigin
    ](mut self, src: Span[UInt8, o], base: _MojoInt) raises:
        """The body of `set_string`, over bytes.

        Go builds a `strings.Reader` and hands it to the same scanner the
        `Float` and `Rat` parsers use, then checks the reader reached its end.
        The scanner here reports how many bytes it consumed instead, so the same
        check is a comparison of two lengths.
        """
        var pos = 0
        var neg = False
        if len(src) > 0:
            if src[0] == _MINUS_BYTE:
                neg = True
                pos = 1
            elif src[0] == _PLUS_BYTE:
                pos = 1

        var scanned = _scan(src[pos:], base, False)
        var used = scanned.used
        var value = scanned^.take_value()

        if pos + used != len(src):
            raise Report("big: cannot parse this as an integer").with_code(
                ErrSyntax
            ).error()

        self._neg = neg and len(value) > 0
        self._abs = value^

    def set_bytes[o: ImmOrigin](mut self, buf: Span[UInt8, o]):
        """Set this to the unsigned number whose big endian bytes are `buf`.
        Go's `Int.SetBytes`."""
        self._abs = _set_bytes(buf)
        self._neg = False

    def bytes(self) -> List[UInt8]:
        """The magnitude as big endian bytes, as few as will hold it. Go's
        `Int.Bytes`.

        Zero comes back empty, which is Go's answer.
        """
        return _to_bytes(Span(self._abs))

    def fill_bytes[o: MutOrigin](self, buf: Span[UInt8, o]) raises:
        """Write the magnitude into `buf`, big endian and zero padded on the
        left. Go's `Int.FillBytes`.

        Raises when the magnitude does not fit, where Go panics. Go returns the
        buffer as well; there is nothing to return here, since the caller
        already holds it.
        """
        if not _fill_bytes(Span(self._abs), buf):
            raise Report(
                "big: the buffer is too small to hold this number"
            ).with_code(ErrInvalidArgument).error()

    def bit_len(self) -> _MojoInt:
        """How many bits the magnitude needs. Go's `Int.BitLen`.

        Zero needs none.
        """
        return _bit_len(Span(self._abs))

    def trailing_zero_bits(self) -> _MojoInt:
        """How many zero bits sit below the lowest set bit of the magnitude.
        Go's `Int.TrailingZeroBits`.

        Zero has none, which is Go's answer rather than the mathematical one.
        """
        return _trailing_zero_bits(Span(self._abs))

    def exp(self, y: Self, m: Self) raises -> Self:
        """This to the power `y`, modulo the magnitude of `m`. Go's `Int.Exp`.

        A zero `m` means no modulus at all, which is where Go passes nil. With
        no modulus and a negative `y` the answer is one, because the true value
        is a fraction and this is an integer type.

        With a modulus and a negative `y`, the answer is the inverse of this
        raised to the magnitude of `y`, and that raises when this and `m` are
        not relatively prime, where Go returns nil.

        The time this takes depends on the size of the inputs, so it is not a
        constant time operation and not one to reach for in cryptography.
        """
        var base = self._abs.copy()
        if y._neg:
            if len(m._abs) == 0:
                return Self(Int64(1))
            base = self.mod_inverse(m)._take_abs()

        var z = _exp_nn(Span(base), Span(y._abs), Span(m._abs), False)

        # An odd power of a negative number is negative, and every other power
        # of one is positive.
        var neg = self._neg and len(y._abs) > 0 and (y._abs[0] & 1) == 1
        if neg and len(z) > 0 and len(m._abs) > 0:
            # The answer has to land in the range the modulus defines, which is
            # the one that has no negative numbers in it.
            var lifted = _sub(Span(m._abs), Span(z))
            return Self._make(False, lifted^)
        return Self._make(neg, z^)

    def gcd(self, b: Self) raises -> Self:
        """The greatest common divisor of this and `b`. Go's `Int.GCD`.

        Never negative, whatever the signs of the two arguments were, and zero
        only when both are zero.

        Go's method also fills in the two Bezout coefficients when it is given
        somewhere to put them. `gcd_ext` is that version, because Mojo has no
        way to leave an argument out.
        """
        var x = Self()
        var y = Self()
        return _gcd(self, b, False, False, x, y)

    def gcd_ext(self, b: Self, mut x: Self, mut y: Self) raises -> Self:
        """The greatest common divisor of this and `b`, with `x` and `y` set so
        that the divisor is `self*x + b*y`. Go's `Int.GCD` with both of its
        optional arguments supplied.

        Lehmer's algorithm, which does most of its work on the leading digits of
        the two numbers in single digit arithmetic and only touches the full
        numbers when those digits stop agreeing on a quotient.
        """
        return _gcd(self, b, True, True, x, y)

    @staticmethod
    def rand[S: Source](mut src: S, n: Self) -> Self:
        """A number drawn uniformly from zero up to but not including `n`. Go's
        `Int.Rand`.

        Zero when `n` is zero or negative, which is Go's answer.

        This draws from an ordinary generator, so it is not the function to
        build a key with. Go says the same about its version and points at
        `crypto/rand` instead.

        Go's method takes the generator; this takes anything that can produce
        digits, which includes `rand.Rand` and the two generators under it.
        """
        if n._neg or len(n._abs) == 0:
            return Self()
        var bits = _bit_len(Span(n._abs))
        return Self._make(False, _random(src, Span(n._abs), bits))

    def mod_inverse(self, n: Self) raises -> Self:
        """The inverse of this in the integers modulo `n`. Go's
        `Int.ModInverse`.

        The answer is the number below the magnitude of `n` whose product with
        this is one modulo `n`. It exists only when this and `n` are relatively
        prime, and this raises when they are not, where Go returns nil.
        """
        var modulus = n.abs()
        var g = self.copy()
        if g._neg:
            g = g.mod(modulus)

        var x = Self()
        var y = Self()
        var d = _gcd(g, modulus, True, False, x, y)

        if d.cmp(Self(Int64(1))) != 0:
            raise Report(
                "big: this number has no inverse for that modulus"
            ).with_code(ErrInvalidArgument).error()

        # The coefficient the extended algorithm produced is an inverse but may
        # be negative, and the answer is asked to be in range.
        if x._neg:
            return x.add(modulus)
        return x^

    def mod_sqrt(self, p: Self) raises -> Self:
        """A square root of this modulo the odd prime `p`. Go's `Int.ModSqrt`.

        Raises when this is not a square modulo `p`, where Go returns nil, and
        when `p` is even, where Go panics. The answer is meaningless if `p` is
        odd but not prime, which Go also says.

        Three algorithms. A prime that is three modulo four gives the root as a
        single exponentiation, a prime that is five modulo eight gives it by
        Atkin's identity, and anything else goes to Tonelli and Shanks.
        """
        var symbol = jacobi(self, p)
        if symbol == -1:
            raise Report(
                "big: this number is not a square for that modulus"
            ).with_code(ErrInvalidArgument).error()
        if symbol == 0:
            return Self()

        var x = self.copy()
        if x._neg or x.cmp(p) >= 0:
            x = x.mod(p)

        if p._abs[0] % 4 == 3:
            return _mod_sqrt_3_mod_4(x, p)
        if p._abs[0] % 8 == 5:
            return _mod_sqrt_5_mod_8(x, p)
        return _mod_sqrt_tonelli_shanks(x, p)

    def lsh(self, n: _MojoInt) -> Self:
        """This shifted up by `n` bits. Go's `Int.Lsh`.

        A shift up is a multiplication by a power of two, so the sign is
        unchanged.
        """
        return Self._make(self._neg, _lsh(Span(self._abs), n))

    def rsh(self, n: _MojoInt) -> Self:
        """This shifted down by `n` bits. Go's `Int.Rsh`.

        Arithmetic, so a negative number shifts towards negative infinity rather
        than towards zero and never reaches zero. That is what makes `x.rsh(1)`
        the same as `x.div(2)` for every `x`, which the truncating shift would
        not be.
        """
        if self._neg:
            # -x >> s is -(((x-1) >> s) + 1), which is the complement identity
            # written without a complement.
            var lowered = _sub(Span(self._abs), Span(_one()))
            var shifted = _rsh(Span(lowered), n)
            var lifted = _add(Span(shifted), Span(_one()))
            return Self._make(True, lifted^)
        return Self._make(False, _rsh(Span(self._abs), n))

    def bit(self, i: _MojoInt) raises -> _MojoInt:
        """Bit `i` of this, counting from zero at the bottom. Go's `Int.Bit`.

        A negative number is read as if it were written in two's complement and
        extended forever to the left, so the bits above its magnitude are all
        ones. Raises on a negative index, where Go panics.
        """
        if i == 0:
            # Bit zero says whether the number is odd, and that is the same for
            # a number and its negation.
            if len(self._abs) > 0:
                return _MojoInt(self._abs[0] & 1)
            return 0
        if i < 0:
            raise Report("big: negative bit index").with_code(
                ErrInvalidArgument
            ).error()
        if self._neg:
            var lowered = _sub(Span(self._abs), Span(_one()))
            return _bit(Span(lowered), i) ^ 1
        return _bit(Span(self._abs), i)

    def set_bit(self, i: _MojoInt, b: _MojoInt) raises -> Self:
        """This with bit `i` set to `b`, which has to be zero or one. Go's
        `Int.SetBit`.

        A new value rather than a change to this one, for the reason the module
        documentation gives, so the name is Go's and the shape is not. Raises on
        a negative index and on a `b` that is not a bit, both of which Go
        panics on.
        """
        if i < 0:
            raise Report("big: negative bit index").with_code(
                ErrInvalidArgument
            ).error()
        if b != 0 and b != 1:
            raise Report("big: a bit has to be zero or one").with_code(
                ErrInvalidArgument
            ).error()

        if self._neg:
            var lowered = _sub(Span(self._abs), Span(_one()))
            var changed = _set_bit(Span(lowered), i, b ^ 1)
            var lifted = _add(Span(changed), Span(_one()))
            return Self._make(True, lifted^)
        return Self._make(False, _set_bit(Span(self._abs), i, b))

    def __and__(self, y: Self) -> Self:
        """This and `y`, bit by bit. Go's `Int.And`, whose name is a Mojo
        keyword.

        Both are read as if written in two's complement and extended forever to
        the left, so a negative operand contributes ones above its magnitude.
        """
        if self._neg == y._neg:
            if self._neg:
                # (-x) & (-y) is -(((x-1) | (y-1)) + 1).
                var x1 = _sub(Span(self._abs), Span(_one()))
                var y1 = _sub(Span(y._abs), Span(_one()))
                var joined = _or(Span(x1), Span(y1))
                var lifted = _add(Span(joined), Span(_one()))
                return Self._make(True, lifted^)
            return Self._make(False, _and(Span(self._abs), Span(y._abs)))

        # One of each sign. The operation is symmetric, so put the positive one
        # first: x & (-y) is x with the bits of y-1 cleared.
        if self._neg:
            var x1 = _sub(Span(self._abs), Span(_one()))
            return Self._make(False, _and_not(Span(y._abs), Span(x1)))
        var y1 = _sub(Span(y._abs), Span(_one()))
        return Self._make(False, _and_not(Span(self._abs), Span(y1)))

    def and_not(self, y: Self) -> Self:
        """This with the bits of `y` cleared. Go's `Int.AndNot`, which Go writes
        as the `&^` operator."""
        if self._neg == y._neg:
            if self._neg:
                # (-x) &^ (-y) is (y-1) &^ (x-1).
                var x1 = _sub(Span(self._abs), Span(_one()))
                var y1 = _sub(Span(y._abs), Span(_one()))
                return Self._make(False, _and_not(Span(y1), Span(x1)))
            return Self._make(False, _and_not(Span(self._abs), Span(y._abs)))

        if self._neg:
            # (-x) &^ y is -(((x-1) | y) + 1).
            var x1 = _sub(Span(self._abs), Span(_one()))
            var joined = _or(Span(x1), Span(y._abs))
            var lifted = _add(Span(joined), Span(_one()))
            return Self._make(True, lifted^)

        # x &^ (-y) is x & (y-1).
        var y1 = _sub(Span(y._abs), Span(_one()))
        return Self._make(False, _and(Span(self._abs), Span(y1)))

    def __or__(self, y: Self) -> Self:
        """This or `y`, bit by bit. Go's `Int.Or`, whose name is a Mojo
        keyword."""
        if self._neg == y._neg:
            if self._neg:
                # (-x) | (-y) is -(((x-1) & (y-1)) + 1).
                var x1 = _sub(Span(self._abs), Span(_one()))
                var y1 = _sub(Span(y._abs), Span(_one()))
                var shared = _and(Span(x1), Span(y1))
                var lifted = _add(Span(shared), Span(_one()))
                return Self._make(True, lifted^)
            return Self._make(False, _or(Span(self._abs), Span(y._abs)))

        # x | (-y) is -(((y-1) &^ x) + 1), and the operation is symmetric.
        if self._neg:
            var x1 = _sub(Span(self._abs), Span(_one()))
            var kept = _and_not(Span(x1), Span(y._abs))
            var lifted = _add(Span(kept), Span(_one()))
            return Self._make(True, lifted^)
        var y1 = _sub(Span(y._abs), Span(_one()))
        var kept = _and_not(Span(y1), Span(self._abs))
        var lifted = _add(Span(kept), Span(_one()))
        return Self._make(True, lifted^)

    def __xor__(self, y: Self) -> Self:
        """This exclusive or `y`, bit by bit. Go's `Int.Xor`, spelled as the
        operator so that it sits beside `__and__` and `__or__`."""
        if self._neg == y._neg:
            if self._neg:
                # (-x) ^ (-y) is (x-1) ^ (y-1); the extended ones cancel.
                var x1 = _sub(Span(self._abs), Span(_one()))
                var y1 = _sub(Span(y._abs), Span(_one()))
                return Self._make(False, _xor(Span(x1), Span(y1)))
            return Self._make(False, _xor(Span(self._abs), Span(y._abs)))

        # x ^ (-y) is -((x ^ (y-1)) + 1), and the operation is symmetric.
        if self._neg:
            var x1 = _sub(Span(self._abs), Span(_one()))
            var mixed = _xor(Span(y._abs), Span(x1))
            var lifted = _add(Span(mixed), Span(_one()))
            return Self._make(True, lifted^)
        var y1 = _sub(Span(y._abs), Span(_one()))
        var mixed = _xor(Span(self._abs), Span(y1))
        var lifted = _add(Span(mixed), Span(_one()))
        return Self._make(True, lifted^)

    def __invert__(self) -> Self:
        """Every bit of this flipped, which is minus this minus one. Go's
        `Int.Not`, whose name is a Mojo keyword."""
        if self._neg:
            # ^(-x) is x-1.
            return Self._make(False, _sub(Span(self._abs), Span(_one())))
        return Self._make(True, _add(Span(self._abs), Span(_one())))

    def sqrt(self) raises -> Self:
        """The integer square root of this, rounded down. Go's `Int.Sqrt`.

        Raises on a negative number, where Go panics.
        """
        if self._neg:
            raise Report("big: square root of a negative number").with_code(
                ErrInvalidArgument
            ).error()
        return Self._make(False, _sqrt(Span(self._abs)))

    def text(self, base: _MojoInt) raises -> String:
        """This written in the given base. Go's `Int.Text`.

        The base has to be between two and `MaxBase`. Digit values ten to thirty
        five are the lower case letters and thirty six to sixty one are the
        upper case ones, so a base above thirty six is case sensitive. There is
        no prefix, whatever the base.
        """
        var digits = _itoa(Span(self._abs), self._neg, base)
        return String(from_utf8_lossy=Span(digits))

    def append(self, mut buf: List[UInt8], base: _MojoInt) raises:
        """Append this in the given base to `buf`. Go's `Int.Append`.

        Go returns the extended slice, because appending to a Go slice may move
        it. A Mojo list grows in place, so the buffer the caller passed is the
        buffer that ends up with the digits in it and there is nothing to hand
        back.
        """
        var digits = _itoa(Span(self._abs), self._neg, base)
        for i in range(len(digits)):
            buf.append(digits[i])

    def string(self) raises -> String:
        """This in decimal. Go's `Int.String`.

        Raises only because the conversion underneath it can, and base ten is
        always a base it accepts, so this never actually fails.
        """
        return self.text(10)

    def gob_encode(self) -> List[UInt8]:
        """This in the form Go's `encoding/gob` writes. Go's `Int.GobEncode`.

        One byte of version and sign, then the magnitude big endian. The format
        is Go's, so a value written here can be read by a Go program and the
        other way round.
        """
        var digits = _to_bytes(Span(self._abs))
        var out = List[UInt8](capacity=len(digits) + 1)
        var header = _GOB_VERSION << 1
        if self._neg:
            header |= 1
        out.append(header)
        for i in range(len(digits)):
            out.append(digits[i])
        return out^

    def gob_decode[o: ImmOrigin](mut self, buf: Span[UInt8, o]) raises:
        """Set this from the form Go's `encoding/gob` writes. Go's
        `Int.GobDecode`.

        An empty input is the zero value, which is what Go's encoder sends for
        one. Any other version byte raises.
        """
        if len(buf) == 0:
            self._neg = False
            self._abs = _zero()
            return

        if (buf[0] >> 1) != _GOB_VERSION:
            raise Report(
                "big: this gob encoding version is not supported"
            ).with_code(ErrInvalidArgument).error()

        self._neg = (buf[0] & 1) != 0
        self._abs = _set_bytes(buf[1:])

    def append_text(self, mut buf: List[UInt8]) raises:
        """Append this in decimal to `buf`. Go's `Int.AppendText`."""
        self.append(buf, 10)

    def marshal_text(self) raises -> List[UInt8]:
        """This in decimal, as bytes. Go's `Int.MarshalText`."""
        var out = List[UInt8]()
        self.append_text(out)
        return out^

    def unmarshal_text[o: ImmOrigin](mut self, text: Span[UInt8, o]) raises:
        """Set this from the decimal or prefixed text in `text`. Go's
        `Int.UnmarshalText`.

        Base zero, so the prefixes `0b`, `0o`, `0x` and a leading zero all mean
        what they mean in Go source, and underscores may separate digits.
        """
        self._set_from_bytes(text, 0)

    def marshal_json(self) raises -> List[UInt8]:
        """This as a JSON number. Go's `Int.MarshalJSON`.

        The same bytes as `marshal_text`. Go keeps both methods for the
        programs that look for them by name.
        """
        return self.marshal_text()

    def unmarshal_json[o: ImmOrigin](mut self, text: Span[UInt8, o]) raises:
        """Set this from a JSON number. Go's `Int.UnmarshalJSON`.

        A JSON null leaves the value alone, which is what the rest of Go's JSON
        decoding does with one.
        """
        if _is_null(text):
            return
        self.unmarshal_text(text)

    def probably_prime(self, n: _MojoInt) raises -> Bool:
        """Whether this is probably prime. Go's `Int.ProbablyPrime`.

        A Baillie-PSW test, plus `n` rounds of Miller-Rabin with randomly chosen
        bases. A prime always answers true. A composite chosen at random answers
        true with probability at most one in four to the `n`, and no composite
        below two to the sixty four is known to answer true even at `n` of zero.

        This is not proof against a number an adversary built to fool it, which
        is Go's warning as well. Raises on a negative `n`, where Go panics.
        """
        return _probably_prime(self._neg, Span(self._abs), n)


def new_int(x: Int64) -> Int:
    """An `Int` holding `x`. Go's `NewInt`.

    Go returns a pointer because every one of its operations needs one. Here it
    is a value, and `Int(x)` is the same call written as a constructor.
    """
    return Int(x)


def jacobi(x: Int, y: Int) raises -> _MojoInt:
    """The Jacobi symbol of `x` over `y`, which is `1`, `-1` or `0`. Go's
    `Jacobi`.

    `y` has to be odd. Go panics when it is not; this raises.
    """
    return _jacobi(x._neg, Span(x._abs), y._neg, Span(y._abs))


def _normalised(var z: List[Word]) -> List[Word]:
    """`z` with its leading zero digits removed.

    `set_bits` is the one place a caller's digits arrive unnormalised, and
    `nat.mojo` keeps its own `_norm` private, so this is the one line of it that
    the public surface needs.
    """
    var i = len(z)
    while i > 0 and z[i - 1] == 0:
        i -= 1
    z.resize(i, Word(0))
    return z^


def _is_null[o: ImmOrigin](text: Span[UInt8, o]) -> Bool:
    """Whether `text` is exactly the four bytes of a JSON null."""
    if len(text) != 4:
        return False
    return (
        text[0] == UInt8(ord("n"))
        and text[1] == UInt8(ord("u"))
        and text[2] == UInt8(ord("l"))
        and text[3] == UInt8(ord("l"))
    )


def _mul_w(x: Int, neg: Bool, w: Word) -> Int:
    """`x` times `w`, negated when `neg`. Go's `mulW`.

    One digit multiplied through a whole number, which is what the cosequences
    in Lehmer's algorithm need and the only multiplication in it that is not
    single digit.
    """
    return Int._make(x._neg != neg, _mul_add_ww(Span(x._abs), w, 0))


def _lehmer_simulate(a: Int, b: Int) -> Tuple[Word, Word, Word, Word, Bool]:
    """Several Euclidean steps at once, from the leading digits alone. Go's
    `lehmerSimulate`.

    Returns four coefficients and a parity, such that the two numbers can be
    advanced by `A = u0*A + v0*B` and `B = u1*A + v1*B`. The coefficients are
    magnitudes and the parity says their signs: on an even count `u0` and `v1`
    are positive and the other two are not, and on an odd count it is the other
    way round. Carrying the sign separately is what keeps every intermediate
    inside one digit.

    `a` has to be at least `b` and `b` has to have at least two digits. The
    stopping condition is Collins', which needs only one quotient per step and
    cannot overflow a digit; Jebelean's paper section 4.2 is the argument.
    """
    var m = len(b._abs)
    var n = len(a._abs)

    # The top digit of each, aligned so that the top bit of a's is set.
    var h = _nlz(a._abs[n - 1])
    var a1 = (a._abs[n - 1] << h) | _shift_down(a._abs[n - 2], Word(_W) - h)

    var a2 = Word(0)
    if n == m:
        a2 = (b._abs[n - 1] << h) | _shift_down(b._abs[n - 2], Word(_W) - h)
    elif n == m + 1:
        # b is one digit shorter, so its top digit lands in the low half.
        a2 = _shift_down(b._abs[n - 2], Word(_W) - h)

    var u0 = Word(0)
    var u1 = Word(1)
    var u2 = Word(0)
    var v0 = Word(0)
    var v1 = Word(0)
    var v2 = Word(1)
    var even = False

    while a2 >= v2 and a1 - a2 >= v1 + v2:
        var q = a1 // a2
        var r = a1 % a2
        a1 = a2
        a2 = r

        var next_u2 = u1 + q * u2
        u0 = u1
        u1 = u2
        u2 = next_u2

        var next_v2 = v1 + q * v2
        v0 = v1
        v1 = v2
        v2 = next_v2

        even = not even

    return (u0, u1, v0, v1, even)


def _shift_down(w: Word, s: Word) -> Word:
    """`w >> s`, answering zero for a shift of the whole width.

    Go's rule for a shift wider than the type is zero, and Mojo leaves it
    undefined, so the one place `lehmerSimulate` relies on it is written out.
    """
    if s >= Word(_W):
        return 0
    return w >> s


def _lehmer_update(
    mut a: Int,
    mut b: Int,
    u0: Word,
    u1: Word,
    v0: Word,
    v1: Word,
    even: Bool,
):
    """Advance `a` and `b` by the coefficients `_lehmer_simulate` produced. Go's
    `lehmerUpdate`."""
    var q = _mul_w(b, even, v0)
    var r = _mul_w(a, even, u1)
    var next_a = _mul_w(a, not even, u0)
    var next_b = _mul_w(b, not even, v1)
    a = next_a.add(q)
    b = next_b.add(r)


def _euclid_update(
    mut a: Int, mut b: Int, mut ua: Int, mut ub: Int, extended: Bool
) raises:
    """One ordinary Euclidean step, with the cosequence carried along. Go's
    `euclidUpdate`.

    What Lehmer's algorithm falls back to when the leading digits are not enough
    to decide a quotient.
    """
    var r = Int()
    var q = a.quo_rem(b, r)

    if extended:
        var scaled = q.mul(ub)
        var next_ub = ua.sub(scaled)
        ua = ub^
        ub = next_ub^

    a = b^
    b = r^


def _gcd(
    a: Int, b: Int, want_x: Bool, want_y: Bool, mut x: Int, mut y: Int
) raises -> Int:
    """The greatest common divisor, and the Bezout coefficients when asked for.
    Go's `Int.GCD` together with `Int.lehmerGCD`.

    Go decides what to compute by whether it was handed somewhere to put the
    answer. Mojo has no absent argument, so the two booleans say it instead.
    """
    if len(a._abs) == 0 or len(b._abs) == 0:
        # One of them is zero, so the other one is the answer and the
        # coefficients are whichever pair reproduces it.
        var len_a = len(a._abs)
        var len_b = len(b._abs)
        var z = b.abs() if len_a == 0 else a.abs()

        if want_x:
            if len_a == 0:
                x = Int()
            else:
                x = Int._make(a._neg, _one())
        if want_y:
            if len_b == 0:
                y = Int()
            else:
                y = Int._make(b._neg, _one())
        return z^

    return _lehmer_gcd(a, b, want_x, want_y, x, y)


def _lehmer_gcd(
    a: Int, b: Int, want_x: Bool, want_y: Bool, mut x: Int, mut y: Int
) raises -> Int:
    """Lehmer's algorithm, with Collins' condition and Jebelean's cosequence
    update. Go's `Int.lehmerGCD`, which cites Knuth volume two section 4.5.2 for
    the algorithm and Cohen and others for the cosequences.

    Both arguments have to be non zero. The idea is that the quotients in the
    Euclidean algorithm are almost always decided by the leading digits alone,
    so several steps at a time are simulated in single digit arithmetic and only
    the combined effect is applied to the full numbers.
    """
    var extended = want_x or want_y

    var big = a.abs()
    var small = b.abs()

    # How many times a has been accumulated into each of the two running values.
    var ua = Int(Int64(1)) if extended else Int()
    var ub = Int()

    if _cmp(Span(big._abs), Span(small._abs)) < 0:
        var swapped = big^
        big = small^
        small = swapped^
        var swapped_u = ua^
        ua = ub^
        ub = swapped_u^

    # The loop keeps the larger of the two first.
    while len(small._abs) > 1:
        var u0, u1, v0, v1, even = _lehmer_simulate(big, small)

        if v0 != 0:
            _lehmer_update(big, small, u0, u1, v0, v1, even)
            if extended:
                _lehmer_update(ua, ub, u0, u1, v0, v1, even)
        else:
            # The leading digits agreed on nothing, so take one real step.
            _euclid_update(big, small, ua, ub, extended)

    if len(small._abs) > 0:
        if len(big._abs) > 1:
            _euclid_update(big, small, ua, ub, extended)
        if len(small._abs) > 0:
            # Both are down to one digit, so the rest is the ordinary algorithm
            # on two machine numbers.
            var av = big._abs[0]
            var bv = small._abs[0]
            if extended:
                var ca = Word(1)
                var cb = Word(0)
                var da = Word(0)
                var db = Word(1)
                var even = True
                while bv != 0:
                    var q = av // bv
                    var r = av % bv
                    av = bv
                    bv = r
                    var next_cb = ca + q * cb
                    ca = cb
                    cb = next_cb
                    var next_db = da + q * db
                    da = db
                    db = next_db
                    even = not even

                var scaled_a = _mul_w(ua, not even, ca)
                var scaled_b = _mul_w(ub, even, da)
                ua = scaled_a.add(scaled_b)
            else:
                while bv != 0:
                    var r = av % bv
                    av = bv
                    bv = r
            big._abs[0] = av

    var neg_a = a._neg
    if want_y:
        # y is what is left of the divisor once a times x is taken out of it.
        var scaled = a.mul(ua)
        if neg_a:
            scaled = scaled.neg()
        var remainder = big.sub(scaled)
        y = remainder.div(b)

    if want_x:
        x = ua.copy()
        if neg_a:
            x = x.neg()

    return big^


def _mod_sqrt_3_mod_4(x: Int, p: Int) raises -> Int:
    """A square root of `x` modulo a prime that is three modulo four. Go's
    `Int.modSqrt3Mod4Prime`.

    For such a prime, `x` to the power `(p+1)/4` squared is `x` to the power
    `p+1`, which is `x` squared by Fermat, so the power itself is a root.
    """
    var one = Int(Int64(1))
    var e = p.add(one)
    var quarter = e.rsh(2)
    return x.exp(quarter, p)


def _mod_sqrt_5_mod_8(x: Int, p: Int) raises -> Int:
    """A square root of `x` modulo a prime that is five modulo eight. Go's
    `Int.modSqrt5Mod8Prime`.

    Atkin's construction. Two is not a square modulo such a prime, so `2x` to
    the power `(p-5)/8` gives an `alpha` from which a square root of minus one
    falls out, and a root of `x` with it.
    """
    var one = Int(Int64(1))
    var e = p.rsh(3)
    var tx = x.lsh(1)
    var alpha = tx.exp(e, p)

    var beta = alpha.mul(alpha).mod(p)
    beta = beta.mul(tx).mod(p)
    beta = beta.sub(one)
    beta = beta.mul(x).mod(p)
    beta = beta.mul(alpha)
    return beta.mod(p)


def _mod_sqrt_tonelli_shanks(x: Int, p: Int) raises -> Int:
    """A square root of `x` modulo any odd prime. Go's
    `Int.modSqrtTonelliShanks`.

    Follows section six of Ezra Brown's `Square roots from 1; 24, 51, 10 to Dan
    Shanks`. Write `p-1` as an odd `s` shifted up by `e`, find any non residue
    `n`, and then walk a value down through the subgroup of order two to the `e`
    until it reaches one, correcting the candidate root at each step.
    """
    var one = Int(Int64(1))

    var s = p.sub(one)
    var e = _trailing_zero_bits(Span(s._abs))
    s = s.rsh(e)

    # Any non residue will do, and the smallest is found by trying.
    var n = Int(Int64(2))
    while jacobi(n, p) != -1:
        n = n.add(one)

    var half = s.add(one).rsh(1)
    var y = x.exp(half, p)
    var b = x.exp(s, p)
    var g = n.exp(s, p)
    var r = e

    while True:
        # The least m with b to the power two to the m equal to one.
        var m = 0
        var t = b.copy()
        while t.cmp(one) != 0:
            t = t.mul(t).mod(p)
            m += 1

        if m == 0:
            return y^

        var bit = Int().set_bit(r - m - 1, 1)
        var factor = g.exp(bit, p)
        g = factor.mul(factor).mod(p)
        y = y.mul(factor).mod(p)
        b = b.mul(g).mod(p)
        r = m
