"""Go's `TestSin`, `TestSinh`, `TestCos`, `TestCosh`, `TestTan`, `TestTanh`,
`TestInfiniteLoopIntanSeries` and `TestTanHuge`.

None of the six has a branch cut, so none of them has a continuity loop. What
they have instead is the second symmetry: the four odd functions are checked
for `f(-z) == -f(z)` and the two even ones for `f(-z) == f(z)`, on top of the
conjugate symmetry the whole package is checked for.

`test_cot_at_zero` is Go's test for issue 17577, where the series `tan` falls
back on for a small argument never terminated at zero. The answer is an
infinity and the point of the test is that there is an answer at all.

`test_tan_huge` is the reason `core.math.bits` is a dependency of this package.
The arguments are around 1e10 and larger, where reducing modulo pi in float64
has no correct digits left, so the reduction is done in three hundred and
twenty bits of an integer pi and the tolerance is still only 3e-15.
"""

from std.complex import ComplexFloat64

from core.math import is_nan as is_nan_float
from core.math.cmplx import conj, cos, cosh, cot, inf, sin, sinh, tan, tanh

from tests.generated.cmplx import (
    cos_rows,
    cos_sc_rows,
    cosh_rows,
    cosh_sc_rows,
    huge_in_rows,
    sin_rows,
    sin_sc_rows,
    sinh_rows,
    sinh_sc_rows,
    tan_huge_rows,
    tan_rows,
    tan_sc_rows,
    tanh_rows,
    tanh_sc_rows,
    vc_rows,
)
from tests.math.cmplx._fixtures import (
    assert_c_alike,
    assert_c_soclose,
    assert_c_symmetric,
)


def test_sin() raises:
    var vc = vc_rows()
    var want = sin_rows()
    for i in range(len(vc)):
        assert_c_soclose(
            sin(vc[i]), want[i], 2e-15, "sin(" + String(vc[i]) + ")"
        )

    for row in sin_sc_rows():
        assert_c_alike(sin(row.arg), row.want, "sin(" + String(row.arg) + ")")
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            # Negating a not a number leaves the sign of the result up to the
            # platform, so the symmetries below are not statements about this
            # function.
            continue
        # sin(conj(z)) == conj(sin(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            sin(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "sin(" + String(mirror) + ")",
        )
        if is_nan_float(row.arg.re) or is_nan_float(row.want.re):
            continue
        # sin(-z) == -sin(z)
        assert_c_symmetric(
            sin(-row.arg),
            -row.want,
            row.arg,
            -row.arg,
            "sin(" + String(-row.arg) + ")",
        )


def test_sinh() raises:
    var vc = vc_rows()
    var want = sinh_rows()
    for i in range(len(vc)):
        assert_c_soclose(
            sinh(vc[i]), want[i], 2e-15, "sinh(" + String(vc[i]) + ")"
        )

    for row in sinh_sc_rows():
        assert_c_alike(sinh(row.arg), row.want, "sinh(" + String(row.arg) + ")")
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            continue
        # sinh(conj(z)) == conj(sinh(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            sinh(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "sinh(" + String(mirror) + ")",
        )
        if is_nan_float(row.arg.re) or is_nan_float(row.want.re):
            continue
        # sinh(-z) == -sinh(z)
        assert_c_symmetric(
            sinh(-row.arg),
            -row.want,
            row.arg,
            -row.arg,
            "sinh(" + String(-row.arg) + ")",
        )


def test_cos() raises:
    var vc = vc_rows()
    var want = cos_rows()
    for i in range(len(vc)):
        assert_c_soclose(
            cos(vc[i]), want[i], 3e-15, "cos(" + String(vc[i]) + ")"
        )

    for row in cos_sc_rows():
        assert_c_alike(cos(row.arg), row.want, "cos(" + String(row.arg) + ")")
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            continue
        # cos(conj(z)) == conj(cos(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            cos(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "cos(" + String(mirror) + ")",
        )
        if is_nan_float(row.arg.re) or is_nan_float(row.want.re):
            continue
        # cos(-z) == cos(z), the even one.
        assert_c_symmetric(
            cos(-row.arg),
            row.want,
            row.arg,
            -row.arg,
            "cos(" + String(-row.arg) + ")",
        )


def test_cosh() raises:
    var vc = vc_rows()
    var want = cosh_rows()
    for i in range(len(vc)):
        assert_c_soclose(
            cosh(vc[i]), want[i], 2e-15, "cosh(" + String(vc[i]) + ")"
        )

    for row in cosh_sc_rows():
        assert_c_alike(cosh(row.arg), row.want, "cosh(" + String(row.arg) + ")")
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            continue
        # cosh(conj(z)) == conj(cosh(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            cosh(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "cosh(" + String(mirror) + ")",
        )
        if is_nan_float(row.arg.re) or is_nan_float(row.want.re):
            continue
        # cosh(-z) == cosh(z), the other even one.
        assert_c_symmetric(
            cosh(-row.arg),
            row.want,
            row.arg,
            -row.arg,
            "cosh(" + String(-row.arg) + ")",
        )


def test_tan() raises:
    var vc = vc_rows()
    var want = tan_rows()
    for i in range(len(vc)):
        assert_c_soclose(
            tan(vc[i]), want[i], 3e-15, "tan(" + String(vc[i]) + ")"
        )

    for row in tan_sc_rows():
        assert_c_alike(tan(row.arg), row.want, "tan(" + String(row.arg) + ")")
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            continue
        # tan(conj(z)) == conj(tan(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            tan(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "tan(" + String(mirror) + ")",
        )
        if is_nan_float(row.arg.re) or is_nan_float(row.want.re):
            continue
        # tan(-z) == -tan(z)
        assert_c_symmetric(
            tan(-row.arg),
            -row.want,
            row.arg,
            -row.arg,
            "tan(" + String(-row.arg) + ")",
        )


def test_tanh() raises:
    var vc = vc_rows()
    var want = tanh_rows()
    for i in range(len(vc)):
        assert_c_soclose(
            tanh(vc[i]), want[i], 2e-15, "tanh(" + String(vc[i]) + ")"
        )

    for row in tanh_sc_rows():
        assert_c_alike(tanh(row.arg), row.want, "tanh(" + String(row.arg) + ")")
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            continue
        # tanh(conj(z)) == conj(tanh(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            tanh(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "tanh(" + String(mirror) + ")",
        )
        if is_nan_float(row.arg.re) or is_nan_float(row.want.re):
            continue
        # tanh(-z) == -tanh(z)
        assert_c_symmetric(
            tanh(-row.arg),
            -row.want,
            row.arg,
            -row.arg,
            "tanh(" + String(-row.arg) + ")",
        )


def test_cot_at_zero() raises:
    """Go's `TestInfiniteLoopIntanSeries`, for issue 17577."""
    var zero = ComplexFloat64(0.0, 0.0)
    assert_c_alike(cot(zero), inf(), "cot(" + String(zero) + ")")


def test_tan_huge() raises:
    var huge = huge_in_rows()
    var want = tan_huge_rows()
    for i in range(len(huge)):
        assert_c_soclose(
            tan(huge[i]), want[i], 3e-15, "tan(" + String(huge[i]) + ")"
        )
