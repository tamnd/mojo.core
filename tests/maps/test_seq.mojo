"""Turning a dict into lists and lists back into a dict.

A `Dict` iterates in an order this package does not promise, so every test
that looks at a whole result sorts it first. The one place order does matter is
`test_keys_and_values_line_up`, which is the guarantee `seq.mojo` makes and the
only reason `keys` and `values` are worth having separately from `all`.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.slices import collect as drain

from core.maps import (
    all,
    all_into,
    collect,
    insert,
    keys,
    keys_into,
    values,
    values_into,
)

from tests.maps._fixtures import Pairs, ages, ordered


def test_keys_gives_every_key_once() raises:
    var d = ages()
    assert_equal(ordered(keys(d)), ["ana", "bo", "cy"])


def test_keys_of_an_empty_dict() raises:
    var d = Dict[String, Int]()
    assert_equal(len(keys(d)), 0)


def test_keys_into_appends_and_does_not_clear() raises:
    var d = ages()
    var into: List[String] = ["zz"]
    keys_into(d, into)
    assert_equal(len(into), 4)
    assert_equal(into[0], "zz")
    assert_equal(ordered(into^), ["ana", "bo", "cy", "zz"])


def test_keys_into_from_two_dicts_accumulates() raises:
    var first = ages()
    var second = {String("dee"): 40}
    var into = List[String]()
    keys_into(first, into)
    keys_into(second, into)
    assert_equal(ordered(into^), ["ana", "bo", "cy", "dee"])


def test_keys_into_from_an_empty_dict_changes_nothing() raises:
    var d = Dict[String, Int]()
    var into: List[String] = ["kept"]
    keys_into(d, into)
    assert_equal(into, ["kept"])


def test_values_keeps_repeats() raises:
    # Two of the three ages are 31. A `values` that went through the keys and
    # deduplicated would answer two elements here and pass every other test.
    var d = ages()
    assert_equal(ordered(values(d)), [27, 31, 31])


def test_values_into_appends() raises:
    var d = ages()
    var into: List[Int] = [0]
    values_into(d, into)
    assert_equal(ordered(into^), [0, 27, 31, 31])


def test_all_gives_every_pair() raises:
    var d = ages()
    var pairs = all(d)
    assert_equal(len(pairs), 3)
    var seen = 0
    for i in range(len(pairs)):
        assert_equal(pairs[i][1], d[pairs[i][0]])
        seen += 1
    assert_equal(seen, 3)


def test_all_of_an_empty_dict() raises:
    var d = Dict[String, Int]()
    assert_equal(len(all(d)), 0)


def test_all_into_appends() raises:
    var d = {String("only"): 1}
    var into: List[Tuple[String, Int]] = [(String("kept"), 0)]
    all_into(d, into)
    assert_equal(len(into), 2)
    assert_equal(into[0][0], "kept")
    assert_equal(into[1][0], "only")


def test_keys_and_values_line_up() raises:
    # The guarantee: with no mutation in between, the three producers walk the
    # dict in the same order, so `keys()[i]` and `values()[i]` are one entry.
    # Go promises nothing of the sort, since each of its iterators randomises
    # separately, and a caller who wants parallel lists here does not have to
    # go through `all` and unpack.
    var d = ages()
    var ks = keys(d)
    var vs = values(d)
    var pairs = all(d)
    assert_equal(len(ks), len(vs))
    assert_equal(len(ks), len(pairs))
    for i in range(len(ks)):
        assert_equal(vs[i], d[ks[i]])
        assert_equal(pairs[i][0], ks[i])
        assert_equal(pairs[i][1], vs[i])


def test_insert_adds_and_overwrites() raises:
    var d = {String("ana"): 31}
    var more: List[Tuple[String, Int]] = [
        (String("bo"), 27),
        (String("ana"), 32),
    ]
    insert(d, Span(more))
    assert_equal(len(d), 2)
    assert_equal(d["ana"], 32)
    assert_equal(d["bo"], 27)


def test_insert_takes_the_last_of_a_repeated_key() raises:
    var d = Dict[String, Int]()
    var pairs: List[Tuple[String, Int]] = [
        (String("k"), 1),
        (String("k"), 2),
        (String("k"), 3),
    ]
    insert(d, Span(pairs))
    assert_equal(len(d), 1)
    assert_equal(d["k"], 3)


def test_insert_of_an_empty_span_changes_nothing() raises:
    var d = ages()
    var empty = List[Tuple[String, Int]]()
    insert(d, Span(empty))
    assert_equal(len(d), 3)


def test_insert_copies_rather_than_taking() raises:
    # The span is a view, so the pairs have to survive the call. A version that
    # moved out of it would leave `pairs` holding destroyed strings.
    var d = Dict[String, Int]()
    var pairs: List[Tuple[String, Int]] = [(String("k"), 1)]
    insert(d, Span(pairs))
    assert_equal(pairs[0][0], "k")
    assert_equal(pairs[0][1], 1)


def test_collect_builds_a_dict() raises:
    var pairs: List[Tuple[String, Int]] = [
        (String("ana"), 31),
        (String("bo"), 27),
    ]
    var d = collect(Span(pairs))
    assert_equal(len(d), 2)
    assert_equal(d["ana"], 31)


def test_collect_of_an_empty_span() raises:
    var pairs = List[Tuple[String, Int]]()
    var d = collect(Span(pairs))
    assert_equal(len(d), 0)


def test_collect_takes_the_last_of_a_repeated_key() raises:
    var pairs: List[Tuple[String, Int]] = [
        (String("k"), 1),
        (String("k"), 9),
    ]
    var d = collect(Span(pairs))
    assert_equal(len(d), 1)
    assert_equal(d["k"], 9)


def test_all_and_collect_round_trip() raises:
    var d = ages()
    var pairs = all(d)
    var back = collect(Span(pairs))
    assert_equal(len(back), len(d))
    for key in d.keys():
        assert_true(key in back)
        assert_equal(back[key], d[key])


def test_a_fallible_source_goes_through_a_list() raises:
    # There is no cursor overload, which is the deviation `seq.mojo` explains.
    # This is the route it points at instead, written out so that the cost of
    # the deviation is a thing somebody can look at: one call and one list.
    var cursor = Pairs([(String("ana"), 31), (String("bo"), 27)])
    var d = collect(Span(drain(cursor)))
    assert_equal(len(d), 2)
    assert_equal(d["bo"], 27)


def test_the_failure_of_a_fallible_source_arrives_before_the_dict_does() raises:
    # The other half of the same point. Draining first means a source that
    # fails part way raises out of the drain, and there is no half filled dict
    # to decide what to do with.
    var cursor = Pairs([(String("ana"), 31), (String("bo"), 27)], fail_at=1)
    with assert_raises(contains="failed at pair 1"):
        _ = drain(cursor)
