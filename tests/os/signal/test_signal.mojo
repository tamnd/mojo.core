"""Arming a signal and hearing about it, as `core.os.signal` presents it.

The handler and the pipe underneath belong to `core.syscall` and are tested
there. What is left for this package is a very thin layer, so these tests are
about the parts a caller can actually observe: that the pipe is one descriptor
however many signals are armed, that a signal armed here really does arrive as
its own number, and that the two calls Go names differently do the same thing.

Every test puts back what it changed and reads exactly what it sent, because
the pipe is shared and never closed, so a byte one test leaves behind is a byte
the next one reads. `SIGUSR1` and `SIGUSR2` are what these use, since nothing
else in the process wants them.

A signal is never sent to this process unless it has been armed first. The
default for both of these is to end the program, so a test that sent one to an
unarmed signal would not fail, it would take the runner down with it.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.os import INTERRUPT, Signal, getpid
from core.os.exec import command
from core.os.signal import ignore, ignored, notify, reset, stop
from core.syscall import (
    SIGKILL,
    SIGSTOP,
    SIGUSR1,
    SIGUSR2,
    kill,
    read,
    signal_restore,
)
from core.time import MILLISECOND, now, since, sleep


def test_an_armed_signal_arrives_as_its_own_number() raises:
    var fd = notify(Signal(SIGUSR1))
    _ = kill(getpid(), SIGUSR1)
    var room = List[Byte](length=1, fill=0)
    assert_equal(read(fd, Span(room)), 1)
    assert_equal(Int(room[0]), SIGUSR1)
    stop(Signal(SIGUSR1))


def test_two_signals_share_one_pipe() raises:
    # The shape this package chose. A program reads one descriptor and looks at
    # the byte, rather than holding one descriptor for every signal it cares
    # about, and this is the assertion that says so.
    var first = notify(Signal(SIGUSR1))
    var second = notify(Signal(SIGUSR2))
    assert_equal(first, second)
    stop(Signal(SIGUSR1))
    stop(Signal(SIGUSR2))


def test_arming_the_same_signal_twice_is_the_second_call_doing_nothing() raises:
    var first = notify(Signal(SIGUSR1))
    var second = notify(Signal(SIGUSR1))
    assert_equal(first, second)
    _ = kill(getpid(), SIGUSR1)
    var room = List[Byte](length=2, fill=0)
    # One signal sent, one byte back, not two. Arming twice does not double it.
    assert_equal(read(first, Span(room)), 1)
    assert_equal(Int(room[0]), SIGUSR1)
    stop(Signal(SIGUSR1))


def test_reset_is_the_same_call_as_stop() raises:
    # Go's two names differ only in whether they are given a channel or a
    # signal. There is one pipe here, so both take the signal and both do the
    # same thing, and a reader coming from Go should find either name working.
    var fd = notify(Signal(SIGUSR1))
    reset(Signal(SIGUSR1))
    var again = notify(Signal(SIGUSR1))
    assert_equal(fd, again)
    stop(Signal(SIGUSR1))


def test_an_ignored_signal_says_it_is_ignored() raises:
    ignore(Signal(SIGUSR2))
    assert_true(ignored(Signal(SIGUSR2)))
    signal_restore(SIGUSR2)
    assert_false(ignored(Signal(SIGUSR2)))


def test_an_armed_signal_is_not_an_ignored_one() raises:
    # Arming and ignoring are opposite answers to the same question, and a
    # program that confused them would be one that never hears about a signal
    # it thinks it is waiting for.
    _ = notify(Signal(SIGUSR1))
    assert_false(ignored(Signal(SIGUSR1)))
    stop(Signal(SIGUSR1))


def test_the_two_signals_no_program_may_catch_are_refused() raises:
    with assert_raises():
        _ = notify(Signal(SIGKILL))
    with assert_raises():
        _ = notify(Signal(SIGSTOP))


def test_a_signal_arriving_during_a_sleep_does_not_shorten_it() raises:
    """`core.time.sleep`'s loop, exercised where a real signal can be sent.

    The interruption is the whole reason that function is a loop, and it cannot
    be reached from `core.time`'s own tests: making a signal arrive part way
    through a wait needs a second process, and `core.time` sits three tiers
    below the package that starts one. Here both are to hand.

    A shell is started that waits a tenth of a second and then signals this
    process, so the signal lands part way through a fifth of a second of sleep.
    The byte read afterwards is the proof it was delivered, and the elapsed time
    is the proof the sleep was not cut short by it. A shell that is slow to
    start would send late instead of early, which makes the test prove less
    rather than fail.
    """
    var fd = notify(Signal(SIGUSR1))
    var sender = command(
        "sh", ["-c", "sleep 0.1; kill -USR1 " + String(getpid())]
    )
    sender.start()

    var start = now()
    sleep(200 * MILLISECOND)
    assert_true(since(start) >= 200 * MILLISECOND)

    sender.wait()
    var room = List[Byte](length=1, fill=0)
    assert_equal(read(fd, Span(room)), 1)
    assert_equal(Int(room[0]), SIGUSR1)
    stop(Signal(SIGUSR1))


def test_interrupt_can_be_armed_and_put_back() raises:
    # The signal a program actually wants, done the way a program would do it,
    # and put back immediately so that pressing control C while the suite runs
    # still stops the suite.
    var fd = notify(INTERRUPT)
    assert_true(fd >= 0)
    stop(INTERRUPT)
    assert_false(ignored(INTERRUPT))
