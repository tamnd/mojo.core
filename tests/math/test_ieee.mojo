"""Go's `TestAbs`, `TestCopysign` and `TestSignbit`, and the bit level
functions the rest of the package is built on.

Go has no test of its own for `Float64bits`, `Inf` or `NaN`; they are exercised
by everything else and a failure in one of them would take the whole package
down with it. They get a short test here anyway, because in this port they are
the layer where a wrong answer would be quiet: `is_inf` compares against
`MAX_FLOAT64`, and `Float64.MAX` in Mojo is positive infinity rather than the
largest finite value, so writing that comparison the obvious way gives an
`is_inf` that is false for every input including infinity.
"""

from std.testing import assert_equal, assert_true

from core.math import (
    MAX_FLOAT64,
    SMALLEST_NONZERO_FLOAT64,
    abs,
    copysign,
    float32bits,
    float32frombits,
    float64bits,
    float64frombits,
    inf,
    is_inf,
    is_nan,
    nan,
    signbit,
)

from tests.generated.math import (
    copysign_rows,
    copysign_sc_rows,
    fabs_rows,
    fabs_sc_rows,
    signbit_rows,
    signbit_sc_rows,
    vf_rows,
    vfcopysign_sc_rows,
    vffabs_sc_rows,
    vfsignbit_sc_rows,
)

from ._fixtures import assert_alike


def test_abs() raises:
    var vf = vf_rows()
    var want = fabs_rows()
    for i in range(len(vf)):
        assert_alike(abs(vf[i]), want[i], "abs(" + String(vf[i]) + ")")

    var sc = vffabs_sc_rows()
    var sc_want = fabs_sc_rows()
    for i in range(len(sc)):
        assert_alike(abs(sc[i]), sc_want[i], "abs(" + String(sc[i]) + ")")


def test_copysign() raises:
    var vf = vf_rows()
    var want = copysign_rows()
    for i in range(len(vf)):
        # Go's table is the answer for a negative sign, so the positive case
        # is the same table negated rather than a second table.
        assert_alike(
            copysign(vf[i], -1), want[i], "copysign(" + String(vf[i]) + ", -1)"
        )
        assert_alike(
            copysign(vf[i], 1), -want[i], "copysign(" + String(vf[i]) + ", 1)"
        )

    var sc = vfcopysign_sc_rows()
    var sc_want = copysign_sc_rows()
    for i in range(len(sc)):
        assert_alike(
            copysign(sc[i], -1),
            sc_want[i],
            "copysign(" + String(sc[i]) + ", -1)",
        )


def test_signbit() raises:
    var vf = vf_rows()
    var want = signbit_rows()
    for i in range(len(vf)):
        assert_equal(signbit(vf[i]), want[i])

    var sc = vfsignbit_sc_rows()
    var sc_want = signbit_sc_rows()
    for i in range(len(sc)):
        assert_equal(signbit(sc[i]), sc_want[i])


def test_signbit_is_not_less_than_zero() raises:
    # The two inputs that separate the question `signbit` answers from the
    # question `x < 0` answers.
    assert_true(signbit(-0.0))
    assert_true(not (-0.0 < 0.0))
    assert_true(signbit(-nan()))
    assert_true(not (-nan() < 0.0))


def test_bits_round_trip() raises:
    var vf = vf_rows()
    for i in range(len(vf)):
        assert_alike(
            float64frombits(float64bits(vf[i])),
            vf[i],
            "float64frombits(float64bits(" + String(vf[i]) + "))",
        )
        var narrow = Float32(vf[i])
        assert_equal(float32frombits(float32bits(narrow)), narrow)

    # The patterns that are not numbers survive the trip as themselves, which
    # is the whole reason these functions exist rather than a cast.
    assert_equal(float64bits(nan()), 0x7FF8000000000001)
    assert_equal(float64bits(inf(1)), 0x7FF0000000000000)
    assert_equal(float64bits(inf(-1)), 0xFFF0000000000000)
    assert_equal(
        float64bits(float64frombits(0x7FF8000000000001)), 0x7FF8000000000001
    )


def test_is_nan_and_is_inf() raises:
    assert_true(is_nan(nan()))
    assert_true(is_nan(-nan()))
    assert_true(not is_nan(inf(1)))
    assert_true(not is_nan(0.0))

    assert_true(is_inf(inf(1), 1))
    assert_true(is_inf(inf(1), 0))
    assert_true(not is_inf(inf(1), -1))
    assert_true(is_inf(inf(-1), -1))
    assert_true(is_inf(inf(-1), 0))
    assert_true(not is_inf(inf(-1), 1))

    # The largest finite float64 is not an infinity, and neither is a not a
    # number. Both of these pass for an `is_inf` written against a
    # `MAX_FLOAT64` that is itself infinite, which is why the two below it are
    # here as well.
    assert_true(not is_inf(MAX_FLOAT64, 0))
    assert_true(not is_inf(-MAX_FLOAT64, 0))
    assert_true(not is_inf(nan(), 0))
    assert_true(not is_inf(SMALLEST_NONZERO_FLOAT64, 0))
