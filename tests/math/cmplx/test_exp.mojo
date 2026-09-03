"""Go's `TestExp`, `TestLog`, `TestLog10`, `TestPow` and `TestSqrt`.

Each is three loops. The first walks the general table at the tolerance Go
gives that function. The second walks the special cases with `assert_c_alike`
and then asks for the conjugate symmetry, `f(conj(z)) == conj(f(z))`, which
holds for all five of these because each is real on the real axis. The third
walks `branch_points`, which are pairs of points either side of a cut, and
asks that the two answers agree: the cut is where the function is defined by
which side the argument arrived from, and the test is that approaching it from
the two sides gives the same answer at the point itself.

`test_pow` opens with the four cases Go documents for `pow(0, y)`, which are
compared exactly rather than closely, because a documented answer of one is
one and not nearly one.
"""

from std.complex import ComplexFloat64
from std.testing import assert_true

from core.math import inf as inf_float
from core.math import is_nan as is_nan_float
from core.math.cmplx import conj, exp, inf, log, log10, pow, sqrt

from tests.generated.cmplx import (
    branch_points_rows,
    exp_rows,
    exp_sc_rows,
    log10_rows,
    log10_sc_rows,
    log_rows,
    log_sc_rows,
    pow_rows,
    pow_sc_rows,
    sqrt_rows,
    sqrt_sc_rows,
    vc_pow_sc_rows,
    vc_rows,
)
from tests.math.cmplx._fixtures import (
    assert_c_alike,
    assert_c_soclose,
    assert_c_symmetric,
    assert_c_veryclose,
)


def test_exp() raises:
    var vc = vc_rows()
    var want = exp_rows()
    for i in range(len(vc)):
        assert_c_soclose(
            exp(vc[i]), want[i], 1e-15, "exp(" + String(vc[i]) + ")"
        )

    for row in exp_sc_rows():
        assert_c_alike(exp(row.arg), row.want, "exp(" + String(row.arg) + ")")
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            # Negating a not a number leaves the sign of the result up to the
            # platform, so the symmetry below is not a statement about this
            # function.
            continue
        # exp(conj(z)) == conj(exp(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            exp(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "exp(" + String(mirror) + ")",
        )


def test_log() raises:
    var vc = vc_rows()
    var want = log_rows()
    for i in range(len(vc)):
        assert_c_veryclose(log(vc[i]), want[i], "log(" + String(vc[i]) + ")")

    for row in log_sc_rows():
        assert_c_alike(log(row.arg), row.want, "log(" + String(row.arg) + ")")
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            continue
        # log(conj(z)) == conj(log(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            log(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "log(" + String(mirror) + ")",
        )

    for pt in branch_points_rows():
        assert_c_veryclose(
            log(pt.a), log(pt.b), "log(" + String(pt.a) + "), across the cut"
        )


def test_log10() raises:
    var vc = vc_rows()
    var want = log10_rows()
    for i in range(len(vc)):
        assert_c_veryclose(
            log10(vc[i]), want[i], "log10(" + String(vc[i]) + ")"
        )

    for row in log10_sc_rows():
        assert_c_alike(
            log10(row.arg), row.want, "log10(" + String(row.arg) + ")"
        )
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            continue
        # log10(conj(z)) == conj(log10(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            log10(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "log10(" + String(mirror) + ")",
        )


def test_pow() raises:
    # The four answers Go's documentation promises for a zero base, exact.
    var zero = ComplexFloat64(0.0, 0.0)
    var exponents: List[ComplexFloat64] = [
        ComplexFloat64(0.0, 0.0),
        ComplexFloat64(1.5, 0.0),
        ComplexFloat64(-1.5, 0.0),
        ComplexFloat64(-1.5, 1.5),
    ]
    var promised: List[ComplexFloat64] = [
        ComplexFloat64(1.0, 0.0),
        ComplexFloat64(0.0, 0.0),
        ComplexFloat64(inf_float(1), 0.0),
        inf(),
    ]
    for i in range(len(exponents)):
        var got = pow(zero, exponents[i])
        assert_true(
            got.re == promised[i].re and got.im == promised[i].im,
            "pow("
            + String(zero)
            + ", "
            + String(exponents[i])
            + ") = "
            + String(got)
            + ", want "
            + String(promised[i]),
        )

    var a = ComplexFloat64(3.0, 3.0)
    var vc = vc_rows()
    var want = pow_rows()
    for i in range(len(vc)):
        assert_c_soclose(
            pow(a, vc[i]),
            want[i],
            4e-15,
            "pow(" + String(a) + ", " + String(vc[i]) + ")",
        )

    var sc = vc_pow_sc_rows()
    var sc_want = pow_sc_rows()
    for i in range(len(sc)):
        assert_c_alike(
            pow(sc[i].a, sc[i].b),
            sc_want[i],
            "pow(" + String(sc[i].a) + ", " + String(sc[i].b) + ")",
        )

    # A tenth is not a power that simplifies, so it is a power that notices
    # which side of the cut the base was on.
    var tenth = ComplexFloat64(0.1, 0.0)
    for pt in branch_points_rows():
        assert_c_veryclose(
            pow(pt.a, tenth),
            pow(pt.b, tenth),
            "pow(" + String(pt.a) + ", 0.1), across the cut",
        )


def test_sqrt() raises:
    var vc = vc_rows()
    var want = sqrt_rows()
    for i in range(len(vc)):
        assert_c_veryclose(sqrt(vc[i]), want[i], "sqrt(" + String(vc[i]) + ")")

    for row in sqrt_sc_rows():
        assert_c_alike(sqrt(row.arg), row.want, "sqrt(" + String(row.arg) + ")")
        if is_nan_float(row.arg.im) or is_nan_float(row.want.im):
            continue
        # sqrt(conj(z)) == conj(sqrt(z))
        var mirror = conj(row.arg)
        assert_c_symmetric(
            sqrt(mirror),
            conj(row.want),
            row.arg,
            mirror,
            "sqrt(" + String(mirror) + ")",
        )

    for pt in branch_points_rows():
        assert_c_veryclose(
            sqrt(pt.a), sqrt(pt.b), "sqrt(" + String(pt.a) + "), across the cut"
        )
