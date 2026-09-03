"""The statistics Go's `math/rand/v2` tests are written in terms of.

Half of that package's tests draw ten thousand samples and ask whether the mean
and the standard deviation are near enough the ones the distribution promises.
Go's `rand_test.go` opens with `nearEqual`, `statsResults` and three helpers
built on them, and every distribution test in the file is one of those helpers
over a table of seeds. They are here rather than in a test file because three
test files want them.

`near_equal` takes two tolerances and not one. The absolute one is there for
the case Go's comment names: a mean that should be zero, where a relative
tolerance is meaningless because the value it would be relative to is zero. The
relative one is against the larger of the two magnitudes, so it is symmetric in
its arguments, which a tolerance relative to the expected value is not.

`assert_slice_distributions` checks each of `slices` consecutive chunks
separately. A generator whose output drifts, or that repeats after a while,
passes a check on the whole run and fails this one, which is the reason Go
bothers with it. The last chunk stops one short of the end, which is Go's
arithmetic and is kept so that the two run over the same samples.
"""

from std.testing import assert_true

from core.math import abs, sqrt

from tests.generated.rand import chacha8seed_rows

comptime NUM_TEST_SAMPLES = 10000
"""How many samples a distribution test draws. Go's `numTestSamples`."""


def near_equal(
    a: Float64, b: Float64, close_enough: Float64, max_error: Float64
) -> Bool:
    """Whether `a` and `b` agree. Go's `nearEqual`.

    Absolutely within `close_enough`, or relatively within `max_error` of the
    larger of the two.
    """
    var gap = abs(a - b)
    if gap < close_enough:
        return True
    return gap / max(abs(a), abs(b)) < max_error


struct Stats(Copyable, Movable):
    """A distribution to check a sample against. Go's `statsResults`."""

    var mean: Float64
    """The mean the samples should have."""

    var stddev: Float64
    """The standard deviation they should have."""

    var close_enough: Float64
    """How far off either may be in absolute terms."""

    var max_error: Float64
    """How far off either may be relative to the larger magnitude."""

    def __init__(
        out self,
        mean: Float64,
        stddev: Float64,
        close_enough: Float64,
        max_error: Float64,
    ):
        """Hold the four numbers."""
        self.mean = mean
        self.stddev = stddev
        self.close_enough = close_enough
        self.max_error = max_error


def moments[o: ImmOrigin](samples: Span[Float64, o]) -> Tuple[Float64, Float64]:
    """The mean and the standard deviation of `samples`. Go's
    `getStatsResults`.

    The deviation comes from the mean of the squares less the square of the
    mean, which is one pass rather than two and is what Go does. It is the
    numerically worse of the two ways to compute it, and it is kept because a
    test that disagreed with Go's about what a sample's deviation is would be
    checking a different thing.
    """
    var total = Float64(0)
    var squares = Float64(0)
    for s in samples:
        total += s
        squares += s * s
    var mean = total / Float64(len(samples))
    return (mean, sqrt(squares / Float64(len(samples)) - mean * mean))


def assert_distribution[
    o: ImmOrigin
](samples: Span[Float64, o], expected: Stats, what: String) raises:
    """Fail unless the samples have the mean and deviation `expected` says.

    Go's `checkSampleDistribution` with its `checkSimilarDistribution`
    folded in, since nothing else calls either of them.
    """
    var mean, stddev = moments(samples)
    assert_true(
        near_equal(
            mean, expected.mean, expected.close_enough, expected.max_error
        ),
        what + ": mean " + String(mean) + ", want " + String(expected.mean),
    )
    assert_true(
        near_equal(
            stddev, expected.stddev, expected.close_enough, expected.max_error
        ),
        what
        + ": stddev "
        + String(stddev)
        + ", want "
        + String(expected.stddev),
    )


def assert_slice_distributions[
    o: ImmOrigin
](samples: Span[Float64, o], slices: Int, expected: Stats, what: String) raises:
    """The same check over each of `slices` consecutive chunks. Go's
    `checkSampleSliceDistributions`."""
    var chunk = len(samples) // slices
    for i in range(slices):
        var low = i * chunk
        var high = (i + 1) * chunk
        if i == slices - 1:
            high = len(samples) - 1
        assert_distribution(
            samples[low:high],
            expected,
            what + " chunk " + String(i) + " of " + String(slices),
        )


def chacha8_seed() -> InlineArray[UInt8, 32]:
    """Go's `chacha8seed`, the 32 bytes `ABCDEFGHIJKLMNOPQRSTUVWXYZ123456`.

    Harvested as numbers rather than written as a string, so that this and the
    output it produces come from the same place.
    """
    var rows = chacha8seed_rows()
    var seed = InlineArray[UInt8, 32](fill=0)
    for i in range(32):
        seed[i] = UInt8(rows[i])
    return seed^


def _hex_digit(v: UInt8) -> String:
    """One lower case hex digit, for a value below sixteen."""
    return String(chr(Int(v) + (48 if v < 10 else 87)))


def hexed[o: ImmOrigin](b: Span[UInt8, o]) -> String:
    """`b` as hex digits, which is what a failing byte comparison prints.

    Two lists of fifty bytes that differ in one place are unreadable side by
    side and two hex strings are not, so every marshalling assertion in these
    tests compares the text rather than the bytes.
    """
    var out = String("")
    for byte in b:
        out += _hex_digit(byte >> 4)
        out += _hex_digit(byte & 0xF)
    return out^
