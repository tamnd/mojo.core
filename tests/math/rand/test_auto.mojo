"""Go's `TestAuto`, which asks whether the top level functions were seeded.

The one thing that can go wrong with an automatically seeded generator and
cannot be seen from its output alone is that it was not seeded at all. Every
process would then produce the same stream, which looks perfectly random until
two of them are compared. Go's test takes ten values from the global generator
and looks for them in a thousand values from a generator seeded with a fixed
constant, on the reasoning that the only way ten specific values turn up in a
thousand draws is that the two generators are the same one.

Go puts this test in its own file with an alphabetically early name so that it
runs before anything else has touched the global generator. The runner here
does not order tests by file name and the check does not depend on the
generator being untouched, so the name is for the reader rather than for the
runner.

The false positive rate is what Go's comment says it is: a value from a 64 bit
stream appearing in a particular thousand draws has probability about `1e-16`,
and ten of them in a row is far below anything worth worrying about.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.math.rand import int64, new, new_pcg, uint64


def test_auto() raises:
    var out = List[Int64](capacity=10)
    for _ in range(10):
        out.append(int64())

    var r = new(new_pcg(1, 0))
    var found = 0
    for _ in range(1000):
        if r.int64() == out[found]:
            found += 1
            assert_true(
                found < len(out),
                (
                    "the top level functions produced the stream of a generator"
                    " seeded with the constant 1, so they were not seeded"
                ),
            )


def test_the_top_level_generator_is_not_a_constant_stream() raises:
    # The failure `test_auto` cannot see, because a generator stuck on one
    # value is not the fixed seed generator either.
    var first = uint64()
    var moved = False
    for _ in range(20):
        if uint64() != first:
            moved = True
    assert_true(moved, "twenty draws from the top level source never changed")


def test_the_top_level_generator_keeps_its_place_across_calls() raises:
    # The per thread generator is fetched afresh on every call, so the thing to
    # check is that fetching it does not also rebuild it. A rebuilt generator
    # would hand back its first value every time, and sixty four draws that are
    # all different says it did not.
    var seen = List[UInt64](capacity=64)
    for _ in range(64):
        seen.append(uint64())
    for i in range(len(seen)):
        for k in range(i + 1, len(seen)):
            assert_false(
                seen[i] == seen[k],
                "value " + String(i) + " and value " + String(k) + " match",
            )
