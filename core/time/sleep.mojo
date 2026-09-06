"""Waiting for a length of time. Go's `time.Sleep`.

One call, and the whole of the work in it is the interruption. A signal that
arrives while a thread is waiting ends the wait, and the kernel says so with
`EINTR` rather than by carrying on, so a sleep that is not written as a loop is
a sleep that returns early whenever the process happens to be signalled. The
loop is here so that no caller has to write it.

What the loop does not do is trust the kernel's own account of what was left.
`nanosleep` will write the remaining time into a second timespec, and using it
means the total wait is the sum of a chain of subtractions, each one made at a
moment nobody measured. Reading `CLOCK_MONOTONIC` before the first wait and
again after every interruption gives the elapsed time directly, and the answer
is the same whether the sleep was interrupted once or a thousand times.
"""

from core.errors import capture
from core.syscall import CLOCK_MONOTONIC, EINTR, Timespec, clock_gettime
from core.syscall import nanosleep as _nanosleep

from .duration import Duration

comptime _NANOSECONDS_PER_SECOND = 1_000_000_000


def sleep(d: Duration) raises:
    """Wait for at least `d`, then return. Go's `Sleep`.

    ```mojo
    from core.time import MILLISECOND, sleep

    def main() raises:
        sleep(10 * MILLISECOND)
    ```

    At least, and not exactly: the platform wakes a thread when it next gets
    round to it, so the wait is the length asked for plus however long the
    scheduler took, and asking for a nanosecond gets whatever the shortest wait
    the machine can make is. A zero or negative `d` returns at once and does not
    reach the kernel at all, which is what Go does with the same argument.

    Signals do not shorten the wait. One that arrives is absorbed here and the
    remainder is waited out, measured against the monotonic clock, so the time
    this takes does not depend on how busy the process was. Setting the wall
    clock does not shorten or lengthen it either, for the same reason.

    Raises only if the platform refuses a clock reading or refuses the wait,
    neither of which happens for an argument in range.
    """
    if d.value <= 0:
        return
    var start = _monotonic()
    var left = d.value
    while True:
        try:
            _nanosleep(
                Timespec(
                    left // _NANOSECONDS_PER_SECOND,
                    left % _NANOSECONDS_PER_SECOND,
                )
            )
            return
        except e:
            if not _interrupted(e):
                raise e
        # The remainder is computed from the total rather than accumulated a
        # subtraction at a time, so a long sleep interrupted often does not
        # drift, and so the arithmetic cannot overflow: the elapsed time is
        # bounded by the sleep and the difference is bounded by `d`.
        left = d.value - (_monotonic() - start)
        if left <= 0:
            return


def _monotonic() raises -> Int:
    """The monotonic clock in nanoseconds, from a start nobody describes.

    Only differences between two of these mean anything, which is all this file
    ever takes.
    """
    var reading = clock_gettime(CLOCK_MONOTONIC)
    return reading.sec * _NANOSECONDS_PER_SECOND + reading.nsec


def _interrupted(e: Error) -> Bool:
    """Whether a failed call was cut short by a signal.

    `core.io.fs.errors` has the same three lines under the name `_errno_of`,
    and this package sits below that one in the tier list and cannot reach it.
    Only one number is wanted here, so the copy is a predicate rather than
    another accessor.
    """
    var held = capture(e).field("errno")
    if not held:
        return False
    try:
        return Int(held.value()) == EINTR
    except:
        return False
