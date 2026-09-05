"""Starting a program and collecting it, as `core.os` presents it.

The call underneath is tested in `tests/syscall/test_spawn.mojo` against the
platform, so what is worth asserting here is the layer this package adds: the
descriptor table it builds from a `ProcAttr`, the wait status it turns into a
`ProcessState`, the sentence that state prints as, and the refusals that happen
before any call is made.

`/bin/sh` is the program every test here runs, because it is on both platforms
at that path, it can be told to exit with any status, and it can be told to
stop and wait so that a signal has something to arrive at.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.errors import matches
from core.errors.codes import ErrProcessDone
from core.io import read_all
from core.os import (
    INTERRUPT,
    KILL,
    ProcAttr,
    ProcessState,
    Signal,
    find_process,
    getpid,
    pipe,
    start_process,
)
from core.syscall import SIGINT, SIGKILL, SIGTERM

comptime _SHELL = "/bin/sh"


def _run(script: String) raises -> ProcessState:
    """Run `script` under the shell with the streams this process has."""
    var started = start_process(
        _SHELL, [String("sh"), "-c", script], ProcAttr()
    )
    return started.wait()


def test_a_program_that_exits_with_zero_says_so() raises:
    var state = _run("exit 0")
    assert_true(state.exited())
    assert_true(state.success())
    assert_equal(state.exit_code(), 0)
    assert_equal(state.string(), "exit status 0")


def test_a_program_that_exits_with_a_number_carries_it() raises:
    var state = _run("exit 3")
    assert_true(state.exited())
    assert_false(state.success())
    assert_equal(state.exit_code(), 3)
    assert_equal(state.string(), "exit status 3")


def test_a_program_killed_by_a_signal_names_the_signal() raises:
    var state = _run("kill -TERM $$")
    assert_false(state.exited())
    assert_false(state.success())
    # Not exited, so there is no code to give and Go gives minus one.
    assert_equal(state.exit_code(), -1)
    assert_equal(state.string(), "signal: terminated")


def test_the_state_knows_which_process_it_is_about() raises:
    var started = start_process(
        _SHELL, [String("sh"), "-c", "exit 0"], ProcAttr()
    )
    var pid = started.pid
    var state = started.wait()
    assert_equal(state.pid(), pid)
    assert_true(pid > 0)
    assert_true(pid != getpid())


def test_the_raw_status_is_the_one_the_platform_gave() raises:
    var state = _run("exit 7")
    # Every platform this builds for puts the exit code in the second byte, so
    # the raw number is the code shifted up. Asserting it is how the accessors
    # are checked against something other than themselves.
    assert_equal(state.sys(), 7 << 8)


def test_the_environment_is_the_one_that_was_asked_for() raises:
    var ends = pipe()
    var attr = ProcAttr(
        env=Optional[List[String]]([String("CHOSEN=yes")]),
        files=[0, ends[1].fd(), 2],
    )
    var started = start_process(
        _SHELL, [String("sh"), "-c", 'printf %s "$CHOSEN"'], attr
    )
    ends[1].close()
    var got = read_all(ends[0])
    ends[0].close()
    assert_true(started.wait().success())
    assert_equal(String(from_utf8_lossy=Span(got)), "yes")


def test_the_directory_is_the_one_that_was_asked_for() raises:
    var ends = pipe()
    var attr = ProcAttr(dir=String("/"), files=[0, ends[1].fd(), 2])
    var started = start_process(
        _SHELL, [String("sh"), "-c", 'printf %s "$(pwd)"'], attr
    )
    ends[1].close()
    var got = read_all(ends[0])
    ends[0].close()
    assert_true(started.wait().success())
    assert_equal(String(from_utf8_lossy=Span(got)), "/")


def test_a_program_that_is_not_there_fails_before_it_starts() raises:
    with assert_raises(contains="no-such-program-anywhere"):
        _ = start_process(
            "/no-such-program-anywhere", [String("nope")], ProcAttr()
        )


def test_waiting_twice_is_refused_rather_than_asked_of_the_platform() raises:
    var started = start_process(
        _SHELL, [String("sh"), "-c", "exit 0"], ProcAttr()
    )
    _ = started.wait()
    with assert_raises(contains="process already finished"):
        _ = started.wait()


def test_the_refusal_to_wait_twice_carries_the_sentinel() raises:
    var started = start_process(
        _SHELL, [String("sh"), "-c", "exit 0"], ProcAttr()
    )
    _ = started.wait()
    try:
        _ = started.wait()
        assert_true(False, "waiting twice should have been refused")
    except e:
        assert_true(matches(e, ErrProcessDone))


def test_a_released_process_is_refused_the_same_way() raises:
    var started = start_process(
        _SHELL, [String("sh"), "-c", "exit 0"], ProcAttr()
    )
    var collector = started.copy()
    started.release()
    with assert_raises(contains="process already finished"):
        _ = started.wait()
    # The copy still has the child, so the suite does not leave a zombie.
    _ = collector.wait()


def test_a_signal_reaches_the_child() raises:
    var started = start_process(
        _SHELL, [String("sh"), "-c", "sleep 30"], ProcAttr()
    )
    started.signal(INTERRUPT)
    var state = started.wait()
    assert_false(state.exited())
    assert_equal(state.string(), "signal: interrupt")


def test_kill_stops_a_child_that_is_doing_nothing_else() raises:
    # The signal no program can catch, which is what `kill` is for and what
    # separates it from `signal`.
    var started = start_process(
        _SHELL, [String("sh"), "-c", "sleep 30"], ProcAttr()
    )
    started.kill()
    var state = started.wait()
    assert_false(state.exited())
    assert_equal(state.string(), "signal: killed")


def test_signalling_a_finished_process_is_refused() raises:
    var started = start_process(
        _SHELL, [String("sh"), "-c", "exit 0"], ProcAttr()
    )
    _ = started.wait()
    with assert_raises(contains="process already finished"):
        started.signal(INTERRUPT)


def test_find_process_gives_back_the_number_it_was_given() raises:
    var found = find_process(getpid())
    assert_equal(found.pid, getpid())


def test_a_signal_prints_what_the_platform_calls_it() raises:
    assert_equal(Signal(SIGINT).string(), "interrupt")
    assert_equal(Signal(SIGKILL).string(), "killed")
    assert_equal(Signal(SIGTERM).string(), "terminated")
    assert_equal(String(Signal(SIGINT)), "interrupt")


def test_a_signal_nobody_named_prints_its_number() raises:
    # Go falls back to this exact wording rather than to an empty string, so a
    # log line about a signal from a real time range still says something.
    assert_equal(Signal(1 << 20).string(), "signal 1048576")


def test_the_two_named_signals_are_the_numbers_they_should_be() raises:
    assert_equal(INTERRUPT.number, SIGINT)
    assert_equal(KILL.number, SIGKILL)
    assert_true(INTERRUPT == Signal(SIGINT))
    assert_true(INTERRUPT != KILL)


def test_a_state_built_by_hand_prints_the_four_shapes() raises:
    # The four sentences Go's `ProcessState.String` can produce, built from raw
    # statuses so that the suite does not have to arrange a stopped child to
    # find out whether the third one is right.
    assert_equal(ProcessState(1, 5 << 8).string(), "exit status 5")
    assert_equal(ProcessState(1, SIGINT).string(), "signal: interrupt")
    assert_equal(
        ProcessState(1, (SIGINT << 8) | 0x7F).string(),
        "stop signal: interrupt",
    )
    assert_equal(ProcessState(1, 0xFFFF).string(), "continued")


def test_a_core_dumped_status_says_so() raises:
    # The bit above the signal number, which no test can produce on demand
    # because whether a core is written is the platform's business.
    assert_equal(
        ProcessState(1, SIGINT | 0x80).string(),
        "signal: interrupt (core dumped)",
    )
