"""The shortest decimal that reads back as the same float. Go's `ftoadbox.go`.

Dragonbox, by Junekey Jeon. Given a float it produces the fewest decimal digits
that no other float is closer to, which is what `format_float` with a precision
of minus one asks for. It cannot do a fixed number of digits, so that case goes
to `ftoafixed.mojo` instead.

The whole algorithm is one multiply by a power of ten from `tables.mojo` and a
handful of comparisons on the product. The comparisons are what decide between
the two candidate digit strings, and the paper is where the reasoning lives:

    https://github.com/jk-jeon/dragonbox/blob/d5dc40a/other_files/Dragonbox.pdf

Section numbers in the comments below refer to it. The float32 path is a second
copy of the float64 one rather than anything shared, which is how Go has it and
for the same reason: the two differ in the width of nearly every intermediate,
so sharing would mean widening the small one.

Nothing here is public.
"""

from core.strconv.decimal import _DIGITS_SHORT, _Digits, _format_base10
from core.strconv.math import (
    _hi64,
    _lo64,
    _mul_log10_2,
    _mul_log10_2_minus_log10_4_over_3,
    _pow10,
    _trim_zeros,
    _u128,
    _umul128,
    _umul192,
)


comptime _MANT_BITS_64 = 52
comptime _MANT_BITS_32 = 23


def _umul96_upper64(x: UInt32, y: UInt64) -> UInt64:
    """The top 64 bits of the 96-bit product. Go's `umul96Upper64`."""
    return _lo64((UInt128(x) * UInt128(y)) >> UInt128(32))


def _umul96_lower64(x: UInt32, y: UInt64) -> UInt64:
    """The bottom 64 bits of the 96-bit product. Go's `umul96Lower64`."""
    return UInt64(x) * y


def _umul192_upper128(x: UInt64, y: UInt128) -> UInt128:
    """The top 128 bits of the 192-bit product. Go's `umul192Upper128`."""
    var p = _umul192(x, y)
    return _u128(p.hi, p.mid)


def _umul192_lower128(x: UInt64, y: UInt128) -> UInt128:
    """The bottom 128 bits of the 192-bit product. Go's `umul192Lower128`.

    Which is what a 128-bit multiply that wraps already gives, so there is
    nothing to do but let it wrap.
    """
    return UInt128(x) * y


struct _MulPow64(Copyable, Movable):
    """A scaled value and whether the scaling was exact."""

    var int_part: UInt64
    var is_int: Bool

    def __init__(out self, int_part: UInt64, is_int: Bool):
        self.int_part = int_part
        self.is_int = is_int


def _dbox_mul_pow64(u: UInt64, phi: UInt128) -> _MulPow64:
    """`u` times the power of ten `phi`, and whether nothing was lost. Go's
    `dboxMulPow64`, which is section 5.2.1."""
    var r = _umul192_upper128(u, phi)
    return _MulPow64(_hi64(r), _lo64(r) == 0)


struct _MulPow32(Copyable, Movable):
    """A scaled value and whether the scaling was exact."""

    var int_part: UInt32
    var is_int: Bool

    def __init__(out self, int_part: UInt32, is_int: Bool):
        self.int_part = int_part
        self.is_int = is_int


def _dbox_mul_pow32(u: UInt32, phi: UInt64) -> _MulPow32:
    """`u` times the power of ten `phi`, and whether nothing was lost. Go's
    `dboxMulPow32`."""
    var r = _umul96_upper64(u, phi)
    var hi = UInt32((r >> UInt64(32)).cast[DType.uint32]())
    return _MulPow32(hi, UInt32(r.cast[DType.uint32]()) == 0)


struct _Parity(Copyable, Movable):
    """The bottom bit of a scaled value, and whether nothing was lost."""

    var parity: Bool
    var is_int: Bool

    def __init__(out self, parity: Bool, is_int: Bool):
        self.parity = parity
        self.is_int = is_int


def _dbox_parity64(mant2: UInt64, phi: UInt128, beta: Int) -> _Parity:
    """Go's `dboxParity64`. The bottom of the product is all the caller wants,
    so only the bottom is computed."""
    var r = _umul192_lower128(mant2, phi)
    var hi = _hi64(r)
    var lo = _lo64(r)
    var parity = ((hi >> UInt64(64 - beta)) & 1) != 0
    var is_int = ((hi << UInt64(beta)) | (lo >> UInt64(64 - beta))) == 0
    return _Parity(parity, is_int)


def _dbox_parity32(mant2: UInt32, phi: UInt64, beta: Int) -> _Parity:
    """Go's `dboxParity32`."""
    var r = _umul96_lower64(mant2, phi)
    var parity = ((r >> UInt64(64 - beta)) & 1) != 0
    var is_int = UInt32((r >> UInt64(32 - beta)).cast[DType.uint32]()) == 0
    return _Parity(parity, is_int)


def _dbox_delta64(phi: UInt128, beta: Int) -> UInt32:
    """The width of the rounding interval, scaled. Go's `dboxDelta64`."""
    return UInt32((_hi64(phi) >> UInt64(64 - 1 - beta)).cast[DType.uint32]())


def _dbox_delta32(phi: UInt64, beta: Int) -> UInt32:
    """The width of the rounding interval, scaled. Go's `dboxDelta32`."""
    return UInt32((phi >> UInt64(64 - 1 - beta)).cast[DType.uint32]())


struct _Range64(Copyable, Movable):
    """The two ends of the interval that rounds back to this float."""

    var left: UInt64
    var right: UInt64

    def __init__(out self, left: UInt64, right: UInt64):
        self.left = left
        self.right = right


def _dbox_range64(phi: UInt128, beta: Int) -> _Range64:
    """Go's `dboxRange64`."""
    var hi = _hi64(phi)
    var shift = UInt64(64 - _MANT_BITS_64 - 1 - beta)
    var left = (hi - (hi >> UInt64(_MANT_BITS_64 + 2))) >> shift
    var right = (hi + (hi >> UInt64(_MANT_BITS_64 + 1))) >> shift
    return _Range64(left, right)


struct _Range32(Copyable, Movable):
    """The two ends of the interval that rounds back to this float."""

    var left: UInt32
    var right: UInt32

    def __init__(out self, left: UInt32, right: UInt32):
        self.left = left
        self.right = right


def _dbox_range32(phi: UInt64, beta: Int) -> _Range32:
    """Go's `dboxRange32`."""
    var shift = UInt64(64 - _MANT_BITS_32 - 1 - beta)
    var left = (phi - (phi >> UInt64(_MANT_BITS_32 + 2))) >> shift
    var right = (phi + (phi >> UInt64(_MANT_BITS_32 + 1))) >> shift
    return _Range32(
        UInt32(left.cast[DType.uint32]()), UInt32(right.cast[DType.uint32]())
    )


def _dbox_round_up64(phi: UInt128, beta: Int) -> UInt64:
    """The midpoint above the value, scaled. Go's `dboxRoundUp64`."""
    return ((_hi64(phi) >> UInt64(64 - _MANT_BITS_64 - 2 - beta)) + 1) // 2


def _dbox_round_up32(phi: UInt64, beta: Int) -> UInt32:
    """The midpoint above the value, scaled. Go's `dboxRoundUp32`."""
    var v = (phi >> UInt64(64 - _MANT_BITS_32 - 2 - beta)) + 1
    return UInt32(v.cast[DType.uint32]()) // 2


struct _Pow64(Copyable, Movable):
    """A power of ten and the shift that goes with it."""

    var phi: UInt128
    var beta: Int

    def __init__(out self, phi: UInt128, beta: Int):
        self.phi = phi
        self.beta = beta


def _dbox_pow64(k: Int, e: Int) -> _Pow64:
    """The table entry for `10^k`, rounded the way this algorithm wants. Go's
    `dboxPow64`.

    Go increments only the low half of the 128 bits, which cannot carry. No
    entry in the table has a low half of all ones, so incrementing the whole
    value is the same operation; `math.mojo` says where that would stop being
    true.
    """
    var p = _pow10(k)
    var phi = p.mant
    if k < 0 or k > 55:
        phi += 1
    return _Pow64(phi, e + p.exp - 1)


struct _Pow32(Copyable, Movable):
    """A power of ten and the shift that goes with it."""

    var phi: UInt64
    var beta: Int

    def __init__(out self, phi: UInt64, beta: Int):
        self.phi = phi
        self.beta = beta


def _dbox_pow32(k: Int, e: Int) -> _Pow32:
    """The table entry for `10^k`, rounded the way this algorithm wants. Go's
    `dboxPow32`, which keeps only the high half because 64 bits are enough for
    a float32."""
    var p = _pow10(k)
    var hi = _hi64(p.mant)
    if k < 0 or k > 27:
        hi += 1
    return _Pow32(hi, e + p.exp - 1)


def _dbox_digits(mut d: _Digits, mant: UInt64, exp: Int):
    """Write the digits of `mant` into `d` with the point placed by `exp`. Go's
    `dboxDigits`.

    The digits are produced backwards from the end of the buffer and then moved
    to the front, because Go reslices its buffer and an `InlineArray` has no
    front to move.
    """
    var i = _format_base10(d.d, _DIGITS_SHORT, mant)
    d.nd = _DIGITS_SHORT - i
    for k in range(d.nd):
        d.d[k] = d.d[i + k]
    d.dp = d.nd + exp


def _dbox_ftoa64(mut d: _Digits, mant: UInt64, exp: Int, denorm: Bool):
    """The shortest digits of `mant * 2^exp` as a float64. Go's `dboxFtoa64`."""
    if mant == (UInt64(1) << UInt64(_MANT_BITS_64)) and not denorm:
        # A power of two, where the interval is lopsided. Algorithm 5.6.
        var k0 = -_mul_log10_2_minus_log10_4_over_3(exp)
        var p = _dbox_pow64(k0, exp)
        var rng = _dbox_range64(p.phi, p.beta)
        var xi = rng.left
        if exp != 2 and exp != 3:
            xi += 1
        var q = rng.right // 10
        if xi <= q * 10:
            var t = _trim_zeros(q)
            _dbox_digits(d, t.value, -k0 + 1 + t.zeros)
            return
        var yru = _dbox_round_up64(p.phi, p.beta)
        if exp == -77 and yru % 2 != 0:
            yru -= 1
        elif yru < xi:
            yru += 1
        _dbox_digits(d, yru, -k0)
        return

    # κ = 2 for float64, section 5.1.3.
    comptime KAPPA = 2
    comptime P10K = UInt32(100)
    comptime P10K1 = UInt64(1000)

    # Algorithm 5.2.
    var k0 = -_mul_log10_2(exp)
    var p = _dbox_pow64(KAPPA + k0, exp)
    var z = _dbox_mul_pow64((mant * 2 + 1) << UInt64(p.beta), p.phi)
    var s = z.int_part // P10K1
    var r = UInt32((z.int_part % P10K1).cast[DType.uint32]())
    var delta = _dbox_delta64(p.phi, p.beta)

    if r < delta:
        if r != 0 or not z.is_int or mant % 2 == 0:
            var t = _trim_zeros(s)
            _dbox_digits(d, t.value, -k0 + 1 + t.zeros)
            return
        s -= 1
        r = UInt32(1000)
    elif r == delta:
        var par = _dbox_parity64(mant * 2 - 1, p.phi, p.beta)
        if par.parity or (par.is_int and mant % 2 == 0):
            var t = _trim_zeros(s)
            _dbox_digits(d, t.value, -k0 + 1 + t.zeros)
            return

    # Algorithm 5.4.
    var big_d = r + P10K // 2 - delta // 2
    var t = big_d // P10K
    var rho = big_d % P10K
    var yru = 10 * s + UInt64(t)
    if rho == 0:
        var par = _dbox_parity64(mant * 2, p.phi, p.beta)
        if par.parity != ((big_d - P10K // 2) % 2 != 0) or (
            par.is_int and yru % 2 != 0
        ):
            yru -= 1
    _dbox_digits(d, yru, -k0)


def _dbox_ftoa32(mut d: _Digits, mant32: UInt32, exp: Int, denorm: Bool):
    """The shortest digits of `mant32 * 2^exp` as a float32. Go's `dboxFtoa32`.

    A second copy of the function above with every intermediate narrowed, which
    is how Go keeps the float32 path from paying for float64 arithmetic.
    """
    if mant32 == (UInt32(1) << UInt32(_MANT_BITS_32)) and not denorm:
        # Algorithm 5.6.
        var k0 = -_mul_log10_2_minus_log10_4_over_3(exp)
        var p = _dbox_pow32(k0, exp)
        var rng = _dbox_range32(p.phi, p.beta)
        var xi = rng.left
        if exp != 2 and exp != 3:
            xi += 1
        var q = rng.right // 10
        if xi <= q * 10:
            var t = _trim_zeros(UInt64(q))
            _dbox_digits(d, t.value, -k0 + 1 + t.zeros)
            return
        var yru = _dbox_round_up32(p.phi, p.beta)
        if exp == -77 and yru % 2 != 0:
            yru -= 1
        elif yru < xi:
            yru += 1
        _dbox_digits(d, UInt64(yru), -k0)
        return

    # κ = 1 for float32, section 5.1.3.
    comptime KAPPA = 1
    comptime P10K = UInt32(10)
    comptime P10K1 = UInt32(100)

    # Algorithm 5.2.
    var k0 = -_mul_log10_2(exp)
    var p = _dbox_pow32(KAPPA + k0, exp)
    var z = _dbox_mul_pow32((mant32 * 2 + 1) << UInt32(p.beta), p.phi)
    var s = z.int_part // P10K1
    var r = z.int_part % P10K1
    var delta = _dbox_delta32(p.phi, p.beta)

    if r < delta:
        if r != 0 or not z.is_int or mant32 % 2 == 0:
            var t = _trim_zeros(UInt64(s))
            _dbox_digits(d, t.value, -k0 + 1 + t.zeros)
            return
        s -= 1
        r = UInt32(100)
    elif r == delta:
        var par = _dbox_parity32(mant32 * 2 - 1, p.phi, p.beta)
        if par.parity or (par.is_int and mant32 % 2 == 0):
            var t = _trim_zeros(UInt64(s))
            _dbox_digits(d, t.value, -k0 + 1 + t.zeros)
            return

    # Algorithm 5.4.
    var big_d = r + P10K // 2 - delta // 2
    var t = big_d // P10K
    var rho = big_d % P10K
    var yru = 10 * s + t
    if rho == 0:
        var par = _dbox_parity32(mant32 * 2, p.phi, p.beta)
        if par.parity != ((big_d - P10K // 2) % 2 != 0) or (
            par.is_int and yru % 2 != 0
        ):
            yru -= 1
    _dbox_digits(d, UInt64(yru), -k0)


def _dbox_ftoa(
    mut d: _Digits, mant: UInt64, exp: Int, denorm: Bool, bit_size: Int
):
    """The shortest digits of `mant * 2^exp`. Go's `dboxFtoa`."""
    if bit_size == 32:
        _dbox_ftoa32(d, UInt32(mant.cast[DType.uint32]()), exp, denorm)
    else:
        _dbox_ftoa64(d, mant, exp, denorm)
