"""The inverse circular and hyperbolic functions. Go's `asin.go`.

Six functions, and four of them are one of the other two turned by a right
angle: `asinh(x)` is `-i * asin(i * x)`, `acos(x)` is `pi/2 - asin(x)`,
`atanh(x)` is `-i * atan(i * x)`, and `acosh` is `acos` rotated the way that
puts the answer in the right half plane. Only `asin` and `atan` have their own
formula.

The switches in front of them are longer than the formulas. Each one is C99
Annex G, and the value that keeps turning up in them is the sign of a zero:
`asin` of `(-inf, 1)` and `asin` of `(inf, 1)` differ by nothing else, and a
zero that lost its sign on the way through would put the answer on the wrong
side of the branch cut.
"""

from std.complex import ComplexFloat64

from core.math import PI
from core.math import abs as _abs
from core.math import asin as _asin
from core.math import asinh as _asinh
from core.math import atan as _atan
from core.math import atan2 as _atan2
from core.math import atanh as _atanh
from core.math import copysign as _copysign
from core.math import is_inf as _is_inf
from core.math import is_nan as _is_nan
from core.math import log as _log
from core.math import nan as _nan

from .exp import log, sqrt
from .ieee import nan
from .trig import _reduce_pi


def asin(x: ComplexFloat64) -> ComplexFloat64:
    """The inverse sine of `x`. Go's `Asin`.

    `-i * log(i*x + sqrt(1 - x*x))`, which is the definition, with the real
    inverse sine used along the two axes where it is the whole answer.
    """
    var re = x.re
    var im = x.im
    if im == 0 and _abs(re) <= 1:
        return ComplexFloat64(_asin(re), im)
    elif re == 0 and _abs(im) <= 1:
        return ComplexFloat64(re, _asinh(im))
    elif _is_nan(im):
        if re == 0:
            return ComplexFloat64(re, _nan())
        if _is_inf(re, 0):
            return ComplexFloat64(_nan(), re)
        return nan()
    elif _is_inf(im, 0):
        if _is_nan(re):
            return x
        if _is_inf(re, 0):
            return ComplexFloat64(_copysign(PI / 4, re), im)
        return ComplexFloat64(_copysign(0.0, re), im)
    elif _is_inf(re, 0):
        return ComplexFloat64(_copysign(PI / 2, re), _copysign(re, im))

    var ct = ComplexFloat64(-im, re)  # i * x
    var xx = x * x
    var x1 = ComplexFloat64(1 - xx.re, -xx.im)  # 1 - x*x
    var x2 = sqrt(x1)
    var w = log(ct + x2)
    return ComplexFloat64(w.im, -w.re)  # -i * w


def asinh(x: ComplexFloat64) -> ComplexFloat64:
    """The inverse hyperbolic sine of `x`. Go's `Asinh`."""
    var re = x.re
    var im = x.im
    if im == 0 and _abs(re) <= 1:
        return ComplexFloat64(_asinh(re), im)
    elif re == 0 and _abs(im) <= 1:
        return ComplexFloat64(re, _asin(im))
    elif _is_inf(re, 0):
        if _is_inf(im, 0):
            return ComplexFloat64(re, _copysign(PI / 4, im))
        if _is_nan(im):
            return x
        return ComplexFloat64(re, _copysign(0.0, im))
    elif _is_nan(re):
        if im == 0:
            return x
        if _is_inf(im, 0):
            return ComplexFloat64(im, re)
        return nan()
    elif _is_inf(im, 0):
        return ComplexFloat64(_copysign(im, re), _copysign(PI / 2, im))

    var xx = x * x
    var x1 = ComplexFloat64(1 + xx.re, xx.im)  # 1 + x*x
    return log(x + sqrt(x1))


def acos(x: ComplexFloat64) -> ComplexFloat64:
    """The inverse cosine of `x`. Go's `Acos`."""
    var w = asin(x)
    return ComplexFloat64(PI / 2 - w.re, -w.im)


def acosh(x: ComplexFloat64) -> ComplexFloat64:
    """The inverse hyperbolic cosine of `x`. Go's `Acosh`."""
    if x.re == 0 and x.im == 0:
        return ComplexFloat64(0.0, _copysign(PI / 2, x.im))
    var w = acos(x)
    if w.im <= 0:
        return ComplexFloat64(-w.im, w.re)  # i * w
    return ComplexFloat64(w.im, -w.re)  # -i * w


def atan(x: ComplexFloat64) -> ComplexFloat64:
    """The inverse tangent of `x`. Go's `Atan`.

    Half the arctangent of a ratio for the real part and a quarter of the
    logarithm of another for the imaginary part, which is Cephes rather than
    the definition. The half angle is reduced modulo pi, because the
    arctangent it comes from is already folded into a half turn and doubling
    it back would put it in the wrong one.
    """
    var re = x.re
    var im = x.im
    if im == 0:
        return ComplexFloat64(_atan(re), im)
    elif re == 0 and _abs(im) <= 1:
        return ComplexFloat64(re, _atanh(im))
    elif _is_inf(im, 0) or _is_inf(re, 0):
        if _is_nan(re):
            return ComplexFloat64(_nan(), _copysign(0.0, im))
        return ComplexFloat64(_copysign(PI / 2, re), _copysign(0.0, im))
    elif _is_nan(re) or _is_nan(im):
        return nan()

    var x2 = re * re
    var a = 1 - x2 - im * im
    if a == 0:
        return nan()
    var t = 0.5 * _atan2(2 * re, a)
    var w = _reduce_pi(t)

    t = im - 1
    var b = x2 + t * t
    if b == 0:
        return nan()
    t = im + 1
    var c = (x2 + t * t) / b
    return ComplexFloat64(w, 0.25 * _log(c))


def atanh(x: ComplexFloat64) -> ComplexFloat64:
    """The inverse hyperbolic tangent of `x`. Go's `Atanh`."""
    var z = atan(ComplexFloat64(-x.im, x.re))  # atan(i * x)
    return ComplexFloat64(z.im, -z.re)  # -i * z
