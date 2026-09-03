"""Go's `TestAsin`, `TestAsinh`, `TestAcos`, `TestAcosh`, `TestAtan` and
`TestAtanh`.

All six have branch cuts and all six get the continuity loop over
`branch_points`. Four of them are odd and get the negation symmetry as well;
`acos` and `acosh` are neither odd nor even, since `acos(-z)` is `pi - acos(z)`
rather than anything simpler, so Go checks only the conjugate symmetry for
those two and so does this.

The tolerance for `asin`, `acos` and `acosh` is 1e-14, which is loose next to
the rest of the package. Each is a logarithm of a square root of a difference,
and the difference is where the digits go: at an argument near one, `1 - z*z`
cancels almost everything before the root ever sees it.
"""

from core.math import is_nan as is_nan_float
from core.math.cmplx import acos, acosh, asin, asinh, atan, atanh, conj

from tests.generated.cmplx import (
    acos_rows,
    acos_sc_rows,
    acosh_rows,
    acosh_sc_rows,
    asin_rows,
    asin_sc_rows,
    asinh_rows,
    asinh_sc_rows,
    atan_rows,
    atan_sc_rows,
    atanh_rows,
    atanh_sc_rows,
    branch_points_rows,
    vc_rows,
)
from tests.math.cmplx._fixtures import (
    assert_c_alike,
    assert_c_soclose,
    assert_c_symmetric,
    assert_c_veryclose,
)


def test_asin() raises:
    var vc = vc_rows()
    var want = asin_rows()
    for i in range(len(vc)):
        assert_c_soclose(
            asin(vc[i]), want[i], 1e-14, "asin(" + String(vc[i]) + ")"
        )

    for row in asin_sc_rows():
        assert_c_alike(asin(row.arg), row.want, "asin(" + String(row.arg) + ")")
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            # Negating a not a number leaves the sign of the result up to the
            # platform, so the symmetries below are not statements about this
            # function.
            continue
        # asin(conj(z)) == conj(asin(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            asin(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "asin(" + String(mirror) + ")",
        )
        if is_nan_float(row.arg.re) or is_nan_float(row.want.re):
            continue
        # asin(-z) == -asin(z)
        assert_c_symmetric(
            asin(-row.arg),
            -row.want,
            row.arg,
            -row.arg,
            "asin(" + String(-row.arg) + ")",
        )

    for pt in branch_points_rows():
        assert_c_veryclose(
            asin(pt.a),
            asin(pt.b),
            "asin(" + String(pt.a) + "), across the cut",
        )


def test_asinh() raises:
    var vc = vc_rows()
    var want = asinh_rows()
    for i in range(len(vc)):
        assert_c_soclose(
            asinh(vc[i]), want[i], 4e-15, "asinh(" + String(vc[i]) + ")"
        )

    for row in asinh_sc_rows():
        assert_c_alike(
            asinh(row.arg), row.want, "asinh(" + String(row.arg) + ")"
        )
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            continue
        # asinh(conj(z)) == conj(asinh(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            asinh(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "asinh(" + String(mirror) + ")",
        )
        if is_nan_float(row.arg.re) or is_nan_float(row.want.re):
            continue
        # asinh(-z) == -asinh(z)
        assert_c_symmetric(
            asinh(-row.arg),
            -row.want,
            row.arg,
            -row.arg,
            "asinh(" + String(-row.arg) + ")",
        )

    for pt in branch_points_rows():
        assert_c_veryclose(
            asinh(pt.a),
            asinh(pt.b),
            "asinh(" + String(pt.a) + "), across the cut",
        )


def test_acos() raises:
    var vc = vc_rows()
    var want = acos_rows()
    for i in range(len(vc)):
        assert_c_soclose(
            acos(vc[i]), want[i], 1e-14, "acos(" + String(vc[i]) + ")"
        )

    for row in acos_sc_rows():
        assert_c_alike(acos(row.arg), row.want, "acos(" + String(row.arg) + ")")
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            continue
        # acos(conj(z)) == conj(acos(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            acos(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "acos(" + String(mirror) + ")",
        )

    for pt in branch_points_rows():
        assert_c_veryclose(
            acos(pt.a),
            acos(pt.b),
            "acos(" + String(pt.a) + "), across the cut",
        )


def test_acosh() raises:
    var vc = vc_rows()
    var want = acosh_rows()
    for i in range(len(vc)):
        assert_c_soclose(
            acosh(vc[i]), want[i], 1e-14, "acosh(" + String(vc[i]) + ")"
        )

    for row in acosh_sc_rows():
        assert_c_alike(
            acosh(row.arg), row.want, "acosh(" + String(row.arg) + ")"
        )
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            continue
        # acosh(conj(z)) == conj(acosh(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            acosh(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "acosh(" + String(mirror) + ")",
        )

    for pt in branch_points_rows():
        assert_c_veryclose(
            acosh(pt.a),
            acosh(pt.b),
            "acosh(" + String(pt.a) + "), across the cut",
        )


def test_atan() raises:
    var vc = vc_rows()
    var want = atan_rows()
    for i in range(len(vc)):
        assert_c_veryclose(atan(vc[i]), want[i], "atan(" + String(vc[i]) + ")")

    for row in atan_sc_rows():
        assert_c_alike(atan(row.arg), row.want, "atan(" + String(row.arg) + ")")
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            continue
        # atan(conj(z)) == conj(atan(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            atan(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "atan(" + String(mirror) + ")",
        )
        if is_nan_float(row.arg.re) or is_nan_float(row.want.re):
            continue
        # atan(-z) == -atan(z)
        assert_c_symmetric(
            atan(-row.arg),
            -row.want,
            row.arg,
            -row.arg,
            "atan(" + String(-row.arg) + ")",
        )

    for pt in branch_points_rows():
        assert_c_veryclose(
            atan(pt.a),
            atan(pt.b),
            "atan(" + String(pt.a) + "), across the cut",
        )


def test_atanh() raises:
    var vc = vc_rows()
    var want = atanh_rows()
    for i in range(len(vc)):
        assert_c_veryclose(
            atanh(vc[i]), want[i], "atanh(" + String(vc[i]) + ")"
        )

    for row in atanh_sc_rows():
        assert_c_alike(
            atanh(row.arg), row.want, "atanh(" + String(row.arg) + ")"
        )
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            continue
        # atanh(conj(z)) == conj(atanh(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            atanh(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "atanh(" + String(mirror) + ")",
        )
        if is_nan_float(row.arg.re) or is_nan_float(row.want.re):
            continue
        # atanh(-z) == -atanh(z)
        assert_c_symmetric(
            atanh(-row.arg),
            -row.want,
            row.arg,
            -row.arg,
            "atanh(" + String(-row.arg) + ")",
        )

    for pt in branch_points_rows():
        assert_c_veryclose(
            atanh(pt.a),
            atanh(pt.b),
            "atanh(" + String(pt.a) + "), across the cut",
        )
