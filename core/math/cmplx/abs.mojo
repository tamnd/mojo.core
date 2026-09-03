"""Taking a complex number apart and putting one back together. Go's `abs.go`,
`phase.go`, `polar.go`, `rect.go` and `conj.go`.

Five functions of one line each. `abs` is a hypotenuse rather than the square
root of the sum of two squares, and that is the whole reason this package does
not hand the job to `ComplexFloat64.norm()`: squaring both parts first
overflows at `(1e308, 1e308)`, where the answer is an ordinary 1.4e308, and
underflows to zero at `(1e-320, 1e-320)`, where the answer is 1.4e-320.
`core.math.hypot` scales before it squares and gets both of them right.
"""

from std.complex import ComplexFloat64

from core.math import atan2 as _atan2
from core.math import hypot as _hypot
from core.math import sincos as _sincos


def abs(x: ComplexFloat64) -> Float64:
    """The absolute value, also called the modulus, of `x`. Go's `Abs`."""
    return _hypot(x.re, x.im)


def phase(x: ComplexFloat64) -> Float64:
    """The phase, also called the argument, of `x`, in `[-pi, pi]`.

    Go's `Phase`.
    """
    return _atan2(x.im, x.re)


def polar(x: ComplexFloat64) -> Tuple[Float64, Float64]:
    """The absolute value and the phase of `x`, so that `x = r * e**(theta*i)`.

    Go's `Polar`, which returns the pair `r, theta`. Here it is a tuple that
    unpacks: `var r, theta = polar(x)`.
    """
    return (abs(x), phase(x))


def rect(r: Float64, theta: Float64) -> ComplexFloat64:
    """The complex number with polar coordinates `r` and `theta`. Go's `Rect`.
    """
    var s, c = _sincos(theta)
    return ComplexFloat64(r * c, r * s)


def conj(x: ComplexFloat64) -> ComplexFloat64:
    """The complex conjugate of `x`. Go's `Conj`."""
    return ComplexFloat64(x.re, -x.im)
