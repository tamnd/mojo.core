"""Bessel functions. Go's `j0.go`, `j1.go` and `jn.go`.

`j0`, `j1`, `y0` and `y1` are the system library's, which has all four under
those names, with Go's special cases in front of the call. Those are not
decoration: `j1` is odd, so the system library hands back negative zero at
negative infinity, and Go's answer there is positive zero.

`jn` and `yn` are ported, because C's standard library does not have them
everywhere and where it does have them the answers disagree. They are also the
interesting half: the orders above one are reached by recurrence, and which
direction the recurrence runs decides whether the answer has any correct digits
in it. Upward is stable when the order is below the argument and ruinous when
it is above, so `jn` runs upward in the first case and, in the second, runs a
continued fraction downward from a guess and rescales by what `j0` should have
come out as. `yn` only ever runs upward, because for the second kind that is
the stable direction at every order.

This is FreeBSD's `e_jn.c` by way of Go, and Go's is already a simplification
of it. The comments Go keeps about how many terms the continued fraction needs
are kept here too, since they are the only record of where 1e9 came from.
"""

from std.math import j0 as _std_j0
from std.math import j1 as _std_j1
from std.math import y0 as _std_y0
from std.math import y1 as _std_y1

from .arith import sqrt
from .const import SQRT_PI
from .ieee import abs, float64frombits, inf, is_inf, is_nan, nan
from .log import log
from .trig import sincos

comptime _TWO_M29 = float64frombits(0x3E10000000000000)
"""2**-29, below which `jn` is its own first Taylor term."""

comptime _TWO302 = float64frombits(0x52D0000000000000)
"""2**302, above which both kinds are a phase shifted sine over a square root.
"""

comptime _OVERFLOW_LIMIT = 7.09782712893383973096e02
"""Where `log((2/x)**n * n!)` gets close enough to overflowing to matter.

The natural logarithm of the largest float64. Above it the backward recurrence
in `jn` needs rescaling as it goes, below it the values stay in range and the
rescaling can be skipped.
"""


def j0(x: Float64) -> Float64:
    """The order zero Bessel function of the first kind.

    Either infinity gives zero, since the function decays.
    """
    if is_nan(x):
        return x
    if is_inf(x, 0):
        return 0.0
    if x == 0:
        return 1.0
    return _std_j0(x)


def j1(x: Float64) -> Float64:
    """The order one Bessel function of the first kind. Same special cases as
    `j0`, except that the value at zero is zero rather than one.

    Go's answer at both infinities and at either zero is positive zero. The
    system library gives negative zero at negative infinity and at negative
    zero, the function being odd, so the special cases are answered here
    before it is asked.
    """
    if is_nan(x):
        return x
    if is_inf(x, 0) or x == 0:
        return 0.0
    return _std_j1(x)


def y0(x: Float64) -> Float64:
    """The order zero Bessel function of the second kind.

    Undefined below zero, so a negative argument is a not a number, and
    `y0(0.0)` is negative infinity.
    """
    if x < 0 or is_nan(x):
        return nan()
    if is_inf(x, 1):
        return 0.0
    if x == 0:
        return inf(-1)
    return _std_y0(x)


def y1(x: Float64) -> Float64:
    """The order one Bessel function of the second kind. Same special cases as
    `y0`."""
    if x < 0 or is_nan(x):
        return nan()
    if is_inf(x, 1):
        return 0.0
    if x == 0:
        return inf(-1)
    return _std_y1(x)


def jn(n: Int, x: Float64) -> Float64:
    """The order `n` Bessel function of the first kind.

    Negative orders are allowed: `jn(-n, x)` is `jn(n, -x)`, which is `jn(n, x)`
    with a sign for odd `n`. Either infinity gives zero.
    """
    if is_nan(x):
        return x
    if is_inf(x, 0):
        return 0.0

    if n == 0:
        return j0(x)
    if x == 0:
        return 0.0

    # J(-n, x) = (-1)**n * J(n, x) and J(n, -x) = (-1)**n * J(n, x), so
    # J(-n, x) = J(n, -x) and a negative order can be turned into a positive
    # one by flipping the argument instead.
    var order = n
    var v = x
    if order < 0:
        order = -order
        v = -v
    if order == 1:
        return j1(v)

    var sign = False
    if v < 0:
        v = -v
        if order & 1 == 1:
            sign = True

    var b: Float64
    if Float64(order) <= v:
        # The order is below the argument, so J(n+1,x) = 2n/x*J(n,x) - J(n-1,x)
        # can be run upward from `j0` and `j1` without losing everything.
        if v >= _TWO302:
            # So far out that the function is the asymptotic form and nothing
            # else. With s and c the sine and cosine of x, the four residues
            # of n modulo four give the four combinations below.
            var s, c = sincos(v)
            var quarter = order & 3
            var temp: Float64
            if quarter == 0:
                temp = c + s
            elif quarter == 1:
                temp = -c + s
            elif quarter == 2:
                temp = -c - s
            else:
                temp = c - s
            b = (1 / SQRT_PI) * temp / sqrt(v)
        else:
            var a = j0(v)
            b = j1(v)
            for i in range(1, order):
                var next = b * (Float64(i + i) / v) - a
                a = b
                b = next
    else:
        if v < _TWO_M29:
            # The argument is tiny, so the first term of the Taylor series,
            # (x/2)**n / n!, is the whole answer. Past order 33 that term is
            # already below the smallest float64 there is.
            if order > 33:
                b = 0.0
            else:
                var half = v * 0.5
                b = half
                var factorial = 1.0
                for i in range(2, order + 1):
                    factorial *= Float64(i)
                    b *= half
                b /= factorial
        else:
            # Backward recurrence, which is the stable direction here. The
            # ratio J(n,x)/J(n-1,x) is the continued fraction
            #
            #                      x      x**2      x**2
            #  J(n,x)/J(n-1,x) =  ----   ------   ------   .....
            #                      2n  - 2(n+1) - 2(n+2)
            #
            # and how many terms of it are needed is found by running its
            # denominators, Q(0) = w, Q(1) = w(w+h) - 1 and
            # Q(k) = (w+k*h)*Q(k-1) - Q(k-2), until one passes 1e9. That
            # threshold is for double precision; 1e4 would do for single and
            # 1e17 would be needed for quadruple.
            var w = Float64(order + order) / v
            var h = 2 / v
            var q0 = w
            var z = w + h
            var q1 = w * z - 1
            var k = 1
            while q1 < 1e9:
                k += 1
                z += h
                var next = z * q1 - q0
                q0 = q1
                q1 = next

            var t = 0.0
            var i = 2 * (order + k)
            while i >= order + order:
                t = 1 / (Float64(i) / v - t)
                i -= 2

            # Recur down from a supposed value of 1, then fix the scale by
            # what J(0,x) actually is against what this run says it is.
            var a = t
            b = 1.0
            var reach = Float64(order) * log(abs(2 / v * Float64(order)))
            if reach < _OVERFLOW_LIMIT:
                for j in range(order - 1, 0, -1):
                    var next = b * Float64(j + j) / v - a
                    a = b
                    b = next
            else:
                for j in range(order - 1, 0, -1):
                    var next = b * Float64(j + j) / v - a
                    a = b
                    b = next
                    # Pull everything back down before it overflows. The
                    # answer is a ratio, so scaling b and t together leaves it
                    # alone.
                    if b > 1e100:
                        a /= b
                        t /= b
                        b = 1.0
            b = t * j0(v) / b

    return -b if sign else b


def yn(n: Int, x: Float64) -> Float64:
    """The order `n` Bessel function of the second kind.

    Undefined below zero like `y0` is, so a negative argument is a not a
    number. At zero the answer is negative infinity, except that a negative odd
    order flips it to positive infinity.
    """
    if x < 0 or is_nan(x):
        return nan()
    if is_inf(x, 1):
        return 0.0

    if n == 0:
        return y0(x)
    if x == 0:
        if n < 0 and n & 1 == 1:
            return inf(1)
        return inf(-1)

    var order = n
    var sign = False
    if order < 0:
        order = -order
        if order & 1 == 1:
            sign = True
    if order == 1:
        return -y1(x) if sign else y1(x)

    var b: Float64
    if x >= _TWO302:
        # The asymptotic form, as in `jn`, with the other four combinations.
        var s, c = sincos(x)
        var quarter = order & 3
        var temp: Float64
        if quarter == 0:
            temp = s - c
        elif quarter == 1:
            temp = -s - c
        elif quarter == 2:
            temp = -s + c
        else:
            temp = s + c
        b = (1 / SQRT_PI) * temp / sqrt(x)
    else:
        # Upward is the stable direction for the second kind at every order,
        # so there is no continued fraction here. It stops early once the
        # recurrence has run off to negative infinity, since nothing after
        # that would be a number.
        var a = y0(x)
        b = y1(x)
        var i = 1
        while i < order and not is_inf(b, -1):
            var next = (Float64(i + i) / x) * b - a
            a = b
            b = next
            i += 1

    return -b if sign else b
