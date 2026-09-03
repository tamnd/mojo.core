"""Multiplication of natural numbers. Go's `natmul.go`.

Three algorithms, picked by size. A one digit multiplier is a single pass with
a carry. Anything else short is grade school multiplication, one pass over the
whole of one operand for each digit of the other. Above forty digits it is
Karatsuba, which splits both operands in half and buys the fourth of the four
half sized products with an addition instead.

Go's Karatsuba writes its three sub-products straight into the answer and
repurposes the low half of the answer as scratch for the two differences it
needs, so it allocates one temporary per level and nothing else. That relies on
handing overlapping slices of one vector to the same call, which Mojo refuses,
so the version here computes each sub-product as its own value and adds the
three into place. It allocates more per level and it is the same algorithm with
the same asymptotic behaviour, and the threshold below is Go's, which is worth
remeasuring here rather than trusting.
"""

from .arith import (
    _add_mul_vvww_into,
    _add_to,
    _add_vv_into,
    _lsh_vu_into,
    _mul_add_vww,
    _mul_ww,
    Word,
)
from .nat import _add, _cmp, _norm, _norm_len, _set_word, _sub, _zero

comptime _KARATSUBA_THRESHOLD = 40
"""Digits below which grade school multiplication wins. Go's
`karatsubaThreshold`, which Go arrives at with `calibrate_test.go`."""

comptime _BASIC_SQR_THRESHOLD = 12
"""Digits below which squaring is not worth its own loop. Go's
`basicSqrThreshold`."""


def _mul_add_ww[o: ImmOrigin](x: Span[Word, o], y: Word, r: Word) -> List[Word]:
    """`x * y + r` for a single digit `y` and `r`. Go's `nat.mulAddWW`."""
    var m = len(x)
    if m == 0 or y == 0:
        return _set_word(r)

    var z = List[Word](length=m + 1, fill=0)
    z[m] = _mul_add_vww(Span(z)[0:m], x, y, r)

    return _norm(z^)


def _basic_mul[
    o1: ImmOrigin, o2: ImmOrigin
](mut z: List[Word], x: Span[Word, o1], y: Span[Word, o2]):
    """Grade school multiplication into an already zeroed `z`. Go's `basicMul`.

    `z` has to be at least `len(x) + len(y)` long. The result is left
    unnormalised, because every caller normalises once at the end.
    """
    var n = len(x)
    for i in range(len(y)):
        var d = y[i]
        if d != 0:
            z[n + i] = _add_mul_vvww_into(Span(z)[i : i + n], x, d, 0)


def _mul[
    o1: ImmOrigin, o2: ImmOrigin
](x: Span[Word, o1], y: Span[Word, o2]) -> List[Word]:
    """`x * y`. Go's `nat.mul`."""
    var m = len(x)
    var n = len(y)

    if m < n:
        return _mul(y, x)
    if m == 0 or n == 0:
        return _zero()
    if n == 1:
        return _mul_add_ww(x, y[0], 0)

    var z = List[Word](length=m + n, fill=0)

    if n < _KARATSUBA_THRESHOLD:
        _basic_mul(z, x, y)
        return _norm(z^)

    # x is longer than y, so cut it into sections as long as y and multiply
    # each of them by y in turn. The first section starts the answer off and
    # the rest are added in at their own offsets.
    var head = _karatsuba(x[0:n], y)
    for i in range(len(head)):
        z[i] = head[i]

    var i = n
    while i < m:
        var hi = i + n
        if hi > m:
            hi = m
        var t = _mul(x[i:hi], y)
        _add_to(Span(z)[i:], Span(t))
        i += n

    return _norm(z^)


def _karatsuba[
    o1: ImmOrigin, o2: ImmOrigin
](x: Span[Word, o1], y: Span[Word, o2]) -> List[Word]:
    """`x * y` where both have the same length. Go's `karatsuba`.

    Writing `x` as `x1:x0` and `y` as `y1:y0`, each half the length of the
    whole, the product is

        x1*y1 : (x0-x1)*(y1-y0) + x1*y1 + x0*y0 : x0*y0

    which is three half sized multiplications where the obvious arrangement
    needs four. The middle term can be negative, so it is computed from the
    magnitudes and a sign, and added or subtracted accordingly. It is never
    more negative than the two squares beside it are positive, because it is
    `x0*y1 + x1*y0` rearranged and that is a sum of products of natural
    numbers.
    """
    var n = len(y)
    if n < _KARATSUBA_THRESHOLD or n < 2:
        var z = List[Word](length=2 * n, fill=0)
        _basic_mul(z, x, y)
        return z^

    var n2 = (n + 1) // 2
    var x0 = x[0 : _norm_len(x[0:n2])]
    var x1 = x[n2 : n2 + _norm_len(x[n2:])]
    var y0 = y[0 : _norm_len(y[0:n2])]
    var y1 = y[n2 : n2 + _norm_len(y[n2:])]

    var z0 = _mul(x0, y0)
    var z2 = _mul(x1, y1)

    # tx = x0 - x1 and ty = y1 - y0, each as a magnitude and a sign.
    var tx_neg = _cmp(x0, x1) < 0
    var tx = _sub(x1, x0) if tx_neg else _sub(x0, x1)
    var ty_neg = _cmp(y1, y0) < 0
    var ty = _sub(y0, y1) if ty_neg else _sub(y1, y0)

    var middle = _add(Span(z0), Span(z2))
    var cross = _mul(Span(tx), Span(ty))
    var z1 = _combine(Span(middle), Span(cross), tx_neg != ty_neg)

    var z = List[Word](length=2 * n, fill=0)
    for i in range(len(z0)):
        z[i] = z0[i]
    _add_to(Span(z)[2 * n2 :], Span(z2))
    _add_to(Span(z)[n2:], Span(z1))
    return z^


def _combine[
    o1: ImmOrigin, o2: ImmOrigin
](m: Span[Word, o1], c: Span[Word, o2], negative: Bool) -> List[Word]:
    """`m - c` when `negative`, `m + c` otherwise.

    Karatsuba's middle term is the one place in the package where a sum and a
    difference are chosen between at run time, and writing the choice as a
    function keeps the caller from having to declare the answer before it knows
    which one it wants.
    """
    if negative:
        return _sub(m, c)
    return _add(m, c)


def _sqr[o: ImmOrigin](x: Span[Word, o]) -> List[Word]:
    """`x * x`. Go's `nat.sqr`.

    Squaring is the operation exponentiation spends its time in, so it is worth
    a loop of its own: every product `x[i] * x[j]` with `i` below `j` appears
    twice in the answer, so the loop collects each of them once, doubles the
    lot with a single shift and adds the diagonal squares to that.
    """
    var n = len(x)
    if n == 0:
        return _zero()
    if n == 1:
        var hi, lo = _mul_ww(x[0], x[0])
        var one = List[Word](length=2, fill=0)
        one[0] = lo
        one[1] = hi
        return _norm(one^)

    if n < _BASIC_SQR_THRESHOLD:
        var z = List[Word](length=2 * n, fill=0)
        _basic_mul(z, x, x)
        return _norm(z^)

    var z = List[Word](length=2 * n, fill=0)
    var t = List[Word](length=2 * n, fill=0)
    var hi, lo = _mul_ww(x[0], x[0])
    z[0] = lo
    z[1] = hi
    for i in range(1, n):
        var d = x[i]
        var dhi, dlo = _mul_ww(d, d)
        z[2 * i] = dlo
        z[2 * i + 1] = dhi
        t[2 * i] = _add_mul_vvww_into(Span(t)[i : 2 * i], x[0:i], d, 0)
    # Doubling the collected cross products can carry out of the top of the
    # range being shifted, and that bit is the top word of the answer.
    t[2 * n - 1] = _lsh_vu_into(Span(t)[1 : 2 * n - 1], 1)
    _ = _add_vv_into(Span(z), Span(t))

    return _norm(z^)


def _mul_range(a: UInt64, b: UInt64) -> List[Word]:
    """The product of every integer from `a` to `b`. Go's `nat.mulRange`.

    An empty range is one, which is what makes `Int.binomial` and
    `Int.mul_range` agree with Go on the edges. The range is halved rather than
    walked, so the multiplications stay balanced and Karatsuba gets to work on
    them.
    """
    if a == 0:
        return _zero()
    if a > b:
        return _set_word(1)
    if a == b:
        return _set_word(Word(a))
    if a + 1 == b:
        var lo = _set_word(Word(a))
        var hi = _set_word(Word(b))
        return _mul(Span(lo), Span(hi))

    var m = a + (b - a) // 2
    var lo = _mul_range(a, m)
    var hi = _mul_range(m + 1, b)
    return _mul(Span(lo), Span(hi))
