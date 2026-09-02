"""Pattern-defeating quicksort, ported from Go's `zsortinterface.go`.

Every function here is parametric on two compile time closures, `less(i, j)`
and `swap(i, j)`, and takes only indices. That is Go's `lessSwap` pair with the
indirection removed: Go generates two copies of this file, one calling methods
on an `Interface` and one calling a pair of function values, because Go had no
generics when `sort` was written. One copy is enough here, and both public
entry points build the pair — `sort.sort` from an `Interface`'s methods,
`sort.slice` from the caller's comparator over a span.

The comparator parameters are spelled `capturing [_]` rather than `capturing`.
That is not a stylistic choice. `tools/probe/probes/comparator_capture_list.mojo`
has the full account: bare `capturing` compiles, drops the capture, and gives a
wrong answer with no diagnostic.

The algorithm is Go's, unchanged, including the constants. It is a quicksort
that watches its own partitions: an unbalanced one costs a life from `limit`
and buys a call to `_break_patterns`, and when `limit` runs out the range goes
to heapsort, so the worst case is n log n rather than n squared. `limit` starts
at the bit width of n, which allows about log n bad pivots before giving up on
quicksort for that range.

`docs/deviations.md` records why this is a port and not a call into
`std.builtin.sort`: that one hands the comparator elements from outside the
span it was given when the comparator is inconsistent, and Go's does not. A
sort's index discipline should not depend on the caller getting the ordering
right, because the caller getting it wrong is the case where a crash is least
welcome.
"""

from std.bit import bit_width

comptime _MAX_INSERTION = 12
"""Ranges this short go to insertion sort. Go's number."""

comptime _SHORTEST_NINTHER = 50
"""Below this the pivot is a median of three; at or above it, a Tukey ninther,
which is the median of three medians of three."""

comptime _MAX_SWAPS = 12
"""4 * 3, the number of order-swaps a ninther makes when the range is exactly
descending. Seeing all of them is the hint that it is."""

comptime _UNKNOWN_HINT = 0
comptime _INCREASING_HINT = 1
comptime _DECREASING_HINT = 2


@fieldwise_init
struct _Xorshift(Copyable, Movable):
    """Marsaglia's xorshift64, seeded from the length of the range.

    Deterministic on purpose. Go seeds it the same way, so two runs over the
    same input make the same swaps, and a failing test is a failing test again
    tomorrow. `_break_patterns` is the only caller and it is not doing
    cryptography.
    """

    var state: UInt64

    def next(mut self) -> UInt64:
        self.state ^= self.state << 13
        self.state ^= self.state >> 7
        self.state ^= self.state << 17
        return self.state


def _next_power_of_two(length: Int) -> UInt64:
    """The smallest power of two strictly greater than `length`.

    Go's `nextPowerOfTwo` shifts by the bit width, so at length 8 it answers
    16 rather than 8. `_break_patterns` only wants a cheap modulus mask and
    corrects for overshoot afterwards, so the off-by-one-doubling is harmless
    and is kept to stay identical to Go.
    """
    return UInt64(1) << bit_width(UInt64(length))


def _insertion_sort[
    less: def(Int, Int) capturing[_] -> Bool,
    swap: def(Int, Int) capturing[_] -> None,
](a: Int, b: Int):
    """Sorts `[a, b)` by insertion. Stable, and the base case for everything."""
    for i in range(a + 1, b):
        var j = i
        while j > a and less(j, j - 1):
            swap(j, j - 1)
            j -= 1


def _sift_down[
    less: def(Int, Int) capturing[_] -> Bool,
    swap: def(Int, Int) capturing[_] -> None,
](lo: Int, hi: Int, first: Int):
    """Restores the heap property on `[lo, hi)` offset by `first`."""
    var root = lo
    while True:
        var child = 2 * root + 1
        if child >= hi:
            break
        if child + 1 < hi and less(first + child, first + child + 1):
            child += 1
        if not less(first + root, first + child):
            return
        swap(first + root, first + child)
        root = child


def _heap_sort[
    less: def(Int, Int) capturing[_] -> Bool,
    swap: def(Int, Int) capturing[_] -> None,
](a: Int, b: Int):
    """Sorts `[a, b)` as a heap.

    This is the fallback, not the algorithm. It is here because it is n log n
    on every input including the ones built to defeat a quicksort, so a range
    that has spent its `limit` on bad pivots finishes in a bounded time instead
    of degrading.
    """
    var first = a
    var lo = 0
    var hi = b - a

    var i = (hi - 1) // 2
    while i >= 0:
        _sift_down[less, swap](i, hi, first)
        i -= 1

    var k = hi - 1
    while k >= 0:
        swap(first, first + k)
        _sift_down[less, swap](lo, k, first)
        k -= 1


def _partition[
    less: def(Int, Int) capturing[_] -> Bool,
    swap: def(Int, Int) capturing[_] -> None,
](a: Int, b: Int, pivot: Int) -> Tuple[Int, Bool]:
    """One quicksort partition of `[a, b)` around the element at `pivot`.

    Returns the pivot's final index and whether the range was already
    partitioned, which the caller uses to decide whether a cheap check for an
    almost-sorted range is worth making.

    The pivot is parked at `a` for the duration, so `less(i, a)` is the
    comparison against it and no element needs copying out.
    """
    swap(a, pivot)
    var i = a + 1
    var j = b - 1

    while i <= j and less(i, a):
        i += 1
    while i <= j and not less(j, a):
        j -= 1
    if i > j:
        swap(j, a)
        return (j, True)
    swap(i, j)
    i += 1
    j -= 1

    while True:
        while i <= j and less(i, a):
            i += 1
        while i <= j and not less(j, a):
            j -= 1
        if i > j:
            break
        swap(i, j)
        i += 1
        j -= 1
    swap(j, a)
    return (j, False)


def _partition_equal[
    less: def(Int, Int) capturing[_] -> Bool,
    swap: def(Int, Int) capturing[_] -> None,
](a: Int, b: Int, pivot: Int) -> Int:
    """Splits `[a, b)` into elements equal to the pivot then elements above it.

    Only called when the caller has established that nothing in the range is
    below the pivot, which is what makes a two-way split correct. It is the
    answer to a range that is mostly one repeated value, where an ordinary
    partition would keep handing back the same lopsided split.
    """
    swap(a, pivot)
    var i = a + 1
    var j = b - 1

    while True:
        while i <= j and not less(a, i):
            i += 1
        while i <= j and less(a, j):
            j -= 1
        if i > j:
            break
        swap(i, j)
        i += 1
        j -= 1
    return i


def _partial_insertion_sort[
    less: def(Int, Int) capturing[_] -> Bool,
    swap: def(Int, Int) capturing[_] -> None,
](a: Int, b: Int) -> Bool:
    """Fixes up to five out-of-order neighbours, and says whether that finished.

    The bet is that a range the pivot chooser called increasing is nearly
    sorted, in which case a handful of adjacent swaps finish it and the whole
    quicksort machinery is skipped. Five is the ceiling on how much is wagered;
    past that it gives up and the caller partitions as usual.
    """
    comptime max_steps = 5
    comptime shortest_shifting = 50

    var i = a + 1
    for _ in range(max_steps):
        while i < b and not less(i, i - 1):
            i += 1

        if i == b:
            return True

        if b - a < shortest_shifting:
            return False

        swap(i, i - 1)

        if i - a >= 2:
            var j = i - 1
            while j >= 1:
                if not less(j, j - 1):
                    break
                swap(j, j - 1)
                j -= 1

        if b - i >= 2:
            var k = i + 1
            while k < b:
                if not less(k, k - 1):
                    break
                swap(k, k - 1)
                k += 1
    return False


def _break_patterns[
    less: def(Int, Int) capturing[_] -> Bool,
    swap: def(Int, Int) capturing[_] -> None,
](a: Int, b: Int):
    """Scatters three elements near the middle of `[a, b)`.

    Called only after a partition came out badly unbalanced. Some inputs are
    shaped so that a deterministic pivot rule picks an extreme every time, and
    three pseudorandom swaps are enough to spoil the shape without costing
    anything on ordinary data.

    `less` is unused and is still a parameter, because every function in this
    file takes the pair and a caller should not have to remember which ones
    need both.
    """
    var length = b - a
    if length >= 8:
        var random = _Xorshift(UInt64(length))
        var modulus = _next_power_of_two(length)

        var start = a + (length // 4) * 2 - 1
        for idx in range(start, start + 3):
            var other = Int(random.next() & (modulus - 1))
            if other >= length:
                other -= length
            swap(idx, a + other)


def _order2[
    less: def(Int, Int) capturing[_] -> Bool,
](a: Int, b: Int, mut swaps: Int) -> Tuple[Int, Int]:
    """`a, b` reordered so the first names the smaller element.

    Counts how often it had to reorder. That count is the whole hint mechanism:
    zero reorderings while choosing a pivot means the samples were already
    ascending, and the maximum means they were exactly descending.
    """
    if less(b, a):
        swaps += 1
        return (b, a)
    return (a, b)


def _median[
    less: def(Int, Int) capturing[_] -> Bool,
](a: Int, b: Int, c: Int, mut swaps: Int) -> Int:
    """Whichever of `a`, `b`, `c` indexes the median of the three."""
    var x: Int
    var y: Int
    x, y = _order2[less](a, b, swaps)
    y, _ = _order2[less](y, c, swaps)
    _, y = _order2[less](x, y, swaps)
    return y


def _median_adjacent[
    less: def(Int, Int) capturing[_] -> Bool,
](a: Int, mut swaps: Int) -> Int:
    """The median of `a - 1`, `a` and `a + 1`."""
    return _median[less](a - 1, a, a + 1, swaps)


def _choose_pivot[
    less: def(Int, Int) capturing[_] -> Bool,
](a: Int, b: Int) -> Tuple[Int, Int]:
    """An index to pivot on, and a hint about how sorted the range looked.

    Under 8 elements the pivot is just the middle. Under 50 it is the median of
    three samples at the quarter points. At 50 and above each of those three
    samples is itself replaced by the median of it and its two neighbours,
    which is Tukey's ninther and costs twelve comparisons to get a pivot that
    is hard to make pathological.

    The hint falls out of the comparison count for free, which is why it is
    worth having: no reorderings means the samples were ascending, the maximum
    means descending, and `_pdqsort` acts on both.
    """
    comptime shortest_ninther = _SHORTEST_NINTHER
    var l = b - a

    var swaps = 0
    var i = a + l // 4 * 1
    var j = a + l // 4 * 2
    var k = a + l // 4 * 3

    if l >= 8:
        if l >= shortest_ninther:
            i = _median_adjacent[less](i, swaps)
            j = _median_adjacent[less](j, swaps)
            k = _median_adjacent[less](k, swaps)
        j = _median[less](i, j, k, swaps)

    if swaps == 0:
        return (j, _INCREASING_HINT)
    if swaps == _MAX_SWAPS:
        return (j, _DECREASING_HINT)
    return (j, _UNKNOWN_HINT)


def _reverse_range[
    swap: def(Int, Int) capturing[_] -> None,
](a: Int, b: Int):
    """Reverses `[a, b)` in place."""
    var i = a
    var j = b - 1
    while i < j:
        swap(i, j)
        i += 1
        j -= 1


def _pdqsort[
    less: def(Int, Int) capturing[_] -> Bool,
    swap: def(Int, Int) capturing[_] -> None,
](a_in: Int, b_in: Int, limit_in: Int):
    """Sorts `[a_in, b_in)`. Not stable.

    Go's loop, with its own recursion on the smaller half and a tail iteration
    on the larger one, so the stack depth stays logarithmic even though the
    partition sizes do not.
    """
    var a = a_in
    var b = b_in
    var limit = limit_in
    var was_balanced = True
    var was_partitioned = True

    while True:
        var length = b - a

        if length <= _MAX_INSERTION:
            _insertion_sort[less, swap](a, b)
            return

        if limit == 0:
            _heap_sort[less, swap](a, b)
            return

        if not was_balanced:
            _break_patterns[less, swap](a, b)
            limit -= 1

        var pivot: Int
        var hint: Int
        pivot, hint = _choose_pivot[less](a, b)
        if hint == _DECREASING_HINT:
            _reverse_range[swap](a, b)
            # The pivot was `pivot - a` from the start; after the reversal it
            # is that far from the end.
            pivot = (b - 1) - (pivot - a)
            hint = _INCREASING_HINT

        if was_balanced and was_partitioned and hint == _INCREASING_HINT:
            if _partial_insertion_sort[less, swap](a, b):
                return

        # Everything to the left is already below this pivot, so the range is
        # probably one repeated value and a two-way split makes progress where
        # an ordinary partition would not.
        if a > 0 and not less(a - 1, pivot):
            a = _partition_equal[less, swap](a, b, pivot)
            continue

        var mid: Int
        var already: Bool
        mid, already = _partition[less, swap](a, b, pivot)
        was_partitioned = already

        var left_len = mid - a
        var right_len = b - mid
        var balance_threshold = length // 8
        if left_len < right_len:
            was_balanced = left_len >= balance_threshold
            _pdqsort[less, swap](a, mid, limit)
            a = mid + 1
        else:
            was_balanced = right_len >= balance_threshold
            _pdqsort[less, swap](mid + 1, b, limit)
            b = mid


def _sort_range[
    less: def(Int, Int) capturing[_] -> Bool,
    swap: def(Int, Int) capturing[_] -> None,
](n: Int):
    """Sorts `[0, n)`, choosing the pivot budget Go chooses.

    `bit_width(n)` bad partitions are allowed before the range falls back to
    heapsort. That is about log2 n, so an input built to force bad pivots costs
    a logarithmic number of them and then stops being able to.
    """
    if n <= 1:
        return
    _pdqsort[less, swap](0, n, Int(bit_width(UInt64(n))))
