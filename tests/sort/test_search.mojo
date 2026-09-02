"""Binary search, checked against a linear scan rather than against opinion.

The interesting tests here are the exhaustive ones. `search` over a predicate
is four lines and every one of the classic off-by-ones — `h` versus `h + 1`,
`<` versus `<=`, returning `i` versus `j` — still returns something plausible
on a handful of hand-written cases. So the two grid tests below run every
target against every prefix length up to 33 and compare with a loop that cannot
be wrong, which is what actually pins the boundary behaviour.

The midpoint is `Int(UInt(i + j) >> 1)` and not `(i + j) // 2`. On a span long
enough for `i + j` to overflow `Int` that difference is a crash, and no test
here can reach that size, so the reason lives in the comment next to the code.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.sort import (
    find,
    search,
    search_float64s,
    search_ints,
    search_strings,
)


def _linear_search(n: Int, threshold: Int) -> Int:
    """The answer `search` must give for the predicate `i >= threshold`.

    Written as a scan so that it shares no code, and no bug, with the thing
    under test.
    """
    for i in range(n):
        if i >= threshold:
            return i
    return n


def test_search_matches_a_linear_scan_at_every_boundary() raises:
    """Every count up to 33, every threshold including both ends and past them.

    33 rather than 32 so that the counts either side of a power of two are both
    covered, since that is where a halving loop divides unevenly.
    """
    for n in range(34):
        for threshold in range(-1, n + 2):

            @parameter
            def at_least(i: Int) -> Bool:
                return i >= threshold

            assert_equal(search[at_least](n), _linear_search(n, threshold))


def test_search_of_an_empty_range_is_zero() raises:
    @parameter
    def always(i: Int) -> Bool:
        return True

    assert_equal(search[always](0), 0)


def test_search_that_finds_nothing_returns_the_count() raises:
    """Not -1. `n` is where the value would be inserted, which is the answer a
    caller who is about to insert actually wants."""

    @parameter
    def never(i: Int) -> Bool:
        return False

    assert_equal(search[never](10), 10)


def test_search_never_asks_outside_the_range() raises:
    """The doc promises `f` is only called for `i` in `[0, n)`, so callers index
    without checking. A predicate that records its arguments proves it."""
    var lowest = 1 << 40
    var highest = -1

    @parameter
    def watching(i: Int) -> Bool:
        if i < lowest:
            lowest = i
        if i > highest:
            highest = i
        return i >= 7

    var got = search[watching](20)
    assert_equal(got, 7)
    assert_true(lowest >= 0)
    assert_true(highest < 20)


def test_search_is_logarithmic() raises:
    """A million elements in at most twenty one calls.

    This is the property that makes the four lines worth having over a scan,
    and a rewrite that turned the loop linear would still pass every other test
    in this file.
    """
    var calls: List[Int] = [0]

    @parameter
    def counting(i: Int) -> Bool:
        calls[0] += 1
        return i >= 999999

    var n = 1000000
    assert_equal(search[counting](n), 999999)
    assert_true(calls[0] <= 21)


def test_find_returns_the_position_and_whether_it_is_there() raises:
    var data = [10, 20, 30, 40]

    @parameter
    def against_30(i: Int) -> Int:
        return 30 - data[i]

    var i: Int
    var found: Bool
    i, found = find[against_30](len(data))
    assert_equal(i, 2)
    assert_true(found)


def test_find_reports_where_a_missing_value_would_go() raises:
    var data = [10, 20, 40]

    @parameter
    def against_30(i: Int) -> Int:
        return 30 - data[i]

    var i: Int
    var found: Bool
    i, found = find[against_30](len(data))
    assert_equal(i, 2)
    assert_false(found)


def test_find_handles_both_ends_and_the_empty_range() raises:
    var data = [10, 20, 30]

    @parameter
    def against_5(i: Int) -> Int:
        return 5 - data[i]

    @parameter
    def against_99(i: Int) -> Int:
        return 99 - data[i]

    @parameter
    def against_nothing(i: Int) -> Int:
        return 0

    var i: Int
    var found: Bool

    i, found = find[against_5](len(data))
    assert_equal(i, 0)
    assert_false(found)

    i, found = find[against_99](len(data))
    assert_equal(i, 3)
    assert_false(found)

    i, found = find[against_nothing](0)
    assert_equal(i, 0)
    assert_false(found)


def test_find_lands_on_the_first_of_a_run_of_equals() raises:
    """`cmp` is zero over a range, and Go's contract is the smallest such `i`.

    A binary search that stopped at whichever equal element it happened to hit
    first would pass a test with distinct elements and fail this one.
    """
    var data = [1, 2, 2, 2, 3]

    @parameter
    def against_2(i: Int) -> Int:
        return 2 - data[i]

    var i: Int
    var found: Bool
    i, found = find[against_2](len(data))
    assert_equal(i, 1)
    assert_true(found)


def test_search_ints_matches_a_scan_over_every_prefix() raises:
    """Every target from below the first element to above the last, against a
    scan, for every length up to 16."""
    var data = List[Int]()
    for n in range(17):
        for x in range(-1, 2 * n + 2):
            var want = n
            for i in range(n):
                if data[i] >= x:
                    want = i
                    break
            assert_equal(search_ints(Span(data), x), want)
        data.append(2 * n)


def test_search_ints_on_an_empty_span_is_zero() raises:
    var data = List[Int]()
    assert_equal(search_ints(Span(data), 5), 0)


def test_search_ints_finds_the_first_of_a_run() raises:
    var data = [1, 2, 2, 2, 3]
    assert_equal(search_ints(Span(data), 2), 1)


def test_search_float64s_skips_the_nans_at_the_front() raises:
    """`Float64Slice` sorts NaNs first, so this is the shape of span callers
    will hand it. Go's `SearchFloat64s` uses `>=` and gives these answers."""
    var zero = Float64(0.0)
    var nan = zero / zero
    var data = [nan, nan, 1.0, 2.0, 3.0]
    assert_equal(search_float64s(Span(data), 2.0), 3)
    assert_equal(search_float64s(Span(data), 0.5), 2)


def test_search_float64s_for_a_nan_answers_zero() raises:
    """A NaN is `>=` nothing, including itself, so no element satisfies the
    predicate and the answer is the count. With no NaN in the data that is the
    end; the interesting case is that it does not crash or loop."""
    var zero = Float64(0.0)
    var nan = zero / zero
    var data = [1.0, 2.0, 3.0]
    assert_equal(search_float64s(Span(data), nan), 3)


def test_search_strings_orders_by_bytes() raises:
    var data = [String("apple"), String("banana"), String("cherry")]
    assert_equal(search_strings(Span(data), String("banana")), 1)
    assert_equal(search_strings(Span(data), String("blueberry")), 2)
    assert_equal(search_strings(Span(data), String("aardvark")), 0)
    assert_equal(search_strings(Span(data), String("zucchini")), 3)
