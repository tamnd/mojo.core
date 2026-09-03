"""The comparisons Go's `math/cmplx` tests are written in terms of.

Go's `cmath_test.go` opens with a complex version of each of the comparisons
in `all_test.go`, and every test in the package is a loop whose body is one of
them. The float versions are imported from the `core.math` tests next door
rather than written again, because they are the same functions.

`c_tolerance` is relative to the modulus of the expected value, so a complex
answer is one number away from its expectation rather than two. It calls `abs`
from the package under test, which is what Go does as well.

`c_alike` is the interesting one. A special case answer that is a multiple of
pi is not bit for bit the same on every platform, so Go compares exactly only
where the expected value is exact, meaning a not a number, an infinity, a zero
or plus or minus one, and allows a couple of ulp everywhere else. `is_exact`
is that list.
"""

from std.complex import ComplexFloat64
from std.testing import assert_true

from core.math import is_inf, is_nan
from core.math.cmplx import abs

from tests.math._fixtures import alike, veryclose


def is_exact(x: Float64) -> Bool:
    """Whether `x` is a value the answer has to match bit for bit.

    Go's `isExact`. The rest are multiples of pi, which the last bit of is a
    property of the platform rather than of the implementation.
    """
    return is_nan(x) or is_inf(x, 0) or x == 0 or x == 1 or x == -1


def c_tolerance(a: ComplexFloat64, b: ComplexFloat64, e: Float64) -> Bool:
    """Whether `a` is within a relative `e` of the expected value `b`.

    Equal first, for the reason the float version is: the scaled tolerance
    underflows to zero for a subnormal expectation, and two values that are bit
    for bit the same should match whatever the tolerance does.
    """
    if a.re == b.re and a.im == b.im:
        return True
    var d = abs(a - b)
    var scaled = e
    if not (b.re == 0 and b.im == 0):
        scaled = e * abs(b)
        if scaled < 0:
            scaled = -scaled
    return d < scaled


def c_soclose(a: ComplexFloat64, b: ComplexFloat64, e: Float64) -> Bool:
    """Within a tolerance the caller picks. Go's `cSoclose`."""
    return c_tolerance(a, b, e)


def c_veryclose(a: ComplexFloat64, b: ComplexFloat64) -> Bool:
    """Within 4e-16 of the expected value `b`. About two ulp."""
    return c_tolerance(a, b, 4e-16)


def c_alike(a: ComplexFloat64, b: ComplexFloat64) -> Bool:
    """Whether `a` and `b` are the same answer. Go's `cAlike`.

    Exactly where the expected part is exact, within a couple of ulp where it
    is not.
    """
    var real_alike = veryclose(a.re, b.re)
    if is_exact(b.re):
        real_alike = alike(a.re, b.re)
    var imag_alike = veryclose(a.im, b.im)
    if is_exact(b.im):
        imag_alike = alike(a.im, b.im)
    return real_alike and imag_alike


def assert_c_alike(
    got: ComplexFloat64, want: ComplexFloat64, what: String
) raises:
    """`c_alike`, as an assertion that says what was asked and what came back.
    """
    assert_true(
        c_alike(got, want),
        what + " = " + String(got) + ", want " + String(want),
    )


def assert_c_symmetric(
    got: ComplexFloat64,
    want: ComplexFloat64,
    arg: ComplexFloat64,
    mirror: ComplexFloat64,
    what: String,
) raises:
    """One of the symmetries every special case table is checked for.

    Each special case loop in Go asks the function twice, once at the point and
    once at its reflection, and expects the two answers to be reflections of
    each other. The check passes when they are, and also when the point is its
    own reflection, since then the two calls are the same call and the equality
    is about nothing. `arg` and `mirror` are the point and its reflection,
    which is what that second condition is asked of.
    """
    assert_true(
        c_alike(got, want) or c_alike(arg, mirror),
        what + " = " + String(got) + ", want " + String(want),
    )


def assert_c_veryclose(
    got: ComplexFloat64, want: ComplexFloat64, what: String
) raises:
    """`c_veryclose`, as an assertion."""
    assert_true(
        c_veryclose(got, want),
        what + " = " + String(got) + ", want " + String(want),
    )


def assert_c_soclose(
    got: ComplexFloat64, want: ComplexFloat64, e: Float64, what: String
) raises:
    """`c_soclose`, as an assertion."""
    assert_true(
        c_soclose(got, want, e),
        what + " = " + String(got) + ", want " + String(want),
    )
