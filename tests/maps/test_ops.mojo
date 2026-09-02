"""Copying, filtering and comparing dicts.

The tests worth reading here are the ones about what a copy shares.
`test_clone_is_shallow` says what `clone` promises, and it is the same promise
Go's `Clone` makes and the same one people misread.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.maps import clone, copy, delete_func, equal, equal_func

from tests.maps._fixtures import ages, ordered


def _nan() -> Float64:
    """A NaN built at run time, so nothing folds the comparison away."""
    var zero = Float64(0.0)
    return zero / zero


def test_clone_has_the_same_entries() raises:
    var d = ages()
    var c = clone(d)
    assert_true(equal(c, d))


def test_clone_of_an_empty_dict() raises:
    var d = Dict[String, Int]()
    assert_equal(len(clone(d)), 0)


def test_writing_to_a_clone_leaves_the_original_alone() raises:
    var d = ages()
    var c = clone(d)
    c["ana"] = 99
    _ = c.pop(String("bo"))
    c[String("new")] = 1
    assert_equal(d["ana"], 31)
    assert_equal(d["bo"], 27)
    assert_equal(len(d), 3)


def test_clone_is_shallow() raises:
    # Go's `Clone` copies the map and not what the values point at, and this
    # does whatever the value's own copy does. For a `List` that is a new list,
    # so the two are independent — but a value holding a handle would give two
    # handles to one thing, which is the case the word shallow is about.
    var d = Dict[String, List[Int]]()
    d[String("xs")] = [1, 2]
    var c = clone(d)
    c[String("xs")].append(3)
    assert_equal(len(d["xs"]), 2)
    assert_equal(len(c["xs"]), 3)


def test_copy_merges_and_overwrites() raises:
    var into = {String("ana"): 31, String("bo"): 27}
    var from_ = {String("bo"): 99, String("cy"): 40}
    copy(into, from_)
    assert_equal(len(into), 3)
    assert_equal(into["ana"], 31)
    assert_equal(into["bo"], 99)
    assert_equal(into["cy"], 40)


def test_copy_leaves_the_source_alone() raises:
    var into = Dict[String, Int]()
    var from_ = ages()
    copy(into, from_)
    assert_equal(len(from_), 3)
    assert_true(equal(into, from_))


def test_copy_from_an_empty_dict_changes_nothing() raises:
    var into = ages()
    var from_ = Dict[String, Int]()
    copy(into, from_)
    assert_equal(len(into), 3)


def test_delete_func_removes_what_it_accepts() raises:
    var d = ages()

    @parameter
    def young(name: String, age: Int) -> Bool:
        return age < 30

    delete_func[young](d)
    assert_equal(ordered(_keys_of(d)), ["ana", "cy"])


def test_delete_func_can_look_at_the_key() raises:
    var d = ages()

    @parameter
    def starts_with_c(name: String, age: Int) -> Bool:
        return name.startswith("c")

    delete_func[starts_with_c](d)
    assert_equal(ordered(_keys_of(d)), ["ana", "bo"])


def test_delete_func_that_accepts_everything_empties_the_dict() raises:
    var d = ages()

    @parameter
    def always(name: String, age: Int) -> Bool:
        return True

    delete_func[always](d)
    assert_equal(len(d), 0)


def test_delete_func_that_accepts_nothing_changes_nothing() raises:
    var d = ages()

    @parameter
    def never(name: String, age: Int) -> Bool:
        return False

    delete_func[never](d)
    assert_equal(len(d), 3)


def test_delete_func_sees_every_entry_exactly_once() raises:
    # The reason the keys are gathered before anything is deleted. A version
    # that deleted while iterating would visit some entries twice or skip
    # some, and on a dict of three that is the difference between three calls
    # and two.
    var d = ages()
    var calls: List[Int] = [0]

    @parameter
    def counting(name: String, age: Int) -> Bool:
        calls[0] += 1
        return age == 27

    delete_func[counting](d)
    assert_equal(calls[0], 3)
    assert_equal(len(d), 2)


def test_delete_func_on_an_empty_dict() raises:
    var d = Dict[String, Int]()

    @parameter
    def always(name: String, age: Int) -> Bool:
        return True

    delete_func[always](d)
    assert_equal(len(d), 0)


def test_equal_ignores_order() raises:
    var a = Dict[String, Int]()
    a[String("ana")] = 31
    a[String("bo")] = 27
    var b = Dict[String, Int]()
    b[String("bo")] = 27
    b[String("ana")] = 31
    assert_true(equal(a, b))


def test_equal_is_false_on_a_different_length() raises:
    var a = ages()
    var b = {String("ana"): 31}
    assert_false(equal(a, b))
    assert_false(equal(b, a))


def test_equal_is_false_on_the_same_count_and_a_different_key() raises:
    var a = {String("ana"): 1, String("bo"): 2}
    var b = {String("ana"): 1, String("cy"): 2}
    assert_false(equal(a, b))


def test_equal_is_false_on_a_different_value() raises:
    var a = {String("ana"): 1}
    var b = {String("ana"): 2}
    assert_false(equal(a, b))


def test_two_empty_dicts_are_equal() raises:
    var a = Dict[String, Int]()
    var b = Dict[String, Int]()
    assert_true(equal(a, b))


def test_equal_uses_eq_so_a_nan_is_not_equal_to_itself() raises:
    # Deliberate, and the same split `core.slices.equal` has. `==` says a NaN
    # is not itself; `core.cmp.compare`'s total order says two NaNs are equal.
    # This one is `==`, because that is what Go's `maps.Equal` is.
    var a = Dict[String, Float64]()
    a[String("k")] = _nan()
    var b = Dict[String, Float64]()
    b[String("k")] = _nan()
    assert_false(equal(a, b))


def test_equal_func_across_two_value_types() raises:
    var numbers = {String("a"): 1, String("b"): 2}
    var names = {String("a"): String("1"), String("b"): String("2")}

    @parameter
    def same(n: Int, s: String) -> Bool:
        return String(n) == s

    assert_true(equal_func[same](numbers, names))
    names[String("b")] = String("9")
    assert_false(equal_func[same](numbers, names))


def test_equal_func_is_false_on_different_lengths_without_calling_eq() raises:
    var calls: List[Int] = [0]
    var a = ages()
    var b = {String("ana"): 31}

    @parameter
    def counting(x: Int, y: Int) -> Bool:
        calls[0] += 1
        return x == y

    assert_false(equal_func[counting](a, b))
    assert_equal(calls[0], 0)


def test_equal_func_calls_eq_once_per_key_and_stops_at_a_missing_one() raises:
    var calls: List[Int] = [0]
    var a = {String("ana"): 1, String("bo"): 2}
    var b = {String("ana"): 1, String("cy"): 2}

    @parameter
    def counting(x: Int, y: Int) -> Bool:
        calls[0] += 1
        return x == y

    assert_false(equal_func[counting](a, b))
    assert_true(calls[0] <= 1)


def _keys_of(d: Dict[String, Int]) -> List[String]:
    """The keys of `d` without going through `core.maps.keys`.

    Written out so that a `delete_func` test cannot pass because `keys` and
    `delete_func` share a bug.
    """
    var out = List[String]()
    for key in d.keys():
        out.append(key.copy())
    return out^
