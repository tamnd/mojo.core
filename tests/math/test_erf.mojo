"""Go's `TestErf`, `TestErfc`, `TestErfinv` and `TestErfcinv`.

The two inverses get a second kind of test on top of the tables: Go walks a
grid and asks that `erf(erfinv(x))` and `erfinv(erf(x))` both come back as `x`.
That is worth more here than it is in Go, because `erfinv` and `erfcinv` are
among the few functions in this package with no system library implementation
behind them at all. They are a rational approximation out of a statistics paper
and the round trip is the only check on it that does not come from Go's own
answers.

Go's grids step by 1e-2 from a float, so the values are not exactly the
hundredths they look like. The loops below accumulate the same way, so they
visit the same values.
"""

from core.math import erf, erfc, erfcinv, erfinv

from tests.generated.math import (
    erf_rows,
    erf_sc_rows,
    erfc_rows,
    erfc_sc_rows,
    erfcinv_sc_rows,
    erfinv_rows,
    erfinv_sc_rows,
    vf_rows,
    vferf_sc_rows,
    vferfc_sc_rows,
    vferfcinv_sc_rows,
    vferfinv_sc_rows,
)

from ._fixtures import assert_alike, assert_close, assert_veryclose


def test_erf() raises:
    var vf = vf_rows()
    var want = erf_rows()
    for i in range(len(vf)):
        var a = vf[i] / 10
        assert_veryclose(erf(a), want[i], "erf(" + String(a) + ")")

    var sc = vferf_sc_rows()
    var sc_want = erf_sc_rows()
    for i in range(len(sc)):
        assert_alike(erf(sc[i]), sc_want[i], "erf(" + String(sc[i]) + ")")


def test_erfc() raises:
    var vf = vf_rows()
    var want = erfc_rows()
    for i in range(len(vf)):
        var a = vf[i] / 10
        assert_veryclose(erfc(a), want[i], "erfc(" + String(a) + ")")

    var sc = vferfc_sc_rows()
    var sc_want = erfc_sc_rows()
    for i in range(len(sc)):
        assert_alike(erfc(sc[i]), sc_want[i], "erfc(" + String(sc[i]) + ")")


def test_erfinv() raises:
    var vf = vf_rows()
    var want = erfinv_rows()
    for i in range(len(vf)):
        var a = vf[i] / 10
        assert_veryclose(erfinv(a), want[i], "erfinv(" + String(a) + ")")

    var sc = vferfinv_sc_rows()
    var sc_want = erfinv_sc_rows()
    for i in range(len(sc)):
        assert_alike(erfinv(sc[i]), sc_want[i], "erfinv(" + String(sc[i]) + ")")


def test_erf_and_erfinv_undo_each_other() raises:
    var x = -0.9
    while x <= 0.90:
        assert_close(erf(erfinv(x)), x, "erf(erfinv(" + String(x) + "))")
        assert_close(erfinv(erf(x)), x, "erfinv(erf(" + String(x) + "))")
        x += 1e-2


def test_erfcinv() raises:
    var vf = vf_rows()
    # The answers are `erfinv`'s, because `erfcinv(1 - x)` is `erfinv(x)`, and
    # feeding it the complement is what checks that.
    var want = erfinv_rows()
    for i in range(len(vf)):
        var a = 1.0 - (vf[i] / 10)
        assert_veryclose(erfcinv(a), want[i], "erfcinv(" + String(a) + ")")

    var sc = vferfcinv_sc_rows()
    var sc_want = erfcinv_sc_rows()
    for i in range(len(sc)):
        assert_alike(
            erfcinv(sc[i]), sc_want[i], "erfcinv(" + String(sc[i]) + ")"
        )


def test_erfc_and_erfcinv_undo_each_other() raises:
    var x = 0.1
    while x <= 1.9:
        assert_close(erfc(erfcinv(x)), x, "erfc(erfcinv(" + String(x) + "))")
        assert_close(erfcinv(erfc(x)), x, "erfcinv(erfc(" + String(x) + "))")
        x += 1e-2
