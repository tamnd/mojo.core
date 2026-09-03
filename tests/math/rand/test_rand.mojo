"""Go's distribution tests, table tests and small checks from `rand_test.go`.

Four kinds of thing live here. The distribution tests draw ten thousand samples
and ask whether the mean and the deviation are what the distribution promises,
which is the only way to test a sampler whose output is correct by definition.
The table tests recompute the ziggurat tables from the recurrence Go's test
uses and compare them to the ones in `tables.mojo`, which catches a table that
was transcribed wrong rather than merely one that is self consistent.
`test_uniform_factorial` is the strongest test in the package: it generates
permutations three different ways and checks that the chi squared statistic of
their distribution follows the normal distribution it should, which would catch
a bias that every golden output test in the tree would sail past.

The last kind is not Go's. Every place Go panics, this raises, and a raise is
behaviour a caller can rely on where a panic is not, so each one has a case.
See `docs/deviations.md`.

`test_float32` and the three heaviest cases are marked slow. Go's own versions
have the same problem and answer it with `testing.Short`, cutting `TestFloat32`
by a hundred and the factorial test from six down to three; the marker here
skips them outright on a local run and CI does the whole thing.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import matches
from core.errors.codes import ErrInvalidArgument
from core.math import exp, log, sqrt
from core.math.rand import n, new, new_pcg
from core.math.rand.tables import _FE, _FN, _KE, _KN, _RE, _RN, _WE, _WN

from tests.generated.rand import test_seeds_rows
from tests.math.rand._fixtures import (
    NUM_TEST_SAMPLES,
    Stats,
    assert_distribution,
    assert_slice_distributions,
    near_equal,
)


def _normal_samples(
    count: Int, mean: Float64, stddev: Float64, seed: UInt64
) -> List[Float64]:
    """`count` samples of the normal distribution with that mean and deviation.

    Go's `generateNormalSamples`. Both seed words are the same value, which is
    Go's `NewPCG(seed, seed)`.
    """
    var r = new(new_pcg(seed, seed))
    var out = List[Float64](capacity=count)
    for _ in range(count):
        out.append(r.norm_float64() * stddev + mean)
    return out^


def _check_normal(mean: Float64, stddev: Float64, seed: UInt64) raises:
    """Go's `testNormalDistribution`, whole then in halves then in sevenths."""
    var samples = _normal_samples(NUM_TEST_SAMPLES, mean, stddev, seed)
    var scale = max(1.0, stddev)
    var expected = Stats(mean, stddev, 0.10 * scale, 0.08 * scale)
    var what = (
        "normal mean "
        + String(mean)
        + " stddev "
        + String(stddev)
        + " seed "
        + String(seed)
    )
    assert_distribution(Span(samples), expected, what)
    assert_slice_distributions(Span(samples), 2, expected, what)
    assert_slice_distributions(Span(samples), 7, expected, what)


def _exponential_samples(
    count: Int, rate: Float64, seed: UInt64
) -> List[Float64]:
    """`count` samples of the exponential distribution with that rate. Go's
    `generateExponentialSamples`."""
    var r = new(new_pcg(seed, seed))
    var out = List[Float64](capacity=count)
    for _ in range(count):
        out.append(r.exp_float64() / rate)
    return out^


def _check_exponential(rate: Float64, seed: UInt64) raises:
    """Go's `testExponentialDistribution`. Mean and deviation are both `1 /
    rate`, which is the exponential distribution's whole shape."""
    var mean = 1 / rate
    var samples = _exponential_samples(NUM_TEST_SAMPLES, rate, seed)
    var scale = max(1.0, mean)
    var expected = Stats(mean, mean, 0.10 * scale, 0.20 * scale)
    var what = "exponential rate " + String(rate) + " seed " + String(seed)
    assert_distribution(Span(samples), expected, what)
    assert_slice_distributions(Span(samples), 2, expected, what)
    assert_slice_distributions(Span(samples), 7, expected, what)


def test_standard_normal_values() raises:
    for seed in test_seeds_rows():
        _check_normal(0, 1, seed)


# slow: eleven deviations by eleven means by four seeds, ten thousand samples
# each, which is nearly five million draws through the ziggurat
def test_non_standard_normal_values() raises:
    var stddev = 0.5
    while stddev < 1000.0:
        var mean = 0.5
        while mean < 1000.0:
            for seed in test_seeds_rows():
                _check_normal(mean, stddev, seed)
            mean *= 2
        stddev *= 2


def test_standard_exponential_values() raises:
    for seed in test_seeds_rows():
        _check_exponential(1, seed)


# slow: eight rates by four seeds, ten thousand samples each
def test_non_standard_exponential_values() raises:
    var rate = 0.05
    while rate < 10:
        for seed in test_seeds_rows():
            _check_exponential(rate, seed)
        rate *= 2


struct _Ziggurat(Movable):
    """The three tables one of the two recurrences below builds.

    A struct rather than a tuple because a `List` is not implicitly copyable
    and `var a, b, c = f()` wants to copy what it unpacks.
    """

    var k: List[UInt32]
    """How much of each strip can be accepted without any further work."""

    var w: List[Float32]
    """What scales an integer draw into a strip."""

    var f: List[Float32]
    """The density at each strip's corner."""

    def __init__(
        out self,
        var k: List[UInt32],
        var w: List[Float32],
        var f: List[Float32],
    ):
        """Take the three."""
        self.k = k^
        self.w = w^
        self.f = f^


def _init_norm() -> _Ziggurat:
    """The normal ziggurat tables, from the recurrence. Go's `initNorm`.

    `vn` is the area of one strip, worked out once by whoever chose 128 strips,
    and everything else follows from it and from `_RN`.
    """
    comptime m1 = Float64(1 << 31)
    var dn = Float64(_RN)
    var tn = dn
    var vn = 9.91256303526217e-3

    var k = List[UInt32](length=128, fill=0)
    var w = List[Float32](length=128, fill=0)
    var f = List[Float32](length=128, fill=0)

    var q = vn / exp(-0.5 * dn * dn)
    k[0] = UInt32(Int((dn / q) * m1))
    k[1] = 0
    w[0] = Float32(q / m1)
    w[127] = Float32(dn / m1)
    f[0] = 1.0
    f[127] = Float32(exp(-0.5 * dn * dn))
    for i in reversed(range(1, 127)):
        dn = sqrt(-2.0 * log(vn / dn + exp(-0.5 * dn * dn)))
        k[i + 1] = UInt32(Int((dn / tn) * m1))
        tn = dn
        f[i] = Float32(exp(-0.5 * dn * dn))
        w[i] = Float32(dn / m1)
    return _Ziggurat(k^, w^, f^)


def _init_exp() -> _Ziggurat:
    """The exponential ziggurat tables, from the recurrence. Go's `initExp`."""
    comptime m2 = Float64(1 << 32)
    var de = Float64(_RE)
    var te = de
    var ve = 3.9496598225815571993e-3

    var k = List[UInt32](length=256, fill=0)
    var w = List[Float32](length=256, fill=0)
    var f = List[Float32](length=256, fill=0)

    var q = ve / exp(-de)
    k[0] = UInt32(Int((de / q) * m2))
    k[1] = 0
    w[0] = Float32(q / m2)
    w[255] = Float32(de / m2)
    f[0] = 1.0
    f[255] = Float32(exp(-de))
    for i in reversed(range(1, 255)):
        de = -log(ve / de + exp(-de))
        k[i + 1] = UInt32(Int((de / te) * m2))
        te = de
        f[i] = Float32(exp(-de))
        w[i] = Float32(de / m2)
    return _Ziggurat(k^, w^, f^)


def _assert_near_float32(got: Float32, want: Float32, what: String) raises:
    """Go's `compareFloat32Slices`, which allows a relative 1e-7.

    Exact equality would be wrong here: the recurrence runs in double precision
    and rounds to single at the end, and two orderings of the same arithmetic
    can land one bit apart. Go allows the bit and so does this.
    """
    assert_true(
        near_equal(Float64(got), Float64(want), 0, 1e-7),
        what + ": " + String(got) + ", want " + String(want),
    )


def test_norm_tables() raises:
    var want = _init_norm()
    # Once each rather than inside the loop: a comptime table has to be
    # materialised before a run time index can reach it, and materialising it
    # a hundred and twenty eight times would be a hundred and twenty eight
    # copies of it.
    var k = materialize[_KN]()
    var w = materialize[_WN]()
    var f = materialize[_FN]()
    for i in range(128):
        assert_equal(k[i], want.k[i], "kn[" + String(i) + "]")
        _assert_near_float32(w[i], want.w[i], "wn[" + String(i) + "]")
        _assert_near_float32(f[i], want.f[i], "fn[" + String(i) + "]")


def test_exp_tables() raises:
    var want = _init_exp()
    var k = materialize[_KE]()
    var w = materialize[_WE]()
    var f = materialize[_FE]()
    for i in range(256):
        assert_equal(k[i], want.k[i], "ke[" + String(i) + "]")
        _assert_near_float32(w[i], want.w[i], "we[" + String(i) + "]")
        _assert_near_float32(f[i], want.f[i], "fe[" + String(i) + "]")


# slow: ten million draws, which is what Go's issue 6721 needed to reproduce
def test_float32_stays_below_one() raises:
    # Go's `TestFloat32`. The bug it is for came after seven and a half million
    # calls, so a smaller run proves nothing and there is no shorter version
    # worth having.
    var r = new(new_pcg(1, 2))
    for _ in range(10000000):
        var f = r.float32()
        if f >= 1:
            assert_true(False, "float32 returned " + String(f))


def test_shuffle_of_nothing_and_of_one_never_swaps() raises:
    # Go's `TestShuffleSmall`. Its swap calls `t.Fatalf`; a swap here cannot
    # raise, so it sets a flag and the test reads it afterwards.
    var r = new(new_pcg(1, 2))
    var called = False

    @parameter
    def swap(i: Int, j: Int):
        called = True

    r.shuffle[swap](0)
    assert_false(called, "shuffle of nothing called swap")
    r.shuffle[swap](1)
    assert_false(called, "shuffle of one called swap")


def _encode_perm(mut s: List[Int]) -> Int:
    """A permutation as a number in `[0, n!)`. Go's `encodePerm`.

    The Lehmer code: each element becomes how many of the elements after it are
    smaller, and the digits are then read in a factorial base. Two different
    permutations cannot encode to the same number, which is what makes counting
    the outputs a fair test of whether they are uniform. Modifies `s`, as Go's
    does.
    """
    for i in range(len(s)):
        var x = s[i]
        for j in range(i + 1, len(s)):
            if s[j] > x:
                s[j] -= 1
    var m = 0
    var fact = 1
    for i in reversed(range(len(s))):
        m += s[i] * fact
        fact *= len(s) - i
    return m


# slow: three ways of building a permutation, four sizes, and a thousand
# permutations per sample of a chi squared statistic that is itself sampled
# thousands of times
def test_uniform_factorial() raises:
    """Go's `TestUniformFactorial`.

    Three generators of a uniform value in `[0, n!)`, each measured by the chi
    squared statistic of a thousand draws, which for `n! - 1` degrees of
    freedom is approximately normal with mean `n! - 1` and deviation
    `sqrt(2 (n! - 1))`. A generator with a bias moves the mean.
    """
    var r = new(new_pcg(1, 2))
    for size in range(3, 7):
        var nfact = 1
        for i in range(2, size + 1):
            nfact *= i

        var samples = max(1000, 10 * nfact)
        var dof = Float64(nfact - 1)
        var stddev = sqrt(2 * dof)
        var expected = Stats(dof, stddev, 0.10 * max(1.0, stddev), 0.08)

        # Go names the three and runs them as subtests. Written out here, since
        # a list of function values would have to be dynamic and `shuffle`
        # takes its swap at compile time.
        var by_int32 = List[Float64](capacity=samples)
        for _ in range(samples):
            var counts = List[Int](length=nfact, fill=0)
            for _ in range(1000):
                counts[Int(r.int32_n(Int32(nfact)))] += 1
            by_int32.append(_chi_squared(counts, nfact))
        assert_distribution(
            Span(by_int32), expected, "int32_n n=" + String(size)
        )

        var by_perm = List[Float64](capacity=samples)
        for _ in range(samples):
            var counts = List[Int](length=nfact, fill=0)
            for _ in range(1000):
                var p = r.perm(size)
                counts[_encode_perm(p)] += 1
            by_perm.append(_chi_squared(counts, nfact))
        assert_distribution(Span(by_perm), expected, "perm n=" + String(size))

        var by_shuffle = List[Float64](capacity=samples)
        var p = List[Int](length=size, fill=0)

        @parameter
        def swap(i: Int, j: Int):
            var held = p[i]
            p[i] = p[j]
            p[j] = held

        for _ in range(samples):
            var counts = List[Int](length=nfact, fill=0)
            for _ in range(1000):
                for i in range(size):
                    p[i] = i
                r.shuffle[swap](size)
                counts[_encode_perm(p)] += 1
            by_shuffle.append(_chi_squared(counts, nfact))
        assert_distribution(
            Span(by_shuffle), expected, "shuffle n=" + String(size)
        )


def _chi_squared(counts: List[Int], nfact: Int) -> Float64:
    """Pearson's statistic for a thousand draws spread over `nfact` buckets."""
    var want = 1000 / Float64(nfact)
    var total = Float64(0)
    for have in counts:
        var off = Float64(have) - want
        total += off * off
    return total / want


def test_n() raises:
    # Go's `TestN`, over the default source rather than a seeded one, which is
    # the point: it is the only test that touches the per thread generator.
    for _ in range(1000):
        var v = n(10)
        assert_true(v >= 0 and v < 10, "n(10) returned " + String(v))


def test_a_bound_that_is_not_positive_raises() raises:
    # Go panics on every one of these. See docs/deviations.md.
    var r = new(new_pcg(1, 2))

    var raised = False
    try:
        _ = r.uint64_n(0)
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidArgument))
    assert_true(raised, "uint64_n(0)")

    raised = False
    try:
        _ = r.uint32_n(0)
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidArgument))
    assert_true(raised, "uint32_n(0)")

    raised = False
    try:
        _ = r.uint_n(0)
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidArgument))
    assert_true(raised, "uint_n(0)")

    raised = False
    try:
        _ = r.int64_n(0)
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidArgument))
    assert_true(raised, "int64_n(0)")

    raised = False
    try:
        _ = r.int32_n(-1)
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidArgument))
    assert_true(raised, "int32_n(-1)")

    raised = False
    try:
        _ = r.int_n(-1)
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidArgument))
    assert_true(raised, "int_n(-1)")


def test_a_negative_count_raises() raises:
    var r = new(new_pcg(1, 2))

    @parameter
    def swap(i: Int, j: Int):
        pass

    var raised = False
    try:
        r.shuffle[swap](-1)
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidArgument))
    assert_true(raised, "shuffle(-1)")

    raised = False
    try:
        _ = r.perm(-1)
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidArgument))
    assert_true(raised, "perm(-1)")


def test_the_top_level_n_raises_on_a_bound_that_is_not_positive() raises:
    var raised = False
    try:
        _ = n(0)
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidArgument))
    assert_true(raised, "n(0)")

    raised = False
    try:
        _ = n(UInt(0))
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidArgument))
    assert_true(raised, "n(UInt(0))")


def test_the_top_level_n_raises_on_a_type_that_is_not_an_integer() raises:
    # Go rules this out at compile time with a type constraint on the type
    # parameter. There is nothing to say that about a `DType`, so the check is
    # a `comptime if` that folds away for the ten types this is for and leaves
    # a function that raises for the rest. See docs/deviations.md.
    var raised = False
    try:
        _ = n(Float64(10))
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidArgument))
    assert_true(raised, "n(Float64(10))")
