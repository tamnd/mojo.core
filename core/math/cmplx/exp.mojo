"""The exponential, the logarithms, the power and the square root. Go's
`exp.go`, `log.go`, `pow.go` and `sqrt.go`.

Cephes by way of Go, and the special case switches are most of the code.
`exp` is `exp(re)` turning the unit vector at angle `im`, `log` is the
logarithm of the modulus with the phase as the imaginary part, and `pow` is
`exp(y * log(x))` written out so that the modulus and the phase are each
computed once.

`sqrt` is the one that is not a formula. The obvious `sqrt((r + re) / 2)` for
the real part loses most of its digits when `re` is negative and close to `-r`,
so it takes the root that does not cancel and gets the other part from
`2 * re(w) * im(w) = im(x)`. The rescaling either side of that is what keeps
`hypot` from overflowing on the way in, which is a different overflow from the
one `abs` avoids.
"""

from std.complex import ComplexFloat64

from core.math import LOG10E
from core.math import abs as _abs
from core.math import copysign as _copysign
from core.math import exp as _exp
from core.math import hypot as _hypot
from core.math import inf as _inf
from core.math import is_inf as _is_inf
from core.math import is_nan as _is_nan
from core.math import log as _log
from core.math import nan as _nan
from core.math import pow as _pow
from core.math import sincos as _sincos
from core.math import sqrt as _sqrt

from .abs import abs, phase
from .ieee import inf, is_nan, nan


def exp(x: ComplexFloat64) -> ComplexFloat64:
    """`e**x`, the base e exponential of `x`. Go's `Exp`."""
    var re = x.re
    var im = x.im
    if _is_inf(re, 0):
        if re > 0 and im == 0:
            return x
        if _is_inf(im, 0) or _is_nan(im):
            # An infinite imaginary part is an angle that does not exist, so
            # there is no direction to point the answer in. Underneath the
            # overflow the modulus is still zero or still infinite, and that
            # much survives.
            if re < 0:
                return ComplexFloat64(0.0, _copysign(0.0, im))
            return ComplexFloat64(_inf(1), _nan())
    elif _is_nan(re):
        if im == 0:
            return ComplexFloat64(_nan(), im)

    var r = _exp(re)
    var s, c = _sincos(im)
    return ComplexFloat64(r * c, r * s)


def log(x: ComplexFloat64) -> ComplexFloat64:
    """The natural logarithm of `x`. Go's `Log`."""
    return ComplexFloat64(_log(abs(x)), phase(x))


def log10(x: ComplexFloat64) -> ComplexFloat64:
    """The decimal logarithm of `x`. Go's `Log10`."""
    var z = log(x)
    return ComplexFloat64(LOG10E * z.re, LOG10E * z.im)


def pow(x: ComplexFloat64, y: ComplexFloat64) -> ComplexFloat64:
    """`x**y`, the base `x` exponential of `y`. Go's `Pow`.

    Go documents two of these itself, for compatibility with `core.math.pow`:
    `pow(0, 0)` is one, and `pow(0, y)` for a negative real `y` is an infinity,
    with an infinite imaginary part as well when `y` has one.
    """
    if x.re == 0 and x.im == 0:  # True of negative zero as well.
        if is_nan(y):
            return nan()
        var yr = y.re
        var yi = y.im
        if yr == 0:
            return ComplexFloat64(1.0, 0.0)
        if yr < 0:
            if yi == 0:
                return ComplexFloat64(_inf(1), 0.0)
            return inf()
        if yr > 0:
            return ComplexFloat64(0.0, 0.0)
        # Go has an unreachable panic here. It is reachable: `is_nan` is false
        # for a not a number sitting beside an infinity, so a `y` of
        # `(nan, inf)` arrives with none of the three comparisons true. A not a
        # number is the answer everywhere else a not a number exponent turns
        # up, and it is the answer here.
        return nan()

    var modulus = abs(x)
    if modulus == 0:
        return ComplexFloat64(0.0, 0.0)
    var r = _pow(modulus, y.re)
    var arg = phase(x)
    var theta = y.re * arg
    if y.im != 0:
        r *= _exp(-y.im * arg)
        theta += y.im * _log(modulus)
    var s, c = _sincos(theta)
    return ComplexFloat64(r * c, r * s)


def sqrt(x: ComplexFloat64) -> ComplexFloat64:
    """The square root of `x`. Go's `Sqrt`.

    The root in the right half plane, whose imaginary part carries the sign of
    the imaginary part of `x`. The other root is its negative.
    """
    if x.im == 0:
        # The sign of a zero imaginary part is which side of the branch cut the
        # argument came from, and it is what says which of the two roots was
        # asked for, so it is carried through rather than computed with.
        if x.re == 0:
            return ComplexFloat64(0.0, x.im)
        if x.re < 0:
            return ComplexFloat64(0.0, _copysign(_sqrt(-x.re), x.im))
        return ComplexFloat64(_sqrt(x.re), x.im)
    elif _is_inf(x.im, 0):
        return ComplexFloat64(_inf(1), x.im)

    if x.re == 0:
        if x.im < 0:
            var down = _sqrt(-0.5 * x.im)
            return ComplexFloat64(down, -down)
        var up = _sqrt(0.5 * x.im)
        return ComplexFloat64(up, up)

    var a = x.re
    var b = x.im
    var scale: Float64
    # Rescaled so that the hypotenuse below neither overflows nor underflows,
    # and by a power of two so that undoing it costs nothing.
    if _abs(a) > 4 or _abs(b) > 4:
        a *= 0.25
        b *= 0.25
        scale = 2
    else:
        a *= 1.8014398509481984e16  # 2**54
        b *= 1.8014398509481984e16
        scale = 7.450580596923828125e-9  # 2**-27
    var r = _hypot(a, b)
    var t: Float64
    if a > 0:
        t = _sqrt(0.5 * r + 0.5 * a)
        r = scale * _abs((0.5 * b) / t)
        t *= scale
    else:
        r = _sqrt(0.5 * r - 0.5 * a)
        t = scale * _abs((0.5 * b) / r)
        r *= scale
    if b < 0:
        return ComplexFloat64(t, -r)
    return ComplexFloat64(t, r)
