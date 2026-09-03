"""Floats to text. Go's `ftoa.go`.

`format_float` and `append_float`, and the three ways of getting digits that
sit under them. Which one runs depends on what was asked for:

- A precision of minus one means the shortest text that reads back as the same
  float, which is Dragonbox in `ftoadbox.mojo`.
- A fixed precision of eighteen digits or fewer is `ftoafixed.mojo`.
- Anything wider falls back to `_Decimal` in `decimal.mojo`, which is slow and
  exact and has no ceiling.

The printers at the bottom are shared by all three. They take the digits as a
span rather than as one of the two buffer types, because the fast formatters
fill 32 bytes and the slow one fills 800.

Go panics on a bit size that is not 32 or 64. This raises, for the reason
`format_int` raises on a bad base: it is a caller's bug, and a caller is the
only one who can decide what to do about it. An unknown format character is not
an error in Go and is not one here either; it comes back as a percent sign and
the character, which is what a caller sees from `fmt` today.
"""

from std.memory import bitcast

from core.errors import Report
from core.strconv.atof import _FloatInfo, _float32_info, _float64_info
from core.strconv.atoi import _lower
from core.strconv.decimal import _Decimal, _Digits
from core.strconv.ftoadbox import _dbox_ftoa
from core.strconv.ftoafixed import _fixed_ftoa
from core.strconv.itoa import append_int, append_uint
from core.strconv.math import _mul_log10_2


comptime _LOWER_HEX = "0123456789abcdef"
comptime _UPPER_HEX = "0123456789ABCDEF"

comptime _ZERO = UInt8(ord("0"))
comptime _NINE = UInt8(ord("9"))
comptime _MINUS = UInt8(ord("-"))
comptime _PLUS = UInt8(ord("+"))
comptime _DOT = UInt8(ord("."))


def format_float(
    f: Float64, fmt: UInt8, prec: Int, bit_size: Int
) raises -> String:
    """`f` written out, rounded as if it had come from a float of `bit_size`
    bits. Go's `FormatFloat`.

    `fmt` is one of

    - `b`, as `-ddddp+ddd`, a binary exponent,
    - `e` or `E`, as `-d.dddde+dd`, a decimal exponent,
    - `f`, as `-ddd.dddd`, with no exponent,
    - `g` or `G`, which is `e` for large exponents and `f` otherwise,
    - `x` or `X`, as `-0xd.ddddp+ddd`, a hexadecimal fraction and a binary
      exponent.

    `prec` is how many digits to print, not counting the exponent. For `e`,
    `E`, `f`, `x` and `X` it is the digits after the point; for `g` and `G` it
    is the significant digits, with trailing zeros dropped. A `prec` of minus
    one asks for the fewest digits that `parse_float` will read back as `f`
    exactly.

    ```mojo
    from core.strconv import format_float

    def main():
        print(format_float(3.1415, UInt8(ord("f")), 2, 64))  # 3.14
        print(format_float(0.1 + 0.2, UInt8(ord("g")), -1, 64))
        # 0.30000000000000004
    ```
    """
    var buf = List[UInt8]()
    _generic_ftoa(buf, f, fmt, prec, bit_size)
    return String(from_utf8_lossy=Span(buf))


def append_float(
    mut dst: List[UInt8], f: Float64, fmt: UInt8, prec: Int, bit_size: Int
) raises -> Int:
    """`format_float(f, fmt, prec, bit_size)` onto the end of `dst`, and how
    many bytes that took. Go's `AppendFloat`, which hands back the grown slice
    instead.

    The count rather than the list, for the reason `append_int` gives.
    """
    var before = len(dst)
    _generic_ftoa(dst, f, fmt, prec, bit_size)
    return len(dst) - before


def _generic_ftoa(
    mut dst: List[UInt8], val: Float64, fmt: UInt8, prec_in: Int, bit_size: Int
) raises:
    """Take the float apart and hand the pieces to whichever formatter fits.
    Go's `genericFtoa`."""
    if bit_size != 32 and bit_size != 64:
        raise Report(
            "strconv: illegal append_float/format_float bit size "
            + String(bit_size)
        ).error()

    var thirty_two = bit_size == 32
    var flt = _float32_info() if thirty_two else _float64_info()
    var bits = UInt64(
        bitcast[DType.uint32](Float32(val))
    ) if thirty_two else bitcast[DType.uint64](val)

    var neg = (bits >> UInt64(flt.exp_bits + flt.mant_bits)) != 0
    var exp = Int(
        (bits >> UInt64(flt.mant_bits))
        & ((UInt64(1) << UInt64(flt.exp_bits)) - 1)
    )
    var mant = bits & ((UInt64(1) << UInt64(flt.mant_bits)) - 1)
    var denorm = False

    if exp == (1 << flt.exp_bits) - 1:
        # Infinity or not a number, which have no digits to produce.
        if mant != 0:
            dst.extend("NaN".as_bytes())
        elif neg:
            dst.extend("-Inf".as_bytes())
        else:
            dst.extend("+Inf".as_bytes())
        return
    elif exp == 0:
        # Subnormal, which has no implicit top bit and a fixed exponent.
        exp += 1
        denorm = True
    else:
        mant |= UInt64(1) << UInt64(flt.mant_bits)
    exp += flt.bias

    # The two formats that are read straight off the bits.
    if fmt == UInt8(ord("b")):
        _fmt_b(dst, neg, mant, exp, flt)
        return
    if fmt == UInt8(ord("x")) or fmt == UInt8(ord("X")):
        _fmt_x(dst, prec_in, fmt, neg, mant, exp, flt)
        return

    var prec = prec_in
    var shortest = prec < 0
    var digs = _Digits()
    if mant == 0:
        _format_digits(dst, shortest, neg, Span(digs.d), 0, 0, prec, fmt)
        return

    if shortest:
        _dbox_ftoa(digs, mant, exp - flt.mant_bits, denorm, bit_size)
        # How many digits that turned out to be is the precision from here on.
        if fmt == UInt8(ord("e")) or fmt == UInt8(ord("E")):
            prec = max(digs.nd - 1, 0)
        elif fmt == UInt8(ord("f")):
            prec = max(digs.nd - digs.dp, 0)
        elif fmt == UInt8(ord("g")) or fmt == UInt8(ord("G")):
            prec = digs.nd
        _format_digits(
            dst, shortest, neg, Span(digs.d), digs.nd, digs.dp, prec, fmt
        )
        return

    # A fixed number of digits.
    var digits = prec
    if fmt == UInt8(ord("f")):
        # `prec` counts digits after the point, so the total is that plus the
        # digits before it. Only an upper bound is available here, and
        # `_fixed_ftoa` cuts back once it knows where the point lands.
        if exp >= 0:
            digits = 1 + _mul_log10_2(1 + exp) + prec
        else:
            digits = 1 + prec - _mul_log10_2(-exp)
    elif fmt == UInt8(ord("e")) or fmt == UInt8(ord("E")):
        digits += 1
    elif fmt == UInt8(ord("g")) or fmt == UInt8(ord("G")):
        if prec == 0:
            prec = 1
        digits = prec
    else:
        # Not a format this knows, so the digits are never looked at.
        digits = 1

    if digits <= 18:
        # A count of zero or less happens for `f` on a very small number and
        # means every digit printed is a zero.
        if digits > 0:
            _fixed_ftoa(digs, mant, exp - flt.mant_bits, digits, prec, fmt)
        _format_digits(
            dst, False, neg, Span(digs.d), digs.nd, digs.dp, prec, fmt
        )
        return

    _big_ftoa(dst, prec, fmt, neg, mant, exp, flt)


def _big_ftoa(
    mut dst: List[UInt8],
    prec_in: Int,
    fmt: UInt8,
    neg: Bool,
    mant: UInt64,
    exp: Int,
    flt: _FloatInfo,
) raises:
    """The exact decimal expansion, rounded to what was asked for. Go's
    `bigFtoa`.

    Slow and unbounded, which is the point: it is what is left when neither
    fast path will answer.
    """
    var d = _Decimal()
    d.assign(mant)
    d.shift(exp - flt.mant_bits)

    var prec = prec_in
    var shortest = prec < 0
    if shortest:
        _round_shortest(d, mant, exp, flt)
        if fmt == UInt8(ord("e")) or fmt == UInt8(ord("E")):
            prec = d.nd - 1
        elif fmt == UInt8(ord("f")):
            prec = max(d.nd - d.dp, 0)
        elif fmt == UInt8(ord("g")) or fmt == UInt8(ord("G")):
            prec = d.nd
    else:
        if fmt == UInt8(ord("e")) or fmt == UInt8(ord("E")):
            d.round(prec + 1)
        elif fmt == UInt8(ord("f")):
            d.round(d.dp + prec)
        elif fmt == UInt8(ord("g")) or fmt == UInt8(ord("G")):
            if prec == 0:
                prec = 1
            d.round(prec)

    _format_digits(dst, shortest, neg, Span(d.d), d.nd, d.dp, prec, fmt)


def _format_digits[
    o: Origin
](
    mut dst: List[UInt8],
    shortest: Bool,
    neg: Bool,
    d: Span[UInt8, o],
    nd: Int,
    dp: Int,
    prec_in: Int,
    fmt: UInt8,
):
    """Hand the digits to the printer for `fmt`. Go's `formatDigits`."""
    if fmt == UInt8(ord("e")) or fmt == UInt8(ord("E")):
        _fmt_e(dst, neg, d, nd, dp, prec_in, fmt)
        return
    if fmt == UInt8(ord("f")):
        _fmt_f(dst, neg, d, nd, dp, prec_in)
        return
    if fmt == UInt8(ord("g")) or fmt == UInt8(ord("G")):
        var prec = prec_in
        # Trailing zeros in the fraction are trimmed in the `e` form.
        var eprec = prec
        if eprec > nd and nd >= dp:
            eprec = nd
        # The `e` form is used when the exponent is below -4 or at least the
        # precision. A shortest conversion has no precision to compare with, so
        # it uses six, which is what an unadorned `%g` in Go prints.
        if shortest:
            eprec = 6
        var exp = dp - 1
        if exp < -4 or exp >= eprec:
            if prec > nd:
                prec = nd
            _fmt_e(
                dst,
                neg,
                d,
                nd,
                dp,
                prec - 1,
                fmt + UInt8(ord("e")) - UInt8(ord("g")),
            )
            return
        if prec > dp:
            prec = nd
        _fmt_f(dst, neg, d, nd, dp, max(prec - dp, 0))
        return

    dst.append(UInt8(ord("%")))
    dst.append(fmt)


def _round_shortest(mut d: _Decimal, mant: UInt64, exp: Int, flt: _FloatInfo):
    """Cut `d` down to the fewest digits that still read back as this float.
    Go's `roundShortest`.

    The idea is to walk the digits of the value alongside the digits of the two
    midpoints on either side of it, and stop at the first place where the value
    can be told apart from both.
    """
    if mant == 0:
        d.nd = 0
        return

    # A quick way out. If the value is not subnormal then it is at least
    # `2^exp` and below `10^dp`, so the nearest shorter number is at least
    # `10^(dp-nd)` away, while the midpoints below are at most
    # `2^(exp-mantbits)` away. So it is already shortest when
    # `log2(10)*(dp-nd) > exp-mantbits`, and 332/100 is under `log2(10)`.
    var minexp = flt.bias + 1
    if exp > minexp and 332 * (d.dp - d.nd) >= 100 * (exp - flt.mant_bits):
        return

    # The value is `mant << (exp-mantbits)` and the next float up is
    # `mant+1 << (exp-mantbits)`, so the midpoint between them is
    # `mant*2+1 << (exp-mantbits-1)`.
    var upper = _Decimal()
    upper.assign(mant * 2 + 1)
    upper.shift(exp - flt.mant_bits - 1)

    # The next float down is `mant-1 << (exp-mantbits)`, unless taking one away
    # drops the top bit and the exponent is not already the smallest, in which
    # case it is `mant*2-1 << (exp-mantbits-1)`.
    var top_bit_stays = mant > (UInt64(1) << UInt64(flt.mant_bits))
    var mantlo = mant - 1 if (top_bit_stays or exp == minexp) else mant * 2 - 1
    var explo = exp if (top_bit_stays or exp == minexp) else exp - 1
    var lower = _Decimal()
    lower.assign(mantlo * 2 + 1)
    lower.shift(explo - flt.mant_bits - 1)

    # A midpoint is itself a possible answer only when the mantissa is even,
    # because that is when rounding to even lands back on this float.
    var inclusive = mant % 2 == 0

    # How far ahead of `upper` the value has fallen, as rounding up walks. Zero
    # means the digits match so far. One means they differed by one somewhere
    # earlier and have been nines against zeros since, so rounding up may leave
    # the interval when it is exclusive. Two means the gap is wider than one
    # and rounding up is certainly inside.
    var upperdelta = 0

    # Walk until the value is distinguished from both bounds. The three have
    # their points in different places, so the walk is indexed by `upper`,
    # which is the longest, and the other two start at possibly -1.
    var ui = 0
    while True:
        var mi = ui - upper.dp + d.dp
        if mi >= d.nd:
            break
        var li = ui - upper.dp + lower.dp
        var l = _ZERO
        if li >= 0 and li < lower.nd:
            l = lower.d[li]
        var m = _ZERO
        if mi >= 0:
            m = d.d[mi]
        var u = _ZERO
        if ui < upper.nd:
            u = upper.d[ui]

        # Rounding down is fine when `lower` has a different digit here, or
        # when `lower` is inclusive and this is its last digit, which makes
        # rounding down land exactly on it.
        var okdown = l != m or (inclusive and li + 1 == lower.nd)

        if upperdelta == 0 and m + 1 < u:
            upperdelta = 2
        elif upperdelta == 0 and m != u:
            upperdelta = 1
        elif upperdelta == 1 and (m != _NINE or u != _ZERO):
            upperdelta = 2

        # Rounding up is fine when `upper` has a different digit and either it
        # is inclusive, or the gap is wide, or `upper` has more digits to come.
        var okup = upperdelta > 0 and (
            inclusive or upperdelta > 1 or ui + 1 < upper.nd
        )

        if okdown and okup:
            d.round(mi + 1)
            return
        elif okdown:
            d.round_down(mi + 1)
            return
        elif okup:
            d.round_up(mi + 1)
            return
        ui += 1


def _fmt_e[
    o: Origin
](
    mut dst: List[UInt8],
    neg: Bool,
    d: Span[UInt8, o],
    nd: Int,
    dp: Int,
    prec: Int,
    fmt: UInt8,
):
    """`-d.ddddde+dd`. Go's `fmtE`."""
    if neg:
        dst.append(_MINUS)

    var ch = _ZERO
    if nd != 0:
        ch = d[0]
    dst.append(ch)

    if prec > 0:
        dst.append(_DOT)
        var i = 1
        var m = min(nd, prec + 1)
        while i < m:
            dst.append(d[i])
            i += 1
        while i <= prec:
            dst.append(_ZERO)
            i += 1

    dst.append(fmt)
    var exp = dp - 1
    if nd == 0:
        # Zero has an exponent of zero rather than of one less than its point.
        exp = 0
    if exp < 0:
        dst.append(_MINUS)
        exp = -exp
    else:
        dst.append(_PLUS)

    # Two digits of exponent, or three when it does not fit in two.
    if exp < 10:
        dst.append(_ZERO)
        dst.append(UInt8(exp) + _ZERO)
    elif exp < 100:
        dst.append(UInt8(exp // 10) + _ZERO)
        dst.append(UInt8(exp % 10) + _ZERO)
    else:
        dst.append(UInt8(exp // 100) + _ZERO)
        dst.append(UInt8((exp // 10) % 10) + _ZERO)
        dst.append(UInt8(exp % 10) + _ZERO)


def _fmt_f[
    o: Origin
](
    mut dst: List[UInt8],
    neg: Bool,
    d: Span[UInt8, o],
    nd: Int,
    dp: Int,
    prec: Int,
):
    """`-ddddddd.ddddd`. Go's `fmtF`."""
    if neg:
        dst.append(_MINUS)

    # The whole part, padded with zeros when the point is past the digits.
    if dp > 0:
        var m = min(nd, dp)
        for i in range(m):
            dst.append(d[i])
        for _ in range(m, dp):
            dst.append(_ZERO)
    else:
        dst.append(_ZERO)

    if prec > 0:
        dst.append(_DOT)
        for i in range(prec):
            var ch = _ZERO
            var j = dp + i
            if 0 <= j and j < nd:
                ch = d[j]
            dst.append(ch)


def _fmt_b(
    mut dst: List[UInt8], neg: Bool, mant: UInt64, exp: Int, flt: _FloatInfo
) raises:
    """`-ddddddddp+ddd`, the mantissa and the binary exponent as they are. Go's
    `fmtB`."""
    if neg:
        dst.append(_MINUS)
    _ = append_uint(dst, mant, 10)
    dst.append(UInt8(ord("p")))
    var e = exp - flt.mant_bits
    if e >= 0:
        dst.append(_PLUS)
    _ = append_int(dst, Int64(e), 10)


def _fmt_x(
    mut dst: List[UInt8],
    prec: Int,
    fmt: UInt8,
    neg: Bool,
    mant_in: UInt64,
    exp_in: Int,
    flt: _FloatInfo,
):
    """`-0x1.yyyyyyyyp+ddd`, or `-0x0p+0` for zero. Go's `fmtX`."""
    var mant = mant_in
    var exp = exp_in
    if mant == 0:
        exp = 0

    # Move the leading one, if there is one, to bit 60.
    mant <<= UInt64(60 - flt.mant_bits)
    while mant != 0 and (mant & (UInt64(1) << UInt64(60))) == 0:
        mant <<= 1
        exp -= 1

    if prec >= 0 and prec < 15:
        var shift = UInt64(prec * 4)
        var extra = (mant << shift) & ((UInt64(1) << UInt64(60)) - 1)
        mant >>= UInt64(60) - shift
        if (extra | (mant & 1)) > (UInt64(1) << UInt64(59)):
            mant += 1
        mant <<= UInt64(60) - shift
        if (mant & (UInt64(1) << UInt64(61))) != 0:
            # Rounding carried past the leading digit.
            mant >>= 1
            exp += 1

    var upper = fmt == UInt8(ord("X"))
    var hex = _UPPER_HEX.as_bytes() if upper else _LOWER_HEX.as_bytes()

    if neg:
        dst.append(_MINUS)
    dst.append(_ZERO)
    dst.append(fmt)
    dst.append(_ZERO + UInt8(((mant >> UInt64(60)) & 1).cast[DType.uint8]()))

    # The fraction, after dropping the leading digit.
    mant <<= 4
    if prec < 0 and mant != 0:
        dst.append(_DOT)
        while mant != 0:
            dst.append(hex[Int((mant >> UInt64(60)) & 15)])
            mant <<= 4
    elif prec > 0:
        dst.append(_DOT)
        for _ in range(prec):
            dst.append(hex[Int((mant >> UInt64(60)) & 15)])
            mant <<= 4

    if fmt == _lower(fmt):
        dst.append(UInt8(ord("p")))
    else:
        dst.append(UInt8(ord("P")))
    if exp < 0:
        dst.append(_MINUS)
        exp = -exp
    else:
        dst.append(_PLUS)

    # Two, three or four digits of exponent.
    if exp < 100:
        dst.append(UInt8(exp // 10) + _ZERO)
        dst.append(UInt8(exp % 10) + _ZERO)
    elif exp < 1000:
        dst.append(UInt8(exp // 100) + _ZERO)
        dst.append(UInt8((exp // 10) % 10) + _ZERO)
        dst.append(UInt8(exp % 10) + _ZERO)
    else:
        dst.append(UInt8(exp // 1000) + _ZERO)
        dst.append(UInt8((exp // 100) % 10) + _ZERO)
        dst.append(UInt8((exp // 10) % 10) + _ZERO)
        dst.append(UInt8(exp % 10) + _ZERO)
