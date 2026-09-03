"""Go's `TestSinh`, `TestCosh`, `TestTanh`, `TestAsinh`, `TestAcosh` and
`TestAtanh`.

`sinh` and `cosh` get `close` from Go and the other four get `veryclose`, which
is Go allowing for the cancellation in `(exp(x) - exp(-x)) / 2` near zero.

`acosh` is the one whose inputs have to be moved: the function is undefined
below one, so Go feeds it `1 + abs(vf[i])`. `atanh` is fed `vf[i] / 10` for the
same reason, its domain being the open interval from minus one to one.
"""

from core.math import abs, acosh, asinh, atanh, cosh, sinh, tanh

from tests.generated.math import (
    acosh_rows,
    acosh_sc_rows,
    asinh_rows,
    asinh_sc_rows,
    atanh_rows,
    atanh_sc_rows,
    cosh_rows,
    cosh_sc_rows,
    sinh_rows,
    sinh_sc_rows,
    tanh_rows,
    tanh_sc_rows,
    vf_rows,
    vfacosh_sc_rows,
    vfasinh_sc_rows,
    vfatanh_sc_rows,
    vfcosh_sc_rows,
    vfsinh_sc_rows,
    vftanh_sc_rows,
)

from ._fixtures import assert_alike, assert_close, assert_veryclose


def test_sinh() raises:
    var vf = vf_rows()
    var want = sinh_rows()
    for i in range(len(vf)):
        assert_close(sinh(vf[i]), want[i], "sinh(" + String(vf[i]) + ")")

    var sc = vfsinh_sc_rows()
    var sc_want = sinh_sc_rows()
    for i in range(len(sc)):
        assert_alike(sinh(sc[i]), sc_want[i], "sinh(" + String(sc[i]) + ")")


def test_cosh() raises:
    var vf = vf_rows()
    var want = cosh_rows()
    for i in range(len(vf)):
        assert_close(cosh(vf[i]), want[i], "cosh(" + String(vf[i]) + ")")

    var sc = vfcosh_sc_rows()
    var sc_want = cosh_sc_rows()
    for i in range(len(sc)):
        assert_alike(cosh(sc[i]), sc_want[i], "cosh(" + String(sc[i]) + ")")


def test_tanh() raises:
    var vf = vf_rows()
    var want = tanh_rows()
    for i in range(len(vf)):
        assert_veryclose(tanh(vf[i]), want[i], "tanh(" + String(vf[i]) + ")")

    var sc = vftanh_sc_rows()
    var sc_want = tanh_sc_rows()
    for i in range(len(sc)):
        assert_alike(tanh(sc[i]), sc_want[i], "tanh(" + String(sc[i]) + ")")


def test_asinh() raises:
    var vf = vf_rows()
    var want = asinh_rows()
    for i in range(len(vf)):
        assert_veryclose(asinh(vf[i]), want[i], "asinh(" + String(vf[i]) + ")")

    var sc = vfasinh_sc_rows()
    var sc_want = asinh_sc_rows()
    for i in range(len(sc)):
        assert_alike(asinh(sc[i]), sc_want[i], "asinh(" + String(sc[i]) + ")")


def test_acosh() raises:
    var vf = vf_rows()
    var want = acosh_rows()
    for i in range(len(vf)):
        # Moved up to one, which is where the function starts.
        var a = 1 + abs(vf[i])
        assert_veryclose(acosh(a), want[i], "acosh(" + String(a) + ")")

    var sc = vfacosh_sc_rows()
    var sc_want = acosh_sc_rows()
    for i in range(len(sc)):
        assert_alike(acosh(sc[i]), sc_want[i], "acosh(" + String(sc[i]) + ")")


def test_atanh() raises:
    var vf = vf_rows()
    var want = atanh_rows()
    for i in range(len(vf)):
        var a = vf[i] / 10
        assert_veryclose(atanh(a), want[i], "atanh(" + String(a) + ")")

    var sc = vfatanh_sc_rows()
    var sc_want = atanh_sc_rows()
    for i in range(len(sc)):
        assert_alike(atanh(sc[i]), sc_want[i], "atanh(" + String(sc[i]) + ")")
