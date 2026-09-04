"""Reading a clock, against the two the platform has.

`CLOCK_MONOTONIC` is 6 on macOS and 1 on Linux, and 6 on Linux is
`CLOCK_THREAD_CPUTIME_ID`. That is the failure this file exists for: the wrong
constant does not fail, it reads a clock that answers, counts up, and is not
the one that was asked for. So the tests here are about telling the two clocks
apart rather than about either one's numbers on its own.

Nothing is asserted about resolution or about how fast a clock moves. Both are
the platform's business and both differ between a laptop and a virtual machine
in CI, so a test that pinned either would be measuring the runner.
"""

from std.testing import assert_equal, assert_true

from core.errors import field
from core.syscall import (
    CLOCK_MONOTONIC,
    CLOCK_REALTIME,
    EINVAL,
    clock_gettime,
)

# 2020-01-01 and 2100-01-01 as seconds since the epoch. A wall clock reading
# outside these is not a slow clock or a badly set one, it is a field read at
# the wrong offset or the wrong width, which is the mistake this package is
# built to catch.
comptime _AFTER = 1577836800
comptime _BEFORE = 4102444800

# A number no platform hands out as a clock id. Deliberately large rather than
# negative, so that a binding passing it at the wrong width does not turn it
# into something real on the way.
comptime _NONSENSE = 12345


def test_the_wall_clock_says_it_is_some_time_this_century() raises:
    var now = clock_gettime(CLOCK_REALTIME)
    assert_true(now.sec > _AFTER)
    assert_true(now.sec < _BEFORE)


def test_the_nanoseconds_are_within_a_second() raises:
    """The field this catches when it is read one byte over.

    `tv_nsec` is under a billion by definition, so a reading that is not says
    the number came from somewhere other than the field, and the whole
    structure is sixteen bytes with nothing after it to pick up by accident.
    """
    for _ in range(64):
        var now = clock_gettime(CLOCK_REALTIME)
        assert_true(now.nsec >= 0)
        assert_true(now.nsec < 1_000_000_000)
        var since = clock_gettime(CLOCK_MONOTONIC)
        assert_true(since.nsec >= 0)
        assert_true(since.nsec < 1_000_000_000)


def test_the_monotonic_clock_never_goes_backwards() raises:
    var last = clock_gettime(CLOCK_MONOTONIC)
    for _ in range(1000):
        var now = clock_gettime(CLOCK_MONOTONIC)
        var back = now.sec < last.sec or (
            now.sec == last.sec and now.nsec < last.nsec
        )
        assert_true(not back)
        last = now


def test_the_monotonic_clock_moves() raises:
    """It advances at some point across a thousand readings.

    Not across two, because two readings close together can land in the same
    tick of a coarse clock and a test that demanded otherwise would fail on a
    slow virtual machine for no reason. Across a thousand, a clock that never
    moves is stopped.
    """
    var first = clock_gettime(CLOCK_MONOTONIC)
    var moved = False
    for _ in range(1000):
        var now = clock_gettime(CLOCK_MONOTONIC)
        if now.sec != first.sec or now.nsec != first.nsec:
            moved = True
    assert_true(moved)


def test_the_two_clocks_are_not_the_same_clock() raises:
    """The one assertion that catches the constants being swapped.

    The monotonic clock counts from a start the platform picked, which on both
    of ours is when the machine came up. The wall clock counts from 1970. No
    machine has been up since 1970, so the monotonic reading is the smaller of
    the two by decades, and the two constants naming the same clock would show
    up here and almost nowhere else.
    """
    var since = clock_gettime(CLOCK_MONOTONIC)
    var now = clock_gettime(CLOCK_REALTIME)
    assert_true(since.sec < now.sec)


def test_a_clock_that_does_not_exist_fails() raises:
    try:
        var reading = clock_gettime(_NONSENSE)
        raise Error("a clock id of ", _NONSENSE, " read ", reading)
    except e:
        assert_equal(field(e, "op").value(), "clock_gettime")
        assert_equal(field(e, "errno").value(), String(EINVAL))
