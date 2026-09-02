"""`Interface` and the three sorts over it, including the swap budget.

The budget is the test that says the sort is not quadratic. A quicksort that
has degenerated still returns a correctly sorted list, so "is it sorted" cannot
tell you it has happened; only counting the moves can. Go bounds an unstable
sort at `n lg n * 12/10` swaps and a stable one at `n lg n lg n / 3`, and those
same two numbers are used here so that a regression shows up as the same
failure it would show up as in Go.

`Counted` also watches the indices it is handed. Every `less` and every `swap`
in this file is checked against `[0, n)`, and a sort that ever steps outside
sets a flag the tests assert on. That is the property this package exists for:
`test_adversary.mojo` is where it is pushed hard, and here it rides along on
every case for free.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.sort import (
    Float64Slice,
    IntSlice,
    Interface,
    Reverse,
    StringSlice,
    is_sorted,
    sort,
    stable,
)

from ._fixtures import (
    N_DIST,
    N_MODE,
    Random,
    distribution,
    histogram,
    lg,
    permutation,
    same_multiset,
    sizes,
)

comptime COMPARES = 0
"""Index into the counter list. Named so the assertions read."""

comptime SWAPS = 1

comptime OUT_OF_RANGE = 2
"""Set to 1 the first time an index outside `[0, n)` arrives."""


def counters() -> List[Int]:
    """A fresh counter list: compares, swaps, and the out-of-range flag."""
    return [0, 0, 0]


struct Counted[o: MutOrigin, c: MutOrigin](Interface):
    """`IntSlice`, plus a count of what the sort did and where it looked.

    The counters live outside the struct and are reached through a pointer,
    because `less` takes `self` by borrow — as it must, since a comparator that
    could mutate the collection it is ordering is not one — and a borrowed self
    cannot write its own fields. Go's equivalent has a pointer receiver and the
    same thing falls out of it.
    """

    var values: Span[Int, Self.o]
    var counts: Pointer[List[Int], Self.c]

    def __init__(
        out self, values: Span[Int, Self.o], ref[Self.c] counts: List[Int]
    ):
        self.values = values
        self.counts = Pointer(to=counts)

    def __len__(self) -> Int:
        return len(self.values)

    def less(self, i: Int, j: Int) -> Bool:
        self.counts[][COMPARES] += 1
        if i < 0 or i >= len(self.values) or j < 0 or j >= len(self.values):
            self.counts[][OUT_OF_RANGE] = 1
            return False
        return self.values[i] < self.values[j]

    def swap(mut self, i: Int, j: Int):
        self.counts[][SWAPS] += 1
        if i < 0 or i >= len(self.values) or j < 0 or j >= len(self.values):
            self.counts[][OUT_OF_RANGE] = 1
            return
        var held = self.values[i]
        self.values[i] = self.values[j]
        self.values[j] = held


struct ByLength[o: MutOrigin](Interface):
    """A hand-written `Interface` over something that is not a list of numbers.

    The point of `Interface` is that the sort never sees the elements, so a
    test that only ever sorts spans of `Int` has not exercised it. This orders
    words by how long they are, which also makes it a pile of equal keys and so
    the input the stability test wants.
    """

    var words: Span[String, Self.o]

    def __init__(out self, words: Span[String, Self.o]):
        self.words = words

    def __len__(self) -> Int:
        return len(self.words)

    def less(self, i: Int, j: Int) -> Bool:
        return self.words[i].byte_length() < self.words[j].byte_length()

    def swap(mut self, i: Int, j: Int):
        var held = self.words[i].copy()
        self.words[i] = self.words[j].copy()
        self.words[j] = held^


def test_sort_orders_a_hand_written_interface() raises:
    var words = [String("ccc"), String("a"), String("dddd"), String("bb")]
    var view = ByLength(Span(words))
    sort(view)
    assert_equal(words[0], String("a"))
    assert_equal(words[1], String("bb"))
    assert_equal(words[2], String("ccc"))
    assert_equal(words[3], String("dddd"))


def test_is_sorted_agrees_with_sort() raises:
    var words = [String("ccc"), String("a"), String("dddd"), String("bb")]
    var view = ByLength(Span(words))
    assert_false(is_sorted(view))
    sort(view)
    assert_true(is_sorted(view))


def test_is_sorted_is_true_of_nothing_and_of_one() raises:
    var empty = List[String]()
    assert_true(is_sorted(ByLength(Span(empty))))
    var one = [String("solo")]
    assert_true(is_sorted(ByLength(Span(one))))


def test_int_slice_sorts_the_callers_list() raises:
    """A `Span` is a view, so the method sorts what the caller handed over and
    not a copy of it. If it did not, this list would come back unchanged."""
    var values = [3, 1, 2]
    var view = IntSlice(Span(values))
    view.sort()
    assert_equal(values, [1, 2, 3])


def test_int_slice_search_finds_and_reports_where() raises:
    var values = [3, 1, 2, 9]
    var view = IntSlice(Span(values))
    view.sort()
    assert_equal(view.search(3), 2)
    assert_equal(view.search(4), 3)


def test_float64_slice_sorts_nan_first() raises:
    var zero = Float64(0.0)
    var nan = zero / zero
    var values = [1.0, nan, -2.0]
    var view = Float64Slice(Span(values))
    view.sort()
    assert_true(values[0] != values[0])
    assert_equal(values[1], -2.0)
    assert_equal(values[2], 1.0)


def test_string_slice_sorts_and_searches() raises:
    var values = [String("pear"), String("apple"), String("fig")]
    var view = StringSlice(Span(values))
    view.sort()
    assert_equal(values[0], String("apple"))
    assert_equal(view.search(String("fig")), 1)


def test_reverse_sorts_descending_through_the_callers_data() raises:
    """`Reverse` holds a pointer at the inner view. Holding it by value would
    sort a copy and hand back an untouched list with no error, which is the one
    way this could go wrong silently."""
    var values = [3, 1, 2]
    var view = IntSlice(Span(values))
    var backwards = Reverse(view)
    sort(backwards)
    assert_equal(values, [3, 2, 1])


def test_reverse_twice_is_ascending_again() raises:
    var values = [3, 1, 2]
    var view = IntSlice(Span(values))
    var once = Reverse(view)
    var twice = Reverse(once)
    sort(twice)
    assert_equal(values, [1, 2, 3])


def test_reverse_reports_is_sorted_the_other_way() raises:
    var values = [3, 2, 1]
    var view = IntSlice(Span(values))
    var backwards = Reverse(view)
    assert_true(is_sorted(backwards))
    assert_false(is_sorted(view))


def test_reverse_of_equal_elements_keeps_them_equal() raises:
    """`Reverse.less` swaps its arguments rather than negating the answer.
    Negating would call two equal elements ordered, which is not a strict weak
    ordering, and `stable` over it would stop being stable."""
    var values = [1, 1, 1]
    var view = IntSlice(Span(values))
    var backwards = Reverse(view)
    assert_false(backwards.less(0, 1))
    assert_false(backwards.less(1, 0))


def test_stable_orders_an_interface() raises:
    var words = [String("ccc"), String("a"), String("dddd"), String("bb")]
    var view = ByLength(Span(words))
    stable(view)
    assert_true(is_sorted(view))


def test_sort_never_indexes_outside_the_data() raises:
    """Every index the sort asks about, on a shuffled thousand, is in range."""
    var rng = Random()
    var values = List[Int]()
    for _ in range(1000):
        values.append(rng.below(1000))
    var counts = counters()
    var view = Counted(Span(values), counts)
    sort(view)
    assert_equal(counts[OUT_OF_RANGE], 0)
    assert_true(is_sorted(IntSlice(Span(values))))


def test_sort_stays_inside_gos_swap_budget() raises:
    """`n lg n * 12/10`, which is the bound Go's own tests use.

    A sort that has fallen to quadratic returns the right answer, so this
    number is the only thing standing between a working sort and a working
    sort that takes a million moves to sort a thousand elements.
    """
    var rng = Random()
    for n in [100, 1000, 10000]:
        var values = List[Int]()
        for _ in range(n):
            values.append(rng.below(n))
        var counts = counters()
        var view = Counted(Span(values), counts)
        sort(view)
        assert_true(is_sorted(IntSlice(Span(values))))
        assert_true(counts[SWAPS] <= n * lg(n) * 12 // 10)
        assert_equal(counts[OUT_OF_RANGE], 0)


def test_stable_stays_inside_gos_swap_budget() raises:
    """`n lg n lg n / 3`. SymMerge buys stability with rotations rather than
    with an extra array, and the extra `lg n` is what it costs."""
    var rng = Random()
    for n in [100, 1000, 10000]:
        var values = List[Int]()
        for _ in range(n):
            values.append(rng.below(n))
        var counts = counters()
        var view = Counted(Span(values), counts)
        stable(view)
        assert_true(is_sorted(IntSlice(Span(values))))
        assert_true(counts[SWAPS] <= n * lg(n) * lg(n) // 3)
        assert_equal(counts[OUT_OF_RANGE], 0)


# slow: the grid again, this time counting every swap and every index
def test_sort_holds_the_budget_over_the_bentley_mcilroy_grid() raises:
    """The budget and the range check over all 1,320 inputs.

    The shapes that make a quicksort quadratic are exactly the ones in this
    grid, so running the budget over a shuffled list and stopping there would
    be testing the easy case. Go runs its budget over this grid for the same
    reason.
    """
    var rng = Random()
    for n in sizes():
        var m = 1
        while m < 2 * n:
            for dist in range(N_DIST):
                var data = distribution(rng, dist, n, m)
                for mode in range(N_MODE):
                    var values = permutation(data, mode)
                    var before = histogram(values)
                    var counts = counters()
                    var view = Counted(Span(values), counts)
                    sort(view)
                    assert_true(is_sorted(IntSlice(Span(values))))
                    assert_true(same_multiset(before, histogram(values)))
                    assert_equal(counts[OUT_OF_RANGE], 0)
                    assert_true(counts[SWAPS] <= n * lg(n) * 12 // 10)
            m *= 2


# slow: and once more through the stable sort
def test_stable_holds_the_budget_over_the_bentley_mcilroy_grid() raises:
    var rng = Random()
    for n in sizes():
        var m = 1
        while m < 2 * n:
            for dist in range(N_DIST):
                var data = distribution(rng, dist, n, m)
                for mode in range(N_MODE):
                    var values = permutation(data, mode)
                    var before = histogram(values)
                    var counts = counters()
                    var view = Counted(Span(values), counts)
                    stable(view)
                    assert_true(is_sorted(IntSlice(Span(values))))
                    assert_true(same_multiset(before, histogram(values)))
                    assert_equal(counts[OUT_OF_RANGE], 0)
                    assert_true(counts[SWAPS] <= n * lg(n) * lg(n) // 3)
            m *= 2
