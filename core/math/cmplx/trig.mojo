"""The circular and hyperbolic functions. Go's `sin.go` and `tan.go`.

Seven functions and three helpers. `sin`, `cos`, `sinh` and `cosh` are the
addition formulas, one real trigonometric call and one real hyperbolic call
each, with a switch in front of them for the values where a product of an
infinity and a zero would otherwise decide the answer.

`tan`, `tanh` and `cot` are a ratio, and the ratio is where the work is. The
denominator of `tan` is `cos(2re) + cosh(2im)`, which is nearly zero at every
odd multiple of pi over two, and near those points the two terms cancel and
take the digits with them. Go evaluates the difference by its Taylor series
instead, and that series needs the argument reduced modulo pi, to more bits
than a float64 holds when the argument is large. That reduction is
`_reduce_pi`, it is Payne-Hanek above 2**30, and it is the reason this package
depends on `core.math.bits`: the reduction multiplies the mantissa by the
digits of one over pi in 128 bit pieces.
"""

from std.complex import ComplexFloat64

from core.math import PI
from core.math import abs as _abs
from core.math import copysign as _copysign
from core.math import cos as _cos
from core.math import cosh as _cosh
from core.math import exp as _exp
from core.math import float64bits as _float64bits
from core.math import float64frombits as _float64frombits
from core.math import inf as _real_inf
from core.math import is_inf as _is_inf
from core.math import is_nan as _is_nan
from core.math import nan as _nan
from core.math import sin as _sin
from core.math import sincos as _sincos
from core.math import sinh as _sinh
from core.math.bits import add64 as _add64
from core.math.bits import leading_zeros64 as _leading_zeros64
from core.math.bits import mul64 as _mul64

from .ieee import inf


def sin(x: ComplexFloat64) -> ComplexFloat64:
    """The sine of `x`. Go's `Sin`."""
    var re = x.re
    var im = x.im
    if im == 0 and (_is_inf(re, 0) or _is_nan(re)):
        return ComplexFloat64(_nan(), im)
    elif _is_inf(im, 0):
        if re == 0:
            return x
        if _is_inf(re, 0) or _is_nan(re):
            return ComplexFloat64(_nan(), im)
    elif re == 0 and _is_nan(im):
        return x

    var s, c = _sincos(re)
    var sh, ch = _sinhcosh(im)
    return ComplexFloat64(s * ch, c * sh)


def sinh(x: ComplexFloat64) -> ComplexFloat64:
    """The hyperbolic sine of `x`. Go's `Sinh`."""
    var re = x.re
    var im = x.im
    if re == 0 and (_is_inf(im, 0) or _is_nan(im)):
        return ComplexFloat64(re, _nan())
    elif _is_inf(re, 0):
        if im == 0:
            return ComplexFloat64(re, im)
        if _is_inf(im, 0) or _is_nan(im):
            return ComplexFloat64(re, _nan())
    elif im == 0 and _is_nan(re):
        return ComplexFloat64(_nan(), im)

    var s, c = _sincos(im)
    var sh, ch = _sinhcosh(re)
    return ComplexFloat64(c * sh, s * ch)


def cos(x: ComplexFloat64) -> ComplexFloat64:
    """The cosine of `x`. Go's `Cos`."""
    var re = x.re
    var im = x.im
    if im == 0 and (_is_inf(re, 0) or _is_nan(re)):
        return ComplexFloat64(_nan(), -im * _copysign(0.0, re))
    elif _is_inf(im, 0):
        if re == 0:
            return ComplexFloat64(_real_inf(1), -re * _copysign(0.0, im))
        if _is_inf(re, 0) or _is_nan(re):
            return ComplexFloat64(_real_inf(1), _nan())
    elif re == 0 and _is_nan(im):
        return ComplexFloat64(_nan(), 0.0)

    var s, c = _sincos(re)
    var sh, ch = _sinhcosh(im)
    return ComplexFloat64(c * ch, -s * sh)


def cosh(x: ComplexFloat64) -> ComplexFloat64:
    """The hyperbolic cosine of `x`. Go's `Cosh`."""
    var re = x.re
    var im = x.im
    if re == 0 and (_is_inf(im, 0) or _is_nan(im)):
        return ComplexFloat64(_nan(), re * _copysign(0.0, im))
    elif _is_inf(re, 0):
        if im == 0:
            return ComplexFloat64(_real_inf(1), im * _copysign(0.0, re))
        if _is_inf(im, 0) or _is_nan(im):
            return ComplexFloat64(_real_inf(1), _nan())
    elif im == 0 and _is_nan(re):
        return ComplexFloat64(_nan(), im)

    var s, c = _sincos(im)
    var sh, ch = _sinhcosh(re)
    return ComplexFloat64(c * ch, s * sh)


def tan(x: ComplexFloat64) -> ComplexFloat64:
    """The tangent of `x`. Go's `Tan`."""
    var re = x.re
    var im = x.im
    if _is_inf(im, 0):
        if _is_inf(re, 0) or _is_nan(re):
            return ComplexFloat64(_copysign(0.0, re), _copysign(1.0, im))
        return ComplexFloat64(_copysign(0.0, _sin(2 * re)), _copysign(1.0, im))
    elif re == 0 and _is_nan(im):
        return x

    var d = _cos(2 * re) + _cosh(2 * im)
    if _abs(d) < 0.25:
        d = _tan_series(x)
    if d == 0:
        return inf()
    return ComplexFloat64(_sin(2 * re) / d, _sinh(2 * im) / d)


def tanh(x: ComplexFloat64) -> ComplexFloat64:
    """The hyperbolic tangent of `x`. Go's `Tanh`."""
    var re = x.re
    var im = x.im
    if _is_inf(re, 0):
        if _is_inf(im, 0) or _is_nan(im):
            return ComplexFloat64(_copysign(1.0, re), _copysign(0.0, im))
        return ComplexFloat64(_copysign(1.0, re), _copysign(0.0, _sin(2 * im)))
    elif im == 0 and _is_nan(re):
        return x

    var d = _cosh(2 * re) + _cos(2 * im)
    if d == 0:
        return inf()
    return ComplexFloat64(_sinh(2 * re) / d, _sin(2 * im) / d)


def cot(x: ComplexFloat64) -> ComplexFloat64:
    """The cotangent of `x`. Go's `Cot`.

    The one function in this package that has no special case switch, in Go
    either. Its denominator is zero at the even multiples of pi over two rather
    than the odd ones, and the same Taylor series covers those.
    """
    var d = _cosh(2 * x.im) - _cos(2 * x.re)
    if _abs(d) < 0.25:
        d = _tan_series(x)
    if d == 0:
        return inf()
    return ComplexFloat64(_sin(2 * x.re) / d, -_sinh(2 * x.im) / d)


def _sinhcosh(x: Float64) -> Tuple[Float64, Float64]:
    """The hyperbolic sine and cosine of `x` together. Go's `sinhcosh`.

    One exponential rather than the two the separate calls would take. Below a
    half it defers to the real functions, because `e - 1/e` there is two nearly
    equal numbers being subtracted.
    """
    if _abs(x) <= 0.5:
        return (_sinh(x), _cosh(x))
    var e = _exp(x)
    var ei = 0.5 / e
    e *= 0.5
    return (e - ei, e + ei)


# PI1, PI2 and PI3 add up to pi to a hundred and two bits. The first two have
# thirty and thirty two trailing zero bits, so a multiple of either by an
# integer of fewer than thirty significant bits is exact, which is what makes
# the subtraction below lose nothing.
comptime _PI1 = 3.141592502593994
comptime _PI2 = 1.5099578831723193e-07
comptime _PI3 = 1.0780605716316238e-14

comptime _REDUCE_THRESHOLD = 1073741824.0
"""2**30, above which the three part reduction stops being exact.

The multiple `t` has to have fewer significant bits than the trailing zeros of
PI1 and PI2 for `t * PI1` and `t * PI2` to be exact, which puts the argument
below 2**30.
"""

comptime _MASK = 0x7FF
comptime _SHIFT = 64 - 11 - 1
comptime _BIAS = 1023
comptime _FRAC_MASK = (1 << _SHIFT) - 1

comptime _M_PI: InlineArray[UInt64, 20] = [
    0x0000000000000000,
    0x517CC1B727220A94,
    0xFE13ABE8FA9A6EE0,
    0x6DB14ACC9E21C820,
    0xFF28B1D5EF5DE2B0,
    0xDB92371D2126E970,
    0x0324977504E8C90E,
    0x7F0EF58E5894D39F,
    0x74411AFA975DA242,
    0x74CE38135A2FBF20,
    0x9CC8EB1CC1A99CFA,
    0x4E422FC5DEFC941D,
    0x8FFC4BFFEF02CC07,
    0xF79788C5AD05368F,
    0xB69B3F6793E584DB,
    0xA7A31FB34F2FF516,
    0xBA93DD63F5F2F8BD,
    0x9E839CFBC5294975,
    0x35FDAFD88FC6AE84,
    0x2B0198237E3DB5D5,
]
"""One over pi in binary, as twenty 64 bit digits.

`1/pi = sum(_M_PI[i] * 2**(-64*i))`. Nineteen of them are a thousand two
hundred and sixteen bits, which is enough for the largest exponent a float64
has.
"""

comptime _MACHEP = 1.0 / (1 << 53)
"""One ulp at one, where the Taylor series below stops."""


def _shl(x: UInt64, n: UInt64) -> UInt64:
    """`x` shifted left by `n`, and zero once `n` reaches the width.

    Go defines a shift of sixty four or more as zero. Mojo hands the shift to
    the hardware, where it is undefined, and the reduction below asks for that
    shift on the values it was written to produce zero for.
    """
    if n >= 64:
        return 0
    return x << n


def _shr(x: UInt64, n: UInt64) -> UInt64:
    """`x` shifted right by `n`, and zero once `n` reaches the width."""
    if n >= 64:
        return 0
    return x >> n


def _reduce_pi(x: Float64) -> Float64:
    """`x` reduced to `(-pi/2, pi/2]`. Go's `reducePi`.

    Cody-Waite in three parts below 2**30, where subtracting an exact multiple
    of an extended precision pi is enough, and Payne-Hanek above it, which
    multiplies the mantissa by the digits of one over pi and keeps the
    fractional part. The second is the only way to be right at 2**500, where
    the spacing between representable numbers is far wider than pi and the
    naive answer is noise.
    """
    if _abs(x) < _REDUCE_THRESHOLD:
        var t = x / PI
        t += 0.5
        t = Float64(Int(t))  # The multiple.
        return ((x - t * _PI1) - t * _PI2) - t * _PI3

    # x is ix * 2**exp, with the implicit bit put back.
    var ix = _float64bits(x)
    var exp = Int((ix >> _SHIFT) & _MASK) - _BIAS - _SHIFT
    ix &= _FRAC_MASK
    ix |= 1 << _SHIFT

    # The three digits of one over pi whose product with the mantissa has its
    # leading digit at 2**-64. exp is at least 50 here, since x is above the
    # threshold, and below 971 for the largest float64.
    var one_over_pi = materialize[_M_PI]()
    var digit = (exp + 64) // 64
    var bitshift = UInt64((exp + 64) % 64)
    var z0 = _shl(one_over_pi[digit], bitshift) | _shr(
        one_over_pi[digit + 1], 64 - bitshift
    )
    var z1 = _shl(one_over_pi[digit + 1], bitshift) | _shr(
        one_over_pi[digit + 2], 64 - bitshift
    )
    var z2 = _shl(one_over_pi[digit + 2], bitshift) | _shr(
        one_over_pi[digit + 3], 64 - bitshift
    )

    # The product, keeping the top two digits of it.
    var z2hi = _mul64(z2, ix)[0]
    var z1hi, z1lo = _mul64(z1, ix)
    var z0lo = z0 * ix
    var lo, carry = _add64(z1lo, z2hi, 0)
    var hi = _add64(z0lo, z1hi, carry)[0]

    # The fraction, normalised into a float64: how far the leading one is down
    # gives the exponent, and the implicit bit goes away again.
    var lz = UInt64(_leading_zeros64(hi))
    var e = UInt64(_BIAS) - (lz + 1)
    hi = _shl(hi, lz + 1) | _shr(lo, 64 - (lz + 1))
    hi >>= 64 - _SHIFT
    hi |= e << _SHIFT

    var fraction = _float64frombits(hi)
    if fraction > 0.5:
        fraction -= 1
    return PI * fraction


def _tan_series(z: ComplexFloat64) -> Float64:
    """`cosh(2im) - cos(2re)` by its Taylor series. Go's `tanSeries`.

    The two terms of that difference are nearly equal near the poles of the
    tangent, so computing each and subtracting leaves almost no correct digits.
    The series has no subtraction of nearly equal numbers in it and is
    accurate where the difference is small, which is the only place it is used.
    """
    var x = _abs(2 * z.re)
    var y = _abs(2 * z.im)
    x = _reduce_pi(x)
    x = x * x
    y = y * y
    var x2 = 1.0
    var y2 = 1.0
    var f = 1.0
    var rn = 0.0
    var d = 0.0
    while True:
        rn += 1
        f *= rn
        rn += 1
        f *= rn
        x2 *= x
        y2 *= y
        var t = y2 + x2
        t /= f
        d += t

        rn += 1
        f *= rn
        rn += 1
        f *= rn
        x2 *= x
        y2 *= y
        t = y2 - x2
        t /= f
        d += t
        # Go's comment: not and greater than rather than less or equal, so that
        # a not a number ratio ends the loop instead of running it forever.
        if not (_abs(t / d) > _MACHEP):
            break
    return d
