"""Go's `TestLog`, `TestLogb`, `TestLog10`, `TestLog1p`, `TestLog2` and
`TestIlogb`.

Go asks for `log` and `logb` bit for bit and allows the other three
`veryclose`, and it checks each of the three against the constant it should
reproduce: `log(10)` is `LN10`, `log10(E)` is `LOG10E`, `log2(E)` is `LOG2E`
and `log1p(9)` is `LN10` again. Those four are exact comparisons and they are
the reason `log2` is written the way it is rather than as `log(x) * LOG2E`.

`ilogb` has no table of its own over `vf`. Its answer is `frexp`'s exponent
less one, because `frexp` returns a fraction in [1/2, 1) and `ilogb` counts
from [1, 2), so Go derives the expected values from the `frexp` table.
"""

from std.testing import assert_equal

from core.math import (
    E,
    LN10,
    LOG2E,
    LOG10E,
    abs,
    ilogb,
    ldexp,
    log,
    log1p,
    log2,
    log10,
    logb,
)

from tests.generated.math import (
    frexp_rows,
    ilogb_sc_rows,
    log10_rows,
    log1p_rows,
    log1p_sc_rows,
    log2_rows,
    log_rows,
    log_sc_rows,
    logb_bc_rows,
    logb_rows,
    logb_sc_rows,
    vf_rows,
    vffrexp_bc_rows,
    vflog1p_sc_rows,
    vflog_sc_rows,
    vflogb_sc_rows,
)

from ._fixtures import assert_alike, assert_veryclose


def test_log() raises:
    var vf = vf_rows()
    var want = log_rows()
    for i in range(len(vf)):
        var a = abs(vf[i])
        assert_alike(log(a), want[i], "log(" + String(a) + ")")

    assert_alike(log(10), LN10, "log(10)")

    var sc = vflog_sc_rows()
    var sc_want = log_sc_rows()
    for i in range(len(sc)):
        assert_alike(log(sc[i]), sc_want[i], "log(" + String(sc[i]) + ")")


def test_logb() raises:
    var vf = vf_rows()
    var want = logb_rows()
    for i in range(len(vf)):
        assert_alike(logb(vf[i]), want[i], "logb(" + String(vf[i]) + ")")

    var sc = vflogb_sc_rows()
    var sc_want = logb_sc_rows()
    for i in range(len(sc)):
        assert_alike(logb(sc[i]), sc_want[i], "logb(" + String(sc[i]) + ")")

    var bc = vffrexp_bc_rows()
    var bc_want = logb_bc_rows()
    for i in range(len(bc)):
        assert_alike(logb(bc[i]), bc_want[i], "logb(" + String(bc[i]) + ")")


def test_log10() raises:
    var vf = vf_rows()
    var want = log10_rows()
    for i in range(len(vf)):
        var a = abs(vf[i])
        assert_veryclose(log10(a), want[i], "log10(" + String(a) + ")")

    assert_alike(log10(E), LOG10E, "log10(E)")

    var sc = vflog_sc_rows()
    var sc_want = log_sc_rows()
    for i in range(len(sc)):
        assert_alike(log10(sc[i]), sc_want[i], "log10(" + String(sc[i]) + ")")


def test_log1p() raises:
    var vf = vf_rows()
    var want = log1p_rows()
    for i in range(len(vf)):
        # Divided by a hundred, for the reason `expm1` divides by a hundred:
        # near zero is where `log(1 + x)` loses its digits and `log1p` is the
        # answer to that.
        var a = vf[i] / 100
        assert_veryclose(log1p(a), want[i], "log1p(" + String(a) + ")")

    assert_alike(log1p(9), LN10, "log1p(9)")

    var sc = vflog1p_sc_rows()
    var sc_want = log1p_sc_rows()
    for i in range(len(sc)):
        assert_alike(log1p(sc[i]), sc_want[i], "log1p(" + String(sc[i]) + ")")


def test_log2() raises:
    var vf = vf_rows()
    var want = log2_rows()
    for i in range(len(vf)):
        var a = abs(vf[i])
        assert_veryclose(log2(a), want[i], "log2(" + String(a) + ")")

    assert_alike(log2(E), LOG2E, "log2(E)")

    var sc = vflog_sc_rows()
    var sc_want = log_sc_rows()
    for i in range(len(sc)):
        assert_alike(log2(sc[i]), sc_want[i], "log2(" + String(sc[i]) + ")")


def test_log2_is_exact_at_every_power_of_two() raises:
    for i in range(-1074, 1024):
        assert_alike(
            log2(ldexp(1, i)),
            Float64(i),
            "log2(2**" + String(i) + ")",
        )


def test_ilogb() raises:
    var vf = vf_rows()
    var parts = frexp_rows()
    for i in range(len(vf)):
        assert_equal(
            ilogb(vf[i]),
            parts[i].i - 1,
            "ilogb(" + String(vf[i]) + ")",
        )

    var sc = vflogb_sc_rows()
    var sc_want = ilogb_sc_rows()
    for i in range(len(sc)):
        assert_equal(ilogb(sc[i]), sc_want[i], "ilogb(" + String(sc[i]) + ")")

    var bc = vffrexp_bc_rows()
    var bc_want = logb_bc_rows()
    for i in range(len(bc)):
        assert_equal(
            ilogb(bc[i]), Int(bc_want[i]), "ilogb(" + String(bc[i]) + ")"
        )
