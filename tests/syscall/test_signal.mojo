"""Signals, delivered to this very process.

There is no way to test this without sending real signals to the test binary,
so these tests use `SIGUSR1` and `SIGUSR2`, which exist for exactly this and
which nothing else in the suite or in the runner touches. Every test puts back
what it changed, because the disposition of a signal is process wide and the
next test in the binary inherits it.

The one thing not tested here is what a signal does to the program when it is
not caught, because a test that let `SIGUSR1` reach its default disposition
would kill the suite.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.syscall import (
    FD_CLOEXEC,
    F_SETFD,
    close,
    fcntl,
    getpid,
    kill,
    pipe,
    read,
    signal_catch,
    signal_ignore,
    signal_ignored,
    signal_pipe,
    signal_restore,
    spawn,
    waitpid,
    write,
)
from core.syscall.abi import SIGUSR1, SIGUSR2


def _expect(sig: Int) raises:
    """Read the signal pipe until `sig` comes out of it.

    Anything else that arrives first is a signal an earlier test asked for and
    did not collect, which is not this test's problem and not a reason to fail.
    The read blocks, so a signal that never arrives hangs rather than failing,
    and that is the honest shape: there is nothing to time out against at this
    layer and a test that gave up early would be reporting on the timeout.
    """
    var room = List[UInt8](length=1, fill=0)
    while True:
        assert_equal(read(signal_pipe(), Span(room)), 1)
        if Int(room[0]) == sig:
            return


def test_a_caught_signal_arrives_as_a_byte() raises:
    """The whole mechanism, in the smallest case.

    `kill` on this process runs the handler before it returns, so by the time
    the read below happens the byte is already in the pipe.
    """
    signal_catch(SIGUSR1)
    kill(getpid(), SIGUSR1)
    _expect(SIGUSR1)
    signal_restore(SIGUSR1)


def test_the_pipe_is_the_same_one_every_time() raises:
    """One descriptor, so a program arming two signals reads one place."""
    assert_equal(signal_pipe(), signal_pipe())


def test_two_signals_share_the_pipe() raises:
    """The number in the byte is what tells them apart."""
    signal_catch(SIGUSR1)
    signal_catch(SIGUSR2)

    kill(getpid(), SIGUSR2)
    _expect(SIGUSR2)
    kill(getpid(), SIGUSR1)
    _expect(SIGUSR1)

    signal_restore(SIGUSR1)
    signal_restore(SIGUSR2)


def test_a_signal_arrives_while_the_program_is_blocked_in_a_read() raises:
    """The property the whole design is for.

    Everything above is a signal sent by this thread, which is delivered before
    `kill` returns and so proves nothing about waiting. Here a child process
    sends it, and this thread is asleep in a read on the signal pipe when it
    lands. The handler runs on whichever thread the operating system picked,
    writes its byte, and the read this thread is sitting in comes back with it.

    That is what makes the pipe worth having rather than a flag: waiting for a
    signal is waiting for a descriptor, which is the same thing waiting for a
    socket will be.
    """
    signal_catch(SIGUSR1)

    var ready = pipe()
    # Close on exec, or the child inherits the write end of its own standard
    # input and holds the pipe open against itself. `spawn` clears the flag on
    # the descriptors it is told to place, so slot zero still reaches the child.
    _ = fcntl(ready[0], F_SETFD, FD_CLOEXEC)
    _ = fcntl(ready[1], F_SETFD, FD_CLOEXEC)
    var pid = spawn(
        "/bin/sh",
        [
            String("sh"),
            "-c",
            "read line; kill -USR1 " + String(getpid()),
        ],
        [String("PATH=/usr/bin:/bin")],
        [ready[0], 1, 2],
        None,
        0,
        0,
    )
    close(ready[0])

    # The child is now waiting on its own standard input. Nothing has been sent
    # yet, so the signal cannot have arrived before this thread starts waiting.
    _ = write(ready[1], "go\n".as_bytes())
    close(ready[1])

    _expect(SIGUSR1)
    assert_equal(waitpid(pid, 0)[0], pid)
    signal_restore(SIGUSR1)


def test_an_ignored_signal_does_not_reach_the_pipe() raises:
    """Ignoring is the operating system throwing it away, not this dropping it.

    Nothing is asserted about the pipe staying empty, because proving a pipe
    has nothing in it means a read that would block forever if it did. What is
    asserted is that the platform says the signal is ignored, which is the
    thing that decides whether the handler runs at all.
    """
    signal_ignore(SIGUSR2)
    assert_true(signal_ignored(SIGUSR2))
    kill(getpid(), SIGUSR2)

    signal_restore(SIGUSR2)
    assert_false(signal_ignored(SIGUSR2))


def test_catching_a_signal_is_not_ignoring_it() raises:
    """The two dispositions, told apart by the question `signal_ignored` asks.
    """
    signal_catch(SIGUSR1)
    assert_false(signal_ignored(SIGUSR1))
    signal_restore(SIGUSR1)


def test_restoring_a_signal_nobody_took_over_is_not_a_failure() raises:
    """There is nothing remembered, so it goes to the platform default.

    A caller putting a signal back that it never took is a caller cleaning up
    along a path where the arming failed, and making that raise would mean
    every cleanup needed to know which path it was on.
    """
    signal_restore(SIGUSR2)
    assert_false(signal_ignored(SIGUSR2))


def test_a_signal_that_cannot_be_caught_says_so() raises:
    """`SIGKILL` is the platform's answer and not one invented here."""
    var failed = False
    try:
        signal_catch(9)
    except:
        failed = True
    assert_true(failed, "catching SIGKILL should raise")
