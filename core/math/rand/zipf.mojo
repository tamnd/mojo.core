"""The Zipf distribution. Go's `zipf.go`.

Hormann and Derflinger, "Rejection-Inversion to Generate Variates from Monotone
Discrete Distributions" (1996). Values `k` in `[0, imax]` come out with
probability proportional to `(v + k) ** -s`, which is the shape of word
frequencies, city sizes and web page popularity, and the reason a load
generator wants it.

```mojo
from core.math.rand import new, new_pcg, new_zipf

var z = new_zipf(new(new_pcg(1, 2)), 2.0, 1.0, 99)
print(z.uint64() <= 99)  # True
```

Rejection inversion means the continuous curve through the discrete
probabilities is inverted directly, which needs no table and no setup
proportional to `imax`, so `imax` can be enormous at no cost. What it costs
instead is a rejection test with two exponentials and two logarithms in it, on
the rare draw that lands where the continuous curve and the discrete
distribution disagree.

Like `Rand`, and for the same reason, a `Zipf` owns the generator it draws
from. Go holds a `*Rand` and lets the caller keep using it alongside.
"""

from core.errors import Report
from core.errors.codes import ErrInvalidArgument
from core.math import exp, floor, log

from .rand import Rand
from .source import Source


def _h(
    x: Float64, v: Float64, oneminus_q: Float64, oneminus_qinv: Float64
) -> Float64:
    """The integral of the continuous density, which is what gets inverted.

    A free function rather than a method because `new_zipf` needs it before the
    fields it would read are all set, and Mojo will not call a method on a
    partly initialised value.
    """
    return exp(oneminus_q * log(v + x)) * oneminus_qinv


def _hinv(
    x: Float64, v: Float64, oneminus_q: Float64, oneminus_qinv: Float64
) -> Float64:
    """The inverse of `_h`."""
    return exp(oneminus_qinv * log(oneminus_q * x)) - v


struct Zipf[S: Source & Deinitable & Movable](Movable, Source):
    """A generator of Zipf distributed values. Go's `rand.Zipf`.

    Nine floats worked out once by `new_zipf` and then only read. The generator
    is the only part that changes.
    """

    var r: Rand[Self.S]
    """Where the uniform draws come from. Owned, not borrowed."""

    var imax: Float64
    """The largest value this can return, held as a float because every use of
    it is arithmetic."""

    var v: Float64
    """Go's `v`, the offset in `(v + k) ** -s`."""

    var q: Float64
    """Go's `q`, which is the exponent `s`."""

    var s: Float64
    """The width of the region where the continuous curve can be trusted
    without a rejection test."""

    var oneminus_q: Float64
    """`1 - q`, which appears in every evaluation of `_h`."""

    var oneminus_qinv: Float64
    """`1 / (1 - q)`, likewise."""

    var hxm: Float64
    """`_h` at the far end, which is the bottom of the range being inverted."""

    var hx0minus_hxm: Float64
    """The height of that range, so a uniform draw scales straight into it."""

    def __init__(
        out self, var r: Rand[Self.S], s: Float64, v: Float64, imax: UInt64
    ) raises:
        """Work out the nine numbers, or raise `ErrInvalidArgument`.

        `s` has to be above 1 and `v` has to be at least 1. Below that the
        series does not converge and there is no distribution to draw from. Go
        returns a nil `*Zipf` here and leaves the caller to notice, which is
        the sort of nil that gets dereferenced three lines later.
        """
        if s <= 1.0 or v < 1:
            raise (
                Report("rand: new_zipf needs s greater than 1 and v at least 1")
                .with_code(ErrInvalidArgument)
                .error()
            )
        self.r = r^
        self.imax = Float64(imax)
        self.v = v
        self.q = s
        self.oneminus_q = 1.0 - s
        self.oneminus_qinv = 1.0 / (1.0 - s)
        self.hxm = _h(self.imax + 0.5, v, self.oneminus_q, self.oneminus_qinv)
        self.hx0minus_hxm = (
            _h(0.5, v, self.oneminus_q, self.oneminus_qinv)
            - exp(log(v) * (-s))
            - self.hxm
        )
        self.s = 1 - _hinv(
            _h(1.5, v, self.oneminus_q, self.oneminus_qinv)
            - exp(-s * log(v + 1.0)),
            v,
            self.oneminus_q,
            self.oneminus_qinv,
        )

    def uint64(mut self) -> UInt64:
        """A value in `[0, imax]`, Zipf distributed.

        Draw uniformly from the range of the integral, invert to get a
        continuous `x`, and round to the nearest whole number. When the
        rounding moved by less than `self.s` the continuous curve and the
        discrete distribution agree closely enough to accept without checking.
        Otherwise the check is made, and it very rarely fails.
        """
        while True:
            var draw = self.r.float64()
            var ur = self.hxm + draw * self.hx0minus_hxm
            var x = _hinv(ur, self.v, self.oneminus_q, self.oneminus_qinv)
            var k = floor(x + 0.5)
            if k - x <= self.s:
                return UInt64(k)
            var edge = _h(
                k + 0.5, self.v, self.oneminus_q, self.oneminus_qinv
            ) - exp(-log(k + self.v) * self.q)
            if ur >= edge:
                return UInt64(k)


def new_zipf[
    S: Source & Deinitable & Movable
](var r: Rand[S], s: Float64, v: Float64, imax: UInt64) raises -> Zipf[S]:
    """A `Zipf` drawing from `r`. Go's `rand.NewZipf`.

    Values come out in `[0, imax]` with `P(k)` proportional to `(v + k) ** -s`.
    Raises `ErrInvalidArgument` unless `s > 1` and `v >= 1`, where Go returns
    nil.
    """
    return Zipf(r^, s, v, imax)
