"""Comparing two spans and looking through one.

Go's own `slices` tests are the shape of this file. The cases that are not
Go's are the NaN ones, and they are here because `core.slices` compares through
`core.cmp` rather than through `<`: `compare` puts a NaN first and calls two of
them equal, while `min` and `max` propagate one, and those two rules disagree
on purpose. A reader who thinks that is a bug should be able to find the test
that says it is not.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.slices import (
    compare,
    compare_func,
    contains,
    contains_func,
    equal,
    equal_func,
    index,
    index_func,
    max,
    max_func,
    min,
    min_func,
)

from _fixtures import nan


def test_equal_on_the_same_contents() raises:
    var a: List[Int] = [1, 2, 3]
    var b: List[Int] = [1, 2, 3]
    assert_true(equal(Span(a), Span(b)))
    # `equal(Span(a), Span(a))` is not written here and cannot be: `Span(a)`
    # over a `var` takes a mutable origin, so passing it twice is two mutable
    # borrows of one list and the compiler refuses. Go's test does compare a
    # slice against itself; here that case does not exist.


def test_equal_is_false_on_different_lengths() raises:
    var a: List[Int] = [1, 2, 3]
    var b: List[Int] = [1, 2]
    assert_false(equal(Span(a), Span(b)))
    assert_false(equal(Span(b), Span(a)))


def test_equal_is_false_on_one_different_element() raises:
    var a: List[Int] = [1, 2, 3]
    var b: List[Int] = [1, 9, 3]
    assert_false(equal(Span(a), Span(b)))


def test_two_empty_spans_are_equal() raises:
    var a = List[Int]()
    var b = List[Int]()
    assert_true(equal(Span(a), Span(b)))


def test_equal_on_floats_disagrees_with_compare_about_nan() raises:
    # `equal` is `==` elementwise, and `==` says a NaN is not itself. `compare`
    # below says two NaNs are equal, because an order has to. Both are right
    # and this test is here so the difference is on the record.
    var a: List[Float64] = [nan()]
    var b: List[Float64] = [nan()]
    assert_false(equal(Span(a), Span(b)))
    assert_equal(compare(Span(a), Span(b)), 0)


def test_equal_func_across_two_element_types() raises:
    var numbers: List[Int] = [1, 2, 3]
    var names: List[String] = ["1", "2", "3"]

    @parameter
    def same(n: Int, s: String) -> Bool:
        return String(n) == s

    assert_true(equal_func[same](Span(numbers), Span(names)))
    names[1] = "9"
    assert_false(equal_func[same](Span(numbers), Span(names)))


def test_equal_func_is_false_on_different_lengths_without_calling_eq() raises:
    var calls: List[Int] = [0]
    var a: List[Int] = [1, 2, 3]
    var b: List[Int] = [1]

    @parameter
    def counting(x: Int, y: Int) -> Bool:
        calls[0] += 1
        return x == y

    assert_false(equal_func[counting](Span(a), Span(b)))
    assert_equal(calls[0], 0)


def test_compare_decides_at_the_first_difference() raises:
    var a: List[Int] = [1, 2, 3]
    var b: List[Int] = [1, 9, 0]
    assert_equal(compare(Span(a), Span(b)), -1)
    assert_equal(compare(Span(b), Span(a)), 1)


def test_a_prefix_compares_first() raises:
    var short: List[Int] = [1, 2]
    var long: List[Int] = [1, 2, 3]
    var same: List[Int] = [1, 2, 3]
    assert_equal(compare(Span(short), Span(long)), -1)
    assert_equal(compare(Span(long), Span(short)), 1)
    assert_equal(compare(Span(long), Span(same)), 0)


def test_compare_on_empty_spans() raises:
    var empty = List[Int]()
    var also_empty = List[Int]()
    var one: List[Int] = [1]
    assert_equal(compare(Span(empty), Span(also_empty)), 0)
    assert_equal(compare(Span(empty), Span(one)), -1)
    assert_equal(compare(Span(one), Span(empty)), 1)


def test_compare_puts_nan_before_every_number() raises:
    var with_nan: List[Float64] = [nan()]
    var with_zero: List[Float64] = [0.0]
    assert_equal(compare(Span(with_nan), Span(with_zero)), -1)
    assert_equal(compare(Span(with_zero), Span(with_nan)), 1)


def test_compare_of_bytes_reads_like_a_string_comparison() raises:
    # The point of the prefix rule: `"ab" < "abc"` and this is that.
    var ab: List[UInt8] = [97, 98]
    var abc: List[UInt8] = [97, 98, 99]
    var abd: List[UInt8] = [97, 98, 100]
    assert_equal(compare(Span(ab), Span(abc)), -1)
    assert_equal(compare(Span(abc), Span(abd)), -1)


def test_compare_func_across_two_element_types() raises:
    var numbers: List[Int] = [1, 2]
    var names: List[String] = ["1", "3"]

    @parameter
    def by_text(n: Int, s: String) -> Int:
        var text = String(n)
        if text < s:
            return -1
        if text > s:
            return 1
        return 0

    assert_equal(compare_func[by_text](Span(numbers), Span(names)), -1)


def test_compare_func_breaks_a_tie_on_length() raises:
    var a: List[Int] = [1, 2]
    var b: List[Int] = [1, 2, 3]

    @parameter
    def always_equal(x: Int, y: Int) -> Int:
        return 0

    assert_equal(compare_func[always_equal](Span(a), Span(b)), -1)
    assert_equal(compare_func[always_equal](Span(b), Span(a)), 1)


def test_index_finds_the_first_of_a_repeat() raises:
    var values: List[Int] = [5, 3, 5, 3]
    assert_equal(index(Span(values), 5), 0)
    assert_equal(index(Span(values), 3), 1)


def test_index_returns_minus_one_when_absent() raises:
    var values: List[Int] = [1, 2, 3]
    assert_equal(index(Span(values), 9), -1)
    var empty = List[Int]()
    assert_equal(index(Span(empty), 1), -1)


def test_index_func_and_its_absence() raises:
    var values: List[Int] = [1, 3, 4, 6]

    @parameter
    def even(x: Int) -> Bool:
        return x % 2 == 0

    @parameter
    def negative(x: Int) -> Bool:
        return x < 0

    assert_equal(index_func[even](Span(values)), 2)
    assert_equal(index_func[negative](Span(values)), -1)


def test_index_func_stops_at_the_first_hit() raises:
    var calls: List[Int] = [0]
    var values: List[Int] = [1, 2, 3, 4, 5]

    @parameter
    def counting(x: Int) -> Bool:
        calls[0] += 1
        return x == 2

    assert_equal(index_func[counting](Span(values)), 1)
    assert_equal(calls[0], 2)


def test_contains_and_contains_func() raises:
    var values: List[Int] = [1, 2, 3]

    @parameter
    def big(x: Int) -> Bool:
        return x > 2

    assert_true(contains(Span(values), 2))
    assert_false(contains(Span(values), 9))
    assert_true(contains_func[big](Span(values)))
    var small: List[Int] = [1, 2]
    assert_false(contains_func[big](Span(small)))


def test_min_and_max_of_ints() raises:
    var values: List[Int] = [4, 1, 9, 1]
    assert_equal(min(Span(values)), 1)
    assert_equal(max(Span(values)), 9)


def test_min_and_max_of_one_element() raises:
    var one: List[Int] = [7]
    assert_equal(min(Span(one)), 7)
    assert_equal(max(Span(one)), 7)


def test_min_and_max_raise_on_an_empty_span() raises:
    var empty = List[Int]()
    with assert_raises(contains="empty span"):
        _ = min(Span(empty))
    with assert_raises(contains="empty span"):
        _ = max(Span(empty))


def test_min_and_max_propagate_a_nan() raises:
    # Go's `min` and `max` builtins do this and `slices.Min` follows them, so
    # this does too. It is the opposite of what `core.cmp.less` would give,
    # which would put the NaN first and hand back a number from `max`.
    var placements: List[List[Float64]] = [
        [nan(), 1.0, 2.0],
        [1.0, nan(), 2.0],
        [1.0, 2.0, nan()],
    ]
    for i in range(len(placements)):
        var lo = min(Span(placements[i]))
        var hi = max(Span(placements[i]))
        assert_true(lo != lo)
        assert_true(hi != hi)


def test_min_and_max_without_a_nan_are_ordinary() raises:
    var values: List[Float64] = [2.0, -1.5, 8.25]
    assert_equal(min(Span(values)), -1.5)
    assert_equal(max(Span(values)), 8.25)


def test_min_func_and_max_func_both_take_the_first_of_a_tie() raises:
    # Three records that compare equal on the key and differ in the payload, so
    # which one came back is observable. Go documents the first for both, and
    # the obvious wrong implementation of `max_func` — `>=` instead of `>` —
    # returns the last and fails here.
    var values: List[Tuple[Int, Int]] = [(1, 10), (1, 20), (1, 30)]

    @parameter
    def by_key(a: Tuple[Int, Int], b: Tuple[Int, Int]) -> Int:
        if a[0] < b[0]:
            return -1
        if a[0] > b[0]:
            return 1
        return 0

    assert_equal(min_func[by_key](Span(values))[1], 10)
    assert_equal(max_func[by_key](Span(values))[1], 10)


def test_min_func_and_max_func_on_real_differences() raises:
    var values: List[Int] = [4, 1, 9]

    @parameter
    def reversed(a: Int, b: Int) -> Int:
        if a > b:
            return -1
        if a < b:
            return 1
        return 0

    assert_equal(min_func[reversed](Span(values)), 9)
    assert_equal(max_func[reversed](Span(values)), 1)


def test_min_func_and_max_func_raise_on_an_empty_span() raises:
    var empty = List[Int]()

    @parameter
    def natural(a: Int, b: Int) -> Int:
        if a < b:
            return -1
        if a > b:
            return 1
        return 0

    with assert_raises(contains="empty span"):
        _ = min_func[natural](Span(empty))
    with assert_raises(contains="empty span"):
        _ = max_func[natural](Span(empty))
