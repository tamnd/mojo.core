"""Waiting, as the binding presents it.

Only the lower bound is checked. A wait is allowed to run over and on a loaded
machine it always does, so an upper bound here would be measuring the runner.

The layout is not tested here either, and there is a reason rather than an
omission. `Timespec` is the same structure `clock_gettime` reads back and
`utimensat` is handed, its field offsets and widths come out of the recorded
baseline, and `tests/syscall/test_stat.mojo` is where they are pinned. What is
left for this file is the call itself: that a wait waits, that a wait of no time
comes back, and that the two arguments the kernel is required to refuse are
refused with the errno on the record where every other call in this package puts
it.
"""

from std.testing import assert_equal, assert_true

from core.errors import field
from core.syscall import (
    CLOCK_MONOTONIC,
    EINVAL,
    Timespec,
    clock_gettime,
    nanosleep,
)

comptime _MILLISECOND = 1_000_000


def _monotonic() raises -> Int:
    var reading = clock_gettime(CLOCK_MONOTONIC)
    return reading.sec * 1_000_000_000 + reading.nsec


def test_a_wait_takes_at_least_as_long_as_it_was_asked_for() raises:
    var start = _monotonic()
    nanosleep(Timespec(0, 20 * _MILLISECOND))
    assert_true(_monotonic() - start >= 20 * _MILLISECOND)


def test_a_wait_of_no_time_returns() raises:
    """Legal, and the kernel is entitled to yield the processor over it.

    Only that it comes back is asserted, since a zero wait that took a moment is
    as correct as one that took none.
    """
    var start = _monotonic()
    nanosleep(Timespec(0, 0))
    assert_true(_monotonic() - start >= 0)


def test_a_negative_wait_is_refused() raises:
    """Not treated as a wait of no time, which is why `core.time.sleep` checks.

    A duration computed by subtracting two instants in the wrong order arrives
    here as a negative number, and the kernel's answer to it is a failure rather
    than an immediate return, so somebody above has to decide which was meant.
    """
    try:
        nanosleep(Timespec(-1, 0))
        raise Error("a wait of minus one second was accepted")
    except e:
        assert_equal(field(e, "op").value(), "nanosleep")
        assert_equal(field(e, "errno").value(), String(EINVAL))


def test_a_nanoseconds_field_of_a_whole_second_is_refused() raises:
    """The field has to be under a billion and the carry is the caller's job.

    A second and a half is `Timespec(1, 500_000_000)` and never
    `Timespec(0, 1_500_000_000)`, and this is the assertion that says the second
    of those does not quietly work on one platform and not the other.
    """
    try:
        nanosleep(Timespec(0, 1_000_000_000))
        raise Error("a nanoseconds field of a whole second was accepted")
    except e:
        assert_equal(field(e, "op").value(), "nanosleep")
        assert_equal(field(e, "errno").value(), String(EINVAL))
