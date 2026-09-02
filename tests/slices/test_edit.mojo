"""Changing what is in a list, and how much of it.

Go's tests for this half are the largest part of `slices_test.go`, and the
reason is that `Insert`, `Delete` and `Replace` are the functions that shift
memory around and the off-by-one lives in the shifting. So the shape of this
file is Go's: a table of every position for every input, checked against the
answer written out by hand.

Two of Go's concerns do not exist here and have tests saying so instead.
Overlap — `Insert(s, i, s...)` — cannot be written, because the borrow checker
will not lend out a read of a list that is mutably borrowed. And Go's
`clear`-the-tail tests exist so that dropped elements do not keep objects alive
for the collector; here `shrink` destroys them and `test_delete_destroys_what_it_dropped`
watches that happen.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.slices import (
    clip,
    clone,
    compact,
    compact_func,
    concat,
    delete,
    delete_func,
    grow,
    insert,
    repeat,
    replace,
    reverse,
)

from _fixtures import counted


struct Tracked[c: MutOrigin](Copyable, Deinitable, Equatable, Movable):
    """An element that keeps a count of how many of it are alive.

    Go's `Delete` and `Compact` tests check that the obsolete tail is cleared,
    because a stale reference there keeps an object alive for the collector.
    The Mojo version of that question is whether the dropped elements were
    destroyed, and the honest way to ask it is a live count rather than a
    destructor count: `compact` copies an element and destroys the old one at
    the same position, so the number of destructor calls is an implementation
    detail while the number of survivors is not.
    """

    var value: Int
    var live: Pointer[List[Int], Self.c]

    def __init__(out self, value: Int, ref[Self.c] live: List[Int]):
        self.value = value
        self.live = Pointer(to=live)
        self.live[][0] += 1

    def __init__(out self, *, copy: Self):
        self.value = copy.value
        self.live = copy.live
        self.live[][0] += 1

    def __deinit__(deinit self):
        self.live[][0] -= 1

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


def test_insert_at_every_position() raises:
    for at in range(4):
        var values = counted(3)
        var middle: List[Int] = [90, 91]
        insert(values, at, Span(middle))
        var want = List[Int](capacity=5)
        for i in range(at):
            want.append(i)
        want.append(90)
        want.append(91)
        for i in range(at, 3):
            want.append(i)
        assert_equal(values, want)


def test_insert_of_one_element() raises:
    var values: List[Int] = [1, 3]
    var one: List[Int] = [2]
    insert(values, 1, Span(one))
    assert_equal(values, [1, 2, 3])


def test_insert_of_nothing_changes_nothing() raises:
    var values: List[Int] = [1, 2, 3]
    var none = List[Int]()
    insert(values, 1, Span(none))
    assert_equal(values, [1, 2, 3])
    insert(values, 3, Span(none))
    assert_equal(values, [1, 2, 3])


def test_insert_into_an_empty_list() raises:
    var values = List[Int]()
    var some: List[Int] = [1, 2]
    insert(values, 0, Span(some))
    assert_equal(values, [1, 2])


def test_insert_out_of_range_raises_and_leaves_the_list_alone() raises:
    var values: List[Int] = [1, 2, 3]
    var some: List[Int] = [9]
    with assert_raises(contains="index out of range"):
        insert(values, 4, Span(some))
    with assert_raises(contains="index out of range"):
        insert(values, -1, Span(some))
    assert_equal(values, [1, 2, 3])


def test_insert_of_a_long_run_at_the_front() raises:
    # The rotation has to move the whole original, which is the case a
    # shift-by-one loop written the wrong way round gets wrong.
    var values = counted(10)
    var head = counted(50)
    insert(values, 0, Span(head))
    assert_equal(len(values), 60)
    for i in range(50):
        assert_equal(values[i], i)
    for i in range(10):
        assert_equal(values[50 + i], i)


def test_insert_of_strings_moves_rather_than_corrupts() raises:
    var values: List[String] = ["a", "d"]
    var middle: List[String] = ["b", "c"]
    insert(values, 1, Span(middle))
    assert_equal(len(values), 4)
    assert_equal(values[0], "a")
    assert_equal(values[1], "b")
    assert_equal(values[2], "c")
    assert_equal(values[3], "d")


def test_delete_every_range_of_a_small_list() raises:
    for i in range(6):
        for j in range(i, 6):
            var values = counted(5)
            delete(values, i, j)
            var want = List[Int](capacity=5)
            for k in range(5):
                if k < i or k >= j:
                    want.append(k)
            assert_equal(values, want)


def test_delete_of_an_empty_range_changes_nothing() raises:
    var values: List[Int] = [1, 2, 3]
    delete(values, 2, 2)
    assert_equal(values, [1, 2, 3])


def test_delete_out_of_range_raises() raises:
    var values: List[Int] = [1, 2, 3]
    with assert_raises(contains="index out of range"):
        delete(values, 1, 4)
    with assert_raises(contains="index out of range"):
        delete(values, 2, 1)
    with assert_raises(contains="index out of range"):
        delete(values, -1, 2)
    assert_equal(values, [1, 2, 3])


def test_delete_destroys_what_it_dropped() raises:
    # Go's `Delete` clears the tail so the collector can reclaim it. Here the
    # dropped elements are destroyed, which is stronger, and this counts what
    # is left alive rather than trusting the length.
    var live: List[Int] = [0]
    var values = List[Tracked[origin_of(live)]](capacity=4)
    for i in range(4):
        values.append(Tracked(i, live))
    assert_equal(live[0], 4)
    delete(values, 1, 3)
    assert_equal(len(values), 2)
    assert_equal(live[0], 2)
    assert_equal(values[0].value, 0)
    assert_equal(values[1].value, 3)


def test_delete_func_removes_scattered_elements() raises:
    var values = counted(10)

    @parameter
    def odd(x: Int) -> Bool:
        return x % 2 == 1

    delete_func[odd](values)
    assert_equal(values, [0, 2, 4, 6, 8])


def test_delete_func_that_matches_nothing_or_everything() raises:
    var none = counted(5)

    @parameter
    def never(x: Int) -> Bool:
        return False

    @parameter
    def always(x: Int) -> Bool:
        return True

    delete_func[never](none)
    assert_equal(none, [0, 1, 2, 3, 4])

    var all_of_them = counted(5)
    delete_func[always](all_of_them)
    assert_equal(len(all_of_them), 0)


def test_delete_func_on_an_empty_list() raises:
    var values = List[Int]()

    @parameter
    def always(x: Int) -> Bool:
        return True

    delete_func[always](values)
    assert_equal(len(values), 0)


def test_delete_func_keeps_the_survivors_in_order() raises:
    var values: List[Int] = [5, 1, 4, 1, 3, 1, 2]

    @parameter
    def is_one(x: Int) -> Bool:
        return x == 1

    delete_func[is_one](values)
    assert_equal(values, [5, 4, 3, 2])


def test_replace_with_a_shorter_a_longer_and_an_equal_run() raises:
    var shorter: List[Int] = [1, 2, 3, 4]
    var one: List[Int] = [9]
    replace(shorter, 1, 3, Span(one))
    assert_equal(shorter, [1, 9, 4])

    var longer: List[Int] = [1, 2, 3, 4]
    var three: List[Int] = [7, 8, 9]
    replace(longer, 1, 3, Span(three))
    assert_equal(longer, [1, 7, 8, 9, 4])

    var same: List[Int] = [1, 2, 3, 4]
    var two: List[Int] = [7, 8]
    replace(same, 1, 3, Span(two))
    assert_equal(same, [1, 7, 8, 4])


def test_replace_of_an_empty_range_is_an_insert() raises:
    var values: List[Int] = [1, 4]
    var middle: List[Int] = [2, 3]
    replace(values, 1, 1, Span(middle))
    assert_equal(values, [1, 2, 3, 4])


def test_replace_with_nothing_is_a_delete() raises:
    var values: List[Int] = [1, 2, 3, 4]
    var none = List[Int]()
    replace(values, 1, 3, Span(none))
    assert_equal(values, [1, 4])


def test_replace_at_the_end() raises:
    var values: List[Int] = [1, 2, 3]
    var tail: List[Int] = [8, 9]
    replace(values, 2, 3, Span(tail))
    assert_equal(values, [1, 2, 8, 9])


def test_replace_out_of_range_raises() raises:
    var values: List[Int] = [1, 2, 3]
    var some: List[Int] = [9]
    with assert_raises(contains="index out of range"):
        replace(values, 1, 4, Span(some))
    with assert_raises(contains="index out of range"):
        replace(values, 2, 1, Span(some))
    assert_equal(values, [1, 2, 3])


def test_compact_collapses_runs() raises:
    var values: List[Int] = [1, 1, 2, 2, 2, 3, 1, 1]
    compact(values)
    assert_equal(values, [1, 2, 3, 1])


def test_compact_leaves_a_list_with_no_runs_alone() raises:
    var values: List[Int] = [1, 2, 3]
    compact(values)
    assert_equal(values, [1, 2, 3])


def test_compact_of_empty_and_single_and_all_equal() raises:
    var empty = List[Int]()
    compact(empty)
    assert_equal(len(empty), 0)

    var one: List[Int] = [5]
    compact(one)
    assert_equal(one, [5])

    var same: List[Int] = [5, 5, 5, 5]
    compact(same)
    assert_equal(same, [5])


def test_compact_is_uniq_and_not_sort_uniq() raises:
    # 1 appears three times and stays three times, because the runs are what
    # collapse and not the values.
    var values: List[Int] = [1, 2, 1, 2, 1]
    compact(values)
    assert_equal(values, [1, 2, 1, 2, 1])


def test_compact_destroys_what_it_dropped() raises:
    var live: List[Int] = [0]
    var values = List[Tracked[origin_of(live)]](capacity=5)
    for i in [0, 0, 0, 1, 2]:
        values.append(Tracked(i, live))
    assert_equal(live[0], 5)
    compact(values)
    assert_equal(len(values), 3)
    assert_equal(live[0], 3)
    assert_equal(values[0].value, 0)
    assert_equal(values[1].value, 1)
    assert_equal(values[2].value, 2)


def test_compact_func_with_a_looser_equality() raises:
    var values: List[Int] = [1, 3, 2, 4, 7, 9]

    @parameter
    def same_parity(a: Int, b: Int) -> Bool:
        return a % 2 == b % 2

    compact_func[same_parity](values)
    assert_equal(values, [1, 2, 7])


def test_compact_func_on_strings_ignoring_case() raises:
    var values: List[String] = ["a", "A", "b", "B", "b"]

    @parameter
    def same_letter(a: String, b: String) -> Bool:
        return a.lower() == b.lower()

    compact_func[same_letter](values)
    assert_equal(len(values), 2)
    assert_equal(values[0], "a")
    assert_equal(values[1], "b")


def test_grow_raises_the_capacity_without_touching_the_contents() raises:
    var values: List[Int] = [1, 2, 3]
    grow(values, 100)
    assert_true(values.capacity() >= 103)
    assert_equal(values, [1, 2, 3])


def test_grow_by_zero_and_by_less_than_is_spare_does_nothing_visible() raises:
    var values = List[Int](capacity=50)
    values.append(1)
    var before = values.capacity()
    grow(values, 0)
    assert_equal(values.capacity(), before)
    grow(values, 10)
    assert_equal(values.capacity(), before)
    assert_equal(values, [1])


def test_grow_by_a_negative_count_raises() raises:
    var values: List[Int] = [1]
    with assert_raises(contains="negative count"):
        grow(values, -1)


def test_clip_drops_the_spare_capacity_and_keeps_the_contents() raises:
    var values = List[Int](capacity=1000)
    for i in range(3):
        values.append(i)
    assert_true(values.capacity() >= 1000)
    clip(values)
    assert_equal(values.capacity(), 3)
    assert_equal(values, [0, 1, 2])


def test_clip_of_an_already_tight_list_changes_nothing() raises:
    var values = List[Int](capacity=2)
    values.append(1)
    values.append(2)
    clip(values)
    assert_equal(values.capacity(), 2)
    assert_equal(values, [1, 2])


def test_clip_of_an_empty_list() raises:
    var values = List[Int](capacity=100)
    clip(values)
    assert_equal(len(values), 0)


def test_clone_copies_and_the_copy_is_independent() raises:
    var values: List[Int] = [1, 2, 3]
    var copy = clone(Span(values))
    assert_equal(copy, [1, 2, 3])
    copy[0] = 99
    assert_equal(values, [1, 2, 3])


def test_clone_of_an_empty_span() raises:
    var empty = List[Int]()
    var copy = clone(Span(empty))
    assert_equal(len(copy), 0)


def test_clone_of_a_sub_range() raises:
    var values = counted(10)
    var copy = clone(Span(values)[3:6])
    assert_equal(copy, [3, 4, 5])


def test_concat_of_several_lists() raises:
    var a: List[Int] = [1, 2]
    var b = List[Int]()
    var c: List[Int] = [3]
    var joined = concat(a, b, c)
    assert_equal(joined, [1, 2, 3])


def test_concat_of_one_list() raises:
    var a: List[Int] = [1, 2]
    var one = concat(a)
    assert_equal(one, [1, 2])
    # `concat()` with no arguments has no way to say what it is a list of, and
    # the element type is inferred, so that call does not compile. Go's
    # `Concat[[]int]()` names the type and returns nil.


def test_concat_leaves_its_inputs_alone() raises:
    var a: List[Int] = [1, 2]
    var b: List[Int] = [3]
    var joined = concat(a, b)
    joined[0] = 99
    assert_equal(a, [1, 2])
    assert_equal(b, [3])


def test_repeat() raises:
    var values: List[Int] = [1, 2]
    var three = repeat(Span(values), 3)
    assert_equal(three, [1, 2, 1, 2, 1, 2])


def test_repeat_zero_times_and_of_an_empty_span() raises:
    var values: List[Int] = [1, 2]
    var none = repeat(Span(values), 0)
    assert_equal(len(none), 0)

    var empty = List[Int]()
    var still_empty = repeat(Span(empty), 5)
    assert_equal(len(still_empty), 0)


def test_repeat_a_negative_number_of_times_raises() raises:
    var values: List[Int] = [1]
    with assert_raises(contains="negative count"):
        _ = repeat(Span(values), -1)


def test_repeat_raises_rather_than_overflowing() raises:
    var values: List[Int] = [1, 2, 3, 4]
    with assert_raises(contains="overflows"):
        _ = repeat(Span(values), Int.MAX // 2)


def test_reverse() raises:
    var odd: List[Int] = [1, 2, 3]
    reverse(Span(odd))
    assert_equal(odd, [3, 2, 1])

    var even: List[Int] = [1, 2, 3, 4]
    reverse(Span(even))
    assert_equal(even, [4, 3, 2, 1])


def test_reverse_of_empty_and_single() raises:
    var empty = List[Int]()
    reverse(Span(empty))
    assert_equal(len(empty), 0)

    var one: List[Int] = [7]
    reverse(Span(one))
    assert_equal(one, [7])


def test_reverse_twice_is_the_identity() raises:
    var values = counted(37)
    reverse(Span(values))
    reverse(Span(values))
    for i in range(37):
        assert_equal(values[i], i)


def test_reverse_of_a_sub_range_leaves_the_rest_alone() raises:
    var values = counted(6)
    reverse(Span(values)[1:4])
    assert_equal(values, [0, 3, 2, 1, 4, 5])


def test_reverse_of_strings() raises:
    var values: List[String] = ["a", "b", "c"]
    reverse(Span(values))
    assert_equal(values[0], "c")
    assert_equal(values[1], "b")
    assert_equal(values[2], "a")
