"""Go's `TestJ0`, `TestJ1`, `TestJn`, `TestY0`, `TestY1` and `TestYn`.

`j0` and `y1` are the two Go does not trust to `close`. They get `soclose` with
tolerances of 4e-14 and 2e-14, which are looser than anything else in the
package, because both functions have zeros in the range being tested and an
answer near a zero has almost no significant digits left to agree on.

`jn` and `yn` are the ported ones, and the orders Go picks are two and minus
three: two goes through the recurrence, and a negative odd order goes through
it and then flips the sign, so between them the two cover the reflection rules
as well as the recurrences.
"""

from core.math import abs, inf, j0, j1, jn, y0, y1, yn

from tests.generated.math import (
    j0_rows,
    j0_sc_rows,
    j1_rows,
    j1_sc_rows,
    j2_rows,
    j2_sc_rows,
    j_m3_rows,
    j_m3_sc_rows,
    vf_rows,
    vfj0_sc_rows,
    vfy0_sc_rows,
    y0_rows,
    y0_sc_rows,
    y1_rows,
    y1_sc_rows,
    y2_rows,
    y2_sc_rows,
    y_m3_rows,
    y_m3_sc_rows,
)

from ._fixtures import assert_alike, assert_close, assert_soclose


def test_j0() raises:
    var vf = vf_rows()
    var want = j0_rows()
    for i in range(len(vf)):
        assert_soclose(j0(vf[i]), want[i], 4e-14, "j0(" + String(vf[i]) + ")")

    var sc = vfj0_sc_rows()
    var sc_want = j0_sc_rows()
    for i in range(len(sc)):
        assert_alike(j0(sc[i]), sc_want[i], "j0(" + String(sc[i]) + ")")


def test_j1() raises:
    var vf = vf_rows()
    var want = j1_rows()
    for i in range(len(vf)):
        assert_close(j1(vf[i]), want[i], "j1(" + String(vf[i]) + ")")

    var sc = vfj0_sc_rows()
    var sc_want = j1_sc_rows()
    for i in range(len(sc)):
        assert_alike(j1(sc[i]), sc_want[i], "j1(" + String(sc[i]) + ")")


def test_jn() raises:
    var vf = vf_rows()
    var want2 = j2_rows()
    var want_m3 = j_m3_rows()
    for i in range(len(vf)):
        assert_close(jn(2, vf[i]), want2[i], "jn(2, " + String(vf[i]) + ")")
        assert_close(jn(-3, vf[i]), want_m3[i], "jn(-3, " + String(vf[i]) + ")")

    var sc = vfj0_sc_rows()
    var sc_want2 = j2_sc_rows()
    var sc_want_m3 = j_m3_sc_rows()
    for i in range(len(sc)):
        assert_alike(jn(2, sc[i]), sc_want2[i], "jn(2, " + String(sc[i]) + ")")
        assert_alike(
            jn(-3, sc[i]), sc_want_m3[i], "jn(-3, " + String(sc[i]) + ")"
        )


def test_y0() raises:
    var vf = vf_rows()
    var want = y0_rows()
    for i in range(len(vf)):
        # The second kind is undefined below zero, so the inputs are folded.
        var a = abs(vf[i])
        assert_close(y0(a), want[i], "y0(" + String(a) + ")")

    var sc = vfy0_sc_rows()
    var sc_want = y0_sc_rows()
    for i in range(len(sc)):
        assert_alike(y0(sc[i]), sc_want[i], "y0(" + String(sc[i]) + ")")


def test_y1() raises:
    var vf = vf_rows()
    var want = y1_rows()
    for i in range(len(vf)):
        var a = abs(vf[i])
        assert_soclose(y1(a), want[i], 2e-14, "y1(" + String(a) + ")")

    var sc = vfy0_sc_rows()
    var sc_want = y1_sc_rows()
    for i in range(len(sc)):
        assert_alike(y1(sc[i]), sc_want[i], "y1(" + String(sc[i]) + ")")


def test_yn() raises:
    var vf = vf_rows()
    var want2 = y2_rows()
    var want_m3 = y_m3_rows()
    for i in range(len(vf)):
        var a = abs(vf[i])
        assert_close(yn(2, a), want2[i], "yn(2, " + String(a) + ")")
        assert_close(yn(-3, a), want_m3[i], "yn(-3, " + String(a) + ")")

    var sc = vfy0_sc_rows()
    var sc_want2 = y2_sc_rows()
    var sc_want_m3 = y_m3_sc_rows()
    for i in range(len(sc)):
        assert_alike(yn(2, sc[i]), sc_want2[i], "yn(2, " + String(sc[i]) + ")")
        assert_alike(
            yn(-3, sc[i]), sc_want_m3[i], "yn(-3, " + String(sc[i]) + ")"
        )

    assert_alike(yn(0, 0), inf(-1), "yn(0, 0)")
