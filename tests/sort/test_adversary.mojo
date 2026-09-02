"""The two adversaries, and the reason this package is a port.

McIlroy's *A Killer Adversary for Quicksort* (1999) does not build a bad input.
It answers the sort's questions as they arrive, choosing each answer so that
whatever pivot the sort is about to pick turns out to be the worst one
available. The answers stay consistent with some total order throughout, so
this is a legal comparator and there is no excuse: a sort that goes quadratic
here is a sort that can be made quadratic by data. Go runs it at 10,000
elements with a budget of `n lg n * 4` comparisons and so does
`test_adversary_cannot_make_the_sort_quadratic` below.

The second adversary is the one this package exists for. It answers at random,
which is *not* consistent with any order, and the only thing a sort owes such a
caller is a wrong answer — not a wrong address. `std.builtin.sort` hands the
comparator indices from outside the span it was given under exactly this
treatment: 645 of them out of a 1,000 element range, which without padding
around the data is a read past the end and a dead process. Go's sort does not,
at any size, stable or not. `docs/deviations.md` has the measurement and issue
#16 has the reproducer.

So `test_an_inconsistent_comparator_never_leaves_the_span` is the test `std`
fails, and it is the whole reason `pdq.mojo` and `stable.mojo` are here rather
than a forwarding import. The required count is zero, not "few".
"""

from std.testing import assert_equal, assert_true

from core.sort import Interface, slice, slice_stable, sort, stable

from ._fixtures import histogram, lg, same_multiset

comptime NCMP = 0
"""Index into the adversary's state list: comparisons made so far."""

comptime NSOLID = 1
"""How many elements have been given a real value instead of gas."""

comptime CANDIDATE = 2
"""The element the adversary believes the sort is about to use as a pivot."""

comptime GAS = 3
"""The placeholder value, meaning "not decided yet"."""

comptime OUT_OF_RANGE = 4
"""Set to 1 the first time an index outside `[0, n)` arrives."""


struct Adversary[d: MutOrigin, s: MutOrigin](Interface):
    """McIlroy's killer adversary, as an `Interface`.

    Every element starts as gas, meaning the adversary has not yet committed to
    a value for it. When the sort compares two undecided elements the adversary
    freezes one — the one that is *not* the current pivot candidate — to the
    next real value, so the candidate stays as large as possible and keeps
    being chosen as a pivot that splits off a single element. Everything else
    stays gas, which compares as the largest value there is, so the answers
    remain consistent with a total order that is only decided as it goes.

    The state is reached through pointers because `less` takes `self` by
    borrow. Go's has a pointer receiver and gets the same thing for free.
    """

    var data: Pointer[List[Int], Self.d]
    var state: Pointer[List[Int], Self.s]

    def __init__(
        out self, ref[Self.d] data: List[Int], ref[Self.s] state: List[Int]
    ):
        self.data = Pointer(to=data)
        self.state = Pointer(to=state)

    def __len__(self) -> Int:
        return len(self.data[])

    def less(self, i: Int, j: Int) -> Bool:
        var n = len(self.data[])
        if i < 0 or i >= n or j < 0 or j >= n:
            self.state[][OUT_OF_RANGE] = 1
            return False

        self.state[][NCMP] += 1
        var gas = self.state[][GAS]

        if self.data[][i] == gas and self.data[][j] == gas:
            if i == self.state[][CANDIDATE]:
                self.data[][i] = self.state[][NSOLID]
            else:
                self.data[][j] = self.state[][NSOLID]
            self.state[][NSOLID] += 1

        if self.data[][i] == gas:
            self.state[][CANDIDATE] = i
        elif self.data[][j] == gas:
            self.state[][CANDIDATE] = j

        return self.data[][i] < self.data[][j]

    def swap(mut self, i: Int, j: Int):
        var n = len(self.data[])
        if i < 0 or i >= n or j < 0 or j >= n:
            self.state[][OUT_OF_RANGE] = 1
            return
        var held = self.data[][i]
        self.data[][i] = self.data[][j]
        self.data[][j] = held


def _gassed(n: Int) -> List[Int]:
    """`n` elements, all gas. Gas is `n - 1`, which is Go's choice: it is the
    last value the adversary will ever hand out, so an undecided element
    compares as the largest thing in the range."""
    var data = List[Int]()
    for _ in range(n):
        data.append(n - 1)
    return data^


def _state(n: Int) -> List[Int]:
    var state: List[Int] = [0, 0, 0, n - 1, 0]
    return state^


struct Chaotic[o: MutOrigin, s: MutOrigin](Interface):
    """A comparator that answers at random, which is no ordering at all.

    `less(i, j)` and `less(j, i)` can both be true, `less(i, i)` can be true,
    and nothing is transitive. Every guarantee a sort has about where its
    indices are comes from the ordering, so this removes all of them at once
    and asks what is left.

    What must be left is that the indices stay inside the data. The result is
    allowed to be any permutation at all — this is the caller's mistake and the
    package promises them nothing about the order — but it may not be a read
    outside the span, because that is not a wrong answer, it is a crash in a
    process that had a bug somewhere else entirely.
    """

    var values: Span[Int, Self.o]
    var state: Pointer[List[Int], Self.s]

    def __init__(
        out self, values: Span[Int, Self.o], ref[Self.s] state: List[Int]
    ):
        self.values = values
        self.state = Pointer(to=state)

    def __len__(self) -> Int:
        return len(self.values)

    def less(self, i: Int, j: Int) -> Bool:
        var n = len(self.values)
        if i < 0 or i >= n or j < 0 or j >= n:
            self.state[][OUT_OF_RANGE] = 1
            return False
        # xorshift, inline, because a borrowed self cannot hold the generator.
        var x = UInt64(self.state[][NCMP] + 1) * 0x2545F4914F6CDD1D
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        self.state[][NCMP] += 1
        return (x & 1) == 1

    def swap(mut self, i: Int, j: Int):
        var n = len(self.values)
        if i < 0 or i >= n or j < 0 or j >= n:
            self.state[][OUT_OF_RANGE] = 1
            return
        var held = self.values[i]
        self.values[i] = self.values[j]
        self.values[j] = held


# slow: 10,000 elements against an adversary that answers to make it worse
def test_adversary_cannot_make_the_sort_quadratic() raises:
    """Go's `TestAdversary`, at Go's size and Go's budget.

    10,000 elements, `n lg n * 4` comparisons. That factor of four is Go's, and
    it was found by trial and error rather than derived, so it is copied rather
    than recomputed. Quadratic here would be 100 million comparisons against a
    budget of 560,000, so the margin is not close and a failure means the
    fallback to heapsort has stopped happening.

    The adversary hands out the values `0` through `n - 1` as it goes, so a
    fully sorted result is `data[i] == i` exactly. That is a stronger check
    than `is_sorted`: it says the sort produced the one right answer to the
    order the adversary committed to, not merely an ascending sequence.
    """
    var n = 10000
    var data = _gassed(n)
    var state = _state(n)
    var view = Adversary(data, state)
    sort(view)

    assert_equal(state[OUT_OF_RANGE], 0)
    assert_true(state[NCMP] <= n * lg(n) * 4)
    for i in range(n):
        assert_equal(data[i], i)


def test_adversary_at_the_size_the_std_measurement_used() raises:
    """The same adversary at 1,000, which is the size issue #16 measured."""
    var n = 1000
    var data = _gassed(n)
    var state = _state(n)
    var view = Adversary(data, state)
    sort(view)

    assert_equal(state[OUT_OF_RANGE], 0)
    assert_true(state[NCMP] <= n * lg(n) * 4)
    for i in range(n):
        assert_equal(data[i], i)


def test_the_stable_sort_also_survives_the_adversary() raises:
    """SymMerge is not a quicksort and has no pivot to poison, so there is
    nothing here for the adversary to attack. It is run anyway, because "that
    algorithm cannot have this bug" is a claim and this is the check."""
    var n = 1000
    var data = _gassed(n)
    var state = _state(n)
    var view = Adversary(data, state)
    stable(view)

    assert_equal(state[OUT_OF_RANGE], 0)
    for i in range(n):
        assert_equal(data[i], i)


def test_an_inconsistent_comparator_never_leaves_the_span() raises:
    """Zero out-of-range indices, at every size, from an ordering that is not one.

    This is the test `std.builtin.sort` fails and the reason this package is a
    port. The required count is zero: not small, not "none observed on the
    sizes we tried". Every size from 0 to 40 covers the insertion-sort cutoff
    at 12 and the ninther threshold; 1,000 is the size the `std` measurement
    used; 5,000 is past the recursion limit where the fallback to heapsort
    kicks in, which is a different code path and would be a different bug.
    """
    var counts = List[Int]()
    for n in range(41):
        counts.append(n)
    for n in [1000, 5000]:
        counts.append(n)

    for n in counts:
        var values = List[Int]()
        for i in range(n):
            values.append(i)
        var before = histogram(values)
        var state: List[Int] = [0, 0, 0, 0, 0]
        var view = Chaotic(Span(values), state)
        sort(view)
        assert_equal(state[OUT_OF_RANGE], 0)
        assert_true(same_multiset(before, histogram(values)))


def test_an_inconsistent_comparator_never_leaves_the_span_when_stable() raises:
    """The same, through SymMerge, whose rotations do their own index
    arithmetic and so could be wrong in an entirely separate way."""
    for n in [0, 1, 2, 3, 12, 13, 20, 21, 40, 41, 1000]:
        var values = List[Int]()
        for i in range(n):
            values.append(i)
        var before = histogram(values)
        var state: List[Int] = [0, 0, 0, 0, 0]
        var view = Chaotic(Span(values), state)
        stable(view)
        assert_equal(state[OUT_OF_RANGE], 0)
        assert_true(same_multiset(before, histogram(values)))


def test_a_comparator_that_always_answers_true_keeps_every_element() raises:
    """`less(i, j)` and `less(j, i)` both true, for every pair. There is no
    order this can be describing, and the span still has to come back whole."""
    var n = 500
    var values = List[Int]()
    for i in range(n):
        values.append(i)
    var before = histogram(values)
    var view = Span(values)

    @parameter
    def always(i: Int, j: Int) -> Bool:
        return True

    slice[always](view)
    assert_true(same_multiset(before, histogram(values)))
    assert_equal(len(values), n)


def test_a_comparator_that_answers_by_coin_toss_keeps_every_element() raises:
    """Through the span entry point rather than through `Interface`, so that
    the copy-based swap is the one being asked to survive it."""
    var n = 1000
    var values = List[Int]()
    for i in range(n):
        values.append(i)
    var before = histogram(values)
    var view = Span(values)
    var tosses: List[Int] = [0]

    @parameter
    def coin(i: Int, j: Int) -> Bool:
        var x = UInt64(tosses[0] + 1) * 0x2545F4914F6CDD1D
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        tosses[0] += 1
        return (x & 1) == 1

    slice[coin](view)
    assert_true(same_multiset(before, histogram(values)))

    var again: List[Int] = [0]

    @parameter
    def coin_again(i: Int, j: Int) -> Bool:
        var x = UInt64(again[0] + 1) * 0x2545F4914F6CDD1D
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        again[0] += 1
        return (x & 1) == 1

    slice_stable[coin_again](view)
    assert_true(same_multiset(before, histogram(values)))
