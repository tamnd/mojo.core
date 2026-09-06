"""Starting real processes, and reading what they left behind.

There is nothing to fake here either. The whole point of `spawn` is what
happens on the far side of a fork, and a mock of it would be a test of the mock
while the fork window, which is the only part that is hard, went unexercised.
So every test below starts a real program.

The programs are `/bin/sh` and `/bin/cat`, which exist on both platforms this
library builds for and are the smallest thing that demonstrates each point. A
test that needed a helper binary of its own would need the suite to build one
first, and the suite builds one program.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import field
from core.syscall import (
    ENOENT,
    FD_CLOEXEC,
    F_SETFD,
    SPAWN_SETPGID,
    WNOHANG,
    close,
    exit_status,
    exited,
    fcntl,
    getpid,
    kill,
    read,
    signaled,
    spawn,
    stop_signal,
    stopped,
    term_signal,
    waitpid,
    write,
)
from core.syscall import pipe as _raw_pipe
from core.syscall.abi import SIGKILL, SIGTERM

comptime _SHELL = "/bin/sh"
"""The one program every test that needs a decision made in the child uses."""


def _pipe() raises -> Tuple[Int, Int]:
    """A pipe whose ends do not survive an exec.

    `core.syscall.pipe` is Go's `syscall.Pipe` and makes two ordinary
    descriptors, which a child inherits along with everything else this process
    has open. That is fine for the descriptors handed to `spawn` on purpose,
    because `dup2` clears close on exec on those, and it is a deadlock for the
    rest: a child that inherited the write end of its own input holds that pipe
    open against itself, never reads the end of it, and never exits, so the
    caller waiting for it waits forever. `core.os.pipe` sets this for the same
    reason and Go's `os.Pipe` has always done it.
    """
    var ends = _raw_pipe()
    _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC)
    _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
    return ends


def _wait(pid: Int) raises -> Int:
    """Wait for `pid` and give back its raw status."""
    var got = waitpid(pid, 0)
    assert_equal(got[0], pid)
    return got[1]


def _drain(fd: Int) raises -> String:
    """Read `fd` to the end and give back what was on it, then close it."""
    var out = List[UInt8]()
    var room = List[UInt8](length=4096, fill=0)
    while True:
        var got = read(fd, Span(room))
        if got <= 0:
            break
        for i in range(got):
            out.append(room[i])
    close(fd)
    return String(from_utf8_lossy=Span(out))


def test_a_program_runs_and_its_status_comes_back() raises:
    """The whole of the mechanism, in the smallest case there is."""
    var pid = spawn(
        _SHELL, [String("sh"), "-c", "exit 7"], [], [0, 1, 2], None, 0, 0
    )
    assert_true(pid > 0)

    var status = _wait(pid)
    assert_true(exited(status))
    assert_false(signaled(status))
    assert_equal(exit_status(status), 7)


def test_the_child_writes_to_the_descriptor_it_was_given() raises:
    """Descriptor one of the child is whatever the caller put in slot one."""
    var ends = _pipe()
    var pid = spawn(
        _SHELL,
        [String("sh"), "-c", "printf hello"],
        [],
        [0, ends[1], 2],
        None,
        0,
        0,
    )
    # The parent's copy of the write end has to go, or the read below never
    # reaches the end of the pipe.
    close(ends[1])

    assert_equal(_drain(ends[0]), "hello")
    assert_true(exited(_wait(pid)))


def test_each_slot_gets_the_descriptor_that_was_put_in_it() raises:
    """Two pipes, crossed over, so a table read in the wrong order shows.

    The child's standard error is the pipe the parent built first and its
    standard output is the second one, which is the opposite of the order they
    are written in, so a shim that filled the slots from whatever was to hand
    rather than from the table would put both lines in the same place.
    """
    var first = _pipe()
    var second = _pipe()
    var pid = spawn(
        _SHELL,
        [String("sh"), "-c", "printf out >&1; printf err >&2"],
        [],
        [0, second[1], first[1]],
        None,
        0,
        0,
    )
    close(first[1])
    close(second[1])

    assert_equal(_drain(first[0]), "err")
    assert_equal(_drain(second[0]), "out")
    assert_true(exited(_wait(pid)))


def test_a_descriptor_in_the_way_of_a_slot_is_moved_first() raises:
    """The case a single pass of `dup2` gets wrong.

    Everything above hands the child descriptors that are all above the slots
    they are going into, which no amount of ordering can get wrong. This one
    crosses two descriptors that are themselves inside the range being written:
    the write end of the first pipe goes into the slot the second one occupies
    and the other way about. A single pass writing the lower slot first would
    close the descriptor the higher slot has not copied yet, and the child
    would get the same pipe twice or nothing at all.

    The slot numbers are whatever the platform handed out, so the table is
    built at runtime and is mostly -1. That is the honest shape of the test:
    the numbers cannot be written down in advance, and picking numbers that
    happened to be free would be testing something else.
    """
    var first = _pipe()
    var second = _pipe()
    var low = first[1]
    var high = second[1]
    assert_true(low < high, "the second pipe should sit above the first")

    var table = List[Int](length=high + 1, fill=-1)
    table[0] = 0
    table[1] = 1
    table[2] = 2
    table[low] = high
    table[high] = low

    var pid = spawn(
        _SHELL,
        [
            String("sh"),
            "-c",
            "printf out >&" + String(low) + "; printf err >&" + String(high),
        ],
        [],
        table,
        None,
        0,
        0,
    )
    close(low)
    close(high)

    assert_equal(_drain(second[0]), "out")
    assert_equal(_drain(first[0]), "err")
    assert_true(exited(_wait(pid)))


def test_a_table_longer_than_three_reaches_the_child() raises:
    """Go's `ExtraFiles`, which is a longer table and nothing else.

    Descriptor three of the child is whatever went in slot three, and the shell
    writing to it proves the slot was filled rather than left over from this
    process, since everything this process opens is close on exec.
    """
    var ends = _pipe()
    var pid = spawn(
        _SHELL,
        [String("sh"), "-c", "printf extra >&3"],
        [],
        [0, 1, 2, ends[1]],
        None,
        0,
        0,
    )
    close(ends[1])

    assert_equal(_drain(ends[0]), "extra")
    assert_true(exited(_wait(pid)))


def test_a_closed_slot_stays_closed() raises:
    """A -1 in the table is a descriptor the child does not have.

    The child is asked whether it can write to descriptor three, which is the
    slot that was closed, and says which it found. Asking about one of the
    first three would have been the same question, but the shell's own answer
    to having no standard output is to report on standard error and the wording
    is its business rather than something to assert about.

    The two redirections are in the order they are for the same reason. A shell
    that cannot open descriptor three complains about it on its standard error,
    so standard error has to be out of the way before the redirection that
    fails is attempted, or the complaint lands in the suite's own output.
    """
    var ends = _pipe()
    var pid = spawn(
        _SHELL,
        [
            String("sh"),
            "-c",
            (
                "if printf x 2>/dev/null >&3; then printf open; else printf"
                " closed; fi"
            ),
        ],
        [],
        [0, ends[1], 2, -1],
        None,
        0,
        0,
    )
    close(ends[1])

    assert_equal(_drain(ends[0]), "closed")
    assert_true(exited(_wait(pid)))


def test_the_environment_is_the_one_that_was_passed() raises:
    """Nothing of this process's environment reaches the child on its own."""
    var ends = _pipe()
    var pid = spawn(
        _SHELL,
        [String("sh"), "-c", 'printf %s "$MARK"'],
        [String("MARK=carried"), "PATH=/usr/bin:/bin"],
        [0, ends[1], 2],
        None,
        0,
        0,
    )
    close(ends[1])

    assert_equal(_drain(ends[0]), "carried")
    assert_true(exited(_wait(pid)))


def test_the_child_starts_in_the_directory_it_was_given() raises:
    """`dir` is a change made in the child, before the exec."""
    var ends = _pipe()
    var pid = spawn(
        _SHELL,
        [String("sh"), "-c", "pwd"],
        [String("PATH=/usr/bin:/bin")],
        [0, ends[1], 2],
        "/",
        0,
        0,
    )
    close(ends[1])

    assert_equal(_drain(ends[0]), "/\n")
    assert_true(exited(_wait(pid)))


def test_a_program_that_is_not_there_fails_rather_than_starting() raises:
    """The errno crosses back from the child on the report pipe.

    Without that pipe this would be a process id for something that never ran,
    and the caller would find out only from an exit status of 127, which a real
    program is also allowed to have.
    """
    var failed = False
    try:
        _ = spawn(
            "/nonexistent/program",
            [String("program")],
            [],
            [0, 1, 2],
            None,
            0,
            0,
        )
    except e:
        failed = True
        assert_equal(field(e, "errno").value(), String(ENOENT))
    assert_true(failed, "spawning a missing program should raise")


def test_a_process_group_is_killed_as_one() raises:
    """What `SPAWN_SETPGID` is for.

    The shell starts a child of its own and waits, so there are two processes
    in the group and killing the leader alone would leave the second one
    running. One `kill` to the negated process id reaches both.
    """
    var ends = _pipe()
    var pid = spawn(
        _SHELL,
        [String("sh"), "-c", "sleep 30 & printf ready; wait"],
        [String("PATH=/usr/bin:/bin")],
        [0, ends[1], 2],
        None,
        SPAWN_SETPGID,
        0,
    )
    close(ends[1])

    # Wait until the shell has started its child, so the group has two members
    # by the time the signal arrives.
    var room = List[UInt8](length=8, fill=0)
    assert_true(read(ends[0], Span(room)) > 0)

    kill(-pid, SIGKILL)
    var status = _wait(pid)
    assert_true(signaled(status))
    assert_equal(term_signal(status), SIGKILL)

    # The shell's own child died with it, so nothing is left holding the write
    # end and the pipe reaches its end.
    assert_equal(_drain(ends[0]), "")


def test_a_signal_status_is_not_an_exit_status() raises:
    """The two halves of a wait status, told apart."""
    var pid = spawn(
        _SHELL,
        [String("sh"), "-c", "sleep 30"],
        [String("PATH=/usr/bin:/bin")],
        [0, 1, 2],
        None,
        0,
        0,
    )
    kill(pid, SIGTERM)

    var status = _wait(pid)
    assert_false(exited(status))
    assert_true(signaled(status))
    assert_equal(term_signal(status), SIGTERM)


def test_a_stopped_status_is_neither_an_exit_nor_a_death() raises:
    """The third answer, which the other two have to leave room for.

    Nothing in this library asks for a stopped child yet, so the status is
    built by hand rather than arranged. It is worth a test anyway because the
    reading of it is a bit trick that is easy to get wrong in exactly one
    direction: the low byte `0x7f` means stopped, and an implementation that
    forgets to exclude it reports a process killed by signal 127.
    """
    var status = (SIGTERM << 8) | 0x7F
    assert_false(exited(status))
    assert_false(signaled(status))
    assert_true(stopped(status))
    assert_equal(stop_signal(status), SIGTERM)


def test_waiting_without_blocking_says_nothing_yet() raises:
    """`WNOHANG` gives back zero rather than failing.

    A caller polling for a child that has not finished has not gone wrong, so
    this is a result and not a raise.
    """
    var ends = _pipe()
    var pid = spawn(
        _SHELL,
        [String("sh"), "-c", "read line; exit 3"],
        [],
        [ends[0], 1, 2],
        None,
        0,
        0,
    )
    close(ends[0])

    assert_equal(waitpid(pid, WNOHANG)[0], 0)

    _ = write(ends[1], "go\n".as_bytes())
    close(ends[1])
    assert_equal(exit_status(_wait(pid)), 3)


def test_a_megabyte_goes_through_pipes_on_all_three_streams() raises:
    """The deadlock this whole arrangement has to not have.

    A pipe on this laptop holds sixteen kilobytes. A caller that writes a
    megabyte into one before reading anything fills it and blocks, and the
    child, having filled its own output pipe, has stopped reading. Neither
    moves again, and there is no thread here to break the tie: Go copies each
    stream on a goroutine of its own and this library has no goroutines yet.

    So the rule the test demonstrates is the one a single threaded caller has
    to follow. Write no more than a pipe will hold, read all of it back, and
    only then write the next block. Both pipes are empty at the top of every
    round, so neither side is ever waiting on the other to drain something.

    `cat` copies its input to its output, so what comes back has to be what
    went out. The bytes count up rather than repeat, so a copy that lost or
    reordered a block would not still compare equal.
    """
    var into = _pipe()
    var back = _pipe()
    var wrong = _pipe()
    var pid = spawn(
        "/bin/cat",
        [String("cat")],
        [],
        [into[0], back[1], wrong[1]],
        None,
        0,
        0,
    )
    close(into[0])
    close(back[1])
    close(wrong[1])

    comptime block = 4096
    var sending = List[UInt8](capacity=block)
    for i in range(block):
        sending.append(UInt8(i & 0xFF))

    var rounds = 256  # 256 * 4096 is one megabyte.
    var got = 0
    var room = List[UInt8](length=block, fill=0)
    for round in range(rounds):
        var sent = 0
        while sent < block:
            sent += write(into[1], Span(sending)[sent:])
        var back_in = 0
        while back_in < block:
            var more = read(back[0], Span(room)[back_in:])
            assert_true(more > 0)
            back_in += more
        got += back_in
        # Once, because comparing a megabyte a byte at a time would cost more
        # than everything else in this file put together and a copy that is
        # wrong is wrong on the first block.
        if round == 0:
            assert_equal(room, sending)

    close(into[1])
    assert_equal(read(back[0], Span(room)), 0)
    close(back[0])

    assert_equal(got, rounds * block)
    assert_equal(_drain(wrong[0]), "")
    assert_true(exited(_wait(pid)))


def test_the_caller_gets_a_process_id_that_is_not_its_own() raises:
    """A sanity check on the value that comes back.

    A fork that reported the child's zero to the parent would be a caller
    waiting for every child there is, and a fork whose return was ignored would
    be this process's own id, which is the sort of thing that only shows up
    when something later kills it.
    """
    var pid = spawn(
        _SHELL, [String("sh"), "-c", "exit 0"], [], [0, 1, 2], None, 0, 0
    )
    assert_true(pid > 0)
    assert_false(pid == getpid())
    assert_true(exited(_wait(pid)))
