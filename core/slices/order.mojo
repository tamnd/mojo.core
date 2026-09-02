"""Sorting a span and searching a sorted one. Go's `slices` ordering half.

Every sort here is `core.sort`'s. This package does not have an algorithm and
is not going to get one: two sorts in one library is two sets of bugs, two
sets of adversarial tests, and a question at every call site about which one
you got. `core.sort` is the port, `docs/packages.md` says why it is a port, and
this is the spelling of it that takes a span and a comparator over elements
rather than a collection and a comparator over indices.

Go's `_func` variants take a three way `cmp` returning a negative number, zero
or a positive one, while `core.sort` wants a two way `less`. The conversion is
`cmp(a, b) < 0`, done once per function here rather than asked of the caller.
"""

from core.cmp import Ordered, less as cmp_less
from core.sort import (
    slice as sort_slice,
    slice_stable as sort_slice_stable,
)


def sort[T: Ordered & Copyable & Deinitable, o: MutOrigin, //](s: Span[T, o]):
    """Sorts `s` ascending. Not stable.

    ```mojo
    from core.slices import sort

    var values = [5, 2, 9]
    sort(Span(values))  # 2, 5, 9
    ```

    `core.cmp.less`, so NaNs come first and two NaNs are equal, which is Go's
    documented behaviour for `slices.Sort` and the only ordering a sort can
    actually keep on data containing one.
    """

    @parameter
    def less(i: Int, j: Int) -> Bool:
        return cmp_less(s[i], s[j])

    sort_slice[less](s)


def sort_func[
    T: Copyable & Deinitable,
    o: MutOrigin,
    //,
    cmp: def(T, T) capturing[_] -> Int,
](s: Span[T, o]):
    """Sorts `s` ascending by `cmp`. Not stable.

    `cmp(a, b)` is negative when `a` sorts first, positive when `b` does, and
    zero when neither does — which includes the case where the two are simply
    not comparable. It has to be a strict weak ordering. One that is not gives
    an unspecified order and never an index outside `s`; `core.sort` is a port
    rather than a wrapper in order to keep that.
    """

    @parameter
    def less(i: Int, j: Int) -> Bool:
        return cmp(s[i], s[j]) < 0

    sort_slice[less](s)


def sort_stable_func[
    T: Copyable & Deinitable,
    o: MutOrigin,
    //,
    cmp: def(T, T) capturing[_] -> Int,
](s: Span[T, o]):
    """Sorts `s` ascending by `cmp`, keeping equal elements in their order.

    Go has no `SortStable` without a `Func`, and neither does this: sorting by
    the natural order means equal elements are indistinguishable, so keeping
    their arrival order is a promise nobody can observe the value of.
    """

    @parameter
    def less(i: Int, j: Int) -> Bool:
        return cmp(s[i], s[j]) < 0

    sort_slice_stable[less](s)


def is_sorted[T: Ordered & Copyable, o: Origin, //](s: Span[T, o]) -> Bool:
    """Whether `s` is ascending by `core.cmp.less`.

    Backwards, as Go's is, so this loop and the one inside the sort read the
    same way.
    """
    var i = len(s) - 1
    while i > 0:
        if cmp_less(s[i], s[i - 1]):
            return False
        i -= 1
    return True


def is_sorted_func[
    T: Copyable, o: Origin, //, cmp: def(T, T) capturing[_] -> Int
](s: Span[T, o]) -> Bool:
    """Whether `s` is ascending by `cmp`."""
    var i = len(s) - 1
    while i > 0:
        if cmp(s[i], s[i - 1]) < 0:
            return False
        i -= 1
    return True


def binary_search[
    T: Ordered & Copyable, o: Origin, //
](s: Span[T, o], target: T) -> Tuple[Int, Bool]:
    """The earliest position of `target` in the sorted `s`, and whether it is there.

    ```mojo
    from core.slices import binary_search

    var values = [1, 3, 5, 7]
    var at, found = binary_search(Span(values), 5)  # 2, True
    ```

    When `target` is absent the position is where it would be inserted, which
    is why the pair is more useful than either half: the caller inserting has
    the index and the caller asking has the answer.

    Two NaNs count as found, matching Go, which is the one place `==` would
    give the wrong answer and `core.cmp` gives the right one.
    """
    var i = 0
    var j = len(s)
    while i < j:
        # Halfway without the overflow `(i + j) // 2` has near the top of the
        # range, which is Go's spelling too.
        var h = Int(UInt(i + j) >> 1)
        if cmp_less(s[h], target):
            i = h + 1
        else:
            j = h
    if i < len(s):
        # Indexed rather than bound to a local, because `T` is only `Copyable`
        # and a local would be an implicit copy the compiler will not make.
        if s[i] == target or (s[i] != s[i] and target != target):
            return (i, True)
    return (i, False)


def binary_search_func[
    T: Copyable,
    K: Copyable,
    o: Origin,
    //,
    cmp: def(T, K) capturing[_] -> Int,
](s: Span[T, o], target: K) -> Tuple[Int, Bool]:
    """`binary_search`, with `cmp` comparing an element against the target.

    The target need not be an element. `cmp` takes an element on the left and
    the target on the right, so a span of records can be searched by a key, and
    that asymmetry is why the two type parameters are separate.

    `cmp` has to order `s` the same way `s` is ordered: if `cmp(a, target) < 0`
    and `cmp(b, target) >= 0` then `a` comes before `b` in `s`.
    """
    var i = 0
    var j = len(s)
    while i < j:
        var h = Int(UInt(i + j) >> 1)
        if cmp(s[h], target) < 0:
            i = h + 1
        else:
            j = h
    return (i, i < len(s) and cmp(s[i], target) == 0)
