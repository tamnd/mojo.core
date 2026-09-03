"""Simple case folding, which is a walk around a cycle and not a fold.

Go's `TestSimpleFold`. `simple_fold(r)` gives the next code point after `r`
that is equal to it under simple case folding, wrapping round to the smallest
when it runs off the end, so calling it repeatedly enumerates an equivalence
class and calling it once gives an answer that is only meaningful as part of
that walk.

The classes worth knowing are the ones with three members. `K`, `k` and U+212A
KELVIN SIGN fold together, as do `S`, `s` and U+017F LATIN SMALL LETTER LONG S,
which is why case insensitive comparison is not an exclusive or with 0x20 and
why this function exists at all rather than being `to_lower` on both sides.
"""

from std.testing import assert_equal, assert_not_equal, assert_true

from core.unicode import (
    MAX_RUNE,
    simple_fold,
    to_lower,
    to_upper,
)

from tests.unicode._fixtures import fold_cycles


def test_the_cycles_are_the_cycles() raises:
    """Go's `TestSimpleFold`, walked exactly the way Go walks it.

    Starting from the last member rather than the first is deliberate and is
    Go's doing: it makes the first call the wrapping one, so a version that
    walks upwards correctly but never comes back round fails on the first
    assertion of every cycle rather than the last.
    """
    for cycle in fold_cycles():
        var r = cycle[len(cycle) - 1]
        for want in cycle:
            assert_equal(simple_fold(r), want)
            r = want


def test_a_cycle_returns_to_where_it_started() raises:
    """The property the cycles have, asked of every code point up to U+3000.

    The fixtures are nine classes somebody chose. This is the rule those nine
    are examples of, and it is the one that matters: the walk from any code
    point comes back to it, in no more steps than the largest class has
    members. A mapping that sent two code points to the same successor would
    make some walk never return and this would not stop.
    """
    for code in range(0, 0x3000):
        var start = Int32(code)
        var r = start
        var steps = 0
        while True:
            r = simple_fold(r)
            steps += 1
            if r == start:
                break
            assert_true(
                steps < 8,
                String("the fold cycle from ")
                + String(code)
                + " does not return",
            )


def test_the_three_member_classes() raises:
    """The classes that make case insensitive comparison hard, by name.

    U+212A KELVIN SIGN and U+017F LONG S each fold together with a pair of
    ASCII letters, and the case mappings only go one way: U+212A lower cases
    to `k`, and nothing upper cases or lower cases to U+212A. So a program
    comparing case insensitively by mapping both sides has to map towards
    lower case to get Kelvin right and towards upper case to get long s right,
    and there is no direction that gets both. That is what `simple_fold` is
    for, and these six lines are the reason it exists.
    """
    assert_equal(simple_fold(Int32(ord("K"))), Int32(ord("k")))
    assert_equal(simple_fold(Int32(ord("k"))), Int32(0x212A))
    assert_equal(simple_fold(Int32(0x212A)), Int32(ord("K")))
    assert_equal(to_lower(Int32(0x212A)), Int32(ord("k")))
    assert_not_equal(to_upper(Int32(ord("k"))), Int32(0x212A))

    assert_equal(simple_fold(Int32(ord("S"))), Int32(ord("s")))
    assert_equal(simple_fold(Int32(ord("s"))), Int32(0x17F))
    assert_equal(simple_fold(Int32(0x17F)), Int32(ord("S")))
    assert_equal(to_upper(Int32(0x17F)), Int32(ord("S")))
    assert_not_equal(to_lower(Int32(ord("S"))), Int32(0x17F))


def test_a_code_point_equal_only_to_itself() raises:
    """The single member classes, which are the common case.

    Most code points fold to nothing but themselves, and the two Turkish
    letters are the interesting members of that set: they have both an upper
    and a lower case mapping and still no fold, because the dotted and
    dotless i are different letters rather than two cases of one.
    """
    assert_equal(simple_fold(Int32(0x130)), Int32(0x130))
    assert_equal(simple_fold(Int32(0x131)), Int32(0x131))
    assert_equal(simple_fold(Int32(ord("1"))), Int32(ord("1")))
    assert_equal(simple_fold(Int32(ord(" "))), Int32(ord(" ")))
    assert_equal(simple_fold(Int32(0x4E00)), Int32(0x4E00))


def test_a_rune_that_is_not_one() raises:
    """Go's last three lines of `TestSimpleFold`, and the other end as well.

    Go answers `-42` for `-42`, and the same identity holds above `MAX_RUNE`.
    Neither is a code point, and both arrive from a decoder sooner or later.
    """
    assert_equal(simple_fold(Int32(-42)), Int32(-42))
    assert_equal(simple_fold(Int32(-1)), Int32(-1))
    assert_equal(simple_fold(MAX_RUNE + 1), MAX_RUNE + 1)
    assert_equal(simple_fold(MAX_RUNE), MAX_RUNE)
