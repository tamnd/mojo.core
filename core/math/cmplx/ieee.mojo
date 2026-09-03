"""The complex infinity and the complex not a number. Go's `isinf.go` and
`isnan.go`.

`is_nan` is the one to read twice. A complex number with an infinity in one
part and a not a number in the other is not a not a number here, it is an
infinity, and the test for the infinity comes first for that reason. C99 Annex
G says so and Go follows it, because an infinite part swamps the other one in
every arithmetic operation and calling such a value a not a number would lose
the only information in it.
"""

from std.complex import ComplexFloat64

from core.math import inf as _inf
from core.math import is_inf as _is_inf
from core.math import is_nan as _is_nan
from core.math import nan as _nan


def is_inf(x: ComplexFloat64) -> Bool:
    """Whether either part of `x` is an infinity. Go's `IsInf`."""
    return _is_inf(x.re, 0) or _is_inf(x.im, 0)


def inf() -> ComplexFloat64:
    """A complex infinity, an infinity in both parts. Go's `Inf`."""
    var value = _inf(1)
    return ComplexFloat64(value, value)


def is_nan(x: ComplexFloat64) -> Bool:
    """Whether either part of `x` is a not a number and neither is an infinity.

    Go's `IsNaN`.
    """
    if _is_inf(x.re, 0) or _is_inf(x.im, 0):
        return False
    return _is_nan(x.re) or _is_nan(x.im)


def nan() -> ComplexFloat64:
    """A complex not a number, a not a number in both parts. Go's `NaN`."""
    var value = _nan()
    return ComplexFloat64(value, value)
