"""Go's `TestExp`, `TestExpm1`, `TestExp2`, `TestPow` and `TestPow10`.

Go runs each of `Exp` and `Exp2` twice, once over the assembly implementation
and once over `ExpGo` and `Exp2Go`, because on some architectures the two are
different code. There is one of each here.

The loop at the end of `test_exp2` is the one worth reading. It asks that
`exp2(n)` be exactly `ldexp(1, n)` for every representable power of two,
including the subnormal ones, which is two thousand and ninety eight exact
answers and is the test that says the argument reduction is right rather than
nearly right.
"""

from core.math import exp, exp2, expm1, ldexp, pow, pow10

from tests.generated.math import (
    exp2_rows,
    exp2_sc_rows,
    exp_rows,
    exp_sc_rows,
    expm1_large_rows,
    expm1_rows,
    expm1_sc_rows,
    pow10_sc_rows,
    pow_rows,
    pow_sc_rows,
    vf_rows,
    vfexp2_sc_rows,
    vfexp_sc_rows,
    vfexpm1_sc_rows,
    vfpow10_sc_rows,
    vfpow_sc_rows,
)

from ._fixtures import assert_alike, assert_close, assert_veryclose


def test_exp() raises:
    var vf = vf_rows()
    var want = exp_rows()
    for i in range(len(vf)):
        assert_veryclose(exp(vf[i]), want[i], "exp(" + String(vf[i]) + ")")

    var sc = vfexp_sc_rows()
    var sc_want = exp_sc_rows()
    for i in range(len(sc)):
        assert_alike(exp(sc[i]), sc_want[i], "exp(" + String(sc[i]) + ")")


def test_expm1() raises:
    var vf = vf_rows()
    var want = expm1_rows()
    for i in range(len(vf)):
        # Divided by a hundred, so that the answers are the small ones where
        # `exp(x) - 1` would lose most of its digits to cancellation and
        # `expm1` is worth having.
        var a = vf[i] / 100
        assert_veryclose(expm1(a), want[i], "expm1(" + String(a) + ")")

    var large = expm1_large_rows()
    for i in range(len(vf)):
        var a = vf[i] * 10
        assert_close(expm1(a), large[i], "expm1(" + String(a) + ")")

    var sc = vfexpm1_sc_rows()
    var sc_want = expm1_sc_rows()
    for i in range(len(sc)):
        assert_alike(expm1(sc[i]), sc_want[i], "expm1(" + String(sc[i]) + ")")


def test_exp2() raises:
    var vf = vf_rows()
    var want = exp2_rows()
    for i in range(len(vf)):
        assert_close(exp2(vf[i]), want[i], "exp2(" + String(vf[i]) + ")")

    var sc = vfexp2_sc_rows()
    var sc_want = exp2_sc_rows()
    for i in range(len(sc)):
        assert_alike(exp2(sc[i]), sc_want[i], "exp2(" + String(sc[i]) + ")")


def test_exp2_is_exact_at_every_power_of_two() raises:
    for n in range(-1074, 1024):
        assert_alike(
            exp2(Float64(n)),
            ldexp(1, n),
            "exp2(" + String(n) + ")",
        )


def test_pow() raises:
    var vf = vf_rows()
    var want = pow_rows()
    for i in range(len(vf)):
        assert_close(pow(10, vf[i]), want[i], "pow(10, " + String(vf[i]) + ")")

    # The largest special case table in the package. Every combination of a
    # sign, a zero, a one, an infinity, a not a number and an odd or even
    # integer exponent, because `pow` has to answer all of them without
    # reaching its general path.
    var sc = vfpow_sc_rows()
    var sc_want = pow_sc_rows()
    for i in range(len(sc)):
        assert_alike(
            pow(sc[i].a, sc[i].b),
            sc_want[i],
            "pow(" + String(sc[i].a) + ", " + String(sc[i].b) + ")",
        )


def test_pow10() raises:
    var sc = vfpow10_sc_rows()
    var sc_want = pow10_sc_rows()
    for i in range(len(sc)):
        assert_alike(pow10(sc[i]), sc_want[i], "pow10(" + String(sc[i]) + ")")
