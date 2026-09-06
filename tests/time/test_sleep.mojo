"""Waiting, against the monotonic clock.

Only the lower bound is asserted. A sleep is allowed to take longer than it was
asked to and on a loaded machine it always does, so a test with an upper bound
would be measuring the runner rather than the code, and the durations here are
kept small because every one of them is time the suite spends doing nothing.

What is not tested here is the interruption, which is the whole reason `sleep`
is a loop. Reaching it means arranging for a signal to arrive during the wait,
and the two ways to do that from this package are a timer, which does not exist
yet, and `core.os.signal`, which is three tiers above `core.time` and cannot be
imported into its tests without inverting the layering. The loop is covered
where the signals live instead: `tests/os/signal` sends a real one to a process
that is sleeping and checks that the sleep finishes.
"""

from std.testing import assert_true

from core.syscall import CLOCK_MONOTONIC, clock_gettime
from core.time import MICROSECOND, MILLISECOND, Duration, sleep


def _monotonic() raises -> Int:
    var reading = clock_gettime(CLOCK_MONOTONIC)
    return reading.sec * 1_000_000_000 + reading.nsec


def test_a_sleep_takes_at_least_as_long_as_it_was_asked_to() raises:
    var asked = 20 * MILLISECOND
    var start = _monotonic()
    sleep(asked)
    assert_true(_monotonic() - start >= asked.value)


def test_a_very_short_sleep_still_waits() raises:
    """A hundred microseconds is under a scheduler tick on most machines.

    The platform rounds it up to whatever the shortest wait it can make is, so
    this returns late rather than early, which is the promise being checked.
    """
    var asked = 100 * MICROSECOND
    var start = _monotonic()
    sleep(asked)
    assert_true(_monotonic() - start >= asked.value)


def test_a_zero_sleep_returns_at_once() raises:
    """It does not reach the kernel, so the only thing to assert is the return.

    A wait of no time is not an error and not a yield either, and Go's `Sleep`
    treats it the same way.
    """
    var start = _monotonic()
    sleep(Duration(0))
    assert_true(_monotonic() - start >= 0)


def test_a_negative_sleep_returns_at_once() raises:
    """`nanosleep` would refuse this with `EINVAL` rather than wait no time.

    So the check is in `sleep` and not in the binding, and this is the test
    that says a duration a caller computed by subtracting two instants in the
    wrong order does not become a failure.
    """
    sleep(Duration(-1))
    sleep(-5 * MILLISECOND)


def test_sleeps_add_up() raises:
    """Ten of them wait at least what one ten times as long would.

    A per call overhead that got lost, or a loop that returned on the first
    round without waiting, shows up here and not in a single sleep.
    """
    var each = 2 * MILLISECOND
    var start = _monotonic()
    for _ in range(10):
        sleep(each)
    assert_true(_monotonic() - start >= 10 * each.value)
