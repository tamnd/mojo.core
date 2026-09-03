"""Floating point numbers of any precision. Go's `float.go`, `floatconv.go`,
`ftoa.go`, `floatmarsh.go` and `sqrt.go`.

A `Float` is a sign, a mantissa and a binary exponent, together with the number
of mantissa bits it is allowed to keep, the way it rounds when it has to drop
some, and a note saying which way the last operation rounded. Go's type is the
same five things and this is a transcription of it.

The number is `sign * mantissa * 2**exponent` with the mantissa in `[0.5, 1)`
and the exponent between `MinExp` and `MaxExp`, or one of `+0`, `-0`, `+Inf`
and `-Inf`. There is no NaN: every operation that would produce one raises
`ErrNaN` instead, which is where Go panics with a value of the same name.

Set the precision to 53 and leave the mode at `ToNearestEven` and the
arithmetic here agrees with `Float64` on every operand a `Float64` can hold
without going denormal. The exponent range is far wider than IEEE's, so the
values that overflow or underflow are not the same ones.
"""

from core.errors import Report
from core.errors.codes import ErrInvalidArgument, ErrNaN, ErrSyntax
from core.math import (
    float32frombits,
    float64bits,
    float64frombits,
    frexp,
    is_inf,
    is_nan,
    signbit,
    sqrt,
)
from core.strconv import append_int

from .arith import (
    _add_vw_into,
    _lsh_vu_into,
    _MojoInt,
    _nlz,
    _rsh_vu_into,
    _S,
    _W,
    Word,
)
from .decimal import _Decimal
from .int import _MINUS_BYTE, _PLUS_BYTE, Int
from .nat import (
    _add,
    _bit,
    _bit_len,
    _clone,
    _fill_bytes,
    _lsh,
    _one,
    _rsh,
    _set_bytes,
    _set_word,
    _sticky,
    _sub,
    _trailing_zero_bits,
)
from .natconv import _DIGIT_0, _PERIOD, _scan, _utoa
from .natdiv import _div
from .natmul import _mul
from .rat import _scan_exponent, Rat
from .rounding import (
    Above,
    Accuracy,
    AwayFromZero,
    Below,
    Exact,
    RoundingMode,
    ToNearestAway,
    ToNearestEven,
    ToNegativeInf,
    ToPositiveInf,
    ToZero,
)

comptime MaxExp = 2147483647
"""The largest exponent a `Float` can hold. Go's `big.MaxExp`."""

comptime MinExp = -2147483648
"""The smallest exponent a `Float` can hold. Go's `big.MinExp`."""

comptime MaxPrec = 4294967295
"""The largest precision a `Float` can be asked for. Go's `big.MaxPrec`.

Nothing gets near it. A mantissa that wide is half a gigabyte, so memory runs
out long before the number does.
"""

comptime _ZERO = UInt8(0)
"""The form of `+0` and `-0`. Go's `zero`."""

comptime _FINITE = UInt8(1)
"""The form of every number that is neither zero nor infinite. Go's `finite`."""

comptime _INF = UInt8(2)
"""The form of `+Inf` and `-Inf`. Go's `inf`.

The three numbers are in this order in Go as well, and the order matters:
`form <= finite` is how Go asks whether a value has a numeric answer.
"""

comptime _FLOAT_GOB_VERSION = UInt8(1)
"""The version byte at the front of a gob encoded `Float`."""

comptime _MAX_INT64 = Int64(9223372036854775807)
"""The largest `Int64`, which `int64` returns for a number above it."""

comptime _MIN_INT64 = -_MAX_INT64 - 1
"""The smallest `Int64`, which `int64` returns for a number below it."""

comptime _MAX_UINT64 = UInt64(18446744073709551615)
"""The largest `UInt64`, which `uint64` returns for a number above it."""

comptime _POW5_MAX = 27
"""The largest power of five that fits in a `Word`.

Go writes the twenty eight values out as a table. Five to the twenty seventh is
7450580596923828125, which is under two to the sixty three, and computing it by
multiplying is exact for every one of them, so the table is a loop here.
"""

comptime _FMT_B = UInt8(ord("b"))
"""Decimal mantissa and binary exponent, Go's `'b'`."""

comptime _FMT_E = UInt8(ord("e"))
"""Decimal with an exponent, Go's `'e'`."""

comptime _FMT_E_UPPER = UInt8(ord("E"))
"""`_FMT_E` with a capital exponent marker."""

comptime _FMT_F = UInt8(ord("f"))
"""Decimal with no exponent, Go's `'f'`."""

comptime _FMT_G = UInt8(ord("g"))
"""`_FMT_E` or `_FMT_F`, whichever is shorter, Go's `'g'`."""

comptime _FMT_G_UPPER = UInt8(ord("G"))
"""`_FMT_G` with a capital exponent marker."""

comptime _FMT_P = UInt8(ord("p"))
"""Hexadecimal mantissa in `[0.5, 1)` and a binary exponent, Go's `'p'`."""

comptime _FMT_X = UInt8(ord("x"))
"""Hexadecimal mantissa in `[1, 2)` and a binary exponent, Go's `'x'`."""

comptime _LOWER_P = UInt8(ord("p"))
"""The exponent marker the power of two formats print."""

comptime _PERCENT = UInt8(ord("%"))
"""What an unrecognised format character comes back wrapped in."""

comptime _DIGIT_9 = UInt8(ord("9"))
"""The digit nine, which `_round_shortest` compares against."""


struct Float(Copyable, Equatable, Movable):
    """A floating point number of any precision. Go's `big.Float`.

    ```mojo
    import core.math.big as big

    # A third to two hundred bits, printed to thirty digits.
    var third = big.Float()
    third.set_prec(200)
    third.set_int64(1)
    var d = big.Float()
    d.set_prec(200)
    d.set_int64(3)
    print(third.quo(d).text(UInt8(ord("f")), 30))
    # 0.333333333333333333333333333333

    # The square root of two, to the same width.
    var two = big.Float()
    two.set_prec(200)
    two.set_int64(2)
    print(two.sqrt().text(UInt8(ord("f")), 30))
    # 1.414213562373095048801688724209
    ```

    The zero value is `+0` with a precision of zero and `ToNearestEven`
    rounding, ready to use. A precision of zero means "not decided yet": the
    first operation that puts a number in fills it in from the operands, which
    is Go's rule and the reason `set_int64` on a fresh value gives sixty four
    bits rather than none.
    """

    var _prec: UInt32
    """How many mantissa bits this is allowed to keep."""

    var _mode: RoundingMode
    """Which way a result that does not fit is rounded."""

    var _acc: Accuracy
    """Which way the last operation rounded."""

    var _form: UInt8
    """One of `_ZERO`, `_FINITE` and `_INF`."""

    var _neg: Bool
    """The sign, which a zero and an infinity carry as well."""

    var _mant: List[Word]
    """The mantissa, low digit first, with the top bit of the top digit set.

    Only meaningful when the form is `_FINITE`. This is the one list in the
    package that is never run through `_norm`: rounding keeps exactly the
    number of digits the precision asks for, and `min_prec` counts the trailing
    zero bits, so dropping a digit at either end would change the number.
    """

    var _exp: Int32
    """The binary exponent, with the mantissa read as a fraction below one."""

    def __init__(out self):
        """Positive zero, with no precision decided and `ToNearestEven`
        rounding."""
        self._prec = 0
        self._mode = ToNearestEven
        self._acc = Exact
        self._form = _ZERO
        self._neg = False
        self._mant = List[Word]()
        self._exp = 0

    def copy(self) -> Self:
        """A copy of this, precision, mode, accuracy and all. Go's
        `Float.Copy`.

        This is what `Copyable` would give anyway, since Go's `Copy` is a field
        for field copy and so is Mojo's. It is written out so that the name Go
        uses is a method here rather than something the language happens to
        provide, and so that the difference from `set` has somewhere to be
        said: `set` rounds to the precision the receiver already has, and this
        takes the source's precision along with the number.
        """
        var z = Self()
        z._copy_from(self)
        return z^

    def _copy_from(mut self, x: Self):
        """Become `x`, precision, mode, accuracy and all. Go's `Float.Copy`.

        `x.copy()` is the way to say this from outside, and it does the same
        thing. This exists for the two places inside the package that have a
        receiver in hand already.
        """
        self._prec = x._prec
        self._mode = x._mode
        self._acc = x._acc
        self._form = x._form
        self._neg = x._neg
        if x._form == _FINITE:
            self._mant = _clone(Span(x._mant))
            self._exp = x._exp

    # Precision, mode and accuracy.

    def set_prec(mut self, prec: _MojoInt) raises:
        """Set the precision to `prec` bits, rounding if the number no longer
        fits. Go's `Float.SetPrec`.

        A precision of zero turns every finite number into a signed zero and
        leaves the infinities alone, which is Go's rule. A precision above
        `MaxPrec` is clamped to it, also Go's rule. Go cannot be handed a
        negative one because its argument is unsigned; that raises here.
        """
        self._acc = Exact
        if prec < 0:
            raise Report("big: a precision cannot be negative").with_code(
                ErrInvalidArgument
            ).error()

        if prec == 0:
            self._prec = 0
            if self._form == _FINITE:
                self._acc = _make_acc(self._neg)
                self._form = _ZERO
            return

        var p = prec
        if p > MaxPrec:
            p = MaxPrec
        var old = self._prec
        self._prec = UInt32(p)
        if self._prec < old:
            self._round(0)

    def set_mode(mut self, mode: RoundingMode):
        """Set the rounding mode, and the accuracy to `Exact`. Go's
        `Float.SetMode`.

        The number is not rounded again, so this is the way to clear a stale
        accuracy: `x.set_mode(x.mode())`.
        """
        self._mode = mode
        self._acc = Exact

    def prec(self) -> _MojoInt:
        """How many mantissa bits this keeps. Go's `Float.Prec`.

        Zero for a zero or an infinity that has never been given a precision.
        """
        return _MojoInt(self._prec)

    def min_prec(self) -> _MojoInt:
        """The smallest precision that holds this number exactly. Go's
        `Float.MinPrec`.

        Zero for a zero and for an infinity. For anything else it is the width
        of the mantissa with the trailing zero bits taken off, which is the
        largest precision `set_prec` can be given before it starts rounding.
        """
        if self._form != _FINITE:
            return 0
        return len(self._mant) * _W - _trailing_zero_bits(Span(self._mant))

    def mode(self) -> RoundingMode:
        """Which way this rounds. Go's `Float.Mode`."""
        return self._mode

    def acc(self) -> Accuracy:
        """Which way the last operation that produced this rounded. Go's
        `Float.Acc`."""
        return self._acc

    # Questions about the value.

    def sign(self) -> _MojoInt:
        """`-1` below zero, `0` at either zero, `+1` above. Go's `Float.Sign`.
        """
        if self._form == _ZERO:
            return 0
        if self._neg:
            return -1
        return 1

    def signbit(self) -> Bool:
        """Whether the sign bit is set, which a negative zero has. Go's
        `Float.Signbit`."""
        return self._neg

    def is_inf(self) -> Bool:
        """Whether this is `+Inf` or `-Inf`. Go's `Float.IsInf`."""
        return self._form == _INF

    def is_int(self) -> Bool:
        """Whether this is a whole number. Go's `Float.IsInt`.

        Both zeros are. Neither infinity is.
        """
        if self._form != _FINITE:
            return self._form == _ZERO
        if self._exp <= 0:
            return False
        var e = _MojoInt(self._exp)
        # Either the precision is too small to hold a fractional part at all,
        # or the bits that are there stop before the point.
        return _MojoInt(self._prec) <= e or self.min_prec() <= e

    def mant_exp(self) -> _MojoInt:
        """The exponent, with the mantissa read as a fraction in `[0.5, 1)`.
        Go's `Float.MantExp` with a nil argument.

        Zero for both zeros and both infinities.
        """
        if self._form == _FINITE:
            return _MojoInt(self._exp)
        return 0

    def mant_exp(self, mut mant: Self) -> _MojoInt:
        """The exponent, and the mantissa written into `mant`. Go's
        `Float.MantExp`.

        `self` is `mant` times two to the returned power, with `mant` in
        `[0.5, 1)` and carrying the same sign, precision and rounding mode.
        A zero or an infinity puts itself in `mant` and returns zero.
        """
        mant._copy_from(self)
        if mant._form == _FINITE:
            mant._exp = 0
        return self.mant_exp()

    def set_mant_exp(mut self, mant: Self, exp: _MojoInt):
        """Set this to `mant` times two to the `exp`. Go's `Float.SetMantExp`.

        The inverse of `mant_exp`, and it does not need `mant` to be in
        `[0.5, 1)`. The precision and the rounding mode come from `mant`. A
        zero or an infinity ignores `exp`.
        """
        self._copy_from(mant)
        if self._form == _FINITE:
            self._set_exp_and_round(Int64(self._exp) + Int64(exp), 0)

    # Setters.

    def set(mut self, x: Self):
        """Set this to `x`, rounded to this precision. Go's `Float.Set`.

        A precision of zero here takes `x`'s, so nothing is lost. Otherwise the
        result is rounded to whatever this was already set to, and the accuracy
        says which way. `x.copy()` is the other way to say it and keeps `x`'s
        precision and mode instead.
        """
        self._acc = Exact
        self._form = x._form
        self._neg = x._neg
        if x._form == _FINITE:
            self._exp = x._exp
            self._mant = _clone(Span(x._mant))
        if self._prec == 0:
            self._prec = x._prec
        elif self._prec < x._prec:
            self._round(0)

    def set_inf(mut self, signbit: Bool):
        """Set this to `-Inf` when `signbit`, `+Inf` otherwise. Go's
        `Float.SetInf`.

        The precision does not change and the result is always `Exact`.
        """
        self._acc = Exact
        self._form = _INF
        self._neg = signbit

    def _set_bits64(mut self, neg: Bool, x: UInt64):
        """Set this to `x` with the given sign. Go's `Float.setBits64`.

        The sign goes on before the rounding because the rounding modes that
        lean one way need it.
        """
        if self._prec == 0:
            self._prec = 64
        self._acc = Exact
        self._neg = neg
        if x == 0:
            self._form = _ZERO
            return

        self._form = _FINITE
        var s = _nlz(x)
        self._mant = _set_word(x << s)
        self._exp = Int32(64 - _MojoInt(s))
        if self._prec < 64:
            self._round(0)

    def set_uint64(mut self, x: UInt64):
        """Set this to `x`. Go's `Float.SetUint64`.

        A precision of zero becomes sixty four, so nothing is rounded.
        """
        self._set_bits64(False, x)

    def set_int64(mut self, x: Int64):
        """Set this to `x`. Go's `Float.SetInt64`.

        A precision of zero becomes sixty four, so nothing is rounded.
        """
        var magnitude = UInt64(x)
        if x < 0:
            magnitude = ~magnitude + 1
        self._set_bits64(x < 0, magnitude)

    def set_float64(mut self, x: Float64) raises:
        """Set this to `x`. Go's `Float.SetFloat64`.

        A precision of zero becomes fifty three, so nothing is rounded. A NaN
        raises `ErrNaN`, where Go panics with it. A signed zero and an infinity
        keep their sign.
        """
        if self._prec == 0:
            self._prec = 53
        if is_nan(x):
            raise _nan("big: Float.set_float64 was given a NaN")

        self._acc = Exact
        self._neg = signbit(x)
        if x == 0:
            self._form = _ZERO
            return
        if is_inf(x, 0):
            self._form = _INF
            return

        self._form = _FINITE
        var fmant, exp = frexp(x)
        # The shift drops the sign and the exponent field, and the top bit is
        # the one an IEEE mantissa leaves implicit, so it is put back by hand.
        self._mant = _set_word((UInt64(1) << 63) | (float64bits(fmant) << 11))
        self._exp = Int32(exp)
        if self._prec < 53:
            self._round(0)

    def set_int(mut self, x: Int):
        """Set this to `x`. Go's `Float.SetInt`.

        A precision of zero becomes the wider of `x.bit_len()` and sixty four,
        so nothing is rounded.
        """
        var bits = x.bit_len()
        if self._prec == 0:
            self._prec = UInt32(max(bits, 64))
        self._acc = Exact
        self._neg = x._neg
        if len(x._abs) == 0:
            self._form = _ZERO
            return

        self._mant = _clone(Span(x._abs))
        _ = _fnorm(self._mant)
        self._set_exp_and_round(Int64(bits), 0)

    def set_rat(mut self, x: Rat) raises:
        """Set this to `x`, rounded. Go's `Float.SetRat`.

        A precision of zero becomes the widest of the numerator, the
        denominator and sixty four.
        """
        if x.is_int():
            self.set_int(x.num())
            return

        var a = Self()
        a.set_int(x.num())
        var b = Self()
        b.set_int(x.denom())
        if self._prec == 0:
            self._prec = max(a._prec, b._prec)
        self._set_quo(a, b)

    # Rounding, which everything above and below goes through.

    def _round(mut self, sbit_in: _MojoInt):
        """Round to this precision and record which way. Go's `Float.round`.

        `sbit_in` is a sticky bit the caller worked out already, one when
        anything below the bits being kept was not zero. The division is the
        only caller that has one, because the remainder tells it.

        The sign has to be right before this runs: `ToNegativeInf` and
        `ToPositiveInf` both read it.
        """
        self._acc = Exact
        if self._form != _FINITE:
            return

        var m = len(self._mant)
        var bits = m * _W
        var prec = _MojoInt(self._prec)
        if bits <= prec:
            return

        # Two bits decide everything. The rounding bit is the one just below
        # what is being kept, worth a half, and the sticky bit says whether
        # anything below that was set.
        var r = bits - prec - 1
        var rbit = _bit(Span(self._mant), r) & 1
        var sbit = sbit_in
        if sbit == 0 and (rbit == 0 or self._mode == ToNearestEven):
            sbit = _sticky(Span(self._mant), r)
        sbit &= 1

        var n = (prec + (_W - 1)) // _W
        if m > n:
            for i in range(n):
                self._mant[i] = self._mant[m - n + i]
            self._mant.resize(n, Word(0))

        var ntz = n * _W - prec
        var lsb = Word(1) << Word(ntz)

        if (rbit | sbit) != 0:
            # Truncating is the default, so the only question is whether to
            # add one to the last bit that is being kept.
            var inc = False
            if self._mode == ToNegativeInf:
                inc = self._neg
            elif self._mode == ToNearestEven:
                inc = rbit != 0 and (sbit != 0 or (self._mant[0] & lsb) != 0)
            elif self._mode == ToNearestAway:
                inc = rbit != 0
            elif self._mode == AwayFromZero:
                inc = True
            elif self._mode == ToPositiveInf:
                inc = not self._neg
            # `ToZero` truncates, and so does a mode nobody defined. Go panics
            # on the second, which would mean this method could fail and every
            # setter with it; truncating is the same answer as `ToZero` and is
            # only reachable through a hand written gob.

            self._acc = _make_acc(inc != self._neg)

            if inc:
                if _add_vw_into(Span(self._mant), lsb) != 0:
                    # The mantissa was all ones and has wrapped, so the value
                    # is now one and the exponent has to take it.
                    if _MojoInt(self._exp) >= MaxExp:
                        self._form = _INF
                        return
                    self._exp += 1
                    _ = _rsh_vu_into(Span(self._mant), 1)
                    self._mant[n - 1] |= Word(1) << Word(_W - 1)

        # The bits below the precision are not part of the number any more.
        self._mant[0] = self._mant[0] & ~(lsb - 1)

    def _set_exp_and_round(mut self, exp: Int64, sbit: _MojoInt):
        """Set the exponent and round, turning a range failure into a zero or
        an infinity. Go's `Float.setExpAndRound`.

        Underflow goes to a signed zero and overflow to a signed infinity, both
        with an accuracy saying which way the value moved.
        """
        if exp < Int64(MinExp):
            self._acc = _make_acc(self._neg)
            self._form = _ZERO
            return

        if exp > Int64(MaxExp):
            self._acc = _make_acc(not self._neg)
            self._form = _INF
            return

        self._form = _FINITE
        self._exp = Int32(exp)
        self._round(sbit)

    # The unsigned kernels. Each one takes the sign from the receiver, which
    # the caller has already set, and ignores the signs of the operands.

    def _uadd(mut self, x: Self, y: Self):
        """Set this to `|x| + |y|`. Go's `Float.uadd`.

        Both mantissas are lined up on the same binary point and added. Go
        guards against the destination sharing storage with an operand; a
        destination here is always a fresh value, so there is nothing to guard.
        """
        var ex = Int64(x._exp) - Int64(len(x._mant)) * _W
        var ey = Int64(y._exp) - Int64(len(y._mant)) * _W

        if ex < ey:
            var t = _lsh(Span(y._mant), _MojoInt(ey - ex))
            self._mant = _add(Span(x._mant), Span(t))
        elif ex > ey:
            var t = _lsh(Span(x._mant), _MojoInt(ex - ey))
            self._mant = _add(Span(t), Span(y._mant))
            ex = ey
        else:
            self._mant = _add(Span(x._mant), Span(y._mant))

        var width = Int64(len(self._mant)) * _W
        var shift = _fnorm(self._mant)
        self._set_exp_and_round(ex + width - shift, 0)

    def _usub(mut self, x: Self, y: Self):
        """Set this to `|x| - |y|`, which the caller knows is not negative.
        Go's `Float.usub`."""
        var ex = Int64(x._exp) - Int64(len(x._mant)) * _W
        var ey = Int64(y._exp) - Int64(len(y._mant)) * _W

        if ex < ey:
            var t = _lsh(Span(y._mant), _MojoInt(ey - ex))
            self._mant = _sub(Span(x._mant), Span(t))
        elif ex > ey:
            var t = _lsh(Span(x._mant), _MojoInt(ex - ey))
            self._mant = _sub(Span(t), Span(y._mant))
            ex = ey
        else:
            self._mant = _sub(Span(x._mant), Span(y._mant))

        if len(self._mant) == 0:
            # The two cancelled exactly, and zero here is a positive zero
            # whatever the operands were.
            self._acc = Exact
            self._form = _ZERO
            self._neg = False
            return

        var width = Int64(len(self._mant)) * _W
        var shift = _fnorm(self._mant)
        self._set_exp_and_round(ex + width - shift, 0)

    def _umul(mut self, x: Self, y: Self):
        """Set this to `|x| * |y|`. Go's `Float.umul`.

        The full product is formed and then rounded, which is more work than
        the precision usually needs. Go says the same about its own.
        """
        var e = Int64(x._exp) + Int64(y._exp)
        self._mant = _mul(Span(x._mant), Span(y._mant))
        var shift = _fnorm(self._mant)
        self._set_exp_and_round(e - shift, 0)

    def _uquo(mut self, x: Self, y: Self) raises:
        """Set this to `|x| / |y|`. Go's `Float.uquo`.

        The numerator is padded with zero digits at the bottom until the
        quotient is at least one bit wider than the precision, so that the
        rounding bit is a real bit and the remainder answers for everything
        below it.
        """
        var n = _MojoInt(self._prec) // _W + 1

        var xadj = _clone(Span(x._mant))
        var extra = n - len(x._mant) + len(y._mant)
        if extra > 0:
            var padded = List[Word](length=len(x._mant) + extra, fill=Word(0))
            for i in range(len(x._mant)):
                padded[extra + i] = x._mant[i]
            xadj = padded^

        var d = len(xadj) - len(y._mant)

        var both = _div(Span(xadj), Span(y._mant))
        var q = List[Word]()
        var r = List[Word]()
        both^.unpack(q, r)
        self._mant = q^

        var e = Int64(x._exp) - Int64(y._exp) - Int64(d - len(self._mant)) * _W

        # A remainder that is not zero means the fraction that was not computed
        # is not zero either, which is exactly what a sticky bit says.
        var sbit = 0
        if len(r) > 0:
            sbit = 1

        var shift = _fnorm(self._mant)
        self._set_exp_and_round(e - shift, sbit)

    def _ucmp(self, y: Self) -> _MojoInt:
        """`-1`, `0` or `+1` as `|self|` is below, on or above `|y|`. Go's
        `Float.ucmp`.

        Both have a normalised mantissa, so the exponents decide first and the
        digits only break a tie. The two mantissas can be different lengths,
        which is why this is not `_cmp`: the shorter one is padded at the
        bottom, not at the top.
        """
        if self._exp < y._exp:
            return -1
        if self._exp > y._exp:
            return 1

        var i = len(self._mant)
        var j = len(y._mant)
        while i > 0 or j > 0:
            var xm = Word(0)
            var ym = Word(0)
            if i > 0:
                i -= 1
                xm = self._mant[i]
            if j > 0:
                j -= 1
                ym = y._mant[j]
            if xm < ym:
                return -1
            if xm > ym:
                return 1
        return 0

    # The signed operations, which sort out the special values and then hand
    # over to the kernels above.

    def _set_add(mut self, x: Self, y: Self) raises:
        """Set this to `x + y`. Go's `Float.Add`."""
        if self._prec == 0:
            self._prec = max(x._prec, y._prec)

        if x._form == _FINITE and y._form == _FINITE:
            self._neg = x._neg
            if x._neg == y._neg:
                # x + y, or -(|x| + |y|).
                self._uadd(x, y)
            elif x._ucmp(y) > 0:
                self._usub(x, y)
            else:
                self._neg = not self._neg
                self._usub(y, x)
            # An exact zero is negative only when rounding towards minus
            # infinity, which is IEEE 754 section 6.3.
            if (
                self._form == _ZERO
                and self._mode == ToNegativeInf
                and self._acc == Exact
            ):
                self._neg = True
            return

        if x._form == _INF and y._form == _INF and x._neg != y._neg:
            self._acc = Exact
            self._form = _ZERO
            self._neg = False
            raise _nan("big: the addition of infinities with opposite signs")

        if x._form == _ZERO and y._form == _ZERO:
            self._acc = Exact
            self._form = _ZERO
            self._neg = x._neg and y._neg
            return

        if x._form == _INF or y._form == _ZERO:
            self.set(x)
            return
        self.set(y)

    def _set_sub(mut self, x: Self, y: Self) raises:
        """Set this to `x - y`. Go's `Float.Sub`."""
        if self._prec == 0:
            self._prec = max(x._prec, y._prec)

        if x._form == _FINITE and y._form == _FINITE:
            self._neg = x._neg
            if x._neg != y._neg:
                self._uadd(x, y)
            elif x._ucmp(y) > 0:
                self._usub(x, y)
            else:
                self._neg = not self._neg
                self._usub(y, x)
            if (
                self._form == _ZERO
                and self._mode == ToNegativeInf
                and self._acc == Exact
            ):
                self._neg = True
            return

        if x._form == _INF and y._form == _INF and x._neg == y._neg:
            self._acc = Exact
            self._form = _ZERO
            self._neg = False
            raise _nan("big: the subtraction of infinities with equal signs")

        if x._form == _ZERO and y._form == _ZERO:
            self._acc = Exact
            self._form = _ZERO
            self._neg = x._neg and not y._neg
            return

        if x._form == _INF or y._form == _ZERO:
            self.set(x)
            return

        self.set(y)
        self._neg = not self._neg

    def _set_mul(mut self, x: Self, y: Self) raises:
        """Set this to `x * y`. Go's `Float.Mul`."""
        if self._prec == 0:
            self._prec = max(x._prec, y._prec)

        self._neg = x._neg != y._neg

        if x._form == _FINITE and y._form == _FINITE:
            self._umul(x, y)
            return

        self._acc = Exact
        if (x._form == _ZERO and y._form == _INF) or (
            x._form == _INF and y._form == _ZERO
        ):
            self._form = _ZERO
            self._neg = False
            raise _nan("big: the multiplication of zero by an infinity")

        if x._form == _INF or y._form == _INF:
            self._form = _INF
            return
        self._form = _ZERO

    def _set_quo(mut self, x: Self, y: Self) raises:
        """Set this to `x / y`. Go's `Float.Quo`."""
        if self._prec == 0:
            self._prec = max(x._prec, y._prec)

        self._neg = x._neg != y._neg

        if x._form == _FINITE and y._form == _FINITE:
            self._uquo(x, y)
            return

        self._acc = Exact
        if (x._form == _ZERO and y._form == _ZERO) or (
            x._form == _INF and y._form == _INF
        ):
            self._form = _ZERO
            self._neg = False
            raise _nan(
                "big: the division of zero by zero or an infinity by an"
                " infinity"
            )

        if x._form == _ZERO or y._form == _INF:
            self._form = _ZERO
            return
        self._form = _INF

    def _set_sqrt(mut self, x: Self) raises:
        """Set this to the square root of `x`. Go's `Float.Sqrt`."""
        if self._prec == 0:
            self._prec = x._prec

        if x.sign() < 0:
            # IEEE 754-2008 section 7.2 says this has no answer.
            raise _nan("big: the square root of a negative number")

        if x._form != _FINITE:
            # The square root of a signed zero is that same signed zero, which
            # IEEE 754-2008 asks for, and the root of positive infinity is
            # positive infinity.
            self._acc = Exact
            self._form = x._form
            self._neg = x._neg
            return

        # Splitting off the exponent leaves a mantissa in `[0.5, 1)`, and
        # taking the mantissa this way also takes `x`'s precision, so the one
        # that was asked for is put back afterwards.
        var prec = self._prec
        var b = x.mant_exp(self)
        self._prec = prec

        # The root of `z * 2**b` is the root of `z` times two to the half of
        # `b`. An odd `b` cannot be halved, so a factor of two moves into the
        # mantissa first. Go writes this as three cases on a truncated
        # remainder; Mojo's remainder is never negative, so an odd exponent of
        # either sign takes the same branch and the halving that follows it
        # rounds down rather than towards zero, which is the matching change.
        if b % 2 != 0:
            self._exp += 1
        # 0.25 <= self < 2.0

        var t = self.copy()
        self._sqrt_inverse(t)

        # Put the halved exponent back on.
        if self._form == _FINITE:
            self._set_exp_and_round(Int64(self._exp) + Int64(b // 2), 0)

    def _sqrt_inverse(mut self, x: Self) raises:
        """Set this to the square root of `x` by way of its reciprocal. Go's
        `Float.sqrtInverse`.

        Newton's method on `1/t**2 - x = 0` converges to `1/sqrt(x)` using only
        multiplication, which is worth a great deal more than the division it
        avoids once the precision is large. The root itself is then `x` times
        that reciprocal.
        """
        var three = Self()
        three.set_float64(3.0)

        var xf, _ = x.float64()
        var sqi = Self()
        sqi.set_float64(1.0 / sqrt(xf))

        # Each step doubles the number of correct bits, so the working
        # precision doubles with it and the early steps stay cheap. The
        # thirty two extra bits are Go's margin against the last step landing
        # just short.
        var target = _MojoInt(self._prec) + 32
        while _MojoInt(sqi._prec) < target:
            sqi._prec = UInt32(min(_MojoInt(sqi._prec) * 2, MaxPrec))
            var next = _newton_step(sqi, x, three)
            sqi = next^

        self._set_mul(x, sqi)

    # Arithmetic. Go writes into a destination and takes the precision and the
    # rounding mode from it; there is no destination here, so the precision is
    # the wider of the two operands and the mode is the first operand's, which
    # is what Go's `new(Float).Add(x, y)` does. The second form names the
    # precision, which is Go's `new(Float).SetPrec(p).Add(x, y)`.

    def add(self, y: Self) raises -> Self:
        """`self + y`, to the wider of the two precisions. Go's `Float.Add`.

        Raises `ErrNaN` when the two are infinities with opposite signs, where
        Go panics with it.
        """
        return _add_at(self, y, -1, self._mode)

    def add(self, y: Self, prec: _MojoInt) raises -> Self:
        """`self + y`, to `prec` bits. Go's `Float.Add` with the destination
        precision set first."""
        return _add_at(self, y, prec, self._mode)

    def sub(self, y: Self) raises -> Self:
        """`self - y`, to the wider of the two precisions. Go's `Float.Sub`.

        Raises `ErrNaN` when the two are infinities with the same sign, where
        Go panics with it.
        """
        return _sub_at(self, y, -1, self._mode)

    def sub(self, y: Self, prec: _MojoInt) raises -> Self:
        """`self - y`, to `prec` bits. Go's `Float.Sub` with the destination
        precision set first."""
        return _sub_at(self, y, prec, self._mode)

    def mul(self, y: Self) raises -> Self:
        """`self * y`, to the wider of the two precisions. Go's `Float.Mul`.

        Raises `ErrNaN` when one side is a zero and the other an infinity,
        where Go panics with it.
        """
        return _mul_at(self, y, -1, self._mode)

    def mul(self, y: Self, prec: _MojoInt) raises -> Self:
        """`self * y`, to `prec` bits. Go's `Float.Mul` with the destination
        precision set first."""
        return _mul_at(self, y, prec, self._mode)

    def quo(self, y: Self) raises -> Self:
        """`self / y`, to the wider of the two precisions. Go's `Float.Quo`.

        Raises `ErrNaN` when both are zeros or both are infinities, where Go
        panics with it. A finite number over a zero is a signed infinity, which
        is not a failure.
        """
        return _quo_at(self, y, -1, self._mode)

    def quo(self, y: Self, prec: _MojoInt) raises -> Self:
        """`self / y`, to `prec` bits. Go's `Float.Quo` with the destination
        precision set first."""
        return _quo_at(self, y, prec, self._mode)

    def sqrt(self) raises -> Self:
        """The square root of this, to this precision. Go's `Float.Sqrt`.

        Raises `ErrNaN` for a negative number, where Go panics with it. The
        accuracy of the result is not computed, which Go also says of its own.
        """
        return _sqrt_at(self, -1, self._mode)

    def sqrt(self, prec: _MojoInt) raises -> Self:
        """The square root of this, to `prec` bits. Go's `Float.Sqrt` with the
        destination precision set first."""
        return _sqrt_at(self, prec, self._mode)

    def abs(self) -> Self:
        """`|self|`, at this precision. Go's `Float.Abs`."""
        var z = self.copy()
        z._acc = Exact
        z._neg = False
        return z^

    def neg(self) -> Self:
        """`-self`, at this precision. Go's `Float.Neg`.

        Both zeros and both infinities flip as well, since the sign is a bit of
        its own.
        """
        var z = self.copy()
        z._acc = Exact
        z._neg = not z._neg
        return z^

    # Comparison.

    def cmp(self, y: Self) -> _MojoInt:
        """`-1`, `0` or `+1` as this is below, equal to or above `y`. Go's
        `Float.Cmp`.

        The two zeros are equal to each other, and so are two infinities of the
        same sign.
        """
        var mx = self._ord()
        var my = y._ord()
        if mx < my:
            return -1
        if mx > my:
            return 1
        if mx == -1:
            return y._ucmp(self)
        if mx == 1:
            return self._ucmp(y)
        return 0

    def _ord(self) -> _MojoInt:
        """Where this sits on the line, as `-2` to `+2`. Go's `Float.ord`.

        Minus two is `-Inf`, minus one is a negative finite number, zero is
        either zero, one is a positive finite number and two is `+Inf`.
        """
        if self._form == _ZERO:
            return 0
        var m = 1
        if self._form == _INF:
            m = 2
        if self._neg:
            return -m
        return m

    def __eq__(self, y: Self) -> Bool:
        """Whether these are the same number, with the two zeros equal."""
        return self.cmp(y) == 0

    def __ne__(self, y: Self) -> Bool:
        """Whether these are different numbers."""
        return self.cmp(y) != 0

    def __lt__(self, y: Self) -> Bool:
        """Whether this is below `y`."""
        return self.cmp(y) < 0

    def __le__(self, y: Self) -> Bool:
        """Whether this is `y` or below it."""
        return self.cmp(y) <= 0

    def __gt__(self, y: Self) -> Bool:
        """Whether this is above `y`."""
        return self.cmp(y) > 0

    def __ge__(self, y: Self) -> Bool:
        """Whether this is `y` or above it."""
        return self.cmp(y) >= 0

    # Conversion out.

    def uint64(self) -> Tuple[UInt64, Accuracy]:
        """This truncated towards zero, and how far that moved it. Go's
        `Float.Uint64`.

        A negative number gives zero and `Above`, and one past the top gives
        the largest `UInt64` and `Below`, which is Go's answer in both cases.
        """
        if self._form == _ZERO:
            return (UInt64(0), Exact)
        if self._form == _INF:
            if self._neg:
                return (UInt64(0), Above)
            return (_MAX_UINT64, Below)

        if self._neg:
            return (UInt64(0), Above)
        var e = _MojoInt(self._exp)
        if e <= 0:
            return (UInt64(0), Below)
        if e <= 64:
            var u = _msb64(Span(self._mant)) >> UInt64(64 - e)
            if self.min_prec() <= 64:
                return (u, Exact)
            return (u, Below)
        return (_MAX_UINT64, Below)

    def int64(self) -> Tuple[Int64, Accuracy]:
        """This truncated towards zero, and how far that moved it. Go's
        `Float.Int64`.

        A number outside the range gives the nearest end of it, with `Above`
        below the bottom and `Below` above the top.
        """
        if self._form == _ZERO:
            return (Int64(0), Exact)
        if self._form == _INF:
            if self._neg:
                return (_MIN_INT64, Above)
            return (_MAX_INT64, Below)

        var acc = _make_acc(self._neg)
        var e = _MojoInt(self._exp)
        if e <= 0:
            return (Int64(0), acc)

        if e <= 63:
            var i = Int64(_msb64(Span(self._mant)) >> UInt64(64 - e))
            if self._neg:
                i = -i
            if self.min_prec() <= e:
                return (i, Exact)
            return (i, acc)

        if self._neg:
            # The smallest `Int64` is a half times two to the sixty four, so it
            # is the one number of this size that is not out of range.
            if e == 64 and self.min_prec() == 1:
                acc = Exact
            return (_MIN_INT64, acc)
        return (_MAX_INT64, Below)

    def float32(self) -> Tuple[Float32, Accuracy]:
        """The nearest `Float32`, and how far that moved it. Go's
        `Float.Float32`.

        A number too small to be one goes to a signed zero and a number too
        large goes to a signed infinity, with the accuracy saying which way.
        """
        if self._form == _ZERO:
            if self._neg:
                return (float32frombits(UInt32(1) << 31), Exact)
            return (Float32(0.0), Exact)
        if self._form == _INF:
            if self._neg:
                return (float32frombits(0xFF800000), Exact)
            return (float32frombits(0x7F800000), Exact)

        var bits, acc = _float_bits[32, 23](self)
        return (float32frombits(UInt32(bits)), acc)

    def float64(self) -> Tuple[Float64, Accuracy]:
        """The nearest `Float64`, and how far that moved it. Go's
        `Float.Float64`.

        A number too small to be one goes to a signed zero and a number too
        large goes to a signed infinity, with the accuracy saying which way.
        """
        if self._form == _ZERO:
            if self._neg:
                return (float64frombits(UInt64(1) << 63), Exact)
            return (Float64(0.0), Exact)
        if self._form == _INF:
            if self._neg:
                return (float64frombits(0xFFF0000000000000), Exact)
            return (float64frombits(0x7FF0000000000000), Exact)

        var bits, acc = _float_bits[64, 52](self)
        return (float64frombits(bits), acc)

    def int(self, mut acc: Accuracy) raises -> Int:
        """This truncated towards zero, with `acc` saying how far that moved
        it. Go's `Float.Int`.

        Go returns a nil `Int` for an infinity; this raises with
        `ErrInvalidArgument`, which is what `Rat.set_float64` does with the
        same input. The accuracy comes back through an argument because a tuple
        would need `Int` to be implicitly copyable and a type holding a list
        cannot be.
        """
        if self._form == _INF:
            raise Report("big: an infinity is not an integer").with_code(
                ErrInvalidArgument
            ).error()

        if self._form == _ZERO:
            acc = Exact
            return Int()

        var direction = _make_acc(self._neg)
        var e = _MojoInt(self._exp)
        if e <= 0:
            # A magnitude below one truncates to zero, and that is a move.
            acc = direction
            return Int()

        var all_bits = len(self._mant) * _W
        if self.min_prec() <= e:
            direction = Exact

        var digits: List[Word]
        if e > all_bits:
            digits = _lsh(Span(self._mant), e - all_bits)
        elif e < all_bits:
            digits = _rsh(Span(self._mant), all_bits - e)
        else:
            digits = _clone(Span(self._mant))

        acc = direction
        return Int._make(self._neg, digits^)

    def rat(self) raises -> Rat:
        """This as an exact quotient of two integers. Go's `Float.Rat`.

        Every finite `Float` is a rational number, so this never rounds and Go
        always reports `Exact`, which is why there is no accuracy here to
        return. Go gives back a nil `Rat` for an infinity; this raises with
        `ErrInvalidArgument`.
        """
        if self._form == _INF:
            raise Report("big: an infinity is not a rational number").with_code(
                ErrInvalidArgument
            ).error()

        var z = Rat()
        if self._form == _ZERO:
            return z^

        var all_bits = len(self._mant) * _W
        var e = _MojoInt(self._exp)
        var num: Int
        var den = Int(Int64(1))
        if e > all_bits:
            num = Int._make(self._neg, _lsh(Span(self._mant), e - all_bits))
        elif e < all_bits:
            num = Int._make(self._neg, _clone(Span(self._mant)))
            den = Int._make(False, _lsh(Span(_one()), all_bits - e))
        else:
            num = Int._make(self._neg, _clone(Span(self._mant)))

        z.set_frac(num, den)
        return z^

    # Text out.

    def text(self, format: UInt8, prec: _MojoInt) raises -> String:
        """This written out in the given format. Go's `Float.Text`.

        The formats are Go's, given as the byte of the letter:

        - `e` and `E` are `-d.ddddde+dd`, with at least two exponent digits.
        - `f` is `-ddddd.dddd` with no exponent.
        - `g` and `G` are `e` or `E` for a large exponent and `f` otherwise.
        - `x` is `-0xd.dddddp+dd`, a hexadecimal mantissa in `[1, 2)` and a
          decimal power of two, which is the form most other languages print.
        - `p` is `-0x.dddp+dd`, a hexadecimal mantissa in `[0.5, 1)`, which is
          Go's own and is exact.
        - `b` is `-ddddddp+dd`, a decimal mantissa of exactly `prec()` bits and
          a decimal power of two, also Go's own and also exact.

        `prec` is the number of digits after the point for `e`, `E`, `f` and
        `x`, and the total number of digits for `g` and `G`. A negative `prec`
        asks for the fewest digits that read back as this same number at this
        precision. The `b` and `p` formats ignore it.

        Any other format character comes back as a `%` and that character,
        which is Go's answer as well.

        ```mojo
        from core.math.big import Float

        var x = Float()
        x.set_float64(0.5)
        print(x.text(UInt8(ord("f")), 3))   # 0.500
        print(x.text(UInt8(ord("p")), 0))   # 0x.8p+00
        ```
        """
        var buf = List[UInt8]()
        self.append(buf, format, prec)
        return String(from_utf8_lossy=Span(buf))

    def string(self) raises -> String:
        """This as `text('g', 10)`. Go's `Float.String`."""
        return self.text(_FMT_G, 10)

    def append(
        self, mut buf: List[UInt8], format: UInt8, prec_in: _MojoInt
    ) raises:
        """Append this in the given format to `buf`. Go's `Float.Append`.

        `text` describes the formats. Go returns the extended buffer; there is
        nothing to return here, because the caller already holds it.
        """
        var start = len(buf)

        if self._neg:
            buf.append(_MINUS_BYTE)

        if self._form == _INF:
            if not self._neg:
                buf.append(_PLUS_BYTE)
            buf.append(UInt8(ord("I")))
            buf.append(UInt8(ord("n")))
            buf.append(UInt8(ord("f")))
            return

        # The three power of two formats are exact and need no decimal work.
        if format == _FMT_B:
            self._fmt_b(buf)
            return
        if format == _FMT_P:
            self._fmt_p(buf)
            return
        if format == _FMT_X:
            self._fmt_x(buf, prec_in)
            return

        # Otherwise: turn the binary mantissa into decimal digits, round those
        # to the number wanted, and lay them out.
        var d = _Decimal()
        if self._form == _FINITE:
            d.set(
                Span(self._mant),
                _MojoInt(self._exp) - _bit_len(Span(self._mant)),
            )

        var prec = prec_in
        var shortest = False
        if prec < 0:
            shortest = True
            _round_shortest(d, self)
            if format == _FMT_E or format == _FMT_E_UPPER:
                prec = len(d.mant) - 1
            elif format == _FMT_F:
                prec = max(len(d.mant) - d.exp, 0)
            elif format == _FMT_G or format == _FMT_G_UPPER:
                prec = len(d.mant)
        else:
            if format == _FMT_E or format == _FMT_E_UPPER:
                d.round(1 + prec)
            elif format == _FMT_F:
                d.round(d.exp + prec)
            elif format == _FMT_G or format == _FMT_G_UPPER:
                if prec == 0:
                    prec = 1
                d.round(prec)

        if format == _FMT_E or format == _FMT_E_UPPER:
            _fmt_e(buf, format, prec, d)
            return
        if format == _FMT_F:
            _fmt_f(buf, prec, d)
            return
        if format == _FMT_G or format == _FMT_G_UPPER:
            # Trailing zeros in the fraction do not count towards the width
            # that decides between the two layouts.
            var eprec = prec
            if eprec > len(d.mant) and len(d.mant) >= d.exp:
                eprec = len(d.mant)
            # The shortest form always compares against six, so that a number
            # that needs few digits still prints the way `%g` would.
            if shortest:
                eprec = 6
            var exp = d.exp - 1
            if exp < -4 or exp >= eprec:
                if prec > len(d.mant):
                    prec = len(d.mant)
                # `g` becomes `e` and `G` becomes `E`, which are two apart.
                _fmt_e(buf, format - (_FMT_G - _FMT_E), prec - 1, d)
                return
            if prec > d.exp:
                prec = len(d.mant)
            _fmt_f(buf, max(prec - d.exp, 0), d)
            return

        # Not a format anybody knows. The sign went on before the format was
        # looked at, so it comes off again.
        buf.resize(start, UInt8(0))
        buf.append(_PERCENT)
        buf.append(format)

    def _fmt_b(self, mut buf: List[UInt8]) raises:
        """Append the `b` form, a decimal mantissa and a binary exponent. Go's
        `Float.fmtB`.

        The mantissa is stretched or squeezed to exactly `prec()` bits, so the
        text says what the precision was and reads back exactly. The sign is
        the caller's business and an infinity never gets here.
        """
        if self._form == _ZERO:
            buf.append(_DIGIT_0)
            return

        var prec = _MojoInt(self._prec)
        var w = len(self._mant) * _W
        var m: List[Word]
        if w < prec:
            m = _lsh(Span(self._mant), prec - w)
        elif w > prec:
            m = _rsh(Span(self._mant), w - prec)
        else:
            m = _clone(Span(self._mant))

        var digits = _utoa(Span(m), 10)
        for i in range(len(digits)):
            buf.append(digits[i])
        buf.append(_LOWER_P)
        var e = Int64(self._exp) - Int64(self._prec)
        if e >= 0:
            buf.append(_PLUS_BYTE)
        _ = append_int(buf, e, 10)

    def _fmt_x(self, mut buf: List[UInt8], prec: _MojoInt) raises:
        """Append the `x` form, a hexadecimal mantissa in `[1, 2)` and a binary
        exponent. Go's `Float.fmtX`."""
        if self._form == _ZERO:
            buf.append(_DIGIT_0)
            buf.append(_FMT_X)
            buf.append(_DIGIT_0)
            if prec > 0:
                buf.append(_PERIOD)
                for _ in range(prec):
                    buf.append(_DIGIT_0)
            buf.append(_LOWER_P)
            buf.append(_PLUS_BYTE)
            buf.append(_DIGIT_0)
            buf.append(_DIGIT_0)
            return

        # A hexadecimal digit is four bits and the leading `1` is one of them,
        # so the mantissa is rounded to one bit more than a multiple of four.
        var n: _MojoInt
        if prec < 0:
            n = 1 + (self.min_prec() - 1 + 3) // 4 * 4
        else:
            n = 1 + 4 * prec

        var r = Self()
        r._prec = UInt32(n)
        r._mode = self._mode
        r.set(self)

        var w = len(r._mant) * _W
        var m: List[Word]
        if w < n:
            m = _lsh(Span(r._mant), n - w)
        elif w > n:
            m = _rsh(Span(r._mant), w - n)
        else:
            m = _clone(Span(r._mant))

        var exp64 = Int64(r._exp) - 1
        var hm = _utoa(Span(m), 16)

        buf.append(_DIGIT_0)
        buf.append(_FMT_X)
        buf.append(UInt8(ord("1")))
        if len(hm) > 1:
            buf.append(_PERIOD)
            for i in range(1, len(hm)):
                buf.append(hm[i])

        buf.append(_LOWER_P)
        if exp64 >= 0:
            buf.append(_PLUS_BYTE)
        else:
            exp64 = -exp64
            buf.append(_MINUS_BYTE)
        # Two exponent digits at least, so that this matches what Go's `fmt`
        # prints for the machine sized floats.
        if exp64 < 10:
            buf.append(_DIGIT_0)
        _ = append_int(buf, exp64, 10)

    def _fmt_p(self, mut buf: List[UInt8]) raises:
        """Append the `p` form, a hexadecimal mantissa in `[0.5, 1)` and a
        binary exponent. Go's `Float.fmtP`."""
        if self._form == _ZERO:
            buf.append(_DIGIT_0)
            return

        # Whole zero digits at the bottom of the mantissa would only become
        # hexadecimal zeros to be trimmed off again, so they go first.
        var i = 0
        while i < len(self._mant) and self._mant[i] == 0:
            i += 1
        var hm = _utoa(Span(self._mant)[i:], 16)

        buf.append(_DIGIT_0)
        buf.append(_FMT_X)
        buf.append(_PERIOD)
        var last = len(hm)
        while last > 0 and hm[last - 1] == _DIGIT_0:
            last -= 1
        for k in range(last):
            buf.append(hm[k])

        buf.append(_LOWER_P)
        if self._exp >= 0:
            buf.append(_PLUS_BYTE)
        _ = append_int(buf, Int64(self._exp), 10)

    # Text in.

    def parse(mut self, s: String, base: _MojoInt) raises -> _MojoInt:
        """Set this to the number written in `s`, and return the base it was
        written in. Go's `Float.Parse`.

        The whole of `s` has to be a number, not merely the front of one.
        `base` is 0, 2, 8, 10 or 16, and 0 means the prefix decides: `0b` or
        `0B` is binary, `0o` or `0O` is octal, `0x` or `0X` is hexadecimal, and
        anything else is decimal. A leading `0` on its own is a decimal zero
        rather than an octal prefix.

        An `e` exponent is a power of ten and a `p` exponent is a power of two.
        A hexadecimal mantissa takes only `p`, because an `e` would be one of
        its digits. `Inf`, `inf`, `+Inf` and `-Inf` are accepted and give an
        infinity, and the base comes back as zero for those, which is Go's
        answer.

        A precision of zero becomes sixty four before any rounding. Go returns
        an error and leaves the value undefined; this raises and leaves the
        value alone.
        """
        var z = Self()
        z._prec = self._prec
        z._mode = self._mode

        var src = s.as_bytes()

        # The scanner does not know the word `Inf`, in Go either.
        if _is_inf_text(src, 0):
            z.set_inf(False)
            self._copy_from(z)
            return 0
        if len(src) > 0 and (src[0] == _PLUS_BYTE or src[0] == _MINUS_BYTE):
            if _is_inf_text(src, 1):
                z.set_inf(src[0] == _MINUS_BYTE)
                self._copy_from(z)
                return 0

        var b, used = z._scan_from(src, base)
        if used != len(src):
            raise Report(
                "big: the text after the number is not part of it"
            ).with_code(ErrSyntax).error()

        self._copy_from(z)
        return b

    def set_string(mut self, s: String) raises:
        """Set this to the number written in `s`. Go's `Float.SetString`.

        Everything `parse` accepts with a base of zero. Go returns a boolean
        and leaves the value undefined on failure; this raises and leaves the
        value alone.
        """
        _ = self.parse(s, 0)

    def _scan_from[
        o: ImmOrigin
    ](mut self, src: Span[UInt8, o], base: _MojoInt) raises -> Tuple[
        _MojoInt, _MojoInt
    ]:
        """Read a number off the front of `src`. Go's `Float.scan`.

        The base it turned out to be in and how many bytes were used. Go reads
        from a byte scanner and leaves it positioned; the scanners here report
        what they consumed, so the caller compares lengths instead.
        """
        var prec = self._prec
        if prec == 0:
            prec = 64

        # A value that is at least valid, in case the caller keeps it after a
        # failure. Go does the same.
        self._form = _ZERO

        var pos = 0
        if pos < len(src) and (
            src[pos] == _MINUS_BYTE or src[pos] == _PLUS_BYTE
        ):
            self._neg = src[pos] == _MINUS_BYTE
            pos += 1
        else:
            self._neg = False

        var scanned = _scan(src[pos:], base, True)
        var b = scanned.base
        var fcount = scanned.count
        pos += scanned.used
        self._mant = scanned^.take_value()

        # Underscores are only a separator when the base was not given, which
        # is the same rule the mantissa scanner follows.
        var exp, ebase, exp_used = _scan_exponent(src[pos:], True, base == 0)
        pos += exp_used

        if len(self._mant) == 0:
            self._prec = prec
            self._acc = Exact
            self._form = _ZERO
            return (b, pos)

        # A radix point divides by the mantissa base raised to the number of
        # digits after it and an exponent multiplies by its own base raised to
        # itself. Both are products of powers of two and powers of five, and
        # multiplication commutes, so the two are collected into one power of
        # each. Normalising the mantissa is a third power of two and joins
        # them.
        var exp2 = Int64(len(self._mant)) * _W - _fnorm(self._mant)
        var exp5 = Int64(0)

        if fcount < 0:
            var d = Int64(fcount)
            if b == 10:
                exp5 = d
                exp2 += d
            elif b == 2:
                exp2 += d
            elif b == 8:
                exp2 += d * 3  # three bits to the octal digit
            else:
                exp2 += d * 4  # four bits to the hexadecimal digit

        if ebase == 10:
            exp5 += exp
        exp2 += exp

        if Int64(MinExp) <= exp2 and exp2 <= Int64(MaxExp):
            self._prec = prec
            self._form = _FINITE
            self._exp = Int32(exp2)
        else:
            raise Report("big: the exponent is out of range").with_code(
                ErrSyntax
            ).error()

        if exp5 == 0:
            self._round(0)
            return (b, pos)

        # The power of five is the part that cannot be a shift. Sixty four
        # extra bits in the factor keep its own rounding out of the answer,
        # which is the margin Go uses.
        var p = Self()
        p._prec = _checked_prec(_MojoInt(self._prec) + 64)
        var n = exp5
        if n < 0:
            n = -n
        p._set_pow5(UInt64(n))

        var t = self.copy()
        if exp5 < 0:
            self._set_quo(t, p)
        else:
            self._set_mul(t, p)
        return (b, pos)

    def _set_pow5(mut self, n_in: UInt64) raises:
        """Set this to five to the `n_in`. Go's `Float.pow5`.

        Go keeps the twenty eight powers that fit in a word as a table. They
        are a loop here, because repeated multiplication of a word by five is
        exact for every one of them and a table that has to be checked against
        Go is a table that can drift.
        """
        var m = UInt64(_POW5_MAX)
        if n_in <= m:
            self.set_uint64(_pow5_word(n_in))
            return

        self.set_uint64(_pow5_word(m))
        var n = n_in - m

        # Square and multiply on the exponent, with the running square carrying
        # more bits than the answer so that its own rounding does not show.
        var f = Self()
        f._prec = _checked_prec(self.prec() + 64)
        f.set_uint64(5)

        while n > 0:
            if (n & 1) != 0:
                var t = self.copy()
                self._set_mul(t, f)
            var a = f.copy()
            var b = f.copy()
            f._set_mul(a, b)
            n >>= 1

    # Codecs.

    def gob_encode(self) raises -> List[UInt8]:
        """This in the form Go's `encoding/gob` writes. Go's `Float.GobEncode`.

        A version byte, a byte holding the mode, the accuracy, the form and the
        sign, the precision as four bytes big endian, and for a finite number
        the exponent as four more and then the mantissa. The layout is Go's, so
        a value written here can be read by a Go program and the other way
        round.
        """
        var sz = 1 + 1 + 4
        var n = 0
        if self._form == _FINITE:
            # The mantissa is written to the width the precision asks for. The
            # list can be shorter, when the low digits are zero, and it can be
            # longer, when the precision does not fill the last digit; the
            # shorter of the two is what carries the number.
            n = (_MojoInt(self._prec) + (_W - 1)) // _W
            if len(self._mant) < n:
                n = len(self._mant)
            sz += 4 + n * _S

        var buf = List[UInt8](length=sz, fill=UInt8(0))
        buf[0] = _FLOAT_GOB_VERSION

        var b = (self._mode.value & 7) << 5
        b |= (UInt8(self._acc.value + 1) & 3) << 3
        b |= (self._form & 3) << 1
        if self._neg:
            b |= 1
        buf[1] = b

        _put_be32(buf, 2, self._prec)

        if self._form == _FINITE:
            _put_be32(buf, 6, UInt32(Int64(self._exp) & 0xFFFFFFFF))
            var mant = List[UInt8](length=n * _S, fill=UInt8(0))
            _ = _fill_bytes(Span(self._mant)[len(self._mant) - n :], Span(mant))
            for i in range(len(mant)):
                buf[10 + i] = mant[i]

        return buf^

    def gob_decode[o: ImmOrigin](mut self, buf: Span[UInt8, o]) raises:
        """Set this from the form Go's `encoding/gob` writes. Go's
        `Float.GobDecode`.

        An empty input is the zero value, which is what Go's encoder sends for
        one. The result is rounded to this precision and mode unless the
        precision is zero, in which case it is taken from the encoding exactly.

        Go accepts a form or a rounding mode outside the ones that exist and
        leaves the value in that state; this raises with `ErrInvalidArgument`,
        because there is nothing sensible either can mean and every method
        afterwards would have to guess.
        """
        if len(buf) == 0:
            self._prec = 0
            self._mode = ToNearestEven
            self._acc = Exact
            self._form = _ZERO
            self._neg = False
            self._mant = List[Word]()
            self._exp = 0
            return

        if len(buf) < 6:
            raise _short_gob()
        if buf[0] != _FLOAT_GOB_VERSION:
            raise Report(
                "big: this gob encoding version is not supported"
            ).with_code(ErrInvalidArgument).error()

        var old_prec = self._prec
        var old_mode = self._mode

        var b = buf[1]
        var mode = (b >> 5) & 7
        var form = (b >> 1) & 3
        if mode > 5 or form > _INF:
            raise Report(
                "big: this gob encoding names a rounding mode or a form that"
                " does not exist"
            ).with_code(ErrInvalidArgument).error()

        self._mode = RoundingMode(mode)
        self._acc = Accuracy(Int8((b >> 3) & 3) - 1)
        self._form = form
        self._neg = (b & 1) != 0
        self._prec = _get_be32(buf, 2)

        if self._form == _FINITE:
            if len(buf) < 10:
                raise _short_gob()
            self._exp = _get_be32(buf, 6).cast[DType.int32]()
            self._mant = _set_bytes(buf[10:])

        if old_prec != 0:
            self._mode = old_mode
            self.set_prec(_MojoInt(old_prec))

        var msg = self._validate()
        if msg.byte_length() > 0:
            raise Report(String("big: ", msg)).with_code(
                ErrInvalidArgument
            ).error()

    def _validate(self) -> String:
        """What is wrong with the internal state, or an empty string. Go's
        `Float.validate0`.

        Go keeps this behind a debugging constant and calls it from `GobDecode`
        whatever that constant says, which is the only place it can catch
        anything a program did not do itself. That is the one caller here.
        """
        if self._form != _FINITE:
            return String("")
        if len(self._mant) == 0:
            return String("a finite number has an empty mantissa")
        if (self._mant[len(self._mant) - 1] >> Word(_W - 1)) == 0:
            return String("the top bit of the mantissa is not set")
        if self._prec == 0:
            return String("a finite number has a precision of zero")
        return String("")

    def append_text(self, mut buf: List[UInt8]) raises:
        """Append this in decimal to `buf`. Go's `Float.AppendText`.

        The shortest text that reads back as this number, which is
        `text('g', -1)`. Only the value is written, so the precision, the mode
        and the accuracy are not in it.
        """
        self.append(buf, _FMT_G, -1)

    def marshal_text(self) raises -> List[UInt8]:
        """This in decimal, as bytes. Go's `Float.MarshalText`."""
        var out = List[UInt8]()
        self.append_text(out)
        return out^

    def unmarshal_text[o: ImmOrigin](mut self, text: Span[UInt8, o]) raises:
        """Set this from the text in `text`. Go's `Float.UnmarshalText`.

        Everything `parse` accepts with a base of zero. The result is rounded
        to this precision and mode, and a precision of zero becomes sixty four
        first.
        """
        _ = self.parse(String(from_utf8_lossy=text), 0)


def new_float(x: Float64) raises -> Float:
    """`x` as a `Float` with fifty three bits and `ToNearestEven` rounding.
    Go's `NewFloat`.

    Raises `ErrNaN` for a NaN, where Go panics with it.
    """
    var z = Float()
    z.set_float64(x)
    return z^


def parse_float(
    s: String, base: _MojoInt, prec: _MojoInt, mode: RoundingMode
) raises -> Float:
    """The number written in `s`, at `prec` bits and rounding by `mode`. Go's
    `ParseFloat`.

    `Float.parse` describes what the text may look like. Go also returns the
    base the mantissa turned out to be in; the arity below returns that through
    an argument, and this one is for the callers that passed a base and so
    already know.
    """
    var z = Float()
    z.set_prec(prec)
    z.set_mode(mode)
    _ = z.parse(s, base)
    return z^


def parse_float(
    s: String,
    base: _MojoInt,
    prec: _MojoInt,
    mode: RoundingMode,
    mut actual_base: _MojoInt,
) raises -> Float:
    """The number written in `s`, with `actual_base` set to the base it was
    written in. Go's `ParseFloat`.

    The base is worth asking for when `base` was zero and the prefix decided.
    It comes back as zero for `Inf`, which is Go's answer.
    """
    var z = Float()
    z.set_prec(prec)
    z.set_mode(mode)
    actual_base = z.parse(s, base)
    return z^


def _make_acc(above: Bool) -> Accuracy:
    """`Above` when the result moved up and `Below` when it moved down. Go's
    `makeAcc`."""
    if above:
        return Above
    return Below


def _nan(msg: String) -> Error:
    """Go panics with an `ErrNaN` value holding this message; here it is an
    error with the matching code on it."""
    return Report(msg).with_code(ErrNaN).error()


def _short_gob() -> Error:
    """The gob input stopped before the number did."""
    return (
        Report("big: this gob encoding is too short")
        .with_code(ErrInvalidArgument)
        .error()
    )


def _checked_prec(prec: _MojoInt) raises -> UInt32:
    """`prec` as a precision, clamped at `MaxPrec`. Raises when it is negative.

    Go's argument is unsigned, so a negative precision is a question it never
    has to answer. Here it is a mistake worth reporting rather than one to read
    as an enormous positive number.
    """
    if prec < 0:
        raise Report("big: a precision cannot be negative").with_code(
            ErrInvalidArgument
        ).error()
    if prec > MaxPrec:
        return UInt32(MaxPrec)
    return UInt32(prec)


def _fnorm(mut m: List[Word]) -> Int64:
    """Shift `m` up until the top bit of its top digit is set, and return how
    far. Go's `fnorm`.

    `m` has at least one digit and its top digit is not zero, which every
    caller here has just made sure of.
    """
    var s = _nlz(m[len(m) - 1])
    if s > 0:
        # Nothing falls off the top, because the bits being taken up are the
        # zeros that `_nlz` just counted.
        _ = _lsh_vu_into(Span(m), s)
    return Int64(s)


def _msb64[o: ImmOrigin](x: Span[Word, o]) -> UInt64:
    """The top sixty four bits of a normalised mantissa. Go's `msb64`.

    Go writes this as a switch on the word size, because it has to work on a
    machine with thirty two bit digits. A digit here is always sixty four bits,
    so the top digit is the answer.
    """
    var i = len(x) - 1
    if i < 0:
        return 0
    return UInt64(x[i])


def _float_bits[
    fbits: _MojoInt, mbits: _MojoInt
](x: Float) -> Tuple[UInt64, Accuracy]:
    """The IEEE bits of the machine float nearest `x`, and how far that moved
    it. Go's `Float.Float32` and `Float.Float64`, without the special values.

    `fbits` is the width of the whole float and `mbits` the width of its
    mantissa field, so 32 and 23 give a `Float32` and 64 and 52 a `Float64`.
    Go writes the two out as two functions a hundred lines apart, differing in
    six constants.

    The two versions can share this because every place Go reads the mantissa
    reads the same bits either way. Go's `msb32` is `msb64 >> 32`, so its
    `msb32 >> (32 - p)` is `msb64 >> (64 - p)` and its `msb32 >> ebits` is
    `msb64 >> (64 - mbits - 1)`. Everything else is an exponent, which is a
    number rather than a field until the last line.

    `x` has to be finite; the caller deals with the zeros and the infinities,
    which is where the concrete type would be needed.
    """
    var ebits = fbits - mbits - 1
    var bias = (1 << (ebits - 1)) - 1
    var emin = 1 - bias
    var emax = bias

    var sign = UInt64(0)
    if x._neg:
        sign = UInt64(1) << UInt64(fbits - 1)
    var inf_bits = UInt64((1 << ebits) - 1) << UInt64(mbits)

    # A `Float` mantissa is in `[0.5, 1)` and an IEEE one is in `[1, 2)`, so
    # the exponent for the machine float is one less.
    var e = _MojoInt(x._exp) - 1

    var p = mbits + 1
    if e < emin:
        # Below the smallest normal exponent the exponent stops moving and the
        # mantissa shifts down instead, so there are fewer bits to round to.
        p = mbits + 1 - emin + e
        if p < 0 or (
            p == 0 and _sticky(Span(x._mant), len(x._mant) * _W - 1) == 0
        ):
            # A quarter of the smallest denormal or less never rounds up, and
            # exactly half of it rounds to even, which is zero.
            if x._neg:
                return (sign, Above)
            return (UInt64(0), Below)
        if p == 0:
            # More than half of the smallest denormal, so it rounds up to it.
            # This is separate because rounding to zero bits is not something
            # `_round` can be asked for.
            if x._neg:
                return (sign | 1, Below)
            return (UInt64(1), Above)

    var r = Float()
    r._prec = UInt32(p)
    r.set(x)
    e = _MojoInt(r._exp) - 1

    # Rounding can carry into the exponent and push the number over the top.
    # It can never push one under the bottom, which is why there is no matching
    # check for an underflow here.
    if r._form == _INF or e > emax:
        if x._neg:
            return (sign | inf_bits, Below)
        return (inf_bits, Above)

    var bexp = UInt64(0)
    var mant: UInt64
    if e < emin:
        # Still denormal after rounding. The biased exponent field is zero and
        # the mantissa carries the leading one, so nothing is implicit.
        p = mbits + 1 - emin + e
        mant = _msb64(Span(r._mant)) >> UInt64(64 - p)
    else:
        bexp = UInt64(e + bias) << UInt64(mbits)
        # The leading one is implicit in a normal number, so it is shifted off.
        mant = (_msb64(Span(r._mant)) >> UInt64(64 - mbits - 1)) & (
            (UInt64(1) << UInt64(mbits)) - 1
        )

    return (sign | bexp | mant, r._acc)


def _add_at(
    x: Float, y: Float, prec: _MojoInt, mode: RoundingMode
) raises -> Float:
    """`x + y` into a value of its own. A negative `prec` means the wider of
    the two operands, which is what Go's `new(Float).Add(x, y)` gives."""
    var z = Float()
    if prec >= 0:
        z._prec = _checked_prec(prec)
    z._mode = mode
    z._set_add(x, y)
    return z^


def _sub_at(
    x: Float, y: Float, prec: _MojoInt, mode: RoundingMode
) raises -> Float:
    """`x - y` into a value of its own, the same way as `_add_at`."""
    var z = Float()
    if prec >= 0:
        z._prec = _checked_prec(prec)
    z._mode = mode
    z._set_sub(x, y)
    return z^


def _mul_at(
    x: Float, y: Float, prec: _MojoInt, mode: RoundingMode
) raises -> Float:
    """`x * y` into a value of its own, the same way as `_add_at`."""
    var z = Float()
    if prec >= 0:
        z._prec = _checked_prec(prec)
    z._mode = mode
    z._set_mul(x, y)
    return z^


def _quo_at(
    x: Float, y: Float, prec: _MojoInt, mode: RoundingMode
) raises -> Float:
    """`x / y` into a value of its own, the same way as `_add_at`."""
    var z = Float()
    if prec >= 0:
        z._prec = _checked_prec(prec)
    z._mode = mode
    z._set_quo(x, y)
    return z^


def _sqrt_at(x: Float, prec: _MojoInt, mode: RoundingMode) raises -> Float:
    """The square root of `x` into a value of its own. A negative `prec` means
    `x`'s own precision, which is what Go's `new(Float).Sqrt(x)` gives."""
    var z = Float()
    if prec >= 0:
        z._prec = _checked_prec(prec)
    z._mode = mode
    z._set_sqrt(x)
    return z^


def _newton_step(t: Float, x: Float, three: Float) raises -> Float:
    """One step of Newton's method towards `1/sqrt(x)`. Go's `ng` inside
    `sqrtInverse`.

    With `f(t) = 1/t**2 - x` the correction is `f(t)/f'(t) = -t(1 - x t**2)/2`,
    so the next guess is `t(3 - x t**2)/2`. The halving is a subtraction from
    the exponent rather than a division.
    """
    var p = t.prec()
    var mode = t.mode()
    var tt = _mul_at(t, t, p, mode)
    var xtt = _mul_at(x, tt, p, mode)
    var v = _sub_at(three, xtt, p, mode)
    var u = _mul_at(t, v, p, mode)
    if u._form == _FINITE:
        u._exp -= 1
    return u^


def _pow5_word(n: UInt64) -> Word:
    """Five to the `n`, which the caller keeps at or below `_POW5_MAX`."""
    var r = Word(1)
    for _ in range(_MojoInt(n)):
        r *= 5
    return r


def _is_inf_text[o: ImmOrigin](src: Span[UInt8, o], start: _MojoInt) -> Bool:
    """Whether `src` from `start` is exactly `Inf` or `inf`."""
    if len(src) - start != 3:
        return False
    if src[start + 1] != UInt8(ord("n")) or src[start + 2] != UInt8(ord("f")):
        return False
    return src[start] == UInt8(ord("I")) or src[start] == UInt8(ord("i"))


def _put_be32(mut buf: List[UInt8], at: _MojoInt, v: UInt32):
    """Write `v` into `buf` at `at`, most significant byte first."""
    buf[at] = UInt8((v >> 24) & 0xFF)
    buf[at + 1] = UInt8((v >> 16) & 0xFF)
    buf[at + 2] = UInt8((v >> 8) & 0xFF)
    buf[at + 3] = UInt8(v & 0xFF)


def _get_be32[o: ImmOrigin](buf: Span[UInt8, o], at: _MojoInt) -> UInt32:
    """Read four bytes at `at`, most significant first."""
    return (
        (UInt32(buf[at]) << 24)
        | (UInt32(buf[at + 1]) << 16)
        | (UInt32(buf[at + 2]) << 8)
        | UInt32(buf[at + 3])
    )


def _round_shortest(mut d: _Decimal, x: Float) raises:
    """Cut `d` to the fewest digits that still name `x` alone. Go's
    `roundShortest`.

    Every number within half a step of `x` rounds back to `x`, so the digits
    only have to be enough to tell `x` from the two numbers half a step either
    side of it. Those two bounds are computed in decimal and the digits are
    walked until one of them can be left behind.
    """
    if len(d.mant) == 0:
        return

    # Give the mantissa one more bit than the precision, so that its bottom bit
    # is worth half a step.
    var mant = _clone(Span(x._mant))
    var exp = _MojoInt(x._exp) - _bit_len(Span(mant))
    var s = _bit_len(Span(mant)) - (_MojoInt(x._prec) + 1)
    if s < 0:
        var widened = _lsh(Span(mant), -s)
        mant = widened^
    elif s > 0:
        var narrowed = _rsh(Span(mant), s)
        mant = narrowed^
    exp += s

    var lower = _Decimal()
    var below = _sub(Span(mant), Span(_one()))
    lower.set(Span(below), exp)

    var upper = _Decimal()
    var above = _add(Span(mant), Span(_one()))
    upper.set(Span(above), exp)

    # A bound is itself a possible answer only when rounding to nearest even
    # would bring it back to `x`, which needs the original mantissa to be even.
    # The test is on bit one because the mantissa was shifted up by one above.
    var inclusive = (mant[0] & 2) == 0

    for i in range(len(d.mant)):
        var m = d.mant[i]
        var l = lower.at(i)
        var u = upper.at(i)

        # Cutting here is allowed if the lower bound already differs, or if it
        # is inclusive and this is the last digit it has.
        var okdown = l != m or (inclusive and i + 1 == len(lower.mant))

        # Rounding up is allowed if the upper bound differs and either it is
        # inclusive, or it is strictly above what rounding up would give. The
        # last two clauses cover the digits past the upper bound's own: `at`
        # reads a zero there, but the bound was really settled by the digits
        # before, so rounding up is safe unless this digit is a nine and would
        # carry into it.
        var okup = m != u and (
            inclusive
            or m + 1 < u
            or i + 1 < len(upper.mant)
            or (i >= len(upper.mant) and m < _DIGIT_9)
        )

        if okdown and okup:
            d.round(i + 1)
            return
        if okdown:
            d.round_down(i + 1)
            return
        if okup:
            d.round_up(i + 1)
            return


def _fmt_e(
    mut buf: List[UInt8], format: UInt8, prec: _MojoInt, d: _Decimal
) raises:
    """Append `d` as `d.ddddde+dd`. Go's `fmtE`."""
    var ch = _DIGIT_0
    if len(d.mant) > 0:
        ch = d.mant[0]
    buf.append(ch)

    if prec > 0:
        buf.append(_PERIOD)
        var i = 1
        var m = min(len(d.mant), prec + 1)
        while i < m:
            buf.append(d.mant[i])
            i += 1
        while i <= prec:
            buf.append(_DIGIT_0)
            i += 1

    buf.append(format)
    var exp = Int64(0)
    if len(d.mant) > 0:
        # One less because the first digit went in front of the point.
        exp = Int64(d.exp) - 1
    if exp < 0:
        buf.append(_MINUS_BYTE)
        exp = -exp
    else:
        buf.append(_PLUS_BYTE)
    # Two exponent digits at least, which is what Go's `fmt` prints.
    if exp < 10:
        buf.append(_DIGIT_0)
    _ = append_int(buf, exp, 10)


def _fmt_f(mut buf: List[UInt8], prec: _MojoInt, d: _Decimal) raises:
    """Append `d` as `ddddddd.ddddd`. Go's `fmtF`."""
    if d.exp > 0:
        var m = min(len(d.mant), d.exp)
        for i in range(m):
            buf.append(d.mant[i])
        var k = m
        while k < d.exp:
            buf.append(_DIGIT_0)
            k += 1
    else:
        buf.append(_DIGIT_0)

    if prec > 0:
        buf.append(_PERIOD)
        for i in range(prec):
            buf.append(d.at(d.exp + i))
