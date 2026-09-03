"""The exponential distribution, by the ziggurat method. Go's `exp.go`.

The same construction as `normal.mojo` with two differences: 256 regions rather
than 128, and no sign, since the exponential density lives entirely to the
right of zero. The tail is simpler too. The normal's tail needs a rejection
loop; this one is exponential all the way out, so a single logarithm shifted to
where the tail starts is exactly right.

The tables are generated, in `tables.mojo`.

A free function over any `Source` rather than a method on `Rand`, for the
reason `normal.mojo` gives. `Rand.exp_float64` is a call to this.
"""

from core.math import exp, log

from .source import Source, _float64
from .tables import _FE, _KE, _RE, _WE


def _exp_float64[S: Source](mut src: S) -> Float64:
    """A value from the exponential distribution with rate 1. Go's
    `Rand.ExpFloat64`.

    One draw again: the low 32 bits position the sample across its region, the
    next eight choose the region.
    """
    while True:
        var u = src.uint64()
        var j = UInt32(u & 0xFFFFFFFF)
        var i = Int((u >> 32) & 0xFF)
        var x = Float64(j) * Float64(materialize[_WE]()[i])
        if j < materialize[_KE]()[i]:
            return x
        if i == 0:
            # The tail. An exponential distribution has no memory, so the tail
            # beyond `_RE` is another exponential starting there, and one
            # logarithm draws from it with nothing to reject.
            return _RE - log(_float64(src))

        var here = materialize[_FE]()[i]
        var above = materialize[_FE]()[i - 1]
        if here + Float32(_float64(src)) * (above - here) < Float32(exp(-x)):
            return x
