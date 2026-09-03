"""The arithmetic the float conversions are built out of. Go's `math.go`.

Parsing and formatting a float both come down to multiplying by a power of ten
held to 128 bits and reading the top of the product. The tables are in
`tables.mojo`; this is the arithmetic around them.

Go carries its own `uint128` struct because Go has no 128-bit integer. Mojo
does, so `UInt128` is used directly and the struct is not ported. The one place
that matters is Go's `pow.Lo++` in the fixed precision formatter, which
increments the low half and would not carry into the high half. No entry in the
table has a low half of all ones, so a plain `+ 1` on the whole value is the
same operation, and `tools/gen/strconv.py` is where that would stop being true.

Nothing here is public. It is arithmetic in service of `parse_float` and
`format_float`, and a caller who wants a 128-bit multiply wants `core.math`.
"""

from std.bit import bit_width

from core.strconv.tables import (
    _DIV5_INV,
    _DIV5_MAX,
    _POW10_HI,
    _POW10_LO,
    _POW10_MAX,
    _POW10_MIN,
)


def _lo64(x: UInt128) -> UInt64:
    """The bottom 64 bits of `x`."""
    return UInt64(x.cast[DType.uint64]())


def _hi64(x: UInt128) -> UInt64:
    """The top 64 bits of `x`."""
    return UInt64((x >> UInt128(64)).cast[DType.uint64]())


def _u128(hi: UInt64, lo: UInt64) -> UInt128:
    """The 128-bit number with those halves."""
    return (UInt128(hi) << UInt128(64)) | UInt128(lo)


def _umul128(x: UInt64, y: UInt64) -> UInt128:
    """The full 128-bit product. Go's `umul128`, which is `bits.Mul64`."""
    return UInt128(x) * UInt128(y)


def _leading_zeros(x: UInt64) -> Int:
    """How many zero bits are above the highest set bit of `x`.

    `bits.LeadingZeros64`. Zero has 64 of them, which is what `bit_width`
    already says, so there is no special case.
    """
    return 64 - Int(bit_width(x))


def _rotate_right(x: UInt64, n: Int) -> UInt64:
    """`x` rotated `n` places towards the bottom.

    `bits.RotateLeft64(x, -n)`. The bits that fall off the bottom come back in
    at the top, which is what makes it a test for trailing zeros rather than a
    shift that throws them away.
    """
    return (x >> UInt64(n)) | (x << UInt64(64 - n))


struct _Mul192(Copyable, Movable):
    """A 192-bit product, in three words from the top down."""

    var hi: UInt64
    var mid: UInt64
    var lo: UInt64

    def __init__(out self, hi: UInt64, mid: UInt64, lo: UInt64):
        self.hi = hi
        self.mid = mid
        self.lo = lo


def _umul192(x: UInt64, y: UInt128) -> _Mul192:
    """The full 192-bit product of a 64-bit and a 128-bit number. Go's
    `umul192`."""
    var low = _umul128(x, _lo64(y))
    var high = _umul128(x, _hi64(y))
    var middle = UInt128(_hi64(low)) + UInt128(_lo64(high))
    return _Mul192(_hi64(high) + _hi64(middle), _lo64(middle), _lo64(low))


struct _Pow10(Copyable, Movable):
    """A power of ten as a 128-bit mantissa and a binary exponent.

    `10^e` is `mant / 2^128 * 2^exp`, with the top bit of `mant` set. `ok` is
    false when the exponent asked for is outside the table, which for a float64
    means the answer was going to be zero or infinity anyway.
    """

    var mant: UInt128
    var exp: Int
    var ok: Bool

    def __init__(out self, mant: UInt128, exp: Int, ok: Bool):
        self.mant = mant
        self.exp = exp
        self.ok = ok


def _pow10(e: Int) -> _Pow10:
    """`10^e` as a mantissa and an exponent. Go's `pow10`."""
    if e < _POW10_MIN or e > _POW10_MAX:
        return _Pow10(UInt128(0), 0, False)
    var i = e - _POW10_MIN
    var mant = _u128(
        materialize[_POW10_HI]()[i],
        materialize[_POW10_LO]()[i],
    )
    return _Pow10(mant, 1 + _mul_log2_10(e), True)


def _mul_log10_2(x: Int) -> Int:
    """`floor(x * log10(2))`, for `x` between -1600 and 1600.

    Go's `mulLog10_2`. The restricted range is what lets a multiply and a shift
    stand in for a logarithm: `log(2)/log(10)` is `78913 / 2^18` to more
    precision than any input in that range can tell apart.
    """
    return (x * 78913) >> 18


def _mul_log2_10(x: Int) -> Int:
    """`floor(x * log2(10))`, for `x` between -500 and 500. Go's `mulLog2_10`.

    `log(10)/log(2)` is `108853 / 2^15` over that range, for the same reason.
    """
    return (x * 108853) >> 15


def _mul_log10_2_minus_log10_4_over_3(e: Int) -> Int:
    """`floor(e * log10(2) - log10(4/3))`, for `e` between -2985 and 2936.

    Go's `mulLog10_2MinusLog10_4Over3`, section 6.3 of the Dragonbox paper. It
    is the exponent to use when the mantissa is exactly a power of two, where
    the interval of values that round to it is lopsided.
    """
    return (e * 631305 - 261663) >> 21


def _divisible_pow5(x: UInt64, p: Int) -> Bool:
    """Whether `x` is a multiple of `5^p`, for `p` between 1 and 22.

    Go's `divisiblePow5`. Multiplying by the inverse of an odd number modulo
    `2^64` maps its multiples onto `0` through `UInt64.MAX / 5^p` and everything
    else above that, so one multiply and one comparison answer a question that
    would otherwise be a division.

    False outside that range of `p` rather than an error, which is Go's answer
    too: `5^23` is bigger than any float64 mantissa, so the question is not one
    a caller here can usefully ask.
    """
    if p < 1 or p > 22:
        return False
    return (
        x * materialize[_DIV5_INV]()[p - 1] <= materialize[_DIV5_MAX]()[p - 1]
    )


struct _Trimmed(Copyable, Movable):
    """A number with its trailing zeros taken off, and how many there were."""

    var value: UInt64
    var zeros: Int

    def __init__(out self, value: UInt64, zeros: Int):
        self.value = value
        self.zeros = zeros


def _trim_zeros(x: UInt64) -> _Trimmed:
    """`x` divided by the largest power of ten that divides it exactly. Go's
    `trimZeros`.

    Eight zeros at a time, then four, then two, then one. Each step is the
    divisibility trick above with the shift folded into a rotation, so that the
    bits being dropped end up at the top where the comparison can see them.

    Zero is answered rather than divided. Every power of ten divides it, so
    Go's loop would run forever on it; Go never passes it one and neither does
    anything here, but a loop that cannot end is not worth leaving in.
    """
    if x == 0:
        return _Trimmed(0, 0)

    # The inverses of 10^8, 10^4, 10^2 and 10 modulo 2^64, which are the
    # inverses of 5^8, 5^4, 5^2 and 5 with the powers of two left to the shift.
    comptime INV8 = UInt64(0xC767074B22E90E21)
    comptime MAX8 = UInt64.MAX // 100000000
    comptime INV4 = UInt64(0xD288CE703AFB7E91)
    comptime MAX4 = UInt64.MAX // 10000
    comptime INV2 = UInt64(0x8F5C28F5C28F5C29)
    comptime MAX2 = UInt64.MAX // 100
    comptime INV1 = UInt64(0xCCCCCCCCCCCCCCCD)
    comptime MAX1 = UInt64.MAX // 10

    var v = x
    var p = 0
    while True:
        var d = _rotate_right(v * INV8, 8)
        if d > MAX8:
            break
        v = d
        p += 8
    var d4 = _rotate_right(v * INV4, 4)
    if d4 <= MAX4:
        v = d4
        p += 4
    var d2 = _rotate_right(v * INV2, 2)
    if d2 <= MAX2:
        v = d2
        p += 2
    var d1 = _rotate_right(v * INV1, 1)
    if d1 <= MAX1:
        v = d1
        p += 1
    return _Trimmed(v, p)
