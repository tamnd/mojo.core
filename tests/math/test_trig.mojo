"""Go's `TestSin`, `TestCos`, `TestTan`, `TestSincos`, `TestAsin`, `TestAcos`,
`TestAtan`, `TestAtan2`, the four large angle tests from `all_test.go` and the
four huge angle tests from `huge_test.go`.

The large and huge tests are the ones that matter. `sin(x)` for a large `x`
needs the argument reduced modulo pi over four to more bits than a float64
holds, so the answers are worked out to four thousand and ninety six bits
somewhere else and written down. Go's comment on the large tests is worth
repeating: testing `sin(x + large) == sin(x)` would prove nothing, because
`(x + large) - large` is not `x` at that size, so the expected values are for
the sum and not for `x`.

`TestTrigReduce` is not here. It reaches inside Go's package for `trigReduce`
and `reduceThreshold`, and the reduction under test is inside the system
library here rather than in this package. The huge angle tests cover the same
ground from the outside.

Go's `vfsinSC` serves `tan` as well as `sin`, since the two have the same
answers at the special values.
"""

from core.math import (
    PI,
    acos,
    asin,
    atan,
    atan2,
    cos,
    sin,
    sincos,
    tan,
)

from tests.generated.math import (
    acos_rows,
    acos_sc_rows,
    asin_rows,
    asin_sc_rows,
    atan2_rows,
    atan2_sc_rows,
    atan_rows,
    atan_sc_rows,
    cos_huge_rows,
    cos_large_rows,
    cos_rows,
    cos_sc_rows,
    sin_huge_rows,
    sin_large_rows,
    sin_rows,
    sin_sc_rows,
    tan_huge_rows,
    tan_large_rows,
    tan_rows,
    trig_huge_rows,
    vf_rows,
    vfacos_sc_rows,
    vfasin_sc_rows,
    vfatan2_sc_rows,
    vfatan_sc_rows,
    vfcos_sc_rows,
    vfsin_sc_rows,
)

from ._fixtures import assert_alike, assert_close, assert_veryclose

comptime _LARGE = 100000 * PI
"""The offset Go adds to every input in its large angle tests.

A multiple of two pi, so the answers are the ones for the input itself, except
that they are not, because the sum is not representable. That is the point.

Written as a product of two comptime values, which Mojo evaluates at arbitrary
precision and rounds once, exactly as Go's untyped `100000 * Pi` does.
Multiplying two float64s instead rounds twice and lands an ulp low, and an ulp
here is 6e-11, which is enough to move the fourth digit of the sine.
"""


def test_sin() raises:
    var vf = vf_rows()
    var want = sin_rows()
    for i in range(len(vf)):
        assert_veryclose(sin(vf[i]), want[i], "sin(" + String(vf[i]) + ")")

    var sc = vfsin_sc_rows()
    var sc_want = sin_sc_rows()
    for i in range(len(sc)):
        assert_alike(sin(sc[i]), sc_want[i], "sin(" + String(sc[i]) + ")")


def test_cos() raises:
    var vf = vf_rows()
    var want = cos_rows()
    for i in range(len(vf)):
        assert_veryclose(cos(vf[i]), want[i], "cos(" + String(vf[i]) + ")")

    var sc = vfcos_sc_rows()
    var sc_want = cos_sc_rows()
    for i in range(len(sc)):
        assert_alike(cos(sc[i]), sc_want[i], "cos(" + String(sc[i]) + ")")


def test_tan() raises:
    var vf = vf_rows()
    var want = tan_rows()
    for i in range(len(vf)):
        assert_veryclose(tan(vf[i]), want[i], "tan(" + String(vf[i]) + ")")

    var sc = vfsin_sc_rows()
    var sc_want = sin_sc_rows()
    for i in range(len(sc)):
        assert_alike(tan(sc[i]), sc_want[i], "tan(" + String(sc[i]) + ")")


def test_sincos() raises:
    var vf = vf_rows()
    var want_sin = sin_rows()
    var want_cos = cos_rows()
    for i in range(len(vf)):
        var s, c = sincos(vf[i])
        var what = "sincos(" + String(vf[i]) + ")"
        assert_veryclose(s, want_sin[i], what + " sine")
        assert_veryclose(c, want_cos[i], what + " cosine")


def test_asin() raises:
    var vf = vf_rows()
    var want = asin_rows()
    for i in range(len(vf)):
        # Divided by ten, to land inside the domain.
        var a = vf[i] / 10
        assert_veryclose(asin(a), want[i], "asin(" + String(a) + ")")

    var sc = vfasin_sc_rows()
    var sc_want = asin_sc_rows()
    for i in range(len(sc)):
        assert_alike(asin(sc[i]), sc_want[i], "asin(" + String(sc[i]) + ")")


def test_acos() raises:
    var vf = vf_rows()
    var want = acos_rows()
    for i in range(len(vf)):
        var a = vf[i] / 10
        assert_close(acos(a), want[i], "acos(" + String(a) + ")")

    var sc = vfacos_sc_rows()
    var sc_want = acos_sc_rows()
    for i in range(len(sc)):
        assert_alike(acos(sc[i]), sc_want[i], "acos(" + String(sc[i]) + ")")


def test_atan() raises:
    var vf = vf_rows()
    var want = atan_rows()
    for i in range(len(vf)):
        assert_veryclose(atan(vf[i]), want[i], "atan(" + String(vf[i]) + ")")

    var sc = vfatan_sc_rows()
    var sc_want = atan_sc_rows()
    for i in range(len(sc)):
        assert_alike(atan(sc[i]), sc_want[i], "atan(" + String(sc[i]) + ")")


def test_atan2() raises:
    var vf = vf_rows()
    var want = atan2_rows()
    for i in range(len(vf)):
        assert_veryclose(
            atan2(10, vf[i]), want[i], "atan2(10, " + String(vf[i]) + ")"
        )

    # Every combination of a sign, a zero and an infinity in both arguments,
    # which is where the quadrant is decided by the signs alone.
    var sc = vfatan2_sc_rows()
    var sc_want = atan2_sc_rows()
    for i in range(len(sc)):
        assert_alike(
            atan2(sc[i].a, sc[i].b),
            sc_want[i],
            "atan2(" + String(sc[i].a) + ", " + String(sc[i].b) + ")",
        )


def test_large_sin() raises:
    var vf = vf_rows()
    var want = sin_large_rows()
    for i in range(len(vf)):
        var a = vf[i] + _LARGE
        assert_close(sin(a), want[i], "sin(" + String(a) + ")")


def test_large_cos() raises:
    var vf = vf_rows()
    var want = cos_large_rows()
    for i in range(len(vf)):
        var a = vf[i] + _LARGE
        assert_close(cos(a), want[i], "cos(" + String(a) + ")")


def test_large_tan() raises:
    var vf = vf_rows()
    var want = tan_large_rows()
    for i in range(len(vf)):
        var a = vf[i] + _LARGE
        assert_close(tan(a), want[i], "tan(" + String(a) + ")")


def test_large_sincos() raises:
    var vf = vf_rows()
    var want_sin = sin_large_rows()
    var want_cos = cos_large_rows()
    for i in range(len(vf)):
        var a = vf[i] + _LARGE
        var s, c = sincos(a)
        var what = "sincos(" + String(a) + ")"
        assert_close(s, want_sin[i], what + " sine")
        assert_close(c, want_cos[i], what + " cosine")


def test_huge_sin() raises:
    var huge = trig_huge_rows()
    var want = sin_huge_rows()
    for i in range(len(huge)):
        assert_close(sin(huge[i]), want[i], "sin(" + String(huge[i]) + ")")
        assert_close(sin(-huge[i]), -want[i], "sin(" + String(-huge[i]) + ")")


def test_huge_cos() raises:
    var huge = trig_huge_rows()
    var want = cos_huge_rows()
    for i in range(len(huge)):
        assert_close(cos(huge[i]), want[i], "cos(" + String(huge[i]) + ")")
        assert_close(cos(-huge[i]), want[i], "cos(" + String(-huge[i]) + ")")


def test_huge_tan() raises:
    var huge = trig_huge_rows()
    var want = tan_huge_rows()
    for i in range(len(huge)):
        assert_close(tan(huge[i]), want[i], "tan(" + String(huge[i]) + ")")
        assert_close(tan(-huge[i]), -want[i], "tan(" + String(-huge[i]) + ")")


def test_huge_sincos() raises:
    var huge = trig_huge_rows()
    var want_sin = sin_huge_rows()
    var want_cos = cos_huge_rows()
    for i in range(len(huge)):
        var s, c = sincos(huge[i])
        var what = "sincos(" + String(huge[i]) + ")"
        assert_close(s, want_sin[i], what + " sine")
        assert_close(c, want_cos[i], what + " cosine")

        var ns, nc = sincos(-huge[i])
        var negated = "sincos(" + String(-huge[i]) + ")"
        assert_close(ns, -want_sin[i], negated + " sine")
        assert_close(nc, want_cos[i], negated + " cosine")
