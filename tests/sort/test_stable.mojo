"""Stability, proved rather than observed.

A test that sorts `[3, 1, 2]` and checks the output is `[1, 2, 3]` says nothing
about stability, and neither does one that sorts records and finds them in a
plausible order: with distinct keys every correct sort agrees, and with a small
example an unstable sort lands on the stable answer by luck often enough that
the test is a coin toss.

So every case here carries a second field that the comparator never sees. Each
element knows where it started, the sort is told only about the key, and the
assertion is that within every run of equal keys the starting positions still
ascend. That is the definition, and it cannot be passed by accident: with
twenty keys over a thousand elements there are fifty in each group, and the
chance of fifty numbers coming out ascending after an unstable sort is one in
fifty factorial.

The sizes are chosen around `stable.mojo`'s block size of 20 and the doubling
above it, because that is where an off-by-one in the merge would live: 19, 20
and 21 sit either side of the first block, 39, 40 and 41 either side of the
first merge, and 1023, 1024 and 1025 either side of a clean power of two.
"""

from std.testing import assert_equal, assert_true

from core.sort import Interface, is_sorted, slice_stable, sort, stable

from ._fixtures import Random


struct ByKey[k: MutOrigin, t: MutOrigin](Interface):
    """Two parallel arrays: the keys that are sorted, and tags that are carried.

    Parallel arrays rather than a list of pairs, because that is the case
    `Interface` exists for and a test that only ever sorts one contiguous span
    has not used it. The comparator reads `keys` and never `tags`, so nothing
    about a tag can influence where its element ends up — which is what makes
    the tags evidence.
    """

    var keys: Span[Int, Self.k]
    var tags: Span[Int, Self.t]

    def __init__(out self, keys: Span[Int, Self.k], tags: Span[Int, Self.t]):
        self.keys = keys
        self.tags = tags

    def __len__(self) -> Int:
        return len(self.keys)

    def less(self, i: Int, j: Int) -> Bool:
        return self.keys[i] < self.keys[j]

    def swap(mut self, i: Int, j: Int):
        var key = self.keys[i]
        self.keys[i] = self.keys[j]
        self.keys[j] = key
        var tag = self.tags[i]
        self.tags[i] = self.tags[j]
        self.tags[j] = tag


def _shuffled_keys(mut rng: Random, n: Int, distinct: Int) -> List[Int]:
    """`n` keys drawn from `distinct` values, in a deliberately jumbled order.

    Drawn at random rather than laid out in runs, because input that arrives
    already grouped is input a stable sort barely has to move, and a merge that
    dropped its stability would still pass over it.
    """
    var keys = List[Int]()
    for _ in range(n):
        keys.append(rng.below(distinct))
    return keys^


def _tags(n: Int) -> List[Int]:
    """Where each element started. Never shown to the comparator."""
    var tags = List[Int]()
    for i in range(n):
        tags.append(i)
    return tags^


def _assert_stable(keys: List[Int], tags: List[Int]) raises:
    """Keys ascend, and tags ascend inside every run of equal keys.

    Both halves are needed. Tags ascending everywhere would mean the sort did
    nothing; keys ascending alone is what an unstable sort also achieves.
    """
    for i in range(1, len(keys)):
        assert_true(keys[i - 1] <= keys[i])
        if keys[i - 1] == keys[i]:
            assert_true(tags[i - 1] < tags[i])


def _sizes() -> List[Int]:
    """Either side of the block size, of the first merge, and of 1024."""
    return [0, 1, 2, 3, 4, 5, 19, 20, 21, 39, 40, 41, 100, 1023, 1024, 1025]


def test_stable_keeps_equal_elements_in_order() raises:
    """Twenty keys over every size, so each group is large enough to be proof.
    """
    var rng = Random()
    for n in _sizes():
        var keys = _shuffled_keys(rng, n, 20)
        var tags = _tags(n)
        var view = ByKey(Span(keys), Span(tags))
        stable(view)
        _assert_stable(keys, tags)


def test_stable_with_only_two_distinct_keys() raises:
    """The hardest case: five hundred elements in each group, so a merge that
    ever takes from the right side first is caught immediately."""
    var rng = Random()
    var keys = _shuffled_keys(rng, 1000, 2)
    var tags = _tags(1000)
    var view = ByKey(Span(keys), Span(tags))
    stable(view)
    _assert_stable(keys, tags)


def test_stable_with_every_key_equal() raises:
    """Nothing may move at all. The output is the input, tag for tag."""
    var n = 500
    var keys = List[Int]()
    for _ in range(n):
        keys.append(7)
    var tags = _tags(n)
    var view = ByKey(Span(keys), Span(tags))
    stable(view)
    for i in range(n):
        assert_equal(tags[i], i)


def test_stable_with_every_key_distinct() raises:
    """Stability is vacuous here, so this is checking the ordinary sort in the
    same harness: keys ascend and every tag arrived with its key."""
    var rng = Random()
    var n = 500
    var keys = _shuffled_keys(rng, n, 1000000)
    var original = keys.copy()
    var tags = _tags(n)
    var view = ByKey(Span(keys), Span(tags))
    stable(view)
    for i in range(n):
        assert_equal(keys[i], original[tags[i]])
    _assert_stable(keys, tags)


def test_stable_on_input_that_is_already_in_order() raises:
    """No key moves, so no tag may either."""
    var n = 200
    var keys = List[Int]()
    for i in range(n):
        keys.append(i // 4)
    var tags = _tags(n)
    var view = ByKey(Span(keys), Span(tags))
    stable(view)
    for i in range(n):
        assert_equal(tags[i], i)


def test_stable_on_input_that_is_exactly_reversed() raises:
    """Every group arrives backwards, so every group has to be turned around
    and no group may be left as it came."""
    var n = 200
    var keys = List[Int]()
    for i in range(n):
        keys.append((n - 1 - i) // 4)
    var tags = _tags(n)
    var view = ByKey(Span(keys), Span(tags))
    stable(view)
    _assert_stable(keys, tags)


def test_slice_stable_is_stable_over_a_span_of_pairs() raises:
    """The same proof through the span entry point, where the elements are one
    contiguous list and the swap goes through a copy."""
    var rng = Random()
    var n = 1000
    var keys = _shuffled_keys(rng, n, 20)
    var tags = _tags(n)
    var pairs = List[Tuple[Int, Int]]()
    for i in range(n):
        pairs.append((keys[i], tags[i]))
    var view = Span(pairs)

    @parameter
    def by_key(i: Int, j: Int) -> Bool:
        return view[i][0] < view[j][0]

    slice_stable[by_key](view)

    var sorted_keys = List[Int]()
    var sorted_tags = List[Int]()
    for pair in pairs:
        sorted_keys.append(pair[0])
        sorted_tags.append(pair[1])
    _assert_stable(sorted_keys, sorted_tags)


def test_the_unstable_sort_still_sorts_and_keeps_every_element() raises:
    """`sort` promises an order and not an order among equals.

    So this asserts only what it promises: the keys ascend and every element
    that went in came out. Asserting that the tags are scrambled would be
    asserting a bug, and asserting they are not would be asserting a guarantee
    the package does not give.
    """
    var rng = Random()
    var n = 1000
    var keys = _shuffled_keys(rng, n, 20)
    var tags = _tags(n)
    var view = ByKey(Span(keys), Span(tags))
    sort(view)
    assert_true(is_sorted(view))

    var seen = List[Bool]()
    for _ in range(n):
        seen.append(False)
    for tag in tags:
        assert_true(not seen[tag])
        seen[tag] = True
