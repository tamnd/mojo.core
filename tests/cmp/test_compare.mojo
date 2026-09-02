"""Ordering, and the one input where it is not `<`.

Almost every case here would pass against a `compare` written as three
comparisons with no NaN handling at all. The ones that would not are the six
NaN tests, and they are the reason the package exists: a NaN answers false to
`<`, `>` and `==` at the same time, so a caller that trusts `<` believes two
NaNs are each after the other, which is not an order and cannot be sorted.

`test_compare_is_a_total_order_on_a_grid_containing_nan` is the one that would
catch a plausible wrong fix. Handling NaN on the left but not the right, or
returning -1 for two NaNs, passes the individual cases and breaks antisymmetry,
and the grid checks antisymmetry at every pair rather than at the pairs someone
thought to write down.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.cmp import compare, first_non_zero, less


def _nan() -> Float64:
    """A NaN built at run time, so the compiler cannot fold the comparisons
    against it into constants and quietly test nothing."""
    var zero = Float64(0.0)
    return zero / zero


def _values() -> List[Float64]:
    """A NaN, both zeros, both infinities and two ordinary numbers.

    Every pair of these goes through the grid test below, which is 64 pairs
    and covers the combinations nobody writes out by hand.
    """
    var inf = Float64(1.0) / Float64(0.0)
    return [_nan(), -inf, -1.5, -0.0, 0.0, 1.5, inf, _nan()]


def test_compare_orders_ints() raises:
    assert_equal(compare(1, 2), -1)
    assert_equal(compare(2, 1), 1)
    assert_equal(compare(2, 2), 0)
    assert_equal(compare(-3, 2), -1)


def test_compare_orders_strings_by_bytes() raises:
    assert_equal(compare(String("a"), String("b")), -1)
    assert_equal(compare(String("b"), String("a")), 1)
    assert_equal(compare(String("a"), String("a")), 0)
    assert_equal(compare(String("a"), String("ab")), -1)
    assert_equal(compare(String(""), String("a")), -1)


def test_compare_puts_nan_before_everything() raises:
    """Go's rule, and not IEEE's. A NaN is less than any non-NaN."""
    var nan = _nan()
    var inf = Float64(1.0) / Float64(0.0)
    assert_equal(compare(nan, Float64(0.0)), -1)
    assert_equal(compare(nan, -inf), -1)
    assert_equal(compare(Float64(0.0), nan), 1)
    assert_equal(compare(-inf, nan), 1)


def test_compare_calls_two_nans_equal() raises:
    """`==` says false here and `compare` says 0.

    Without this a sort sees two elements each of which is after the other,
    which is the state a partition loop cannot recover from.
    """
    var a = _nan()
    var b = _nan()
    assert_false(a == b)
    assert_equal(compare(a, b), 0)
    assert_equal(compare(b, a), 0)


def test_compare_calls_the_two_zeros_equal() raises:
    """Go documents -0.0 and 0.0 as equal, and `==` already agrees."""
    assert_equal(compare(Float64(-0.0), Float64(0.0)), 0)
    assert_equal(compare(Float64(0.0), Float64(-0.0)), 0)


def test_compare_is_a_total_order_on_a_grid_containing_nan() raises:
    """Antisymmetry and reflexivity at all 64 pairs of `_values`.

    `compare(a, b)` must be the negation of `compare(b, a)` for every pair and
    0 on the diagonal. A fix that special cases a NaN on the left only, or that
    answers -1 for two NaNs, satisfies every named case above and fails here.
    """
    var values = _values()
    for i in range(len(values)):
        assert_equal(compare(values[i], values[i]), 0)
        for j in range(len(values)):
            var forward = compare(values[i], values[j])
            var backward = compare(values[j], values[i])
            assert_equal(forward, -backward)


def test_compare_agrees_with_less_everywhere() raises:
    """`less(a, b)` is `compare(a, b) < 0` at every pair, NaN included.

    Two functions written from the same rule can drift apart, and Go ships
    both, so the agreement is worth asserting rather than assuming.
    """
    var values = _values()
    for i in range(len(values)):
        for j in range(len(values)):
            assert_equal(
                less(values[i], values[j]), compare(values[i], values[j]) < 0
            )


def test_less_is_not_the_operator() raises:
    """The single input where `less` and `<` disagree.

    If `less` were `a < b` this test fails and nothing else in the file does,
    which is what makes it worth its own name.
    """
    var nan = _nan()
    assert_false(nan < Float64(0.0))
    assert_true(less(nan, Float64(0.0)))
    assert_false(less(Float64(0.0), nan))
    assert_false(less(nan, nan))


def test_less_orders_ints_and_strings() raises:
    assert_true(less(1, 2))
    assert_false(less(2, 1))
    assert_false(less(2, 2))
    assert_true(less(String("a"), String("b")))
    assert_false(less(String("b"), String("a")))


def test_first_non_zero_takes_the_first_one_that_is_not_default() raises:
    assert_equal(first_non_zero(0, 0, 7, 9), 7)
    assert_equal(first_non_zero(3, 0), 3)
    assert_equal(
        first_non_zero(String(""), String("x"), String("y")), String("x")
    )


def test_first_non_zero_falls_back_to_the_default() raises:
    """All zero, so the answer is the zero. Go's `Or` does the same."""
    assert_equal(first_non_zero(0, 0, 0), 0)
    assert_equal(first_non_zero(String(""), String("")), String(""))


def test_first_non_zero_of_one_argument_is_that_argument() raises:
    assert_equal(first_non_zero(0), 0)
    assert_equal(first_non_zero(5), 5)


def test_first_non_zero_treats_negative_zero_as_zero() raises:
    """-0.0 equals 0.0, so it is the zero value and gets skipped.

    Worth pinning because it is the one float that looks non-default and is
    not, and a caller reaching for `first_non_zero` on floats should find the
    answer written down rather than discover it.
    """
    assert_equal(first_non_zero(Float64(-0.0), Float64(2.5)), Float64(2.5))
