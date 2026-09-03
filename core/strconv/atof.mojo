"""Text to floats. Go's `atof.go` and `atofeisel.go`.

Three algorithms, tried in order, all producing the same answer:

The exact path multiplies or divides by a power of ten in hardware, and is
allowed only when both the mantissa and the power are exactly representable, so
one rounding happens and it is the right one. It handles most of the numbers
people actually write.

Eisel-Lemire multiplies the mantissa by a 128-bit power of ten and reads the
top of the product. It answers for almost everything else, and declines rather
than guesses when the product lands too close to halfway to be sure.

The slow path writes the digits into a `_Decimal` and shifts it by powers of
two until it is in range, which is exact arithmetic and always right. It is
what the other two are checked against.

Go returns the nearest float alongside `ErrRange` for a number too big or too
small to hold, so a caller gets an infinity and an error together. A raise
carries no value, so this raises and the caller who wants the infinity can say
so; `errors.field(e, "num")` still has the text. That is the same trade
`parse_int` makes for its clamped value.
"""

from std.memory import bitcast

from core.strconv.atoi import _lower, _underscore_ok
from core.strconv.decimal import _Decimal
from core.strconv.math import _leading_zeros, _lo64, _hi64, _pow10, _umul128
from core.strconv.num_error import _range_error, _syntax_error


comptime _ZERO = UInt8(ord("0"))
comptime _NINE = UInt8(ord("9"))
comptime _PLUS = UInt8(ord("+"))
comptime _MINUS = UInt8(ord("-"))
comptime _DOT = UInt8(ord("."))
comptime _UNDERSCORE = UInt8(ord("_"))

comptime _FLOAT32_MANT_BITS = 23
comptime _FLOAT32_EXP_BITS = 8
comptime _FLOAT32_BIAS = -127
comptime _FLOAT64_MANT_BITS = 52
comptime _FLOAT64_EXP_BITS = 11
comptime _FLOAT64_BIAS = -1023

comptime _INF_BITS = UInt64(0x7FF0000000000000)
comptime _NEG_INF_BITS = UInt64(0xFFF0000000000000)
comptime _NAN_BITS = UInt64(0x7FF8000000000001)

comptime _F64_POW10: Array[Float64, 23] = [
    1e0,
    1e1,
    1e2,
    1e3,
    1e4,
    1e5,
    1e6,
    1e7,
    1e8,
    1e9,
    1e10,
    1e11,
    1e12,
    1e13,
    1e14,
    1e15,
    1e16,
    1e17,
    1e18,
    1e19,
    1e20,
    1e21,
    1e22,
]
"""The powers of ten a float64 holds exactly, which is as far as 10^22."""

comptime _F32_POW10: Array[Float32, 11] = [
    1e0,
    1e1,
    1e2,
    1e3,
    1e4,
    1e5,
    1e6,
    1e7,
    1e8,
    1e9,
    1e10,
]
"""The powers of ten a float32 holds exactly."""

comptime _POWTAB: Array[Int, 9] = [1, 3, 6, 9, 13, 16, 19, 23, 26]
"""How far to shift a decimal to move the point one place. Go's `powtab`."""


struct _FloatInfo(Copyable, Movable):
    """The shape of one binary float format. Go's `floatInfo`."""

    var mant_bits: Int
    var exp_bits: Int
    var bias: Int

    def __init__(out self, mant_bits: Int, exp_bits: Int, bias: Int):
        self.mant_bits = mant_bits
        self.exp_bits = exp_bits
        self.bias = bias


def _float32_info() -> _FloatInfo:
    """Go's `float32info`."""
    return _FloatInfo(_FLOAT32_MANT_BITS, _FLOAT32_EXP_BITS, _FLOAT32_BIAS)


def _float64_info() -> _FloatInfo:
    """Go's `float64info`."""
    return _FloatInfo(_FLOAT64_MANT_BITS, _FLOAT64_EXP_BITS, _FLOAT64_BIAS)


def _inf(sign: Int) -> Float64:
    """An infinity with that sign."""
    if sign < 0:
        return bitcast[DType.float64](_NEG_INF_BITS)
    return bitcast[DType.float64](_INF_BITS)


def _nan() -> Float64:
    """A quiet NaN, with the payload Go's `math.NaN` uses."""
    return bitcast[DType.float64](_NAN_BITS)


struct _Special(Copyable, Movable):
    """The answer to `_special`: a value, how much of the text it used, and
    whether the text was one of the special spellings at all."""

    var value: Float64
    var n: Int
    var ok: Bool

    def __init__(out self, value: Float64, n: Int, ok: Bool):
        self.value = value
        self.n = n
        self.ok = ok


def _common_prefix_len_ignore_case[
    o: ImmOrigin
](s: StringSlice[o], prefix: StringSlice[ImmStaticOrigin]) -> Int:
    """How much of `s` matches `prefix`, ignoring the case of `s`.

    Go's `commonPrefixLenIgnoreCase`. `prefix` has to be lower case already,
    which every caller here writes as a literal.
    """
    var data = s.as_bytes()
    var want = prefix.as_bytes()
    var n = min(len(want), len(data))
    for i in range(n):
        var c = data[i]
        if UInt8(ord("A")) <= c and c <= UInt8(ord("Z")):
            c += UInt8(ord("a")) - UInt8(ord("A"))
        if c != want[i]:
            return i
    return n


def _special[o: ImmOrigin](s: StringSlice[o]) -> _Special:
    """`inf`, `infinity` or `nan`, in any case, with an optional sign.

    Go's `special`. `nan` takes no sign, which is Go's rule and not an accident
    of this translation: Go reaches the infinity branch by falling through the
    sign branch, so a signed `nan` never gets looked at.
    """
    var data = s.as_bytes()
    if len(data) == 0:
        return _Special(0.0, 0, False)

    var sign = 1
    var nsign = 0
    var rest = s
    var c = data[0]
    if c == _PLUS or c == _MINUS:
        if c == _MINUS:
            sign = -1
        nsign = 1
        rest = s[byte = 1 : s.byte_length()]
    elif c == UInt8(ord("n")) or c == UInt8(ord("N")):
        if _common_prefix_len_ignore_case(s, "nan") == 3:
            return _Special(_nan(), 3, True)
        return _Special(0.0, 0, False)
    elif not (c == UInt8(ord("i")) or c == UInt8(ord("I"))):
        return _Special(0.0, 0, False)

    var n = _common_prefix_len_ignore_case(rest, "infinity")
    # Anything past `inf` has to reach the end of `infinity` to count, so a
    # prefix in between takes only the three letters.
    if 3 < n and n < 8:
        n = 3
    if n == 3 or n == 8:
        return _Special(_inf(sign), nsign + n, True)
    return _Special(0.0, 0, False)


def _set[o: ImmOrigin](mut b: _Decimal, s: StringSlice[o]) -> Bool:
    """Read `s` into `b` as digits and a decimal point. Go's `decimal.set`.

    The whole of `s` has to be the number, because the only caller has already
    found where it ends. Underscores are skipped without checking, because
    `_read_float` has checked them.
    """
    var data = s.as_bytes()
    var i = 0
    b.neg = False
    b.trunc = False

    if i >= len(data):
        return False
    if data[i] == _PLUS:
        i += 1
    elif data[i] == _MINUS:
        i += 1
        b.neg = True

    var sawdot = False
    var sawdigits = False
    while i < len(data):
        var c = data[i]
        if c == _UNDERSCORE:
            i += 1
            continue
        if c == _DOT:
            if sawdot:
                return False
            sawdot = True
            b.dp = b.nd
            i += 1
            continue
        if _ZERO <= c and c <= _NINE:
            sawdigits = True
            if c == _ZERO and b.nd == 0:
                # Leading zeros move the point rather than take a slot.
                b.dp -= 1
                i += 1
                continue
            if b.nd < len(b.d):
                b.d[b.nd] = c
                b.nd += 1
            elif c != _ZERO:
                b.trunc = True
            i += 1
            continue
        break

    if not sawdigits:
        return False
    if not sawdot:
        b.dp = b.nd

    if i < len(data) and _lower(data[i]) == UInt8(ord("e")):
        i += 1
        if i >= len(data):
            return False
        var esign = 1
        if data[i] == _PLUS:
            i += 1
        elif data[i] == _MINUS:
            i += 1
            esign = -1
        if i >= len(data) or data[i] < _ZERO or data[i] > _NINE:
            return False
        var e = 0
        while i < len(data) and (
            (_ZERO <= data[i] and data[i] <= _NINE) or data[i] == _UNDERSCORE
        ):
            if data[i] != _UNDERSCORE:
                # Ten thousand is already past every representable exponent, so
                # a longer one only has to be large, not exact.
                if e < 10000:
                    e = e * 10 + Int(data[i] - _ZERO)
            i += 1
        b.dp += e * esign

    return i == len(data)


struct _ReadFloat(Copyable, Movable):
    """What `_read_float` found: a mantissa and exponent, the flags that say how
    to read them, how many bytes it used and whether it worked."""

    var mantissa: UInt64
    var exp: Int
    var neg: Bool
    var trunc: Bool
    var hex: Bool
    var i: Int
    var ok: Bool

    def __init__(out self):
        self.mantissa = 0
        self.exp = 0
        self.neg = False
        self.trunc = False
        self.hex = False
        self.i = 0
        self.ok = False


def _read_float[o: ImmOrigin](s: StringSlice[o]) -> _ReadFloat:
    """Read a float from the front of `s`. Go's `readFloat`.

    A prefix rather than the whole string, because the same routine serves
    `parse_float`, which insists the number reaches the end, and a complex
    parser, which does not. Anything past the nineteenth significant digit is
    dropped and recorded in `trunc`, since nineteen is as many as a `UInt64`
    holds and the algorithms above know what to do with the flag.

    `i` is set whether or not the read worked, which is Go's behaviour and is
    what lets a caller say how much of its input was a number even when the
    part after it was not.
    """
    var out = _ReadFloat()
    var data = s.as_bytes()
    var underscores = False
    var i = 0

    if i >= len(data):
        return out^
    if data[i] == _PLUS:
        i += 1
    elif data[i] == _MINUS:
        i += 1
        out.neg = True

    var base = UInt64(10)
    var max_mant_digits = 19
    var exp_char = UInt8(ord("e"))
    if (
        i + 2 < len(data)
        and data[i] == _ZERO
        and _lower(data[i + 1]) == UInt8(ord("x"))
    ):
        base = 16
        max_mant_digits = 16
        i += 2
        exp_char = UInt8(ord("p"))
        out.hex = True

    var sawdot = False
    var sawdigits = False
    var nd = 0
    var nd_mant = 0
    var dp = 0

    while i < len(data):
        var c = data[i]
        if c == _UNDERSCORE:
            underscores = True
            i += 1
            continue
        if c == _DOT:
            if sawdot:
                break
            sawdot = True
            dp = nd
            i += 1
            continue
        if _ZERO <= c and c <= _NINE:
            sawdigits = True
            if c == _ZERO and nd == 0:
                dp -= 1
                i += 1
                continue
            nd += 1
            if nd_mant < max_mant_digits:
                out.mantissa *= base
                out.mantissa += UInt64((c - _ZERO).cast[DType.uint64]())
                nd_mant += 1
            elif c != _ZERO:
                out.trunc = True
            i += 1
            continue
        if (
            base == 16
            and UInt8(ord("a")) <= _lower(c)
            and _lower(c) <= UInt8(ord("f"))
        ):
            sawdigits = True
            nd += 1
            if nd_mant < max_mant_digits:
                out.mantissa *= 16
                out.mantissa += UInt64(
                    (_lower(c) - UInt8(ord("a")) + 10).cast[DType.uint64]()
                )
                nd_mant += 1
            else:
                out.trunc = True
            i += 1
            continue
        break

    out.i = i
    if not sawdigits:
        return out^
    if not sawdot:
        dp = nd

    if base == 16:
        # A hex digit is four binary ones, and the exponent is binary.
        dp *= 4
        nd_mant *= 4

    if i < len(data) and _lower(data[i]) == exp_char:
        i += 1
        if i >= len(data):
            out.i = i
            return out^
        var esign = 1
        if data[i] == _PLUS:
            i += 1
        elif data[i] == _MINUS:
            i += 1
            esign = -1
        if i >= len(data) or data[i] < _ZERO or data[i] > _NINE:
            out.i = i
            return out^
        var e = 0
        while i < len(data) and (
            (_ZERO <= data[i] and data[i] <= _NINE) or data[i] == _UNDERSCORE
        ):
            if data[i] == _UNDERSCORE:
                underscores = True
                i += 1
                continue
            if e < 10000:
                e = e * 10 + Int(data[i] - _ZERO)
            i += 1
        dp += e * esign
    elif base == 16:
        # A hex float without an exponent is not a hex float.
        return out^

    out.i = i
    if out.mantissa != 0:
        out.exp = dp - nd_mant

    if underscores and not _underscore_ok(s[byte=0:i]):
        return out^

    out.ok = True
    return out^


struct _Bits(Copyable, Movable):
    """A float's bit pattern, and whether making it overflowed."""

    var bits: UInt64
    var overflow: Bool

    def __init__(out self, bits: UInt64, overflow: Bool):
        self.bits = bits
        self.overflow = overflow


def _assemble(
    neg: Bool, mant: UInt64, exp: Int, flt: _FloatInfo, overflow: Bool
) -> _Bits:
    """A sign, a mantissa and a biased exponent, packed into a word."""
    var bits = mant & ((UInt64(1) << UInt64(flt.mant_bits)) - 1)
    bits |= UInt64(
        Int64((exp - flt.bias) & ((1 << flt.exp_bits) - 1)).cast[DType.uint64]()
    ) << UInt64(flt.mant_bits)
    if neg:
        bits |= UInt64(1) << UInt64(flt.mant_bits) << UInt64(flt.exp_bits)
    return _Bits(bits, overflow)


def _overflowed(neg: Bool, flt: _FloatInfo) -> _Bits:
    """An infinity of the right sign, flagged as out of range."""
    return _assemble(neg, 0, (1 << flt.exp_bits) - 1 + flt.bias, flt, True)


def _float_bits(mut d: _Decimal, flt: _FloatInfo) -> _Bits:
    """`d` as the bits of a float. Go's `decimal.floatBits`.

    The exact path: shift by powers of two until the value is in `[0.5, 1)`,
    then shift up by the mantissa width and round. Every shift is exact, so the
    only rounding is the last one and it is the one IEEE asks for.
    """
    if d.nd == 0:
        return _assemble(d.neg, 0, flt.bias, flt, False)

    # These bounds are for float64 and are wide enough for float32 as well.
    if d.dp > 310:
        return _overflowed(d.neg, flt)
    if d.dp < -330:
        return _assemble(d.neg, 0, flt.bias, flt, False)

    var exp = 0
    var powtab = materialize[_POWTAB]()
    while d.dp > 0:
        var n: Int
        if d.dp >= len(powtab):
            n = 27
        else:
            n = powtab[d.dp]
        d.shift(-n)
        exp += n
    while d.dp < 0 or (d.dp == 0 and d.d[0] < UInt8(ord("5"))):
        var n: Int
        if -d.dp >= len(powtab):
            n = 27
        else:
            n = powtab[-d.dp]
        d.shift(n)
        exp -= n

    # The loop above lands in [0.5, 1) and a float mantissa lives in [1, 2).
    exp -= 1

    if exp < flt.bias + 1:
        # Below the smallest normal exponent, so denormalize into it.
        var n = flt.bias + 1 - exp
        d.shift(-n)
        exp += n

    if exp - flt.bias >= (1 << flt.exp_bits) - 1:
        return _overflowed(d.neg, flt)

    d.shift(1 + flt.mant_bits)
    var mant = d.rounded_integer()

    if mant == UInt64(2) << UInt64(flt.mant_bits):
        # Rounding carried into a new bit.
        mant >>= 1
        exp += 1
        if exp - flt.bias >= (1 << flt.exp_bits) - 1:
            return _overflowed(d.neg, flt)

    if mant & (UInt64(1) << UInt64(flt.mant_bits)) == 0:
        exp = flt.bias

    return _assemble(d.neg, mant, exp, flt, False)


struct _Exact(Copyable, Movable):
    """A value the hardware could produce on its own, if it could."""

    var f: Float64
    var ok: Bool

    def __init__(out self, f: Float64, ok: Bool):
        self.f = f
        self.ok = ok


def _atof64_exact(mantissa: UInt64, exp: Int, neg: Bool) -> _Exact:
    """`mantissa * 10^exp` in float64 arithmetic, when that is exact enough.

    Go's `atof64exact`. One multiply or one divide, both of which the hardware
    rounds correctly, so the answer is right whenever the inputs are exact: a
    mantissa that fits in 52 bits and a power of ten no larger than 10^22.
    """
    if mantissa >> UInt64(_FLOAT64_MANT_BITS) != 0:
        return _Exact(0.0, False)
    var f = Float64(mantissa.cast[DType.float64]())
    if neg:
        f = -f
    var pow10 = materialize[_F64_POW10]()
    if exp == 0:
        return _Exact(f, True)
    if exp > 0 and exp <= 15 + 22:
        var e = exp
        if e > 22:
            # A long exponent on a short mantissa: move some of it into the
            # integer, where it still costs nothing.
            f *= pow10[e - 22]
            e = 22
        if f > 1e15 or f < -1e15:
            return _Exact(0.0, False)
        return _Exact(f * pow10[e], True)
    if exp < 0 and exp >= -22:
        return _Exact(f / pow10[-exp], True)
    return _Exact(0.0, False)


struct _Exact32(Copyable, Movable):
    """The float32 flavour of `_Exact`."""

    var f: Float32
    var ok: Bool

    def __init__(out self, f: Float32, ok: Bool):
        self.f = f
        self.ok = ok


def _atof32_exact(mantissa: UInt64, exp: Int, neg: Bool) -> _Exact32:
    """`mantissa * 10^exp` in float32 arithmetic. Go's `atof32exact`."""
    if mantissa >> UInt64(_FLOAT32_MANT_BITS) != 0:
        return _Exact32(0.0, False)
    var f = Float32(mantissa.cast[DType.float32]())
    if neg:
        f = -f
    var pow10 = materialize[_F32_POW10]()
    if exp == 0:
        return _Exact32(f, True)
    if exp > 0 and exp <= 7 + 10:
        var e = exp
        if e > 10:
            f *= pow10[e - 10]
            e = 10
        if f > 1e7 or f < -1e7:
            return _Exact32(0.0, False)
        return _Exact32(f * pow10[e], True)
    if exp < 0 and exp >= -10:
        return _Exact32(f / pow10[-exp], True)
    return _Exact32(0.0, False)


struct _HexResult(Copyable, Movable):
    """A hex float and whether it went out of range."""

    var f: Float64
    var out_of_range: Bool

    def __init__(out self, f: Float64, out_of_range: Bool):
        self.f = f
        self.out_of_range = out_of_range


def _atof_hex(
    flt: _FloatInfo, mantissa: UInt64, exp: Int, neg: Bool, trunc: Bool
) -> _HexResult:
    """A hexadecimal float, already split into a mantissa and an exponent.

    Go's `atofHex`. Both are binary, so there is no decimal arithmetic here at
    all: the mantissa is shifted into place and rounded on two spare bits, the
    lower of which is sticky and carries the `trunc` flag.
    """
    var max_exp = (1 << flt.exp_bits) + flt.bias - 2
    var min_exp = flt.bias + 1
    var mant = mantissa
    var e = exp + flt.mant_bits

    while mant != 0 and mant >> UInt64(flt.mant_bits + 2) == 0:
        mant <<= 1
        e -= 1
    if trunc:
        mant |= 1
    while mant >> UInt64(1 + flt.mant_bits + 2) != 0:
        mant = (mant >> 1) | (mant & 1)
        e += 1

    # Too small to be normal, so give up bits in the hope of staying nonzero.
    while mant > 1 and e < min_exp - 2:
        mant = (mant >> 1) | (mant & 1)
        e += 1

    var round = mant & 3
    mant >>= 2
    round |= mant & 1
    e += 2
    if round == 3:
        mant += 1
        if mant == UInt64(1) << UInt64(1 + flt.mant_bits):
            mant >>= 1
            e += 1

    if mant >> UInt64(flt.mant_bits) == 0:
        e = flt.bias

    var out_of_range = False
    if e > max_exp:
        mant = UInt64(1) << UInt64(flt.mant_bits)
        e = max_exp + 1
        out_of_range = True

    var packed = _assemble(neg, mant, e, flt, False)
    if flt.mant_bits == _FLOAT32_MANT_BITS:
        var narrow = bitcast[DType.float32](
            UInt32(packed.bits.cast[DType.uint32]())
        )
        return _HexResult(Float64(narrow), out_of_range)
    return _HexResult(bitcast[DType.float64](packed.bits), out_of_range)


def _eisel_lemire64(man: UInt64, exp10: Int, neg: Bool) -> _Exact:
    """`man * 10^exp10` as a float64, or a decline. Go's `eiselLemire64`.

    The mantissa is normalised so its top bit is set, multiplied by a 128-bit
    power of ten, and the top 54 bits of the product are read off. That is
    enough to name the answer unless the product sits within one unit of a
    halfway point, which is what each of the checks below is looking for. On any
    of them it declines and the slow path takes over.

    The section names in the comments are from Nigel Tao's write up, which is
    the reference Go's implementation follows.
    """
    # Exp10 range.
    if man == 0:
        if neg:
            return _Exact(
                bitcast[DType.float64](UInt64(0x8000000000000000)), True
            )
        return _Exact(0.0, True)
    var pow = _pow10(exp10)
    if not pow.ok:
        return _Exact(0.0, False)

    # Normalization.
    var clz = _leading_zeros(man)
    var m = man << UInt64(clz)
    var ret_exp2 = Int64(pow.exp + 63 - _FLOAT64_BIAS).cast[
        DType.uint64
    ]() - UInt64(clz)

    # Multiplication.
    var x = _umul128(m, _hi64(pow.mant))
    var x_hi = _hi64(x)
    var x_lo = _lo64(x)

    # Wider approximation.
    if x_hi & 0x1FF == 0x1FF and x_lo + m < m:
        var y = _umul128(m, _lo64(pow.mant))
        var merged_hi = x_hi
        var merged_lo = x_lo + _hi64(y)
        if merged_lo < x_lo:
            merged_hi += 1
        if (
            merged_hi & 0x1FF == 0x1FF
            and merged_lo + 1 == 0
            and _lo64(y) + m < m
        ):
            return _Exact(0.0, False)
        x_hi = merged_hi
        x_lo = merged_lo

    # Shifting to 54 bits.
    var msb = x_hi >> 63
    var ret_mantissa = x_hi >> (msb + 9)
    ret_exp2 -= UInt64(1) ^ msb

    # Half-way ambiguity.
    if x_lo == 0 and x_hi & 0x1FF == 0 and ret_mantissa & 3 == 1:
        return _Exact(0.0, False)

    # From 54 to 53 bits.
    ret_mantissa += ret_mantissa & 1
    ret_mantissa >>= 1
    if ret_mantissa >> 53 > 0:
        ret_mantissa >>= 1
        ret_exp2 += 1

    # Zero or below means subnormal and 0x7FF or above means infinity, neither
    # of which this is allowed to answer. Written as one unsigned comparison,
    # which is what Go does: an exponent that went below zero has wrapped to
    # something enormous and fails the same test.
    if ret_exp2 - 1 >= 0x7FF - 1:
        return _Exact(0.0, False)

    var bits = (ret_exp2 << UInt64(_FLOAT64_MANT_BITS)) | (
        ret_mantissa & ((UInt64(1) << UInt64(_FLOAT64_MANT_BITS)) - 1)
    )
    if neg:
        bits |= 0x8000000000000000
    return _Exact(bitcast[DType.float64](bits), True)


def _eisel_lemire32(man: UInt64, exp10: Int, neg: Bool) -> _Exact32:
    """The float32 flavour. Go's `eiselLemire32`.

    Kept as a second copy rather than folded into the first, which is what Go
    does: the shifts and masks are different constants throughout and the
    arithmetic is still 64-bit, so sharing the body would mean passing every one
    of them in.
    """
    if man == 0:
        if neg:
            return _Exact32(bitcast[DType.float32](UInt32(0x80000000)), True)
        return _Exact32(0.0, True)
    var pow = _pow10(exp10)
    if not pow.ok:
        return _Exact32(0.0, False)

    var clz = _leading_zeros(man)
    var m = man << UInt64(clz)
    var ret_exp2 = Int64(pow.exp + 63 - _FLOAT32_BIAS).cast[
        DType.uint64
    ]() - UInt64(clz)

    var x = _umul128(m, _hi64(pow.mant))
    var x_hi = _hi64(x)
    var x_lo = _lo64(x)

    if x_hi & 0x3FFFFFFFFF == 0x3FFFFFFFFF and x_lo + m < m:
        var y = _umul128(m, _lo64(pow.mant))
        var merged_hi = x_hi
        var merged_lo = x_lo + _hi64(y)
        if merged_lo < x_lo:
            merged_hi += 1
        if (
            merged_hi & 0x3FFFFFFFFF == 0x3FFFFFFFFF
            and merged_lo + 1 == 0
            and _lo64(y) + m < m
        ):
            return _Exact32(0.0, False)
        x_hi = merged_hi
        x_lo = merged_lo

    var msb = x_hi >> 63
    var ret_mantissa = x_hi >> (msb + 38)
    ret_exp2 -= UInt64(1) ^ msb

    if x_lo == 0 and x_hi & 0x3FFFFFFFFF == 0 and ret_mantissa & 3 == 1:
        return _Exact32(0.0, False)

    ret_mantissa += ret_mantissa & 1
    ret_mantissa >>= 1
    if ret_mantissa >> 24 > 0:
        ret_mantissa >>= 1
        ret_exp2 += 1

    if ret_exp2 - 1 >= 0xFF - 1:
        return _Exact32(0.0, False)

    var bits = (ret_exp2 << UInt64(_FLOAT32_MANT_BITS)) | (
        ret_mantissa & ((UInt64(1) << UInt64(_FLOAT32_MANT_BITS)) - 1)
    )
    if neg:
        bits |= 0x80000000
    return _Exact32(
        bitcast[DType.float32](UInt32(bits.cast[DType.uint32]())), True
    )


struct _Parsed(Copyable, Movable):
    """A parsed float, how much of the text it used, and what went wrong.

    `ok` false is a syntax failure and `out_of_range` is a value that does not
    fit. They are carried rather than raised because the caller decides which
    one to report: text left over after a number that overflowed is a syntax
    failure, not a range one.
    """

    var f: Float64
    var n: Int
    var ok: Bool
    var out_of_range: Bool

    def __init__(out self, f: Float64, n: Int, ok: Bool, out_of_range: Bool):
        self.f = f
        self.n = n
        self.ok = ok
        self.out_of_range = out_of_range


def _atof32[o: ImmOrigin](s: StringSlice[o]) -> _Parsed:
    """A float32, widened. Go's `atof32`."""
    var sp = _special(s)
    if sp.ok:
        return _Parsed(Float64(Float32(sp.value)), sp.n, True, False)

    var read = _read_float(s)
    if not read.ok:
        return _Parsed(0.0, read.i, False, False)

    if read.hex:
        var hex = _atof_hex(
            _float32_info(), read.mantissa, read.exp, read.neg, read.trunc
        )
        return _Parsed(hex.f, read.i, True, hex.out_of_range)

    if not read.trunc:
        var exact = _atof32_exact(read.mantissa, read.exp, read.neg)
        if exact.ok:
            return _Parsed(Float64(exact.f), read.i, True, False)
    var el = _eisel_lemire32(read.mantissa, read.exp, read.neg)
    if el.ok:
        if not read.trunc:
            return _Parsed(Float64(el.f), read.i, True, False)
        # Digits were dropped, so the answer is only right if the number one
        # above the truncated mantissa rounds to the same float.
        var up = _eisel_lemire32(read.mantissa + 1, read.exp, read.neg)
        if up.ok and el.f == up.f:
            return _Parsed(Float64(el.f), read.i, True, False)

    var d = _Decimal()
    if not _set(d, s[byte = 0 : read.i]):
        return _Parsed(0.0, read.i, False, False)
    var bits = _float_bits(d, _float32_info())
    var f = bitcast[DType.float32](UInt32(bits.bits.cast[DType.uint32]()))
    return _Parsed(Float64(f), read.i, True, bits.overflow)


def _atof64[o: ImmOrigin](s: StringSlice[o]) -> _Parsed:
    """A float64. Go's `atof64`."""
    var sp = _special(s)
    if sp.ok:
        return _Parsed(sp.value, sp.n, True, False)

    var read = _read_float(s)
    if not read.ok:
        return _Parsed(0.0, read.i, False, False)

    if read.hex:
        var hex = _atof_hex(
            _float64_info(), read.mantissa, read.exp, read.neg, read.trunc
        )
        return _Parsed(hex.f, read.i, True, hex.out_of_range)

    if not read.trunc:
        var exact = _atof64_exact(read.mantissa, read.exp, read.neg)
        if exact.ok:
            return _Parsed(exact.f, read.i, True, False)
    var el = _eisel_lemire64(read.mantissa, read.exp, read.neg)
    if el.ok:
        if not read.trunc:
            return _Parsed(el.f, read.i, True, False)
        var up = _eisel_lemire64(read.mantissa + 1, read.exp, read.neg)
        if up.ok and el.f == up.f:
            return _Parsed(el.f, read.i, True, False)

    var d = _Decimal()
    if not _set(d, s[byte = 0 : read.i]):
        return _Parsed(0.0, read.i, False, False)
    var bits = _float_bits(d, _float64_info())
    return _Parsed(
        bitcast[DType.float64](bits.bits), read.i, True, bits.overflow
    )


def _parse_float_prefix[
    o: ImmOrigin
](s: StringSlice[o], bit_size: Int) -> _Parsed:
    """`parse_float` on a prefix of `s`. Go's `parseFloatPrefix`."""
    if bit_size == 32:
        return _atof32(s)
    return _atof64(s)


def parse_float[
    o: ImmOrigin
](s: StringSlice[o], bit_size: Int) raises -> Float64:
    """`s` as a floating point number of `bit_size` bits. Go's `ParseFloat`.

    `bit_size` is 32 or 64, and anything else is read as 64, which is Go's
    behaviour. At 32 the result is still a `Float64`, holding a value a `Float32`
    can represent exactly.

    The syntax is Go's floating point literal: decimal digits with an optional
    point and an optional `e` exponent, or `0x` digits with a mandatory `p`
    exponent, with underscores allowed between digits. `inf`, `infinity` and
    `nan` are accepted in any case, the first two with a sign.

    Raises with `ErrSyntax` when the text is not a number or has anything left
    over after one, and with `ErrRange` when it is a number too large to hold.

    ```mojo
    from core.strconv import parse_float

    def main() raises:
        print(parse_float("3.1415", 64))  # 3.1415
        print(parse_float("0x1p-2", 64))  # 0.25
    ```
    """
    var parsed = _parse_float_prefix(s, bit_size)
    if not parsed.ok or parsed.n != s.byte_length():
        raise _syntax_error("parse_float", s)
    if parsed.out_of_range:
        raise _range_error("parse_float", s)
    return parsed.f
