"""`core.math.rand.Zipf`, which Go's own test suite does not cover.

There is no `TestZipf` in Go, in either version of the package. `zipf.go` has
been in the standard library since 2011 and the only thing that has ever
checked it is the example in the documentation, which prints nothing that
depends on the arithmetic. So the golden values below were taken from Go
1.26.7 rather than from a Go test file: three parameter sets, twenty values
each, all from `new_pcg(3, 4)` so that the same uniform draws feed all three
and a difference between them is the parameters and nothing else.

The three sets are chosen to reach the parts of `uint64` that differ. `s = 2,
v = 1` is the ordinary case and the one the documentation uses. `s = 1.5` is
close enough to the bound that `1 / (1 - q)` is large and the inversion is
stretched, and `imax = 1000` lets a draw land far enough out to show it. `s =
3, v = 2.5` has a non integral `v`, a steep curve and a small `imax`, so most
draws are 0 or 1 and the rejection branch is reached often.

`test_zipf_has_the_right_shape` is the one test here that would notice a
generator that produced plausible looking values from the wrong distribution,
which is the failure a golden list cannot see when the golden list came from
the implementation's own ancestor.
"""

from std.testing import assert_equal, assert_true

from core.errors import matches
from core.errors.codes import ErrInvalidArgument
from core.math import abs
from core.math.rand import new, new_pcg, new_zipf

comptime DRAWS = 20
"""How many values each golden table holds."""


def _golden_s2_v1() -> List[UInt64]:
    """`new_zipf(new(new_pcg(3, 4)), 2, 1, 99)`, from Go 1.26.7."""
    return [
        UInt64(0),
        0,
        0,
        0,
        9,
        0,
        1,
        2,
        0,
        0,
        2,
        0,
        1,
        1,
        3,
        1,
        0,
        9,
        6,
        0,
    ]


def _golden_s15_v1() -> List[UInt64]:
    """`new_zipf(new(new_pcg(3, 4)), 1.5, 1, 1000)`, from Go 1.26.7."""
    return [
        UInt64(2),
        0,
        0,
        0,
        102,
        1,
        3,
        8,
        0,
        0,
        10,
        1,
        8,
        6,
        23,
        4,
        0,
        99,
        54,
        0,
    ]


def _golden_s3_v25() -> List[UInt64]:
    """`new_zipf(new(new_pcg(3, 4)), 3, 2.5, 10)`, from Go 1.26.7."""
    return [
        UInt64(1),
        0,
        0,
        0,
        5,
        0,
        1,
        2,
        0,
        0,
        2,
        0,
        2,
        1,
        3,
        1,
        0,
        5,
        4,
        0,
    ]


def _assert_golden(
    s: Float64, v: Float64, imax: UInt64, want: List[UInt64], what: String
) raises:
    """Fail unless a `Zipf` with those parameters produces `want`."""
    var z = new_zipf(new(new_pcg(3, 4)), s, v, imax)
    for i in range(len(want)):
        assert_equal(z.uint64(), want[i], what + " #" + String(i))


def test_zipf() raises:
    _assert_golden(2.0, 1.0, 99, _golden_s2_v1(), "s=2 v=1 imax=99")
    _assert_golden(1.5, 1.0, 1000, _golden_s15_v1(), "s=1.5 v=1 imax=1000")
    _assert_golden(3.0, 2.5, 10, _golden_s3_v25(), "s=3 v=2.5 imax=10")


def test_zipf_stays_within_its_bound() raises:
    # The bound is the whole promise of the type and the rejection loop is
    # where it could be broken, so this draws enough to reach that loop with a
    # small `imax`, where the continuous curve and the discrete distribution
    # are furthest apart.
    var z = new_zipf(new(new_pcg(7, 8)), 1.2, 1.0, 4)
    for i in range(10000):
        var got = z.uint64()
        assert_true(got <= 4, "draw #" + String(i) + " was " + String(got))


def test_zipf_has_the_right_shape() raises:
    # `P(k)` is proportional to `(v + k) ** -s`, so with `v = 1` and `s = 2`
    # the first three values should come out in the ratio 1 : 1/4 : 1/9. A
    # hundred thousand draws puts the sampling error on the commonest value
    # near a fifth of a percent, and the tolerance below is twenty times that,
    # so this fails on a wrong distribution and not on an unlucky seed.
    var z = new_zipf(new(new_pcg(5, 6)), 2.0, 1.0, 999)
    var counts = List[Int](length=3, fill=0)
    for _ in range(100000):
        var got = z.uint64()
        if got < 3:
            counts[Int(got)] += 1

    var zeros = Float64(counts[0])
    assert_true(
        abs(Float64(counts[1]) / zeros - 0.25) < 0.02,
        "P(1)/P(0) was " + String(Float64(counts[1]) / zeros) + ", want 0.25",
    )
    assert_true(
        abs(Float64(counts[2]) / zeros - 1.0 / 9.0) < 0.02,
        "P(2)/P(0) was "
        + String(Float64(counts[2]) / zeros)
        + ", want "
        + String(1.0 / 9.0),
    )


def test_zipf_rejects_parameters_it_cannot_draw_from() raises:
    # Go returns a nil `*Zipf` for all three of these and says so in a comment.
    # See docs/deviations.md.
    var ss = [1.0, 0.5, 2.0]
    var vs = [1.0, 1.0, 0.5]
    var names = [
        String("s exactly 1"),
        String("s below 1"),
        String("v below 1"),
    ]
    for i in range(len(ss)):
        var raised = False
        try:
            _ = new_zipf(new(new_pcg(1, 2)), ss[i], vs[i], 99)
        except e:
            raised = True
            assert_true(matches(e, ErrInvalidArgument), names[i])
        assert_true(raised, names[i] + " should be refused")
