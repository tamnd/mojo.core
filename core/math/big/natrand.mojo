"""Random natural numbers. Go's `nat.random`, which lives in `nat.go`.

One function, in its own file so that the rest of the arithmetic does not have
to depend on a generator. `Int.rand` and the Miller-Rabin rounds of
`Int.probably_prime` are the only two callers.

Go builds each sixty four bit digit out of two calls to `Uint32`, because Go's
`math/rand` had a thirty one bit source underneath it and pairing the calls was
how a full digit was made. `core.math.rand` is Go's `math/rand/v2`, whose
sources are sixty four bits wide, so a digit here is one call. The distribution
is the same and the sequence is not: a program that seeded a generator and
compared the numbers against Go's would see different ones. `docs/deviations.md`
records it.
"""

from core.math.rand import Source

from .arith import _M, _W, Word
from .nat import _cmp, _norm, _zero


def _random[
    S: Source, o: ImmOrigin
](mut src: S, limit: Span[Word, o], n: Int) -> List[Word]:
    """A uniform number below `limit`, which has `n` bits. Go's `nat.random`.

    Rejection sampling. Enough digits are drawn to cover `limit`, the ones
    above its top bit are masked off, and the draw is thrown away and repeated
    if it landed at or above `limit`. Masking first is what keeps the rejection
    rate below one half however far `limit` is from a power of two.

    A `limit` of zero has nothing below it, so this answers zero rather than
    looping. Go indexes off the front of the empty slice and panics.
    """
    var m = len(limit)
    if m == 0:
        return _zero()

    var bits = n % _W
    if bits == 0:
        bits = _W
    # Go writes the mask as `(1 << bits) - 1`, which is a shift by the whole
    # width when `limit` fills its top digit. That is zero under Go's rule and
    # undefined under Mojo's, so the full mask is spelled out.
    var mask = _M if bits == _W else (Word(1) << Word(bits)) - 1

    var z = List[Word](length=m, fill=0)
    while True:
        for i in range(m):
            z[i] = src.uint64()
        z[m - 1] &= mask
        if _cmp(Span(z), limit) < 0:
            break

    return _norm(z^)
