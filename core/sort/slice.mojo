"""Sorting a span directly, without writing an `Interface` for it.

Go spells these `sort.Slice(x any, less func(i, j int) bool)` and reaches for
reflection to swap elements of a slice it was handed as `any`. design.md
section 8 says there is no reflection here and there is not going to be, and
none is needed: the element type is a parameter, so the swap is generated.

The comparator takes indices, as Go's does, and it is a compile time parameter
rather than a value. What a Go closure would capture, a `@parameter` closure
captures, and it monomorphizes, so `slice` on a span of `Int` compiles to the
same thing a hand-written `Interface` would.
"""

from core.cmp import less as cmp_less

from .pdq import _sort_range
from .stable import _stable_range


def slice[
    T: Copyable & Deinitable,
    o: MutOrigin,
    //,
    less: def(Int, Int) capturing[_] -> Bool,
](span: Span[T, o]):
    """Sorts `span` by `less`, which is given indices into it. Not stable.

    ```mojo
    from core.sort import slice

    var people = [String("carol"), String("alice"), String("bob")]
    var view = Span(people)

    @parameter
    def by_name(i: Int, j: Int) -> Bool:
        return view[i] < view[j]

    slice[by_name](view)
    ```

    `less` sees indices and not elements, exactly as Go's does, which means it
    reads the span while the sort is rearranging it. That is intended: `less`
    is asking about whatever is at those positions now.

    A comparator that is not a strict weak ordering gives an unspecified order.
    It does not give an index outside the span, which is the guarantee this
    package is a port to keep; `docs/deviations.md` has the measurement.
    """

    @parameter
    def swap(i: Int, j: Int):
        var held = span[i].copy()
        span[i] = span[j].copy()
        span[j] = held^

    _sort_range[less, swap](len(span))


def slice_stable[
    T: Copyable & Deinitable,
    o: MutOrigin,
    //,
    less: def(Int, Int) capturing[_] -> Bool,
](span: Span[T, o]):
    """Sorts `span` by `less`, keeping equal elements in their original order.
    """

    @parameter
    def swap(i: Int, j: Int):
        var held = span[i].copy()
        span[i] = span[j].copy()
        span[j] = held^

    _stable_range[less, swap](len(span))


def slice_is_sorted[
    T: Copyable,
    o: Origin,
    //,
    less: def(Int, Int) capturing[_] -> Bool,
](span: Span[T, o]) -> Bool:
    """Whether `span` is in ascending order by `less`.

    Only the length of `span` is read here; `less` reaches the elements itself,
    exactly as it does in `slice`. The span is still the argument, because Go's
    call is `SliceIsSorted(x, less)` and a version taking a bare count would
    read as a different function at every call site.
    """
    var i = len(span) - 1
    while i > 0:
        if less(i, i - 1):
            return False
        i -= 1
    return True


def ints[o: MutOrigin](span: Span[Int, o]):
    """Sorts a span of `Int` ascending."""

    @parameter
    def less(i: Int, j: Int) -> Bool:
        return span[i] < span[j]

    slice[less](span)


def float64s[o: MutOrigin](span: Span[Float64, o]):
    """Sorts a span of `Float64` ascending, with NaNs first.

    `core.cmp.less`, not `<`, for the reason `Float64Slice.less` gives: `<` on
    a NaN is not an ordering and a sort handed one has no invariant to keep.
    """

    @parameter
    def less(i: Int, j: Int) -> Bool:
        return cmp_less(span[i], span[j])

    slice[less](span)


def strings[o: MutOrigin](span: Span[String, o]):
    """Sorts a span of `String` ascending by byte order."""

    @parameter
    def less(i: Int, j: Int) -> Bool:
        return span[i] < span[j]

    slice[less](span)


def ints_are_sorted[o: Origin](span: Span[Int, o]) -> Bool:
    """Whether a span of `Int` is ascending."""

    @parameter
    def less(i: Int, j: Int) -> Bool:
        return span[i] < span[j]

    return slice_is_sorted[less](span)


def float64s_are_sorted[o: Origin](span: Span[Float64, o]) -> Bool:
    """Whether a span of `Float64` is ascending with NaNs first."""

    @parameter
    def less(i: Int, j: Int) -> Bool:
        return cmp_less(span[i], span[j])

    return slice_is_sorted[less](span)


def strings_are_sorted[o: Origin](span: Span[String, o]) -> Bool:
    """Whether a span of `String` is ascending."""

    @parameter
    def less(i: Int, j: Int) -> Bool:
        return span[i] < span[j]

    return slice_is_sorted[less](span)
