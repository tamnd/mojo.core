"""Go's `TestFloatMinMax` and `TestFloatMinima`, and a check on the constants
Go has no test for.

Go tests only the four limits, and it tests them by formatting them, because
what it is checking is that the compiler accepted a sixty digit constant and
kept the right float64. Here the same question is asked of the bit pattern
instead. Formatting is `core.strconv`'s business and a test in this package
that failed because a printer changed would be pointing at the wrong file.

The eleven irrational constants get a test that Go does not have, because here
they are a hand transcription of sixty digits each and two of them, `LOG2E` and
`LOG10E`, are written out where Go computes them by dividing. The bit patterns
below are what Go's constants round to. If a digit were dropped from one of the
literals this is the test that would say so.
"""

from std.testing import assert_equal

from core.math import (
    E,
    LN2,
    LN10,
    LOG2E,
    LOG10E,
    MAX_FLOAT32,
    MAX_FLOAT64,
    MAX_INT8,
    MAX_INT16,
    MAX_INT32,
    MAX_INT64,
    MAX_UINT8,
    MAX_UINT16,
    MAX_UINT32,
    MAX_UINT64,
    MIN_INT8,
    MIN_INT16,
    MIN_INT32,
    MIN_INT64,
    PHI,
    PI,
    SMALLEST_NONZERO_FLOAT32,
    SMALLEST_NONZERO_FLOAT64,
    SQRT2,
    SQRT_E,
    SQRT_PHI,
    SQRT_PI,
    float32bits,
    float64bits,
)


def test_the_irrational_constants_round_the_way_gos_do() raises:
    assert_equal(float64bits(E), 0x4005BF0A8B145769)
    assert_equal(float64bits(PI), 0x400921FB54442D18)
    assert_equal(float64bits(PHI), 0x3FF9E3779B97F4A8)
    assert_equal(float64bits(SQRT2), 0x3FF6A09E667F3BCD)
    assert_equal(float64bits(SQRT_E), 0x3FFA61298E1E069C)
    assert_equal(float64bits(SQRT_PI), 0x3FFC5BF891B4EF6B)
    assert_equal(float64bits(SQRT_PHI), 0x3FF45A3146A88456)
    assert_equal(float64bits(LN2), 0x3FE62E42FEFA39EF)
    assert_equal(float64bits(LN10), 0x40026BB1BBB55516)


def test_the_two_written_out_logarithms_match_gos() raises:
    assert_equal(float64bits(LOG2E), 0x3FF71547652B82FE)
    assert_equal(float64bits(LOG10E), 0x3FDBCB7B1526E50E)


def test_dividing_at_run_time_would_not_have_given_log10e() raises:
    # Go writes `Log10E` as `1 / Ln10`, which it can do because its untyped
    # constants divide at arbitrary precision and round once at the end. Mojo
    # does the same with comptime values, so the constant could have been
    # written that way here too. A float64 division rounds twice and lands a
    # bit low, which is what the second half of this test pins: the value is
    # written out so that nobody has to know which of the two contexts a
    # division would have ended up in.
    var ln10: Float64 = LN10
    assert_equal(float64bits(1 / LN10), 0x3FDBCB7B1526E50E)
    assert_equal(float64bits(1 / ln10), 0x3FDBCB7B1526E50D)


def test_float_min_max() raises:
    assert_equal(float64bits(MAX_FLOAT64), 0x7FEFFFFFFFFFFFFF)
    assert_equal(float64bits(SMALLEST_NONZERO_FLOAT64), 0x0000000000000001)
    assert_equal(float32bits(MAX_FLOAT32), 0x7F7FFFFF)
    assert_equal(float32bits(SMALLEST_NONZERO_FLOAT32), 0x00000001)


def test_float_minima() raises:
    # Half of the smallest thing there is has nowhere to round to but zero.
    assert_equal(SMALLEST_NONZERO_FLOAT32 / 2, Float32(0))
    assert_equal(SMALLEST_NONZERO_FLOAT64 / 2, Float64(0))


def test_the_integer_limits_are_the_limits_of_the_types_they_name() raises:
    # These are one line each off Mojo's own types, so the failure they are
    # here to catch is a name paired with the wrong width.
    assert_equal(MAX_INT8, 127)
    assert_equal(MIN_INT8, -128)
    assert_equal(MAX_INT16, 32767)
    assert_equal(MIN_INT16, -32768)
    assert_equal(MAX_INT32, 2147483647)
    assert_equal(MIN_INT32, -2147483648)
    assert_equal(MAX_INT64, 9223372036854775807)
    assert_equal(MIN_INT64, -9223372036854775808)
    assert_equal(MAX_UINT8, 255)
    assert_equal(MAX_UINT16, 65535)
    assert_equal(MAX_UINT32, 4294967295)
    assert_equal(MAX_UINT64, 18446744073709551615)
