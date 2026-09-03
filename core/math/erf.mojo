"""The error function, its complement, and the inverses of both. Go's `erf.go`
and `erfinv.go`.

All four are ported. `erfinv` and `erfcinv` have to be, since there is no
`erfinv` in a C standard library to call: it is not in the standard, and Go's
is a rational approximation out of a 1988 Applied Statistics paper rather than
a transcription of anybody's libm. `erf` and `erfc` are ported because
`std.math.erf` is out by a hundred and seventy million units in the last place
on an ordinary argument, and because the two share their coefficients, so
taking one and leaving the other would leave two approximations of the same
function in one file.

`erf` and `erfc` are FDLIBM's, by way of Go, in four pieces: a rational
function in x squared up to 0.84375, a second one in x-1 up to 1.25, and beyond
that an exponential times a rational function in 1/x squared, with the crossover
at 1/0.35. The strange looking `float64frombits(float64bits(x) & 0xffffffff...)`
is deliberate: it drops `x` to the top twenty bits of its fraction so that
`z*z` is exact and the error of the reduction can be carried separately.

`erfinv` is three rational functions with eight coefficients over eight, one
for each of `|x| <= 0.85`, out to `1 - 2*exp(-25)`, and the last sliver up
against one where the answer is running away to infinity.
"""

from .arith import sqrt
from .const import LN2
from .exp import exp
from .ieee import float64bits, float64frombits, inf, is_inf, is_nan, nan
from .log import log

comptime _ERX = 8.45062911510467529297e-01
"""What `erf` is at the join, to twenty bits, so that the piece past it can be
written as a correction and keep its low bits."""

# The rational function for erf on [0, 0.84375], numerator then denominator.
comptime _EFX = 1.28379167095512586316e-01
comptime _EFX8 = 1.02703333676410069053e00
comptime _PP0 = 1.28379167095512558561e-01
comptime _PP1 = -3.25042107247001499370e-01
comptime _PP2 = -2.84817495755985104766e-02
comptime _PP3 = -5.77027029648944159157e-03
comptime _PP4 = -2.37630166566501626084e-05
comptime _QQ1 = 3.97917223959155352819e-01
comptime _QQ2 = 6.50222499887672944485e-02
comptime _QQ3 = 5.08130628187576562776e-03
comptime _QQ4 = 1.32494738004321644526e-04
comptime _QQ5 = -3.96022827877536812320e-06

# The rational function for erf on [0.84375, 1.25], in x-1.
comptime _PA0 = -2.36211856075265944077e-03
comptime _PA1 = 4.14856118683748331666e-01
comptime _PA2 = -3.72207876035701323847e-01
comptime _PA3 = 3.18346619901161753674e-01
comptime _PA4 = -1.10894694282396677476e-01
comptime _PA5 = 3.54783043256182359371e-02
comptime _PA6 = -2.16637559486879084300e-03
comptime _QA1 = 1.06420880400844228286e-01
comptime _QA2 = 5.40397917702171048937e-01
comptime _QA3 = 7.18286544141962662868e-02
comptime _QA4 = 1.26171219808761642112e-01
comptime _QA5 = 1.36370839120290507362e-02
comptime _QA6 = 1.19844998467991074170e-02

# The rational function for erfc on [1.25, 1/0.35], in 1/(x*x).
comptime _RA0 = -9.86494403484714822705e-03
comptime _RA1 = -6.93858572707181764372e-01
comptime _RA2 = -1.05586262253232909814e01
comptime _RA3 = -6.23753324503260060396e01
comptime _RA4 = -1.62396669462573470355e02
comptime _RA5 = -1.84605092906711035994e02
comptime _RA6 = -8.12874355063065934246e01
comptime _RA7 = -9.81432934416914548592e00
comptime _SA1 = 1.96512716674392571292e01
comptime _SA2 = 1.37657754143519042600e02
comptime _SA3 = 4.34565877475229228821e02
comptime _SA4 = 6.45387271733267880336e02
comptime _SA5 = 4.29008140027567833386e02
comptime _SA6 = 1.08635005541779435134e02
comptime _SA7 = 6.57024977031928170135e00
comptime _SA8 = -6.04244152148580987438e-02

# The rational function for erfc on [1/0.35, 28], also in 1/(x*x).
comptime _RB0 = -9.86494292470009928597e-03
comptime _RB1 = -7.99283237680523006574e-01
comptime _RB2 = -1.77579549177547519889e01
comptime _RB3 = -1.60636384855821916062e02
comptime _RB4 = -6.37566443368389627722e02
comptime _RB5 = -1.02509513161107724954e03
comptime _RB6 = -4.83519191608651397019e02
comptime _SB1 = 3.03380607434824582924e01
comptime _SB2 = 3.25792512996573918826e02
comptime _SB3 = 1.53672958608443695994e03
comptime _SB4 = 3.19985821950859553908e03
comptime _SB5 = 2.55305040643316442583e03
comptime _SB6 = 4.74528541206955367215e02
comptime _SB7 = -2.24409524465858183362e01

comptime _ERF_VERY_TINY = 2.848094538889218e-306
comptime _ERF_SMALL = 1.0 / Float64(1 << 28)
comptime _ERFC_TINY = 1.0 / Float64(1 << 56)

# erfinv on |x| <= 0.85.
comptime _A0 = 1.1975323115670912564578e0
comptime _A1 = 4.7072688112383978012285e1
comptime _A2 = 6.9706266534389598238465e2
comptime _A3 = 4.8548868893843886794648e3
comptime _A4 = 1.6235862515167575384252e4
comptime _A5 = 2.3782041382114385731252e4
comptime _A6 = 1.1819493347062294404278e4
comptime _A7 = 8.8709406962545514830200e2
comptime _B0 = 1.0000000000000000000e0
comptime _B1 = 4.2313330701600911252e1
comptime _B2 = 6.8718700749205790830e2
comptime _B3 = 5.3941960214247511077e3
comptime _B4 = 2.1213794301586595867e4
comptime _B5 = 3.9307895800092710610e4
comptime _B6 = 2.8729085735721942674e4
comptime _B7 = 5.2264952788528545610e3

# erfinv out to 1 - 2*exp(-25).
comptime _C0 = 1.42343711074968357734e0
comptime _C1 = 4.63033784615654529590e0
comptime _C2 = 5.76949722146069140550e0
comptime _C3 = 3.64784832476320460504e0
comptime _C4 = 1.27045825245236838258e0
comptime _C5 = 2.41780725177450611770e-1
comptime _C6 = 2.27238449892691845833e-2
comptime _C7 = 7.74545014278341407640e-4
comptime _D0 = 1.4142135623730950488016887e0
comptime _D1 = 2.9036514445419946173133295e0
comptime _D2 = 2.3707661626024532365971225e0
comptime _D3 = 9.7547832001787427186894837e-1
comptime _D4 = 2.0945065210512749128288442e-1
comptime _D5 = 2.1494160384252876777097297e-2
comptime _D6 = 7.7441459065157709165577218e-4
comptime _D7 = 1.4859850019840355905497876e-9

# erfinv on the last sliver up against one.
comptime _E0 = 6.65790464350110377720e0
comptime _E1 = 5.46378491116411436990e0
comptime _E2 = 1.78482653991729133580e0
comptime _E3 = 2.96560571828504891230e-1
comptime _E4 = 2.65321895265761230930e-2
comptime _E5 = 1.24266094738807843860e-3
comptime _E6 = 2.71155556874348757815e-5
comptime _E7 = 2.01033439929228813265e-7
comptime _F0 = 1.414213562373095048801689e0
comptime _F1 = 8.482908416595164588112026e-1
comptime _F2 = 1.936480946950659106176712e-1
comptime _F3 = 2.103693768272068968719679e-2
comptime _F4 = 1.112800997078859844711555e-3
comptime _F5 = 2.611088405080593625138020e-5
comptime _F6 = 2.010321207683943062279931e-7
comptime _F7 = 2.891024605872965461538222e-15


def erf(x: Float64) -> Float64:
    """The error function of `x`.

    `erf(-0.0)` is negative zero and the infinities give plus and minus one.
    Past six in either direction the answer has rounded to one already.
    """
    if is_nan(x):
        return nan()
    if is_inf(x, 1):
        return 1
    if is_inf(x, -1):
        return -1

    var sign = x < 0
    var a = -x if sign else x

    if a < 0.84375:
        var temp: Float64
        if a < _ERF_SMALL:
            if a < _ERF_VERY_TINY:
                # Written this way rather than as `x + _EFX*x`, which would
                # lose the answer to underflow at this size.
                temp = 0.125 * (8.0 * a + _EFX8 * a)
            else:
                temp = a + _EFX * a
        else:
            var z = a * a
            var r = _PP0 + z * (_PP1 + z * (_PP2 + z * (_PP3 + z * _PP4)))
            var s = 1 + z * (
                _QQ1 + z * (_QQ2 + z * (_QQ3 + z * (_QQ4 + z * _QQ5)))
            )
            temp = a + a * (r / s)
        return -temp if sign else temp

    if a < 1.25:
        var p, q = _erf_near_one(a)
        return -_ERX - p / q if sign else _ERX + p / q

    if a >= 6:
        return -1.0 if sign else 1.0

    var r = _erfc_tail(a)
    return r / a - 1 if sign else 1 - r / a


def erfc(x: Float64) -> Float64:
    """The complementary error function, `1 - erf(x)`.

    Its own function because subtracting from one throws away the accuracy
    that matters out in the tail, where `erf(x)` is a hair under one and the
    interesting number is how much of a hair. `erfc(+Inf)` is zero and
    `erfc(-Inf)` is two.
    """
    if is_nan(x):
        return nan()
    if is_inf(x, 1):
        return 0
    if is_inf(x, -1):
        return 2

    var sign = x < 0
    var a = -x if sign else x

    if a < 0.84375:
        var temp: Float64
        if a < _ERFC_TINY:
            temp = a
        else:
            var z = a * a
            var r = _PP0 + z * (_PP1 + z * (_PP2 + z * (_PP3 + z * _PP4)))
            var s = 1 + z * (
                _QQ1 + z * (_QQ2 + z * (_QQ3 + z * (_QQ4 + z * _QQ5)))
            )
            var y = r / s
            if a < 0.25:
                temp = a + a * y
            else:
                # Regrouped so that the half is subtracted from a quantity of
                # its own size rather than from something near one.
                temp = 0.5 + (a * y + (a - 0.5))
        return 1 + temp if sign else 1 - temp

    if a < 1.25:
        var p, q = _erf_near_one(a)
        return 1 + _ERX + p / q if sign else 1 - _ERX - p / q

    if a < 28:
        if sign and a > 6:
            return 2
        var r = _erfc_tail(a)
        return 2 - r / a if sign else r / a

    return 2.0 if sign else 0.0


def _erf_near_one(a: Float64) -> Tuple[Float64, Float64]:
    """The numerator and denominator of the piece on [0.84375, 1.25].

    Shared, because `erf` adds it to `_ERX` and `erfc` subtracts it from one
    less `_ERX`, and a second copy of seven coefficients is a second place for
    a digit to be wrong.
    """
    var s = a - 1
    var p = _PA0 + s * (
        _PA1 + s * (_PA2 + s * (_PA3 + s * (_PA4 + s * (_PA5 + s * _PA6))))
    )
    var q = 1 + s * (
        _QA1 + s * (_QA2 + s * (_QA3 + s * (_QA4 + s * (_QA5 + s * _QA6))))
    )
    return p, q


def _erfc_tail(a: Float64) -> Float64:
    """`erfc(a) * a` out past 1.25, for a positive `a` below 28.

    The tail behaves like `exp(-a*a)/a` times a slowly varying rational
    function of `1/(a*a)`, and this is that product without the division.

    `z` is `a` with the bottom half of its fraction cleared, so that `z*z` is
    exact and `-z*z - 0.5625` loses nothing. What the clearing threw away comes
    back through `(z-a)*(z+a)`, which is `z*z - a*a` computed without the
    cancellation.
    """
    var s = 1 / (a * a)
    var r: Float64
    var q: Float64
    if a < 1 / 0.35:
        r = _RA0 + s * (
            _RA1
            + s
            * (
                _RA2
                + s * (_RA3 + s * (_RA4 + s * (_RA5 + s * (_RA6 + s * _RA7))))
            )
        )
        q = 1 + s * (
            _SA1
            + s
            * (
                _SA2
                + s
                * (
                    _SA3
                    + s
                    * (_SA4 + s * (_SA5 + s * (_SA6 + s * (_SA7 + s * _SA8))))
                )
            )
        )
    else:
        r = _RB0 + s * (
            _RB1 + s * (_RB2 + s * (_RB3 + s * (_RB4 + s * (_RB5 + s * _RB6))))
        )
        q = 1 + s * (
            _SB1
            + s
            * (
                _SB2
                + s * (_SB3 + s * (_SB4 + s * (_SB5 + s * (_SB6 + s * _SB7))))
            )
        )
    var z = float64frombits(float64bits(a) & 0xFFFFFFFF00000000)
    return exp(-z * z - 0.5625) * exp((z - a) * (z + a) + r / q)


def erfinv(x: Float64) -> Float64:
    """The inverse of `erf`.

    Plus and minus infinity at plus and minus one, and a not a number outside
    that, since `erf` never leaves it.
    """
    if is_nan(x) or x <= -1 or x >= 1:
        if x == -1:
            return inf(-1)
        if x == 1:
            return inf(1)
        return nan()

    var sign = x < 0
    var a = -x if sign else x

    var ans: Float64
    if a <= 0.85:
        var r = 0.180625 - 0.25 * a * a
        var z1 = (
            (((((_A7 * r + _A6) * r + _A5) * r + _A4) * r + _A3) * r + _A2) * r
            + _A1
        ) * r + _A0
        var z2 = (
            (((((_B7 * r + _B6) * r + _B5) * r + _B4) * r + _B3) * r + _B2) * r
            + _B1
        ) * r + _B0
        ans = (a * z1) / z2
    else:
        var r = sqrt(LN2 - log(1.0 - a))
        var z1: Float64
        var z2: Float64
        if r <= 5.0:
            r -= 1.6
            z1 = (
                (((((_C7 * r + _C6) * r + _C5) * r + _C4) * r + _C3) * r + _C2)
                * r
                + _C1
            ) * r + _C0
            z2 = (
                (((((_D7 * r + _D6) * r + _D5) * r + _D4) * r + _D3) * r + _D2)
                * r
                + _D1
            ) * r + _D0
        else:
            r -= 5.0
            z1 = (
                (((((_E7 * r + _E6) * r + _E5) * r + _E4) * r + _E3) * r + _E2)
                * r
                + _E1
            ) * r + _E0
            z2 = (
                (((((_F7 * r + _F6) * r + _F5) * r + _F4) * r + _F3) * r + _F2)
                * r
                + _F1
            ) * r + _F0
        ans = z1 / z2

    return -ans if sign else ans


def erfcinv(x: Float64) -> Float64:
    """The inverse of `erfc`.

    Positive infinity at zero and negative infinity at two, and a not a number
    outside [0, 2].
    """
    return erfinv(1 - x)
