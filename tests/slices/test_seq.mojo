"""Producing a sequence from a span, and consuming one into a list.

The split this file is really testing is the one `seq.mojo` explains: the four
producers are ordinary Mojo iterators and a `for` loop over one is correct,
while the five consumers take a `Cursor` and are written with a `while`. So the
producer tests are written as `for` loops on purpose — if any of them stops
compiling, the producers have quietly become fallible and the whole rule needs
looking at — and the consumer tests all include a case where the cursor fails
part way, because that is the case a `for` loop would have swallowed.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.slices import (
    all,
    append_seq,
    backward,
    chunk,
    collect,
    sorted,
    sorted_func,
    sorted_stable_func,
    values,
)

from tests.slices._fixtures import Ints, counted


def _by_value(a: Int, b: Int) -> Int:
    if a < b:
        return -1
    if a > b:
        return 1
    return 0


def test_all_yields_every_pair_in_order() raises:
    var xs: List[Int] = [7, 8, 9]
    var indices = List[Int]()
    var elements = List[Int]()
    for i, v in all(Span(xs)):
        indices.append(i)
        elements.append(v)
    assert_equal(indices, [0, 1, 2])
    assert_equal(elements, [7, 8, 9])


def test_all_of_an_empty_span_yields_nothing() raises:
    var xs = List[Int]()
    var seen = 0
    for _, _ in all(Span(xs)):
        seen += 1
    assert_equal(seen, 0)


def test_backward_descends_and_reports_indices_into_the_span() raises:
    var xs: List[Int] = [7, 8, 9]
    var indices = List[Int]()
    var elements = List[Int]()
    for i, v in backward(Span(xs)):
        indices.append(i)
        elements.append(v)
    assert_equal(indices, [2, 1, 0])
    assert_equal(elements, [9, 8, 7])


def test_backward_of_empty_and_single() raises:
    var empty = List[Int]()
    var seen = 0
    for _, _ in backward(Span(empty)):
        seen += 1
    assert_equal(seen, 0)

    var one: List[Int] = [5]
    var pairs = List[Int]()
    for i, v in backward(Span(one)):
        pairs.append(i)
        pairs.append(v)
    assert_equal(pairs, [0, 5])


def test_values_yields_elements_without_indices() raises:
    var xs: List[Int] = [1, 2, 3]
    var total = 0
    for v in values(Span(xs)):
        total += v
    assert_equal(total, 6)


def test_values_over_a_sub_range() raises:
    var xs = counted(10)
    var seen = List[Int]()
    for v in values(Span(xs)[3:6]):
        seen.append(v)
    assert_equal(seen, [3, 4, 5])


def test_values_of_strings() raises:
    var xs: List[String] = ["a", "b"]
    var joined = String()
    for v in values(Span(xs)):
        joined += v
    assert_equal(joined, "ab")


def test_chunk_makes_full_chunks_and_a_short_last_one() raises:
    var xs = counted(5)
    var sizes = List[Int]()
    var firsts = List[Int]()
    for part in chunk(Span(xs), 2):
        sizes.append(len(part))
        firsts.append(part[0])
    assert_equal(sizes, [2, 2, 1])
    assert_equal(firsts, [0, 2, 4])


def test_chunk_that_divides_exactly() raises:
    var xs = counted(6)
    var sizes = List[Int]()
    for part in chunk(Span(xs), 3):
        sizes.append(len(part))
    assert_equal(sizes, [3, 3])


def test_chunk_larger_than_the_span_gives_one_chunk() raises:
    var xs = counted(3)
    var sizes = List[Int]()
    for part in chunk(Span(xs), 100):
        sizes.append(len(part))
    assert_equal(sizes, [3])


def test_chunk_of_an_empty_span_yields_nothing_not_one_empty_chunk() raises:
    var xs = List[Int]()
    var seen = 0
    for _ in chunk(Span(xs), 2):
        seen += 1
    assert_equal(seen, 0)


def test_chunk_of_size_one() raises:
    var xs = counted(4)
    var seen = List[Int]()
    for part in chunk(Span(xs), 1):
        assert_equal(len(part), 1)
        seen.append(part[0])
    assert_equal(seen, [0, 1, 2, 3])


def test_chunk_of_a_size_below_one_raises() raises:
    var xs = counted(4)
    with assert_raises(contains="size less than one"):
        _ = chunk(Span(xs), 0)
    with assert_raises(contains="size less than one"):
        _ = chunk(Span(xs), -1)


def test_chunk_covers_the_span_exactly_once_at_every_size() raises:
    for n in range(0, 20):
        for size in range(1, 8):
            var xs = counted(n)
            var rebuilt = List[Int]()
            for part in chunk(Span(xs), size):
                assert_true(len(part) > 0)
                assert_true(len(part) <= size)
                for i in range(len(part)):
                    rebuilt.append(part[i])
            assert_equal(rebuilt, xs)


def test_collect_drains_a_cursor() raises:
    var cursor = Ints(counted(4))
    var got = collect(cursor)
    assert_equal(got, [0, 1, 2, 3])
    assert_false(cursor.has_next())


def test_collect_of_an_exhausted_cursor_gives_an_empty_list() raises:
    var cursor = Ints(List[Int]())
    var got = collect(cursor)
    assert_equal(len(got), 0)


def test_collect_raises_and_returns_nothing_when_the_cursor_fails() raises:
    var cursor = Ints(counted(5), fail_at=2)
    with assert_raises(contains="failed at element 2"):
        _ = collect(cursor)


def test_append_seq_adds_to_what_is_already_there() raises:
    var into: List[Int] = [90, 91]
    var cursor = Ints(counted(3))
    append_seq(cursor, into)
    assert_equal(into, [90, 91, 0, 1, 2])


def test_append_seq_keeps_what_it_read_before_a_failure() raises:
    # This is the difference between `append_seq` and `collect` and the reason
    # both exist. `collect` drops the partial list; this one hands it back.
    var into = List[Int]()
    var cursor = Ints(counted(5), fail_at=3)
    with assert_raises(contains="failed at element 3"):
        append_seq(cursor, into)
    assert_equal(into, [0, 1, 2])


def test_append_seq_from_an_empty_cursor_changes_nothing() raises:
    var into: List[Int] = [1]
    var cursor = Ints(List[Int]())
    append_seq(cursor, into)
    assert_equal(into, [1])


def test_sorted_collects_and_sorts() raises:
    var cursor = Ints([5, 2, 9, 2])
    var got = sorted(cursor)
    assert_equal(got, [2, 2, 5, 9])


def test_sorted_of_an_empty_cursor() raises:
    var cursor = Ints(List[Int]())
    var got = sorted(cursor)
    assert_equal(len(got), 0)


def test_sorted_raises_when_the_cursor_does() raises:
    var cursor = Ints(counted(5), fail_at=1)
    with assert_raises(contains="failed at element 1"):
        _ = sorted(cursor)


def test_sorted_func_uses_the_comparator() raises:
    var cursor = Ints([1, 3, 2])

    @parameter
    def descending(a: Int, b: Int) -> Int:
        return _by_value(b, a)

    var got = sorted_func[descending](cursor)
    assert_equal(got, [3, 2, 1])


def test_sorted_stable_func_keeps_the_order_the_cursor_produced() raises:
    # The key is the value modulo three and the tie break is arrival order, so
    # a sort that is not stable puts these in a different order and the test
    # says which one it got.
    var cursor = Ints([3, 1, 6, 4, 9, 7])

    @parameter
    def by_remainder(a: Int, b: Int) -> Int:
        return _by_value(a % 3, b % 3)

    var got = sorted_stable_func[by_remainder](cursor)
    assert_equal(got, [3, 6, 9, 1, 4, 7])


def test_sorted_stable_func_over_a_longer_run() raises:
    var arrivals = List[Int](capacity=60)
    for i in range(60):
        arrivals.append(i)
    var cursor = Ints(arrivals^)

    @parameter
    def by_low_bits(a: Int, b: Int) -> Int:
        return _by_value(a % 4, b % 4)

    var got = sorted_stable_func[by_low_bits](cursor)
    assert_equal(len(got), 60)
    for i in range(1, 60):
        assert_true(got[i - 1] % 4 <= got[i] % 4)
        if got[i - 1] % 4 == got[i] % 4:
            assert_true(got[i - 1] < got[i])


def test_a_producer_feeds_a_consumer_through_a_list() raises:
    # There is no shortcut from a producer to a consumer, because the two
    # halves are deliberately different types. Going through a list is the
    # route, and this checks it is a short one.
    var xs: List[Int] = [3, 1, 2]
    var backwards = List[Int]()
    for v in values(Span(xs)):
        backwards.append(v)
    var cursor = Ints(backwards^)
    var got = sorted(cursor)
    assert_equal(got, [1, 2, 3])
