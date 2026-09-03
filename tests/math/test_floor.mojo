"""Go's `TestCeil`, `TestFloor`, `TestTrunc`, `TestRound`, `TestRoundToEven`,
`TestModf`, `TestDim`, `TestMax`, `TestMin` and `TestMod`.

These are the functions whose answers are exact, so almost everything here is
`alike` rather than a tolerance. The exception is `modf`, where Go allows
`veryclose` on both halves.

Go's `vfceilSC` serves `ceil`, `floor` and `trunc` with three different answer
tables, which is why one input table appears in three tests. `dim`, `max` and
`min` share `vffdimSC` and `vffdim2SC`; the second is the first with the
argument pairs the other way round, and both are run against the same answers
because those three functions are each symmetric in a way the special values
are supposed to respect.
"""

from core.math import (
    ceil,
    dim,
    floor,
    max,
    min,
    mod,
    modf,
    round,
    round_to_even,
    trunc,
)

from tests.generated.math import (
    ceil_rows,
    ceil_sc_rows,
    fdim_rows,
    fdim_sc_rows,
    floor_rows,
    floor_sc_rows,
    fmax_sc_rows,
    fmin_sc_rows,
    fmod_rows,
    fmod_sc_rows,
    modf_rows,
    modf_sc_rows,
    round_rows,
    trunc_rows,
    trunc_sc_rows,
    vf_rows,
    vfceil_sc_rows,
    vffdim2_sc_rows,
    vffdim_sc_rows,
    vffmod_sc_rows,
    vfmodf_sc_rows,
    vfround_even_sc_rows,
    vfround_sc_rows,
)

from ._fixtures import assert_alike, assert_veryclose


def test_ceil() raises:
    var vf = vf_rows()
    var want = ceil_rows()
    for i in range(len(vf)):
        assert_alike(ceil(vf[i]), want[i], "ceil(" + String(vf[i]) + ")")

    var sc = vfceil_sc_rows()
    var sc_want = ceil_sc_rows()
    for i in range(len(sc)):
        assert_alike(ceil(sc[i]), sc_want[i], "ceil(" + String(sc[i]) + ")")


def test_floor() raises:
    var vf = vf_rows()
    var want = floor_rows()
    for i in range(len(vf)):
        assert_alike(floor(vf[i]), want[i], "floor(" + String(vf[i]) + ")")

    var sc = vfceil_sc_rows()
    var sc_want = floor_sc_rows()
    for i in range(len(sc)):
        assert_alike(floor(sc[i]), sc_want[i], "floor(" + String(sc[i]) + ")")


def test_trunc() raises:
    var vf = vf_rows()
    var want = trunc_rows()
    for i in range(len(vf)):
        assert_alike(trunc(vf[i]), want[i], "trunc(" + String(vf[i]) + ")")

    var sc = vfceil_sc_rows()
    var sc_want = trunc_sc_rows()
    for i in range(len(sc)):
        assert_alike(trunc(sc[i]), sc_want[i], "trunc(" + String(sc[i]) + ")")


def test_round() raises:
    var vf = vf_rows()
    var want = round_rows()
    for i in range(len(vf)):
        assert_alike(round(vf[i]), want[i], "round(" + String(vf[i]) + ")")

    # This table carries its own inputs, one pair to a row, because the
    # interesting cases are halves and the values either side of them rather
    # than anything in `vf`.
    for row in vfround_sc_rows():
        assert_alike(round(row.a), row.b, "round(" + String(row.a) + ")")


def test_round_to_even() raises:
    var vf = vf_rows()
    var want = round_rows()
    for i in range(len(vf)):
        # Nothing in `vf` is a half, so the two roundings agree there and Go
        # checks both against the one table.
        assert_alike(
            round_to_even(vf[i]),
            want[i],
            "round_to_even(" + String(vf[i]) + ")",
        )

    for row in vfround_even_sc_rows():
        assert_alike(
            round_to_even(row.a), row.b, "round_to_even(" + String(row.a) + ")"
        )


def test_modf() raises:
    var vf = vf_rows()
    var want = modf_rows()
    for i in range(len(vf)):
        var whole, frac = modf(vf[i])
        var what = "modf(" + String(vf[i]) + ")"
        assert_veryclose(whole, want[i].a, what + " whole part")
        assert_veryclose(frac, want[i].b, what + " fractional part")

    var sc = vfmodf_sc_rows()
    var sc_want = modf_sc_rows()
    for i in range(len(sc)):
        var whole, frac = modf(sc[i])
        var what = "modf(" + String(sc[i]) + ")"
        assert_alike(whole, sc_want[i].a, what + " whole part")
        assert_alike(frac, sc_want[i].b, what + " fractional part")


def test_dim() raises:
    var vf = vf_rows()
    var want = fdim_rows()
    for i in range(len(vf)):
        assert_alike(dim(vf[i], 0), want[i], "dim(" + String(vf[i]) + ", 0)")

    var sc_want = fdim_sc_rows()
    var sc = vffdim_sc_rows()
    for i in range(len(sc)):
        assert_alike(
            dim(sc[i].a, sc[i].b),
            sc_want[i],
            "dim(" + String(sc[i].a) + ", " + String(sc[i].b) + ")",
        )

    var sc2 = vffdim2_sc_rows()
    for i in range(len(sc2)):
        assert_alike(
            dim(sc2[i].a, sc2[i].b),
            sc_want[i],
            "dim(" + String(sc2[i].a) + ", " + String(sc2[i].b) + ")",
        )


def test_max() raises:
    var vf = vf_rows()
    var ceiling = ceil_rows()
    for i in range(len(vf)):
        # The ceiling of a value is never below it, so it is the answer.
        assert_alike(
            max(vf[i], ceiling[i]),
            ceiling[i],
            "max(" + String(vf[i]) + ", " + String(ceiling[i]) + ")",
        )

    var sc_want = fmax_sc_rows()
    var sc = vffdim_sc_rows()
    for i in range(len(sc)):
        assert_alike(
            max(sc[i].a, sc[i].b),
            sc_want[i],
            "max(" + String(sc[i].a) + ", " + String(sc[i].b) + ")",
        )

    var sc2 = vffdim2_sc_rows()
    for i in range(len(sc2)):
        assert_alike(
            max(sc2[i].a, sc2[i].b),
            sc_want[i],
            "max(" + String(sc2[i].a) + ", " + String(sc2[i].b) + ")",
        )


def test_min() raises:
    var vf = vf_rows()
    var flooring = floor_rows()
    for i in range(len(vf)):
        assert_alike(
            min(vf[i], flooring[i]),
            flooring[i],
            "min(" + String(vf[i]) + ", " + String(flooring[i]) + ")",
        )

    var sc_want = fmin_sc_rows()
    var sc = vffdim_sc_rows()
    for i in range(len(sc)):
        assert_alike(
            min(sc[i].a, sc[i].b),
            sc_want[i],
            "min(" + String(sc[i].a) + ", " + String(sc[i].b) + ")",
        )

    var sc2 = vffdim2_sc_rows()
    for i in range(len(sc2)):
        assert_alike(
            min(sc2[i].a, sc2[i].b),
            sc_want[i],
            "min(" + String(sc2[i].a) + ", " + String(sc2[i].b) + ")",
        )


def test_mod() raises:
    var vf = vf_rows()
    var want = fmod_rows()
    for i in range(len(vf)):
        assert_alike(mod(10, vf[i]), want[i], "mod(10, " + String(vf[i]) + ")")

    var sc = vffmod_sc_rows()
    var sc_want = fmod_sc_rows()
    for i in range(len(sc)):
        assert_alike(
            mod(sc[i].a, sc[i].b),
            sc_want[i],
            "mod(" + String(sc[i].a) + ", " + String(sc[i].b) + ")",
        )


def test_mod_keeps_its_precision_at_the_extremes() raises:
    # Go's one hand written case. Two hundred orders of magnitude apart, so an
    # implementation that subtracts a multiple of the divisor rather than
    # working on exponents has lost every digit by the time it gets here.
    assert_alike(
        mod(5.9790119248836734e200, 1.1258465975523544),
        0.6447968302508578,
        "mod(5.9790119248836734e+200, 1.1258465975523544)",
    )
