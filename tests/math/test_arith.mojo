"""Go's `TestSqrt`, `TestCbrt`, `TestHypot`, `TestFMA`, `TestRemainder`,
`TestFrexp`, `TestLdexp`, `TestNextafter32`, `TestNextafter64` and
`TestFloat32Sqrt`.

`frexp` and `ldexp` are the pair that carry the boundary tables, `vffrexpBC`
and `vfldexpBC`, which are the subnormal and overflow edges. Go runs `ldexp`
over `frexp`'s answers as well as over its own table, so the two are checked
against each other as well as against Go.

`hypot` is not tested against a table of answers at all. Go computes the
expected value as `abs(1e200 * tanh[i] * Sqrt(2))` and asks for the hypotenuse
of two equal sides, which is a value large enough that squaring either side
would overflow. An implementation that reaches for `sqrt(x*x + y*y)` returns
infinity for every row.

Go's `TestFMANegativeArgs` is not here. It runs the same function three more
times with signs flipped, to catch a compiler that has substituted a fused
multiply subtract instruction for one of them, and there is no second path
through `fma` in this package for it to be checking.
"""

from std.math import sqrt as _std_sqrt
from std.testing import assert_equal, assert_true

from core.math import (
    abs,
    cbrt,
    fma,
    frexp,
    hypot,
    is_nan,
    ldexp,
    nextafter,
    nextafter32,
    remainder,
    signbit,
    sqrt,
)

from tests.generated.math import (
    cbrt_rows,
    cbrt_sc_rows,
    fma_c_rows,
    fmod_sc_rows,
    frexp_bc_rows,
    frexp_rows,
    frexp_sc_rows,
    hypot_sc_rows,
    ldexp_bc_rows,
    ldexp_sc_rows,
    nextafter32_rows,
    nextafter32_sc_rows,
    nextafter64_rows,
    nextafter64_sc_rows,
    remainder_rows,
    sqrt32_rows,
    sqrt_rows,
    sqrt_sc_rows,
    tanh_rows,
    vf_rows,
    vfcbrt_sc_rows,
    vffmod_sc_rows,
    vffrexp_bc_rows,
    vffrexp_sc_rows,
    vfhypot_sc_rows,
    vfldexp_bc_rows,
    vfldexp_sc_rows,
    vfnextafter32_sc_rows,
    vfnextafter64_sc_rows,
    vfsqrt_sc_rows,
)

from ._fixtures import assert_alike, assert_veryclose


def test_sqrt() raises:
    var vf = vf_rows()
    var want = sqrt_rows()
    for i in range(len(vf)):
        var a = abs(vf[i])
        assert_alike(sqrt(a), want[i], "sqrt(" + String(a) + ")")

    var sc = vfsqrt_sc_rows()
    var sc_want = sqrt_sc_rows()
    for i in range(len(sc)):
        assert_alike(sqrt(sc[i]), sc_want[i], "sqrt(" + String(sc[i]) + ")")


def test_float32_sqrt() raises:
    # Go's `TestFloat32Sqrt` checks a compiler optimisation it has and this
    # does not: that a float64 square root narrowed to float32 is the float32
    # square root. There is only one `sqrt` here, so the test becomes a cross
    # check against the system library's float32 root, over the inputs Go
    # collected for being awkward.
    for v in sqrt32_rows():
        var want = _std_sqrt(v)
        var got = Float32(sqrt(Float64(v)))
        if is_nan(Float64(want)):
            assert_true(
                is_nan(Float64(got)),
                "sqrt(" + String(v) + ") = " + String(got) + ", want a nan",
            )
        else:
            assert_equal(got, want)


def test_cbrt() raises:
    var vf = vf_rows()
    var want = cbrt_rows()
    for i in range(len(vf)):
        assert_veryclose(cbrt(vf[i]), want[i], "cbrt(" + String(vf[i]) + ")")

    var sc = vfcbrt_sc_rows()
    var sc_want = cbrt_sc_rows()
    for i in range(len(sc)):
        assert_alike(cbrt(sc[i]), sc_want[i], "cbrt(" + String(sc[i]) + ")")


def test_hypot() raises:
    var tanh = tanh_rows()
    for i in range(len(tanh)):
        var side = 1e200 * tanh[i]
        var want = abs(side * sqrt(2.0))
        assert_veryclose(
            hypot(side, side),
            want,
            "hypot(" + String(side) + ", " + String(side) + ")",
        )

    var sc = vfhypot_sc_rows()
    var sc_want = hypot_sc_rows()
    for i in range(len(sc)):
        assert_alike(
            hypot(sc[i].a, sc[i].b),
            sc_want[i],
            "hypot(" + String(sc[i].a) + ", " + String(sc[i].b) + ")",
        )


def test_fma() raises:
    for row in fma_c_rows():
        assert_alike(
            fma(row.x, row.y, row.z),
            row.want,
            "fma("
            + String(row.x)
            + ", "
            + String(row.y)
            + ", "
            + String(row.z)
            + ")",
        )


def test_remainder() raises:
    var vf = vf_rows()
    var want = remainder_rows()
    for i in range(len(vf)):
        assert_alike(
            remainder(10, vf[i]),
            want[i],
            "remainder(10, " + String(vf[i]) + ")",
        )

    # `remainder` and `mod` agree on every special case, so Go runs the second
    # one's table through the first.
    var sc = vffmod_sc_rows()
    var sc_want = fmod_sc_rows()
    for i in range(len(sc)):
        assert_alike(
            remainder(sc[i].a, sc[i].b),
            sc_want[i],
            "remainder(" + String(sc[i].a) + ", " + String(sc[i].b) + ")",
        )


def test_remainder_keeps_its_precision_at_the_extremes() raises:
    assert_alike(
        remainder(5.9790119248836734e200, 1.1258465975523544),
        -0.4810497673014966,
        "remainder(5.9790119248836734e+200, 1.1258465975523544)",
    )


def test_remainder_of_a_zero_answer_has_the_sign_of_the_dividend() raises:
    # An exact division leaves a zero, and which zero it is comes from the
    # numerator and not from the denominator.
    for xi in range(0, 4):
        for yi in range(1, 4):
            var x = Float64(xi)
            var y = Float64(yi)
            _check_zero_sign(x, y)
            _check_zero_sign(x, -y)
            _check_zero_sign(-x, y)
            _check_zero_sign(-x, -y)


def _check_zero_sign(x: Float64, y: Float64) raises:
    var r = remainder(x, y)
    if r == 0:
        assert_equal(
            signbit(r),
            signbit(x),
            "remainder("
            + String(x)
            + ", "
            + String(y)
            + ") is a zero of the wrong sign",
        )


def test_frexp() raises:
    var vf = vf_rows()
    var want = frexp_rows()
    for i in range(len(vf)):
        var frac, exp = frexp(vf[i])
        var what = "frexp(" + String(vf[i]) + ")"
        assert_veryclose(frac, want[i].f, what + " fraction")
        assert_equal(exp, want[i].i, what + " exponent")

    var sc = vffrexp_sc_rows()
    var sc_want = frexp_sc_rows()
    for i in range(len(sc)):
        var frac, exp = frexp(sc[i])
        var what = "frexp(" + String(sc[i]) + ")"
        assert_alike(frac, sc_want[i].f, what + " fraction")
        assert_equal(exp, sc_want[i].i, what + " exponent")

    var bc = vffrexp_bc_rows()
    var bc_want = frexp_bc_rows()
    for i in range(len(bc)):
        var frac, exp = frexp(bc[i])
        var what = "frexp(" + String(bc[i]) + ")"
        assert_alike(frac, bc_want[i].f, what + " fraction")
        assert_equal(exp, bc_want[i].i, what + " exponent")


def test_ldexp() raises:
    # Run over `frexp`'s answers first, which asks that the two undo each
    # other, and then over `ldexp`'s own tables.
    var vf = vf_rows()
    var parts = frexp_rows()
    for i in range(len(vf)):
        assert_veryclose(
            ldexp(parts[i].f, parts[i].i),
            vf[i],
            "ldexp(" + String(parts[i].f) + ", " + String(parts[i].i) + ")",
        )

    var sc_in = vffrexp_sc_rows()
    var sc_parts = frexp_sc_rows()
    for i in range(len(sc_in)):
        assert_alike(
            ldexp(sc_parts[i].f, sc_parts[i].i),
            sc_in[i],
            "ldexp("
            + String(sc_parts[i].f)
            + ", "
            + String(sc_parts[i].i)
            + ")",
        )

    var sc = vfldexp_sc_rows()
    var sc_want = ldexp_sc_rows()
    for i in range(len(sc)):
        assert_alike(
            ldexp(sc[i].f, sc[i].i),
            sc_want[i],
            "ldexp(" + String(sc[i].f) + ", " + String(sc[i].i) + ")",
        )

    var bc_in = vffrexp_bc_rows()
    var bc_parts = frexp_bc_rows()
    for i in range(len(bc_in)):
        assert_alike(
            ldexp(bc_parts[i].f, bc_parts[i].i),
            bc_in[i],
            "ldexp("
            + String(bc_parts[i].f)
            + ", "
            + String(bc_parts[i].i)
            + ")",
        )

    var bc = vfldexp_bc_rows()
    var bc_want = ldexp_bc_rows()
    for i in range(len(bc)):
        assert_alike(
            ldexp(bc[i].f, bc[i].i),
            bc_want[i],
            "ldexp(" + String(bc[i].f) + ", " + String(bc[i].i) + ")",
        )


def test_nextafter32() raises:
    var vf = vf_rows()
    var want = nextafter32_rows()
    for i in range(len(vf)):
        var narrow = Float32(vf[i])
        assert_equal(
            nextafter32(narrow, 10),
            want[i],
            "nextafter32(" + String(narrow) + ", 10)",
        )

    var sc = vfnextafter32_sc_rows()
    var sc_want = nextafter32_sc_rows()
    for i in range(len(sc)):
        assert_alike(
            Float64(nextafter32(sc[i].a, sc[i].b)),
            Float64(sc_want[i]),
            "nextafter32(" + String(sc[i].a) + ", " + String(sc[i].b) + ")",
        )


def test_nextafter64() raises:
    var vf = vf_rows()
    var want = nextafter64_rows()
    for i in range(len(vf)):
        assert_alike(
            nextafter(vf[i], 10),
            want[i],
            "nextafter(" + String(vf[i]) + ", 10)",
        )

    var sc = vfnextafter64_sc_rows()
    var sc_want = nextafter64_sc_rows()
    for i in range(len(sc)):
        assert_alike(
            nextafter(sc[i].a, sc[i].b),
            sc_want[i],
            "nextafter(" + String(sc[i].a) + ", " + String(sc[i].b) + ")",
        )
