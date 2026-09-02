"""The stable sort: insertion sort on blocks, then SymMerge upwards.

Ported from Go's `zsortinterface.go`, which in turn implements Kim and
Kutzner, "Stable Minimum Storage Merging by Symmetric Comparisons", ESA 2004.

Stability is the whole point and it is a property of the algorithm, not of the
test data. Insertion sort never moves an element past an equal one, and
SymMerge, when it has to choose between two equal elements, takes the one from
the left block. Neither of those depends on the input, which is why
`tests/sort/test_stable.mojo` can assert on the original positions of equal
elements rather than hoping the answer looks right.

The cost is Go's cost: n log n comparisons and n log squared n swaps, using
only logarithmic extra stack and no extra array. A merge sort with a scratch
buffer would swap less, and it would also need somewhere to put the buffer,
which an `Interface` that is a database cursor or a pair of parallel arrays
does not have.
"""

from .pdq import _insertion_sort


def _swap_range[
    swap: def(Int, Int) capturing[_] -> None,
](a: Int, b: Int, n: Int):
    """Exchanges the `n` elements at `a` with the `n` elements at `b`."""
    for i in range(n):
        swap(a + i, b + i)


def _rotate[
    swap: def(Int, Int) capturing[_] -> None,
](a: Int, m: Int, b: Int):
    """Turns `u v` into `v u`, where `u` is `[a, m)` and `v` is `[m, b)`.

    The block-swapping rotation: repeatedly exchange the shorter block with an
    equal-length piece of the longer one, which is the subtraction step of
    Euclid's algorithm and lands every element in its final place with at most
    `b - a` swaps.

    Assumes `a < m < b`; the caller checks, because checking here would cost a
    branch on every one of the many leaf calls.
    """
    var i = m - a
    var j = b - m

    while i != j:
        if i > j:
            _swap_range[swap](m - i, m, j)
            i -= j
        else:
            _swap_range[swap](m - i, m + j - i, i)
            j -= i
    _swap_range[swap](m - i, m, i)


def _sym_merge[
    less: def(Int, Int) capturing[_] -> Bool,
    swap: def(Int, Int) capturing[_] -> None,
](a: Int, m: Int, b: Int):
    """Merges the sorted runs `[a, m)` and `[m, b)` in place.

    The two single-element cases at the top are not an optimisation of the
    general case, they are most of the calls: a merge sort's recursion bottoms
    out on them, and handling them here removes two levels of recursion per
    merge.

    Ties go to the left run. That is where stability lives: the binary search
    in the first branch stops at the lowest index whose element is not less
    than the one being placed, so an equal element from the right run never
    ends up in front of one from the left.
    """
    if m - a == 1:
        # One element on the left. Binary search for where it belongs in the
        # right run and walk it there.
        var i = m
        var j = b
        while i < j:
            var h = Int(UInt(i + j) >> 1)
            if less(h, a):
                i = h + 1
            else:
                j = h
        for k in range(a, i - 1):
            swap(k, k + 1)
        return

    if b - m == 1:
        # One element on the right, mirrored.
        var i = a
        var j = m
        while i < j:
            var h = Int(UInt(i + j) >> 1)
            if not less(m, h):
                i = h + 1
            else:
                j = h
        var k = m
        while k > i:
            swap(k, k - 1)
            k -= 1
        return

    var mid = Int(UInt(a + b) >> 1)
    var n = mid + m
    var start: Int
    var r: Int
    if m > mid:
        start = n - b
        r = mid
    else:
        start = a
        r = m
    var p = n - 1

    # The symmetric comparison the algorithm is named for: find the split
    # where the left run's suffix and the right run's prefix can be exchanged
    # wholesale, which is the rotation below.
    while start < r:
        var c = Int(UInt(start + r) >> 1)
        if not less(p - c, c):
            start = c + 1
        else:
            r = c

    var end = n - start
    if start < m and m < end:
        _rotate[swap](start, m, end)
    if a < start and start < mid:
        _sym_merge[less, swap](a, start, mid)
    if mid < end and end < b:
        _sym_merge[less, swap](mid, end, b)


def _stable_range[
    less: def(Int, Int) capturing[_] -> Bool,
    swap: def(Int, Int) capturing[_] -> None,
](n: Int):
    """Sorts `[0, n)` stably.

    Insertion sort over blocks of twenty first, because insertion sort is the
    fastest thing there is on twenty elements and it is stable, then merge
    neighbouring blocks and double the block size until one block covers
    everything.
    """
    var block_size = 20
    var a = 0
    var b = block_size
    while b <= n:
        _insertion_sort[less, swap](a, b)
        a = b
        b += block_size
    _insertion_sort[less, swap](a, n)

    while block_size < n:
        a = 0
        b = 2 * block_size
        while b <= n:
            _sym_merge[less, swap](a, a + block_size, b)
            a = b
            b += 2 * block_size
        var m = a + block_size
        if m < n:
            _sym_merge[less, swap](a, m, n)
        block_size *= 2
