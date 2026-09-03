"""Go's `TestAbs`, `TestConj`, `TestIsNaN`, `TestPolar` and `TestRect`.

The five that are geometry rather than analysis. None of them has a branch cut
to be continuous across or a symmetry to hold, so each is a table and a loop.

`TestRect` runs the polar table backwards: it takes the modulus and the phase
that `polar` was expected to produce and asks for the point they came from.
That makes it a round trip through two functions rather than a check of one,
which is Go's arrangement and is kept.
"""

from std.testing import assert_true

from core.math.cmplx import abs, conj, is_nan, polar, rect

from tests.generated.cmplx import (
    abs_rows,
    abs_sc_rows,
    conj_rows,
    conj_sc_rows,
    is_na_nsc_rows,
    polar_rows,
    polar_sc_rows,
    vc_abs_sc_rows,
    vc_conj_sc_rows,
    vc_is_na_nsc_rows,
    vc_polar_sc_rows,
    vc_rows,
)
from tests.math._fixtures import assert_alike, assert_veryclose
from tests.math.cmplx._fixtures import assert_c_alike, assert_c_veryclose


def test_abs() raises:
    var vc = vc_rows()
    var want = abs_rows()
    for i in range(len(vc)):
        assert_veryclose(abs(vc[i]), want[i], "abs(" + String(vc[i]) + ")")

    var sc = vc_abs_sc_rows()
    var sc_want = abs_sc_rows()
    for i in range(len(sc)):
        assert_alike(abs(sc[i]), sc_want[i], "abs(" + String(sc[i]) + ")")


def test_conj() raises:
    var vc = vc_rows()
    var want = conj_rows()
    for i in range(len(vc)):
        assert_c_veryclose(conj(vc[i]), want[i], "conj(" + String(vc[i]) + ")")

    var sc = vc_conj_sc_rows()
    var sc_want = conj_sc_rows()
    for i in range(len(sc)):
        assert_c_alike(conj(sc[i]), sc_want[i], "conj(" + String(sc[i]) + ")")


def test_is_nan() raises:
    var sc = vc_is_na_nsc_rows()
    var want = is_na_nsc_rows()
    for i in range(len(sc)):
        var got = is_nan(sc[i])
        assert_true(
            got == want[i],
            "is_nan("
            + String(sc[i])
            + ") = "
            + String(got)
            + ", want "
            + String(want[i]),
        )


def test_polar() raises:
    var vc = vc_rows()
    var want = polar_rows()
    for i in range(len(vc)):
        var r, theta = polar(vc[i])
        var what = "polar(" + String(vc[i]) + ")"
        assert_veryclose(r, want[i].r, what + " modulus")
        assert_veryclose(theta, want[i].theta, what + " phase")

    var sc = vc_polar_sc_rows()
    var sc_want = polar_sc_rows()
    for i in range(len(sc)):
        var r, theta = polar(sc[i])
        var what = "polar(" + String(sc[i]) + ")"
        assert_alike(r, sc_want[i].r, what + " modulus")
        assert_alike(theta, sc_want[i].theta, what + " phase")


def test_rect() raises:
    var vc = vc_rows()
    var p = polar_rows()
    for i in range(len(vc)):
        var what = "rect(" + String(p[i].r) + ", " + String(p[i].theta) + ")"
        assert_c_veryclose(rect(p[i].r, p[i].theta), vc[i], what)

    var sc = vc_polar_sc_rows()
    var sc_p = polar_sc_rows()
    for i in range(len(sc)):
        var what = (
            "rect(" + String(sc_p[i].r) + ", " + String(sc_p[i].theta) + ")"
        )
        assert_c_alike(rect(sc_p[i].r, sc_p[i].theta), sc[i], what)
