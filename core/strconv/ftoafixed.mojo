"""A fixed number of decimal digits. Go's `ftoafixed.go`.

Dragonbox answers "the shortest digits that read back", which is a different
question from "the first eighteen digits". This answers the second one, by
multiplying the float by whichever power of ten puts the digits asked for on
the integer side of the point and then reading the integer off.

Adams proved in the Ryū paper that 128 bits of the power of ten are enough to
round every float64 correctly at up to eighteen digits, which is why the table
in `tables.mojo` is the width it is and why eighteen is the ceiling here.
Anything wider goes to the `_Decimal` path in `ftoa.mojo`.

    https://dl.acm.org/doi/10.1145/3192366.3192369

Nothing here is public.
"""

from std.bit import bit_width

from core.errors import Report
from core.strconv.decimal import _Digits, _format_base10
from core.strconv.math import _divisible_pow5, _mul_log10_2, _pow10, _umul192


comptime _UINT64_POW10: Array[UInt64, 20] = [
    1,
    10,
    100,
    1000,
    10000,
    100000,
    1000000,
    10000000,
    100000000,
    1000000000,
    10000000000,
    100000000000,
    1000000000000,
    10000000000000,
    100000000000000,
    1000000000000000,
    10000000000000000,
    100000000000000000,
    1000000000000000000,
    10000000000000000000,
]
"""Every power of ten a `UInt64` holds. Go's `uint64pow10`."""


def _fixed_ftoa(
    mut d: _Digits,
    mant_in: UInt64,
    exp_in: Int,
    digits_in: Int,
    prec: Int,
    fmt: UInt8,
) raises:
    """`digits` decimal digits of `mant * 2^exp` into `d`. Go's `fixedFtoa`.

    `mant` has to be above zero and `digits` between one and eighteen. For
    `fmt` of `f` the count is an overestimate the caller could not pin down
    before knowing where the point lands, and it is cut back to `prec` places
    past the point here.

    Go panics on a count above eighteen and on a power of ten outside the
    table. Neither is reachable from `format_float`, which is why they are
    raises rather than checks the callers have to thread a result through.
    """
    if digits_in > 18:
        raise Report("strconv: fixed_ftoa called with digits > 18").error()

    var mant = mant_in
    var exp = exp_in
    var digits = digits_in

    # Line the mantissa up with the top of the word, so that the 192-bit
    # product below has at least 63 bits in its top word.
    var b = 64 - Int(bit_width(mant))
    mant <<= UInt64(b)
    exp -= b

    # The value is at least 2^(63+exp), and it wants multiplying by the 10^p
    # that leaves it with the digits asked for plus one bit to round on:
    #
    #     2 * 10^(digits-1) <= f * 10^p < about 2 * 10^digits
    #
    # Taking logs of the lower bound and expanding f gives the p below. The
    # upper bound is approximate on purpose: too few digits cannot be fixed
    # afterwards, too many can be rounded away.
    var p = (digits - 1) - _mul_log10_2(63 + exp)
    var pw = _pow10(p)
    if not pw.ok:
        raise Report("strconv: fixed_ftoa: pow10 out of range").error()

    var pow = pw.mant
    if -22 <= p and p < 0:
        # Dividing by 10^q for q in 1 through 22, where the mantissa may be a
        # multiple of 5^q and the division has to come out exact for the
        # rounding below to be right. Rounding the constant up instead of down
        # makes the floor and the ceiling cancel over this range, which is the
        # same trick a compiler uses for division by a constant. Hacker's
        # Delight, second edition, chapter 10.
        #
        # Go increments only the low half. The whole value is incremented here
        # for the reason `ftoadbox.mojo` gives.
        pow += 1

    var product = _umul192(mant, pow)
    var v = product.hi
    var de = exp + pw.exp

    # Whether anything was dropped on the way to the top word. Read in this
    # order, because the last case is only reached when the first two do not.
    var dt: UInt64
    if 0 <= p and p <= 55:
        # Up to 10^55 the constant is exact, because 5^55 fits in 128 bits, so
        # the only loss is the bottom of the 192-bit product.
        dt = UInt64(1) if ((product.mid | product.lo) != 0) else UInt64(0)
    elif -22 <= p and p < 0 and _divisible_pow5(mant, -p):
        # The division came out exact, per the comment above.
        dt = UInt64(0)
    else:
        # Every other power of ten uses a truncated constant, so the result is
        # truncated too.
        dt = UInt64(1)

    # The value is `v * 2^de` with `de` below zero, so the multiply by `2^de`
    # is a shift. One bit is left behind to round on: after the shift the whole
    # part is `v >> 1`, the rounding bit is `v & 1`, and `dt` says whether
    # anything fell off below that.
    var shift = UInt64(-de - 1)
    if (v & ((UInt64(1) << shift) - 1)) != 0:
        dt = UInt64(1)
    v >>= shift

    # Where the point lands, kept up to date as digits come off below.
    d.dp = digits - p

    # One digit too many is possible, because the bound above was approximate.
    var limit = materialize[_UINT64_POW10]()[digits] << 1
    if v >= limit:
        var q = v // 10
        if v - q * 10 != 0:
            dt = UInt64(1)
        v = q
        d.dp += 1

    # For `f` the count was an overestimate. Now that the point is placed, cut
    # back to the digits actually wanted, which is `dp + prec`.
    if fmt == UInt8(ord("f")) and digits != d.dp + prec:
        while digits > d.dp + prec:
            var q = v // 10
            if v - q * 10 != 0:
                dt = UInt64(1)
            v = q
            digits -= 1

        # Dropping those can uncover a new leading digit, which is how `%.1f`
        # turns 0.09 into 0.1.
        if digits <= 0:
            digits = 1
            d.dp += 1

        limit = materialize[_UINT64_POW10]()[digits] << 1

    # Round, then drop the rounding bit. Up when the fraction is above a half,
    # and when it is exactly a half and the whole part is odd.
    v += v & (dt | (v >> 1)) & 1
    v >>= 1
    if v == limit >> 1:
        # All nines rolled over into a one and some zeros.
        v = materialize[_UINT64_POW10]()[digits - 1]
        d.dp += 1

    if v != 0:
        if _format_base10(d.d, digits, v) != 0:
            raise Report("strconv: fixed_ftoa: digits do not fit").error()
        d.nd = digits
        while d.d[d.nd - 1] == UInt8(ord("0")):
            d.nd -= 1
