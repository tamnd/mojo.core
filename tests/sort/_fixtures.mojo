"""The inputs Go's sort tests are run over, and the counters that watch a sort.

Go's `sort` package gets most of its confidence from two things that are not
"here is a list, is it sorted afterwards". The first is Bentley and McIlroy's
grid from *Engineering a Sort Function* (1993): five ways of generating values,
six ways of permuting them, every size around a power of two, which between
them hit the shapes that break a naive quicksort — long runs of equal keys,
already-sorted input, organ-pipe input. The second is a swap budget, because a
sort that has fallen to quadratic still returns the right answer and the only
evidence is that it took n squared moves to do it.

Both live here rather than in one test file because `test_slice.mojo`,
`test_interface.mojo` and `test_stable.mojo` all want them, with different
bounds: an unstable sort is allowed `n lg n` swaps and a stable one `n lg n
lg n`, which is the same grid and a different budget.

The generator is a fixed xorshift rather than a system source. A grid failure
is a bug in a sort, and reproducing it must not depend on the day.
"""


@fieldwise_init
struct Random(Copyable, Movable):
    """xorshift64, seeded, so that every run sees the same grid.

    Go's tests use `math/rand`, which is seeded from the clock in recent
    versions and therefore hands you a different grid each run. That trade —
    covering more inputs over time against being able to rerun a failure — is
    the right one for a package with thirty years of use behind it and the
    wrong one for a port being written now, where the first failure is the
    thing you most want to be able to run again.
    """

    var state: UInt64

    def __init__(out self):
        self.state = 0x2545F4914F6CDD1D

    def next(mut self) -> UInt64:
        self.state ^= self.state << 13
        self.state ^= self.state >> 7
        self.state ^= self.state << 17
        return self.state

    def below(mut self, n: Int) -> Int:
        """A value in `[0, n)`. `n` must be positive."""
        return Int(self.next() % UInt64(n))


def lg(n: Int) -> Int:
    """The smallest `i` with `1 << i >= n`, which is Go's `lg` from `sort_test.go`.

    Used only to size the swap budgets. It is written the same slow way Go
    writes it so that the budget numbers here can be compared with Go's without
    anyone having to check whether the two agree at the boundaries.
    """
    var i = 0
    while (1 << i) < n:
        i += 1
    return i


def sizes() -> List[Int]:
    """Go's sizes: one small, and the three around a power of two.

    The three matter because a halving loop divides 1024 evenly and 1023 and
    1025 unevenly, and an off-by-one in a partition tends to survive the even
    case. A function rather than a `comptime` list because a comptime `Array`
    cannot be walked by a runtime loop.
    """
    return [100, 1023, 1024, 1025]


comptime N_DIST = 5
"""sawtooth, rand, stagger, plateau, shuffle."""

comptime N_MODE = 6
"""copy, reverse, reverse first half, reverse second half, sorted, dither."""


def distribution(mut rng: Random, dist: Int, n: Int, m: Int) -> List[Int]:
    """One of Bentley and McIlroy's five value distributions, `n` long.

    `m` is their spread parameter, run over the powers of two below `2n`. At
    `m = 1` a sawtooth is all zeros and a plateau is all ones, which is the
    all-equal input; at `m = n` the sawtooth is `0..n` and the input is already
    sorted. So sweeping `m` sweeps between the two shapes a quicksort handles
    worst, and the tests do not have to name either of them.
    """
    var data = List[Int]()
    var j = 0
    var k = 1
    for i in range(n):
        if dist == 0:  # sawtooth
            data.append(i % m)
        elif dist == 1:  # rand
            data.append(rng.below(m))
        elif dist == 2:  # stagger
            data.append((i * m + i) % n)
        elif dist == 3:  # plateau
            data.append(min(i, m))
        else:  # shuffle
            if rng.below(m) != 0:
                j += 2
                data.append(j)
            else:
                k += 2
                data.append(k)
    return data^


def permutation(data: List[Int], mode: Int) -> List[Int]:
    """One of Bentley and McIlroy's six permutations of a distribution.

    `sorted` is done here with a scan-and-insert rather than by calling the
    package, because a test input must not be built by the thing under test:
    if `ints` were broken, mode 4 would hand it input it had already broken and
    the case would pass.
    """
    var n = len(data)
    var out = List[Int]()
    if mode == 0:  # copy
        for i in range(n):
            out.append(data[i])
    elif mode == 1:  # reverse
        for i in range(n):
            out.append(data[n - i - 1])
    elif mode == 2:  # reverse the first half
        for i in range(n // 2):
            out.append(data[n // 2 - i - 1])
        for i in range(n // 2, n):
            out.append(data[i])
    elif mode == 3:  # reverse the second half
        for i in range(n // 2):
            out.append(data[i])
        for i in range(n // 2, n):
            out.append(data[n - (i - n // 2) - 1])
    elif mode == 4:  # sorted
        for i in range(n):
            out.append(data[i])
        _insertion_sorted(out)
    else:  # dither
        for i in range(n):
            out.append(data[i] + i % 5)
    return out^


def _insertion_sorted(mut data: List[Int]):
    """Insertion sort, written out, so that mode 4 owes nothing to `core.sort`.

    Quadratic and only ever asked for 1025 elements at a time, which is a
    million operations and invisible next to the grid it feeds.
    """
    for i in range(1, len(data)):
        var held = data[i]
        var j = i - 1
        while j >= 0 and data[j] > held:
            data[j + 1] = data[j]
            j -= 1
        data[j + 1] = held


def histogram(data: List[Int]) -> Dict[Int, Int]:
    """How many times each value appears.

    A sort is a permutation, and checking only that the output is ascending
    misses a swap that duplicates an element instead of exchanging it — which
    is exactly the failure a copy-based swap through a temporary can have, and
    the swap in `slice.mojo` is copy-based. Comparing histograms before and
    after is the check that would catch it.
    """
    var counts = Dict[Int, Int]()
    for value in data:
        counts[value] = counts.get(value, 0) + 1
    return counts^


def same_multiset(before: Dict[Int, Int], after: Dict[Int, Int]) -> Bool:
    """Whether two histograms agree, in both directions."""
    if len(before) != len(after):
        return False
    for entry in before.items():
        if after.get(entry.key, -1) != entry.value:
            return False
    return True
