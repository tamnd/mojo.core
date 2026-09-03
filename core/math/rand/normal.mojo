"""The normal distribution, by the ziggurat method. Go's `normal.go`.

Marsaglia and Tsang, "The Ziggurat Method for Generating Random Variables"
(2000). The half of the normal density to the right of zero is covered by 128
regions of equal area: 127 rectangles stacked up under the curve, and a base
region that is a rectangle plus the tail. A draw picks a region and a point
across it, and if the point is in the part of the rectangle that lies entirely
under the curve, which it is more than 99 percent of the time, the answer is
that point and the density is never evaluated at all.

The tables that describe the regions are generated, in `tables.mojo`. Nobody
should be reading them and nobody needs to.

This is a free function over any `Source` rather than a method on `Rand`,
because Mojo has no methods outside a struct body and `Rand` is declared in
`rand.mojo`. `Rand.norm_float64` is a call to this.
"""

from core.math import exp, log

from .source import Source, _float64
from .tables import _FN, _KN, _RN, _WN


def _abs_int32(i: Int32) -> UInt32:
    """The magnitude of `i`. Go's `absInt32`.

    `Int32.MIN` negated is itself, and its magnitude does not fit an `Int32`,
    which is why this answers in a `UInt32` and why the negation happens after
    the width has changed rather than before.
    """
    if i < 0:
        return UInt32(-Int64(i))
    return UInt32(Int64(i))


def _norm_float64[S: Source](mut src: S) -> Float64:
    """A value from the standard normal distribution. Go's `Rand.NormFloat64`.

    One draw gives all three things the method needs: the low 32 bits are the
    position across the region and carry the sign, the next seven bits choose
    the region, and the rest are unused.

    The comparison in the rejection test is written in single precision because
    Go writes it in single precision, and that is not an accident of the table
    widths. Widening it changes which samples are accepted, and the stream
    stops being the same stream.
    """
    while True:
        var u = src.uint64()
        var j = UInt32(u & 0xFFFFFFFF).cast[DType.int32]()
        var i = Int((u >> 32) & 0x7F)
        var x = Float64(j) * Float64(materialize[_WN]()[i])
        if _abs_int32(j) < materialize[_KN]()[i]:
            # More than 99 percent of draws end here.
            return x

        if i == 0:
            # The base region, which is the only one with a tail hanging off
            # it. Marsaglia's exponential rejection covers the tail: draw from
            # an exponential shifted out to where the tail starts, and keep it
            # when a second exponential draw is at least half its square.
            while True:
                x = -log(_float64(src)) * (1.0 / _RN)
                var y = -log(_float64(src))
                if y + y >= x * x:
                    break
            if j > 0:
                return _RN + x
            return -_RN - x

        var here = materialize[_FN]()[i]
        var above = materialize[_FN]()[i - 1]
        if here + Float32(_float64(src)) * (above - here) < Float32(
            exp(-0.5 * x * x)
        ):
            return x
