"""Sorting a span, over Bentley and McIlroy's grid and over the awkward cases.

The grid is the test that matters. Everything above it is a case somebody
thought of; the grid is 1,320 inputs nobody thought of, built to break sorts,
and it is the reason Go's sort has the shape it does.

The multiset check is here rather than only in `test_interface.mojo` because
this is the path whose swap goes through a temporary and two copies. An
`Interface.swap` that exchanges two `Int`s cannot lose one. A copy-based swap
that got its move wrong could leave the same element in both places, and the
result would still be ascending.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.sort import (
    float64s,
    float64s_are_sorted,
    ints,
    ints_are_sorted,
    slice,
    slice_is_sorted,
    slice_stable,
    strings,
    strings_are_sorted,
)

from ._fixtures import (
    N_DIST,
    N_MODE,
    Random,
    sizes,
    distribution,
    histogram,
    permutation,
    same_multiset,
)


def _nan() -> Float64:
    """A NaN built at run time, so nothing folds at compile time."""
    var zero = Float64(0.0)
    return zero / zero


def test_ints_sorts() raises:
    var values = [5, 2, 9, 1, 5, 6]
    ints(Span(values))
    assert_equal(values, [1, 2, 5, 5, 6, 9])


def test_ints_are_sorted_agrees_with_ints() raises:
    var values = [5, 2, 9, 1]
    assert_false(ints_are_sorted(Span(values)))
    ints(Span(values))
    assert_true(ints_are_sorted(Span(values)))


def test_ints_on_an_empty_and_a_single_span() raises:
    """Both are sorted, and neither may index anything."""
    var empty = List[Int]()
    ints(Span(empty))
    assert_true(ints_are_sorted(Span(empty)))

    var one = [7]
    ints(Span(one))
    assert_equal(one, [7])
    assert_true(ints_are_sorted(Span(one)))


def test_ints_on_input_that_is_already_sorted() raises:
    """The case a quicksort with a first-element pivot goes quadratic on."""
    var values = List[Int]()
    for i in range(200):
        values.append(i)
    ints(Span(values))
    for i in range(200):
        assert_equal(values[i], i)


def test_ints_on_input_that_is_entirely_equal() raises:
    """The other one. Partitioning on equal keys is where a two-way split with
    the wrong boundary puts every element on one side, every time."""
    var values = List[Int]()
    for _ in range(200):
        values.append(4)
    ints(Span(values))
    assert_true(ints_are_sorted(Span(values)))
    assert_equal(len(values), 200)
    for i in range(200):
        assert_equal(values[i], 4)


def test_float64s_puts_nan_first() raises:
    """`float64s` uses `core.cmp.less`, so NaN sorts before everything and two
    NaNs compare equal. With `<` this input has no valid ordering at all."""
    var inf = Float64(1.0) / Float64(0.0)
    var values = [1.0, _nan(), -inf, 0.0, inf, _nan(), -2.5]
    float64s(Span(values))

    assert_true(values[0] != values[0])
    assert_true(values[1] != values[1])
    assert_equal(values[2], -inf)
    assert_equal(values[3], -2.5)
    assert_equal(values[4], 0.0)
    assert_equal(values[5], 1.0)
    assert_equal(values[6], inf)
    assert_true(float64s_are_sorted(Span(values)))


def test_float64s_are_sorted_rejects_a_trailing_nan() raises:
    """A NaN at the end is not sorted, and a check written with `<` would say
    it was, because `<` is false in both directions there."""
    var values = [1.0, 2.0, _nan()]
    assert_false(float64s_are_sorted(Span(values)))


def test_strings_sorts_by_bytes() raises:
    var values = [
        String("pear"),
        String("apple"),
        String("Pear"),
        String("fig"),
    ]
    strings(Span(values))
    assert_equal(values[0], String("Pear"))
    assert_equal(values[1], String("apple"))
    assert_equal(values[2], String("fig"))
    assert_equal(values[3], String("pear"))
    assert_true(strings_are_sorted(Span(values)))


def test_slice_takes_a_comparator_over_indices() raises:
    """The comparator sees indices into the span it is sorting, as Go's does,
    and reads it while the sort is moving elements around."""
    var values = [3, 1, 2]
    var view = Span(values)

    @parameter
    def descending(i: Int, j: Int) -> Bool:
        return view[i] > view[j]

    slice[descending](view)
    assert_equal(values, [3, 2, 1])


def test_slice_sorts_by_a_captured_key() raises:
    """The capture is the thing `capturing [_]` buys, and a comparator spelled
    without it compiles, loses the capture and sorts by nothing.
    `tools/probe/probes/comparator_capture_list.mojo` pins that."""
    var order = [2, 0, 1]
    var values = [0, 1, 2]
    var view = Span(values)

    @parameter
    def by_key(i: Int, j: Int) -> Bool:
        return order[view[i]] < order[view[j]]

    slice[by_key](view)
    assert_equal(values, [1, 2, 0])


def test_slice_moves_strings_without_losing_one() raises:
    """The span swap goes through a temporary and two copies. A wrong move
    there leaves a duplicate, and the result is still ascending."""
    var values = [
        String("delta"),
        String("alpha"),
        String("charlie"),
        String("bravo"),
    ]
    var view = Span(values)

    @parameter
    def by_name(i: Int, j: Int) -> Bool:
        return view[i] < view[j]

    slice[by_name](view)
    assert_equal(values[0], String("alpha"))
    assert_equal(values[1], String("bravo"))
    assert_equal(values[2], String("charlie"))
    assert_equal(values[3], String("delta"))


def test_slice_is_sorted_walks_the_whole_span() raises:
    """One inversion at the very end, which a check that stopped early misses.
    """
    var values = [1, 2, 3, 4, 0]
    var view = Span(values)

    @parameter
    def ascending(i: Int, j: Int) -> Bool:
        return view[i] < view[j]

    assert_false(slice_is_sorted[ascending](view))
    slice[ascending](view)
    assert_true(slice_is_sorted[ascending](view))


def test_slice_stable_sorts() raises:
    """That it sorts. `test_stable.mojo` is where the stability is proved."""
    var values = [5, 2, 9, 1, 5, 6]
    var view = Span(values)

    @parameter
    def ascending(i: Int, j: Int) -> Bool:
        return view[i] < view[j]

    slice_stable[ascending](view)
    assert_equal(values, [1, 2, 5, 5, 6, 9])


# slow: 1,320 sorts of up to 1,025 elements, two sorts each
def test_ints_over_the_bentley_mcilroy_grid() raises:
    """Every size, spread, distribution and permutation, sorted and checked.

    Four sizes, eleven spreads, five distributions and six permutations is
    1,320 inputs, and the output of each is checked twice: ascending, and the
    same multiset it went in as. Go runs this same grid, from the same paper,
    with the same five and six names.
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
                    ints(Span(values))
                    assert_true(ints_are_sorted(Span(values)))
                    assert_true(same_multiset(before, histogram(values)))
            m *= 2


# slow: the same grid again, through the stable sort
def test_slice_stable_over_the_bentley_mcilroy_grid() raises:
    """The stable sort over the same 1,320 inputs.

    SymMerge is a different algorithm from pdqsort and shares none of its code,
    so the grid has to be run twice or half of it is untested.
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
                    var view = Span(values)

                    @parameter
                    def ascending(i: Int, j: Int) -> Bool:
                        return view[i] < view[j]

                    slice_stable[ascending](view)
                    assert_true(ints_are_sorted(Span(values)))
                    assert_true(same_multiset(before, histogram(values)))
            m *= 2
