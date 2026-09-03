"""Go's `TestGamma` and `TestLgamma`.

`gamma` gets a second table, `vfgamma`, that carries its own inputs and picks
its tolerance per row. Anything that lands on a special value is compared
exactly, the middle of the range gets `veryclose`, and outside minus fifty to a
hundred and seventy one it drops to `close`, because that is where the answers
are so large or so small that a couple of ulp in the argument moves the result
by more than that.

`lgamma` returns a sign as well as a value, and the sign is the half that is
ported rather than wrapped here: the system library keeps it in a global that a
call sets as a side effect, which is not something this package hands back.
The special case table is where that shows, since it is the only place the sign
is negative.
"""

from std.testing import assert_equal

from core.math import gamma, is_inf, is_nan, lgamma

from tests.generated.math import (
    gamma_rows,
    lgamma_rows,
    lgamma_sc_rows,
    vf_rows,
    vfgamma_rows,
    vflgamma_sc_rows,
)

from ._fixtures import assert_alike, assert_close, assert_veryclose


def test_gamma() raises:
    var vf = vf_rows()
    var want = gamma_rows()
    for i in range(len(vf)):
        assert_close(gamma(vf[i]), want[i], "gamma(" + String(vf[i]) + ")")

    for row in vfgamma_rows():
        var got = gamma(row.a)
        var what = "gamma(" + String(row.a) + ")"
        if is_nan(row.b) or is_inf(row.b, 0) or row.b == 0 or got == 0:
            assert_alike(got, row.b, what)
        elif row.a > -50 and row.a <= 171:
            assert_veryclose(got, row.b, what)
        else:
            assert_close(got, row.b, what)


def test_lgamma() raises:
    var vf = vf_rows()
    var want = lgamma_rows()
    for i in range(len(vf)):
        var value, sign = lgamma(vf[i])
        var what = "lgamma(" + String(vf[i]) + ")"
        assert_close(value, want[i].f, what + " value")
        assert_equal(sign, want[i].i, what + " sign")

    var sc = vflgamma_sc_rows()
    var sc_want = lgamma_sc_rows()
    for i in range(len(sc)):
        var value, sign = lgamma(sc[i])
        var what = "lgamma(" + String(sc[i]) + ")"
        assert_alike(value, sc_want[i].f, what + " value")
        assert_equal(sign, sc_want[i].i, what + " sign")
