"""Rational numbers. Go's `rat.go`, `ratconv.go` and `ratmarsh.go`.

A `Rat` is a numerator and a denominator, both `Int`, kept in lowest terms with
the sign on the numerator and the denominator always one or more. Every
operation ends by dividing out the common factor, so two values that are equal
as numbers are equal digit for digit as well.

Go leaves the denominator of a fresh `Rat` empty and treats an empty one as a
one, which saves it an allocation on a value nobody has assigned to yet. It
pays for that with `mulDenom` and `scaleDenom`, two helpers whose whole job is
to remember that an empty denominator is really a one, and with the repair
inside `norm`. The denominator here is a one from the moment the value exists,
so neither helper has a counterpart and neither does that half of `norm`. Go
normalises at the first assignment, so no number ever behaves differently.

The two shape changes from `int.mojo` run through this file as well. There is
no destination argument: `x.add(y)` returns a new value where Go writes
`z.Add(x, y)`. Panics and nil returns are raises: a zero denominator, an
inverse of zero and a division by zero all raise with `ErrDivideByZero`, a
`SetFloat64` of an infinity or a NaN raises where Go returns nil, and every
text that will not parse raises where Go returns a false.

`num` and `denom` return copies. Go returns pointers into the value and
documents that assigning to the `Rat` changes what they point at, which is the
same sharing `Int.bits` does not do here for the same reason: the owner can
move.
"""

from core.errors import Report
from core.errors.codes import ErrInvalidArgument, ErrOverflow, ErrSyntax
from core.math import float64bits, is_inf, ldexp
from core.strconv import parse_int

from .arith import _MojoInt, Word
from .int import _MINUS_BYTE, _PLUS_BYTE, Int
from .nat import (
    _add,
    _bit_len,
    _clone,
    _cmp,
    _five,
    _lsh,
    _one,
    _rsh,
    _set_word,
    _sub,
    _ten,
    _to_bytes,
    _trailing_zero_bits,
    _zero,
)
from .natconv import (
    _DIGIT_0,
    _DIGIT_9,
    _PERIOD,
    _PREV_DIGIT,
    _PREV_OTHER,
    _PREV_SEPARATOR,
    _scan,
    _UNDERSCORE,
    _utoa,
)
from .natdiv import _div, _divide_by_zero
from .natexp import _exp_nn
from .natmul import _mul, _sqr

comptime _SLASH = UInt8(ord("/"))
"""The byte between the numerator and the denominator."""

comptime _LOWER_E = UInt8(ord("e"))
"""The decimal exponent marker, in both cases."""

comptime _UPPER_E = UInt8(ord("E"))
"""The decimal exponent marker, in both cases."""

comptime _LOWER_P = UInt8(ord("p"))
"""The binary exponent marker, in both cases."""

comptime _UPPER_P = UInt8(ord("P"))
"""The binary exponent marker, in both cases."""

comptime _RAT_GOB_VERSION = UInt8(1)
"""The gob encoding this package writes and the only one it reads. Go's
`ratGobVersion`."""

comptime _MAX_EXP5 = Int64(1_000_000)
"""The largest power of five `set_string` will build. Go's `1e6`.

A number with a million decimal digits of exponent is a number nobody meant to
write, and building it would eat the machine rather than fail."""

comptime _MAX_EXP2 = Int64(10_000_000)
"""The largest power of two `set_string` will shift by. Go's `1e7`.

Ten times the power of five limit, because a shift is cheap next to a
multiplication."""

comptime _FIVE_POWER = 13
"""The exponent of the power of five `float_prec` starts its table at. Go's
`fp`.

Five to the thirteenth is the largest power of five that fits in thirty two
bits, which is what Go needs it to be so the constant can be written as one
digit on either word size."""


struct Rat(Copyable, Equatable, Movable):
    """A quotient of two integers, of any size. Go's `big.Rat`.

    The zero value is the number zero. `Rat(1, 3)` is a third, `new_rat(1, 3)`
    is the same call under Go's name, and `set_string` reads one out of text in
    either the `a/b` form or the floating point one.

    Go's documentation warns that a `Rat` is only ever used through a pointer
    and that shallow copies are not supported. This is a value: `b = a.copy()`
    is a second number and there is nothing to share by accident.
    """

    var _a: Int
    """The numerator, which carries the sign of the whole number."""

    var _b: Int
    """The denominator, which is always one or more."""

    def __init__(out self):
        """Zero, which is zero over one."""
        self._a = Int()
        self._b = _one_int()

    def __init__(out self, a: Int64, b: Int64) raises:
        """`a` over `b`, in lowest terms. `new_rat(a, b)` written as a
        constructor.

        Raises on a zero `b`, where Go panics.
        """
        self._a = Int()
        self._b = _one_int()
        self.set_frac64(a, b)

    @staticmethod
    def _frac(var a: Int, var b: Int) raises -> Self:
        """`a` over `b`, reduced, with `b` already made positive and the sign
        already moved onto `a` by the caller.

        Every operation that produces a new number ends here.
        """
        var z = Self()
        z._a = a^
        z._b = b^
        z._normalise()
        return z^

    def _normalise(mut self) raises:
        """Divide the common factor out of the two halves. Go's `Rat.norm`.

        Go's version also has to fill in a denominator left empty by the zero
        value, which is the one place its "an empty denominator means one"
        trick gets repaired. There is nothing to repair here.
        """
        if self._a.sign() == 0:
            # Zero has one spelling, and it is not a negative zero over some
            # denominator that happened to be lying around.
            self._a = Int()
            self._b = _one_int()
            return

        var f = self._a.gcd(self._b)
        if f.cmp(_one_int()) != 0:
            var num = self._a.quo(f)
            var den = self._b.quo(f)
            self._a = num^
            self._b = den^

    def set_int64(mut self, x: Int64):
        """Set this to `x`. Go's `Rat.SetInt64`."""
        self._a.set_int64(x)
        self._b.set_int64(1)

    def set_uint64(mut self, x: UInt64):
        """Set this to `x`. Go's `Rat.SetUint64`."""
        self._a.set_uint64(x)
        self._b.set_int64(1)

    def set_int(mut self, x: Int):
        """Set this to `x`. Go's `Rat.SetInt`."""
        self._a.set(x)
        self._b.set_int64(1)

    def set(mut self, x: Self):
        """Set this to `x`. Go's `Rat.Set`."""
        self._a.set(x._a)
        self._b.set(x._b)

    def set_frac(mut self, a: Int, b: Int) raises:
        """Set this to `a` over `b`, in lowest terms. Go's `Rat.SetFrac`.

        Raises on a zero `b`, where Go panics. Go also copies `b` when it is
        the same value as the receiver's numerator; nothing here can be the
        receiver and an argument at once, so that check has nothing to catch.
        """
        if b.sign() == 0:
            raise _divide_by_zero()

        var neg = (a.sign() < 0) != (b.sign() < 0)
        var num = a.abs()
        if neg:
            var flipped = num.neg()
            num = flipped^
        self._a = num^
        self._b = b.abs()
        self._normalise()

    def set_frac64(mut self, a: Int64, b: Int64) raises:
        """Set this to `a` over `b`, in lowest terms. Go's `Rat.SetFrac64`.

        Raises on a zero `b`, where Go panics.
        """
        if b == 0:
            raise _divide_by_zero()

        self._a.set_int64(a)
        var den = b
        if den < 0:
            den = -den
            var flipped = self._a.neg()
            self._a = flipped^
        # The most negative `Int64` is its own negation, and the conversion
        # below still reads it as the magnitude, which is Go's behaviour here
        # for the same reason.
        self._b.set_uint64(UInt64(den))
        self._normalise()

    def set_float64(mut self, f: Float64) raises:
        """Set this to exactly `f`. Go's `Rat.SetFloat64`.

        Every finite `Float64` is a whole number over a power of two, so
        nothing is lost. An infinity or a NaN raises, where Go returns nil.
        """
        var bits = float64bits(f)
        var mantissa = bits & ((UInt64(1) << 52) - 1)
        var exp = _MojoInt((bits >> 52) & 0x7FF)
        if exp == 0x7FF:
            raise Report(
                "big: cannot set a rational to an infinity or a NaN"
            ).with_code(ErrInvalidArgument).error()
        if exp == 0:
            # A subnormal has no implicit leading one and one exponent more.
            exp -= 1022
        else:
            mantissa |= UInt64(1) << 52
            exp -= 1023

        var shift = 52 - exp

        # Taking the low zeros off the mantissa before shifting keeps both
        # halves smaller than they would otherwise be.
        while (mantissa & 1) == 0 and shift > 0:
            mantissa >>= 1
            shift -= 1

        self._a.set_uint64(mantissa)
        if f < 0:
            var flipped = self._a.neg()
            self._a = flipped^
        self._b.set_int64(1)
        if shift > 0:
            var den = self._b.lsh(shift)
            self._b = den^
        else:
            var num = self._a.lsh(-shift)
            self._a = num^
        self._normalise()

    def sign(self) -> _MojoInt:
        """`-1` when this is negative, `0` when it is zero, `1` when it is
        positive. Go's `Rat.Sign`."""
        return self._a.sign()

    def is_int(self) -> Bool:
        """Whether the denominator is one. Go's `Rat.IsInt`."""
        return self._b.cmp(_one_int()) == 0

    def num(self) -> Int:
        """The numerator, which carries the sign. Go's `Rat.Num`.

        A copy. Go returns a pointer into the value and documents that the two
        change together.
        """
        return self._a.copy()

    def denom(self) -> Int:
        """The denominator, which is always one or more. Go's `Rat.Denom`.

        A copy, for the reason `num` gives. Go has a second case here, where
        the value was never assigned to and the denominator it hands back is a
        fresh one rather than a pointer; there is no such value here.
        """
        return self._b.copy()

    def abs(self) -> Self:
        """The magnitude of this. Go's `Rat.Abs`."""
        var z = Self()
        z._a = self._a.abs()
        z._b = self._b.copy()
        return z^

    def neg(self) -> Self:
        """This with its sign flipped. Go's `Rat.Neg`.

        Zero has no sign, so the negative of zero is zero.
        """
        var z = Self()
        z._a = self._a.neg()
        z._b = self._b.copy()
        return z^

    def inv(self) raises -> Self:
        """One over this. Go's `Rat.Inv`.

        Raises on zero, where Go panics. The two halves of a reduced fraction
        are still reduced the other way up, so there is nothing to divide out.
        """
        if self._a.sign() == 0:
            raise _divide_by_zero()

        var z = Self()
        z._a = self._b.copy()
        z._b = self._a.abs()
        if self._a.sign() < 0:
            var flipped = z._a.neg()
            z._a = flipped^
        return z^

    def cmp(self, y: Self) -> _MojoInt:
        """`-1` when this is below `y`, `0` when they are equal, `1` when it is
        above. Go's `Rat.Cmp`.

        Both sides are put over the same denominator and the numerators are
        compared. The denominators are positive, so the direction is the
        numerators' own.
        """
        return self._a.mul(y._b).cmp(y._a.mul(self._b))

    def __eq__(self, y: Self) -> Bool:
        """Whether the two are the same number."""
        return self.cmp(y) == 0

    def __ne__(self, y: Self) -> Bool:
        """Whether the two are different numbers."""
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

    def add(self, y: Self) raises -> Self:
        """This plus `y`. Go's `Rat.Add`."""
        var num = self._a.mul(y._b).add(y._a.mul(self._b))
        var den = self._b.mul(y._b)
        return Self._frac(num^, den^)

    def sub(self, y: Self) raises -> Self:
        """This minus `y`. Go's `Rat.Sub`."""
        var num = self._a.mul(y._b).sub(y._a.mul(self._b))
        var den = self._b.mul(y._b)
        return Self._frac(num^, den^)

    def mul(self, y: Self) raises -> Self:
        """This times `y`. Go's `Rat.Mul`.

        Go spots a square by comparing the two pointers and skips the reduction
        for it, because a reduced fraction squared is still reduced. There are
        no pointers here, and the property is about the values rather than
        about which value it is, so the test is `x == y` and it catches the
        squares Go's pointer comparison misses as well.
        """
        var z = Self()
        if self == y:
            z._a = self._a.mul(self._a)
            z._b = self._b.mul(self._b)
            return z^

        var num = self._a.mul(y._a)
        var den = self._b.mul(y._b)
        return Self._frac(num^, den^)

    def quo(self, y: Self) raises -> Self:
        """This divided by `y`. Go's `Rat.Quo`.

        Raises on a zero `y`, where Go panics.
        """
        if y._a.sign() == 0:
            raise _divide_by_zero()

        var num = self._a.mul(y._b)
        var den = y._a.mul(self._b)
        var neg = (num.sign() < 0) != (den.sign() < 0)
        var top = num.abs()
        if neg:
            var flipped = top.neg()
            top = flipped^
        return Self._frac(top^, den.abs())

    def float32(self) raises -> Tuple[Float32, Bool]:
        """The nearest `Float32`, and whether it is exact. Go's `Rat.Float32`.

        A number too large for the type comes back as an infinity and not
        exact. The sign of the answer is the sign of the number even when the
        answer is a zero.

        Raises only because the division underneath it can, and the denominator
        is never zero, so it never actually fails.
        """
        var value, exact = _quot_to_float[23, 32](
            Span(self._a._abs), Span(self._b._abs)
        )
        var f = Float32(value)
        if self._a._neg:
            f = -f
        # The rounding above was to a `Float32` mantissa, so the only things
        # the narrowing can change are the two ends, both of which
        # `_quot_to_float` measured against the wider type.
        if is_inf(Float64(f), 0) or (f == 0 and value != 0):
            exact = False
        return (f, exact)

    def float64(self) raises -> Tuple[Float64, Bool]:
        """The nearest `Float64`, and whether it is exact. Go's `Rat.Float64`.

        As `float32`, in the wider type.
        """
        var value, exact = _quot_to_float[52, 64](
            Span(self._a._abs), Span(self._b._abs)
        )
        var f = -value if self._a._neg else value
        return (f, exact)

    def set_string(mut self, s: String) raises:
        """Set this to the number written in `s`. Go's `Rat.SetString`.

        Two forms are accepted. A fraction is `a/b`, where each half may be a
        decimal number or carry a `0b`, `0o`, `0` or `0x` prefix of its own,
        and where the denominator may not be signed. A floating point number is
        a mantissa in any of those bases followed by an optional exponent,
        which is `e` for a power of ten or `p` for a power of two, except that
        a hexadecimal mantissa takes only `p` because an `e` would be a digit.
        A leading `0` on a floating point mantissa is a decimal zero rather
        than an octal prefix.

        The whole of `s` has to be a number, not merely the front of one. Go
        returns a boolean and leaves the value undefined on failure; this
        raises and leaves the value alone. A zero denominator raises with
        `ErrDivideByZero` rather than as a syntax problem, because that is what
        it is.
        """
        self._set_from_bytes(s.as_bytes())

    def _set_from_bytes[o: ImmOrigin](mut self, src: Span[UInt8, o]) raises:
        """The body of `set_string`, over bytes.

        Go builds a `strings.Reader` and checks afterwards that the scanner
        reached its end. The scanners here report how many bytes they consumed
        instead, so the same check is a comparison of two lengths.
        """
        if len(src) == 0:
            raise _bad_syntax()

        var sep = -1
        for i in range(len(src)):
            if src[i] == _SLASH:
                sep = i
                break

        if sep >= 0:
            var num = Int()
            num._set_from_bytes(src[:sep], 0)

            # The denominator goes through the scanner directly, because a sign
            # on it is not allowed.
            var scanned = _scan(src[sep + 1 :], 0, False)
            var used = scanned.used
            var digits = scanned^.take_value()
            if sep + 1 + used != len(src):
                raise _bad_syntax()
            if len(digits) == 0:
                raise _divide_by_zero()

            self._a = num^
            self._b = Int._make(False, digits^)
            self._normalise()
            return

        var pos = 0
        var neg = False
        if src[0] == _MINUS_BYTE:
            neg = True
            pos = 1
        elif src[0] == _PLUS_BYTE:
            pos = 1

        var scanned = _scan(src[pos:], 0, True)
        var base = scanned.base
        var fcount = scanned.count
        pos += scanned.used
        var mantissa = scanned^.take_value()

        # A `p` exponent is allowed whatever base the mantissa was written in,
        # which is Go passing a fixed true here even though the scanner takes
        # the question. `2p10` is a number and is `2048`.
        var exp, ebase, exp_used = _scan_exponent(src[pos:], True, True)
        pos += exp_used

        if pos != len(src):
            raise _bad_syntax()

        if len(mantissa) == 0:
            # Zero, whatever the exponent said and whatever the sign was.
            self._a = Int()
            self._b = _one_int()
            return

        # A radix point divides by the base raised to the number of digits
        # after it, and an exponent multiplies by its own base raised to
        # itself. Both are products of powers of two and powers of five, and
        # multiplication commutes, so the two are collected into one power of
        # each and applied together. Splitting ten into two and five that way
        # keeps the factors smaller than a power of ten would be.
        var exp2 = Int64(0)
        var exp5 = Int64(0)
        if fcount < 0:
            var d = Int64(fcount)
            if base == 10:
                exp5 = d
                exp2 = d
            elif base == 2:
                exp2 = d
            elif base == 8:
                exp2 = d * 3  # three bits to the octal digit
            else:
                exp2 = d * 4  # four bits to the hexadecimal digit
        if ebase == 10:
            exp5 += exp
        exp2 += exp

        var num = Int._make(False, mantissa^)
        var den = _one_int()

        # The power of five goes first, because it is the smaller of the two
        # and the shift below it then has less to move.
        if exp5 != 0:
            var n = exp5
            if n < 0:
                n = -n
                if n < 0:
                    # The most negative `Int64` is its own negation.
                    raise _exponent_too_large()
            if n > _MAX_EXP5:
                raise _exponent_too_large()
            var pow5 = _exp_nn(
                Span(_five()), Span(_set_word(Word(n))), Span(_zero()), False
            )
            if exp5 > 0:
                num = Int._make(False, _mul(Span(num._abs), Span(pow5)))
            else:
                den = Int._make(False, pow5^)

        if exp2 < -_MAX_EXP2 or exp2 > _MAX_EXP2:
            raise _exponent_too_large()
        if exp2 > 0:
            var shifted = num.lsh(_MojoInt(exp2))
            num = shifted^
        elif exp2 < 0:
            var shifted = den.lsh(_MojoInt(-exp2))
            den = shifted^

        if neg:
            var flipped = num.neg()
            num = flipped^
        self._a = num^
        self._b = den^
        self._normalise()

    def string(self) raises -> String:
        """This as `a/b`, with the denominator written even when it is one.
        Go's `Rat.String`."""
        var buf = List[UInt8]()
        self._marshal(buf)
        return String(from_utf8_lossy=Span(buf))

    def _marshal(self, mut buf: List[UInt8]) raises:
        """Append `a/b` in decimal to `buf`. Go's `Rat.marshal`."""
        self._a.append(buf, 10)
        buf.append(_SLASH)
        self._b.append(buf, 10)

    def rat_string(self) raises -> String:
        """This as `a/b`, or as `a` when the denominator is one. Go's
        `Rat.RatString`."""
        if self.is_int():
            return self._a.string()
        return self.string()

    def float_string(self, prec: _MojoInt) raises -> String:
        """This in decimal with `prec` digits after the point. Go's
        `Rat.FloatString`.

        The last digit is rounded to nearest, with a half going away from zero.
        """
        var buf = List[UInt8]()
        if self.is_int():
            self._a.append(buf, 10)
            if prec > 0:
                buf.append(_PERIOD)
                for _ in range(prec):
                    buf.append(_DIGIT_0)
            return String(from_utf8_lossy=Span(buf))

        var whole = List[Word]()
        var rest = List[Word]()
        _div(Span(self._a._abs), Span(self._b._abs)).unpack(whole, rest)

        # The digits after the point are the remainder scaled by ten to the
        # precision and divided again, and what is left over after that decides
        # the rounding.
        var p = _one()
        if prec > 0:
            p = _exp_nn(
                Span(_ten()), Span(_set_word(Word(prec))), Span(_zero()), False
            )

        var scaled = _mul(Span(rest), Span(p))
        var frac = List[Word]()
        var left = List[Word]()
        _div(Span(scaled), Span(self._b._abs)).unpack(frac, left)

        var doubled = _add(Span(left), Span(left))
        if _cmp(Span(self._b._abs), Span(doubled)) <= 0:
            var bumped = _add(Span(frac), Span(_one()))
            frac = bumped^
            if _cmp(Span(frac), Span(p)) >= 0:
                # The last digit carried all the way out of the fraction.
                var carried = _add(Span(whole), Span(_one()))
                whole = carried^
                var back = _sub(Span(frac), Span(p))
                frac = back^

        if self._a._neg:
            buf.append(_MINUS_BYTE)
        var digits = _utoa(Span(whole), 10)
        for i in range(len(digits)):
            buf.append(digits[i])

        if prec > 0:
            buf.append(_PERIOD)
            var after = _utoa(Span(frac), 10)
            for _ in range(prec - len(after)):
                buf.append(_DIGIT_0)
            for i in range(len(after)):
                buf.append(after[i])

        return String(from_utf8_lossy=Span(buf))

    def float_prec(self) raises -> Tuple[_MojoInt, Bool]:
        """How many digits after the decimal point this number has before it
        starts repeating, and whether writing that many is exact. Go's
        `Rat.FloatPrec`.

        A half is one digit and exact, a third is no digits and not exact, a
        sixth is one digit and not exact, since a sixth is a fifth of a third
        and only the fifth divides out.

        The denominator is `q` times two to the `p2` times five to the `p5`,
        the answer is the larger of `p2` and `p5`, and it is exact when what is
        left of `q` is one. Taking the twos out first, which is counting the
        low zero bits, leaves the least for the fives to work through.
        """
        var p2 = _trailing_zero_bits(Span(self._b._abs))
        var q = _rsh(Span(self._b._abs), p2)

        # A table of five to the thirteenth, squared over and over, so a large
        # power of five comes out in a few divisions rather than one at a time.
        var tab = List[List[Word]]()
        var f = _set_word(Word(1220703125))  # five to the thirteenth
        while True:
            if len(_div(Span(q), Span(f)).take_r()) != 0:
                break
            tab.append(f.copy())
            var squared = _sqr(Span(f))
            f = squared^

        # Each table entry divides at most once, since twice would mean the
        # next entry up divided as well, and that one was tried first.
        var p5 = 0
        for i in range(len(tab) - 1, -1, -1):
            var t = List[Word]()
            var r = List[Word]()
            _div(Span(q), Span(tab[i])).unpack(t, r)
            if len(r) == 0:
                p5 += _FIVE_POWER * (1 << i)
                q = t^

        # The table steps in thirteens, so up to twelve fives can be left.
        while True:
            var t = List[Word]()
            var r = List[Word]()
            _div(Span(q), Span(_five())).unpack(t, r)
            if len(r) != 0:
                break
            p5 += 1
            q = t^

        var n = p2 if p2 > p5 else p5
        return (n, _cmp(Span(q), Span(_one())) == 0)

    def gob_encode(self) raises -> List[UInt8]:
        """This in the form Go's `encoding/gob` writes. Go's `Rat.GobEncode`.

        One byte of version and sign, four bytes of numerator length big
        endian, then the numerator and the denominator, both big endian
        magnitudes. The format is Go's, so a value written here can be read by
        a Go program and the other way round.

        Raises when the numerator needs more bytes than that length can
        describe, which is Go's check as well and takes a number of some
        gigabytes to reach.
        """
        var num = _to_bytes(Span(self._a._abs))
        var den = _to_bytes(Span(self._b._abs))
        if len(num) > 0xFFFFFFFF:
            raise Report(
                "big: the numerator is too large for this encoding"
            ).with_code(ErrOverflow).error()

        var out = List[UInt8](capacity=5 + len(num) + len(den))
        var header = _RAT_GOB_VERSION << 1
        if self._a._neg:
            header |= 1
        out.append(header)

        var n = UInt32(len(num))
        out.append(UInt8((n >> 24) & 0xFF))
        out.append(UInt8((n >> 16) & 0xFF))
        out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8(n & 0xFF))

        for i in range(len(num)):
            out.append(num[i])
        for i in range(len(den)):
            out.append(den[i])
        return out^

    def gob_decode[o: ImmOrigin](mut self, buf: Span[UInt8, o]) raises:
        """Set this from the form Go's `encoding/gob` writes. Go's
        `Rat.GobDecode`.

        An empty input is the zero value, which is what Go's encoder sends for
        one. Any other version byte raises, and so does an input too short for
        the length it claims.

        Go's own zero value encodes an empty denominator, which its code reads
        back as a one. That reading is done here rather than left to every
        method afterwards.
        """
        if len(buf) == 0:
            self._a = Int()
            self._b = _one_int()
            return

        if len(buf) < 5:
            raise _short_gob()
        if (buf[0] >> 1) != _RAT_GOB_VERSION:
            raise Report(
                "big: this gob encoding version is not supported"
            ).with_code(ErrInvalidArgument).error()

        var n = (
            (UInt64(buf[1]) << 24)
            | (UInt64(buf[2]) << 16)
            | (UInt64(buf[3]) << 8)
            | UInt64(buf[4])
        )
        var end = 5 + _MojoInt(n)
        if len(buf) < end:
            raise _short_gob()

        self._a.set_bytes(buf[5:end])
        self._b.set_bytes(buf[end:])
        if self._b.sign() == 0:
            self._b.set_int64(1)
        if (buf[0] & 1) != 0 and self._a.sign() != 0:
            var flipped = self._a.neg()
            self._a = flipped^

    def append_text(self, mut buf: List[UInt8]) raises:
        """Append this in decimal to `buf`. Go's `Rat.AppendText`.

        `a/b`, or just `a` when the denominator is one, which is `rat_string`
        rather than `string`.
        """
        if self.is_int():
            self._a.append_text(buf)
            return
        self._marshal(buf)

    def marshal_text(self) raises -> List[UInt8]:
        """This in decimal, as bytes. Go's `Rat.MarshalText`."""
        var out = List[UInt8]()
        self.append_text(out)
        return out^

    def unmarshal_text[o: ImmOrigin](mut self, text: Span[UInt8, o]) raises:
        """Set this from the text in `text`. Go's `Rat.UnmarshalText`.

        Everything `set_string` accepts.
        """
        self._set_from_bytes(text)


def new_rat(a: Int64, b: Int64) raises -> Rat:
    """`a` over `b`, in lowest terms. Go's `NewRat`.

    Go returns a pointer because every one of its operations needs one. Here it
    is a value, and `Rat(a, b)` is the same call written as a constructor.
    """
    return Rat(a, b)


def _one_int() -> Int:
    """The number one.

    Go keeps a package level `intOne` and hands out a pointer to it. A value
    cannot be shared that way, so this builds one where Go points at one.
    """
    return Int(Int64(1))


def _bad_syntax() -> Error:
    """Go returns a false and leaves the value undefined; here it is an error
    with a code on it."""
    return (
        Report("big: cannot parse this as a rational number")
        .with_code(ErrSyntax)
        .error()
    )


def _exponent_too_large() -> Error:
    """An exponent so large that building the number would eat the machine.

    Go refuses the same two sizes, and says so in a comment rather than in the
    documentation, so a program that meets this in Go meets it here.
    """
    return (
        Report("big: the exponent is too large")
        .with_code(ErrInvalidArgument)
        .error()
    )


def _short_gob() -> Error:
    """The gob input stopped before the number did."""
    return (
        Report("big: this gob encoding is too short")
        .with_code(ErrInvalidArgument)
        .error()
    )


def _quot_to_float[
    msize: _MojoInt, fsize: _MojoInt, o1: ImmOrigin, o2: ImmOrigin
](a: Span[Word, o1], b: Span[Word, o2]) raises -> Tuple[Float64, Bool]:
    """The float nearest `a` over `b`, and whether it is exact. Go's
    `quotToFloat32` and `quotToFloat64`.

    `msize` is the width of the mantissa field and `fsize` the width of the
    whole float. Go writes the two sizes out as two functions, forty lines
    apart, differing in five constants; here they are parameters, so there is
    one function and the constants are worked out from them when the program is
    compiled.

    The answer for the narrower size is exact as a `Float64` as well, since a
    twenty four bit mantissa fits a fifty three bit one, so the caller narrows
    it afterwards and checks once more for an overflow the wider type did not
    have.

    Both arguments are magnitudes, the second is not zero, and the two have no
    common factor, which is what `Rat` guarantees. Rounding is to nearest, ties
    to even.
    """
    comptime msize1 = msize + 1  # with the leading one that is not stored
    comptime msize2 = msize1 + 1  # with the rounding bit below that
    comptime esize = fsize - msize1
    comptime ebias = (1 << (esize - 1)) - 1
    comptime emin = 1 - ebias

    var alen = _bit_len(a)
    if alen == 0:
        return (Float64(0), True)
    var blen = _bit_len(b)
    if blen == 0:
        raise _divide_by_zero()

    # Shift one side so the quotient lands with `msize2` or `msize2 + 1` bits
    # in it: the mantissa, the leading one, the rounding bit, and possibly one
    # more that the next step takes back off.
    var exp = alen - blen
    var shift = msize2 - exp
    var a2 = _lsh(a, shift) if shift > 0 else _clone(a)
    var b2 = _lsh(b, -shift) if shift < 0 else _clone(b)

    var q = List[Word]()
    var r = List[Word]()
    _div(Span(a2), Span(b2)).unpack(q, r)

    var mantissa = UInt64(q[0]) if len(q) > 0 else UInt64(0)
    # A remainder means the true value is above what the digits say, which is
    # what decides a tie.
    var have_rem = len(r) > 0

    if (mantissa >> UInt64(msize2)) == 1:
        # One bit too many, so the division was by half of what it should have
        # been, and dropping the low bit is the rest of that division.
        if (mantissa & 1) == 1:
            have_rem = True
        mantissa >>= 1
        exp += 1

    if emin - msize <= exp and exp <= emin:
        # A subnormal, which has fewer bits of mantissa the smaller it is, so
        # the ones below the point of the smallest exponent are lost here
        # rather than to the rounding below.
        var lost = _MojoInt(emin - (exp - 1))
        var bits = mantissa & ((UInt64(1) << UInt64(lost)) - 1)
        have_rem = have_rem or bits != 0
        mantissa >>= UInt64(lost)
        exp = 2 - ebias

    var exact = not have_rem
    if (mantissa & 1) != 0:
        # The rounding bit is set, so the value is not one of the floats. It
        # goes up when there is anything at all below the rounding bit, and on
        # an exact half it goes to the even neighbour.
        exact = False
        if have_rem or (mantissa & 2) != 0:
            mantissa += 1
            if mantissa >= (UInt64(1) << UInt64(msize2)):
                # All ones became one and a row of zeros, so the shift is safe.
                mantissa >>= 1
                exp += 1
    mantissa >>= 1  # the rounding bit has done its work

    var f = ldexp(Float64(mantissa), exp - msize1)
    if is_inf(f, 0):
        exact = False
    if f == 0:
        # A number smaller than the smallest subnormal, which the rounding
        # above does not see because the branch that loses bits only covers
        # exponents down to the bottom of the subnormal range. Go stops at the
        # overflow check and reports `1/(1<<2000)` as an exact zero, which
        # `docs/deviations.md` records as the one place this disagrees with it.
        # The zero numerator returned at the top, which is exact, never reaches
        # here.
        exact = False
    return (f, exact)


def _scan_exponent[
    o: ImmOrigin
](src: Span[UInt8, o], base2_ok: Bool, sep_ok: Bool) raises -> Tuple[
    Int64, _MojoInt, _MojoInt
]:
    """Read an exponent off the front of `src`. Go's `scanExponent`.

    The exponent, the base it is a power of, and how many bytes were used. An
    `e` is a power of ten and a `p` is a power of two, and a `p` is only an
    exponent at all when `base2_ok`. When `sep_ok`, an underscore may sit
    between two digits and changes nothing.

    No exponent is not a failure: the answer is zero, base ten and nothing
    used, which is Go's answer with the byte it looked at put back. An exponent
    marker with no digits after it is a failure, and so is a misplaced
    underscore, and so is an exponent too large for an `Int64`.
    """
    if len(src) == 0:
        return (Int64(0), 10, 0)

    var base: _MojoInt
    if src[0] == _LOWER_E or src[0] == _UPPER_E:
        base = 10
    elif (src[0] == _LOWER_P or src[0] == _UPPER_P) and base2_ok:
        base = 2
    else:
        return (Int64(0), 10, 0)

    var i = 1
    var digits = List[UInt8]()
    if i < len(src) and (src[i] == _MINUS_BYTE or src[i] == _PLUS_BYTE):
        if src[i] == _MINUS_BYTE:
            digits.append(_MINUS_BYTE)
        i += 1

    var prev = _PREV_OTHER
    var inval_sep = False
    var has_digits = False
    while i < len(src):
        var ch = src[i]
        if _DIGIT_0 <= ch and ch <= _DIGIT_9:
            digits.append(ch)
            prev = _PREV_DIGIT
            has_digits = True
        elif ch == _UNDERSCORE and sep_ok:
            if prev != _PREV_DIGIT:
                inval_sep = True
            prev = _PREV_SEPARATOR
        else:
            break
        i += 1

    if not has_digits:
        raise Report("big: the exponent has no digits").with_code(
            ErrSyntax
        ).error()

    # Go lets the range error win over the separator one, so the parse comes
    # first even though the separator was noticed earlier.
    var value = parse_int(String(from_utf8_lossy=Span(digits)), 10, 64)
    if inval_sep or prev == _PREV_SEPARATOR:
        raise Report(
            "big: an underscore in an exponent must sit between two digits"
        ).with_code(ErrSyntax).error()

    return (value, base, i)
