"""Sorting a span and searching a sorted one.

The sorting itself is `core.sort`'s and is hammered by `tests/sort/`, including
Go's Bentley–McIlroy grid and Go's adversary. What is tested here is the layer:
that a three way `cmp` is converted to a two way `less` the right way round,
that the stable one is stable, and that `binary_search` agrees with a scan.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.slices import (
    binary_search,
    binary_search_func,
    is_sorted,
    is_sorted_func,
    sort,
    sort_func,
    sort_stable_func,
)

from _fixtures import counted, nan


def _by_value(a: Int, b: Int) -> Int:
    if a < b:
        return -1
    if a > b:
        return 1
    return 0


def test_sort_orders_ints() raises:
    var values: List[Int] = [5, 2, 9, 2, 7]
    sort(Span(values))
    assert_equal(values, [2, 2, 5, 7, 9])


def test_sort_of_empty_and_single() raises:
    var empty = List[Int]()
    sort(Span(empty))
    assert_equal(len(empty), 0)
    var one: List[Int] = [7]
    sort(Span(one))
    assert_equal(one, [7])


def test_sort_of_strings() raises:
    var values: List[String] = ["pear", "apple", "fig"]
    sort(Span(values))
    assert_equal(values[0], "apple")
    assert_equal(values[1], "fig")
    assert_equal(values[2], "pear")


def test_sort_puts_nan_first_and_keeps_every_element() raises:
    var values: List[Float64] = [2.0, nan(), -1.0, nan(), 0.5]
    sort(Span(values))
    assert_true(values[0] != values[0])
    assert_true(values[1] != values[1])
    assert_equal(values[2], -1.0)
    assert_equal(values[3], 0.5)
    assert_equal(values[4], 2.0)


def test_sort_func_takes_the_negative_answer_as_first() raises:
    # The one thing this layer can get backwards. A `cmp` reversed here would
    # sort descending and every other test in this file would still pass.
    var values: List[Int] = [3, 1, 2]

    @parameter
    def ascending(a: Int, b: Int) -> Int:
        return _by_value(a, b)

    sort_func[ascending](Span(values))
    assert_equal(values, [1, 2, 3])

    @parameter
    def descending(a: Int, b: Int) -> Int:
        return _by_value(b, a)

    sort_func[descending](Span(values))
    assert_equal(values, [3, 2, 1])


def test_sort_func_over_a_captured_key() raises:
    var keys: List[Int] = [2, 0, 1]
    var values: List[Int] = [0, 1, 2]

    @parameter
    def by_key(a: Int, b: Int) -> Int:
        return _by_value(keys[a], keys[b])

    sort_func[by_key](Span(values))
    assert_equal(values, [1, 2, 0])


def test_sort_stable_func_keeps_equal_elements_in_order() raises:
    # Forty records, four keys, and the payload is the arrival order. A stable
    # sort leaves the payloads ascending inside every key.
    var records = List[Tuple[Int, Int]](capacity=40)
    for i in range(40):
        records.append((i % 4, i))

    @parameter
    def by_key(a: Tuple[Int, Int], b: Tuple[Int, Int]) -> Int:
        return _by_value(a[0], b[0])

    sort_stable_func[by_key](Span(records))
    for i in range(1, len(records)):
        assert_true(records[i - 1][0] <= records[i][0])
        if records[i - 1][0] == records[i][0]:
            assert_true(records[i - 1][1] < records[i][1])


def test_sort_stable_func_on_all_equal_changes_nothing() raises:
    var records = List[Tuple[Int, Int]](capacity=25)
    for i in range(25):
        records.append((0, i))

    @parameter
    def by_key(a: Tuple[Int, Int], b: Tuple[Int, Int]) -> Int:
        return _by_value(a[0], b[0])

    sort_stable_func[by_key](Span(records))
    for i in range(25):
        assert_equal(records[i][1], i)


def test_is_sorted() raises:
    var up: List[Int] = [1, 2, 2, 3]
    var down: List[Int] = [3, 2, 1]
    var empty = List[Int]()
    var one: List[Int] = [5]
    assert_true(is_sorted(Span(up)))
    assert_false(is_sorted(Span(down)))
    assert_true(is_sorted(Span(empty)))
    assert_true(is_sorted(Span(one)))


def test_is_sorted_agrees_with_sort_on_nans() raises:
    var values: List[Float64] = [2.0, nan(), -1.0]
    assert_false(is_sorted(Span(values)))
    sort(Span(values))
    assert_true(is_sorted(Span(values)))


def test_is_sorted_func() raises:
    var values: List[Int] = [3, 2, 1]

    @parameter
    def descending(a: Int, b: Int) -> Int:
        return _by_value(b, a)

    @parameter
    def ascending(a: Int, b: Int) -> Int:
        return _by_value(a, b)

    assert_true(is_sorted_func[descending](Span(values)))
    assert_false(is_sorted_func[ascending](Span(values)))


def test_binary_search_over_every_target_in_a_gapped_range() raises:
    # Every even number from 0 to 30 is present, every odd one is not, and the
    # position an absent one reports has to be where it would be inserted. A
    # `binary_search` off by one anywhere fails on some odd target here.
    var values = List[Int](capacity=16)
    for i in range(16):
        values.append(i * 2)
    for target in range(-1, 33):
        var at, found = binary_search(Span(values), target)
        assert_equal(found, target >= 0 and target <= 30 and target % 2 == 0)
        var expected = 0
        while expected < len(values) and values[expected] < target:
            expected += 1
        assert_equal(at, expected)


def test_binary_search_finds_the_first_of_a_run() raises:
    var values: List[Int] = [1, 2, 2, 2, 3]
    var at, found = binary_search(Span(values), 2)
    assert_true(found)
    assert_equal(at, 1)


def test_binary_search_on_an_empty_span() raises:
    var empty = List[Int]()
    var at, found = binary_search(Span(empty), 5)
    assert_false(found)
    assert_equal(at, 0)


def test_binary_search_does_not_overflow_near_the_top_of_the_range() raises:
    # `(i + j) // 2` overflows when the two halves are near `Int.MAX`, which
    # cannot be reached with a real list. What can be reached is the ordinary
    # large case, and this at least walks a range wide enough that a broken
    # midpoint shows up as a wrong answer rather than as luck.
    var values = counted(100_000)
    for target in [0, 1, 49_999, 50_000, 99_999]:
        var at, found = binary_search(Span(values), target)
        assert_true(found)
        assert_equal(at, target)
    var at, found = binary_search(Span(values), 100_000)
    assert_false(found)
    assert_equal(at, 100_000)


def test_binary_search_counts_two_nans_as_found() raises:
    var values: List[Float64] = [nan(), 1.0, 2.0]
    var at, found = binary_search(Span(values), nan())
    assert_true(found)
    assert_equal(at, 0)


def test_binary_search_func_searches_by_a_key_of_another_type() raises:
    var records: List[Tuple[Int, String]] = [
        (1, String("one")),
        (3, String("three")),
        (5, String("five")),
    ]

    @parameter
    def by_key(record: Tuple[Int, String], target: Int) -> Int:
        return _by_value(record[0], target)

    var at_three, found_three = binary_search_func[by_key](Span(records), 3)
    assert_true(found_three)
    assert_equal(at_three, 1)

    var at_four, found_four = binary_search_func[by_key](Span(records), 4)
    assert_false(found_four)
    assert_equal(at_four, 2)

    var at_zero, found_zero = binary_search_func[by_key](Span(records), 0)
    assert_false(found_zero)
    assert_equal(at_zero, 0)

    var at_nine, found_nine = binary_search_func[by_key](Span(records), 9)
    assert_false(found_nine)
    assert_equal(at_nine, 3)


def test_binary_search_func_over_a_descending_order() raises:
    # The contract is that `cmp` orders the span the way the span is ordered,
    # not that the span is ascending, so a reversed span with a reversed `cmp`
    # has to work.
    var values: List[Int] = [9, 7, 5, 3, 1]

    @parameter
    def descending(element: Int, target: Int) -> Int:
        return _by_value(target, element)

    var at, found = binary_search_func[descending](Span(values), 5)
    assert_true(found)
    assert_equal(at, 2)
