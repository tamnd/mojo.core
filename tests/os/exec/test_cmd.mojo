"""Running a command. `core.os.exec.Cmd`.

`/bin/sh` does the work in almost every test here, because it is at that path
on both platforms and it can be told to print anything, complain about
anything, read its input and exit with any status. What is being tested is not
the shell: it is which descriptor the child ended up with, whether the parent's
copy of a pipe was closed at the right moment, and what a non zero exit turns
into on the way back.

The tests that capture are the interesting ones. A capture that gets the order
of start, drain and wait wrong does not fail, it hangs, so the ones that write
more than a pipe will hold are here on purpose.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.errors import matches
from core.errors.codes import ErrExit, ErrNotFound
from core.io import read_all
from core.io.fs import FileMode
from core.os import mkdir_temp, pipe, remove_all, write_file
from core.os.exec import ExecError, ExitError, command
from core.path.filepath import base, join

comptime _SHELL = "/bin/sh"


def _sh(script: String) raises -> List[String]:
    """The argument list that runs `script` under the shell."""
    var out = List[String](capacity=2)
    out.append("-c")
    out.append(script)
    return out^


def _text(data: List[Byte]) -> String:
    return String(from_utf8_lossy=Span(data))


def test_a_command_that_succeeds_says_nothing_and_records_its_state() raises:
    var run = command(_SHELL, _sh("exit 0"))
    run.run()
    var state = run.process_state()
    assert_true(Bool(state))
    assert_true(state.value().success())
    assert_equal(state.value().exit_code(), 0)


def test_a_command_that_fails_raises_with_the_status_on_it() raises:
    var run = command(_SHELL, _sh("exit 4"))
    try:
        run.run()
        assert_true(False, "a non zero exit should have been raised")
    except e:
        assert_true(matches(e, ErrExit))
        var failed = ExitError.of(e)
        assert_true(Bool(failed))
        assert_equal(failed.value().state.exit_code(), 4)
        assert_equal(String(failed.value()), "exit status 4")


def test_a_program_nobody_has_installed_fails_at_the_lookup() raises:
    try:
        _ = command("no-such-program-anywhere")
        assert_true(False, "the lookup should have failed")
    except e:
        assert_true(matches(e, ErrNotFound))
        assert_true(Bool(ExecError.of(e)))
        # Not an exit error, because nothing ran. That is the split the two
        # types exist to make.
        assert_false(Bool(ExitError.of(e)))


def test_the_name_goes_in_front_of_the_arguments() raises:
    var run = command(_SHELL, _sh("exit 0"))
    assert_equal(run.args[0], _SHELL)
    assert_equal(run.args[1], "-c")
    assert_equal(len(run.args), 3)
    assert_equal(run.string(), _SHELL + " -c exit 0")


def test_output_gives_back_what_the_program_printed() raises:
    var run = command(_SHELL, _sh("printf hello"))
    assert_equal(_text(run.output()), "hello")


def test_output_keeps_standard_error_separate() raises:
    var run = command(_SHELL, _sh("printf out; printf err >&2"))
    assert_equal(_text(run.output()), "out")
    assert_equal(_text(run.captured_stderr()), "err")


def test_output_keeps_both_streams_when_the_program_fails() raises:
    # Go returns the bytes beside the error. A raise has no room for them, so
    # they are on the `Cmd` and this is the test that says they are there even
    # on the path that raised.
    var run = command(_SHELL, _sh("printf out; printf err >&2; exit 9"))
    try:
        _ = run.output()
        assert_true(False, "a non zero exit should have been raised")
    except e:
        assert_true(matches(e, ErrExit))
    assert_equal(_text(run.captured_output()), "out")
    assert_equal(_text(run.captured_stderr()), "err")


def test_combined_output_puts_both_streams_in_one_place() raises:
    var run = command(_SHELL, _sh("printf one; printf two >&2; printf three"))
    assert_equal(_text(run.combined_output()), "onetwothree")


def test_a_program_that_prints_more_than_a_pipe_holds_is_still_captured() raises:
    # The test that hangs rather than fails if the capture is arranged wrong. A
    # pipe holds sixteen kilobytes here at most, so a megabyte cannot be sitting
    # in it when the child exits: the parent has to be reading while the child
    # is writing.
    var run = command(
        _SHELL,
        _sh(
            "i=0; while [ $i -lt 1024 ]; do printf '%01023d\\n' $i; i=$((i+1));"
            " done"
        ),
    )
    var got = run.output()
    assert_equal(len(got), 1024 * 1024)


def test_a_program_that_complains_more_than_a_pipe_holds_is_still_captured() raises:
    # The same thing on the other stream, which is the one that goes to a file
    # rather than a pipe, and which would be the one to fill if it did not.
    var run = command(
        _SHELL,
        _sh(
            "i=0; while [ $i -lt 512 ]; do printf '%01023d\\n' $i >&2;"
            " i=$((i+1)); done; printf done"
        ),
    )
    assert_equal(_text(run.output()), "done")
    assert_equal(len(run.captured_stderr()), 512 * 1024)


def test_a_descriptor_the_caller_set_is_the_one_the_child_writes_to() raises:
    var ends = pipe()
    var run = command(_SHELL, _sh("printf chosen"))
    run.stdout = ends[1].fd()
    run.run()
    ends[1].close()
    var got = read_all(ends[0])
    ends[0].close()
    assert_equal(_text(got), "chosen")


def test_a_stream_nobody_set_is_not_a_closed_descriptor() raises:
    # `/dev/null`, not a closed slot. A program that reads its input should see
    # the end of it rather than a bad descriptor, and this is the difference.
    var run = command(_SHELL, _sh("cat; exit 0"))
    run.run()
    assert_true(run.process_state().value().success())


def test_the_directory_is_the_one_that_was_set() raises:
    var dir = mkdir_temp("", "cmd-dir-")
    var run = command(_SHELL, _sh('printf %s "$(pwd)"'))
    run.dir = dir.copy()
    var got = _text(run.output())
    remove_all(dir)
    # macOS hands out a temporary directory under a symbolic link, so the name
    # the shell reports is the resolved one and only the last piece of it is
    # worth asking about.
    assert_true(got.endswith(base(dir)))


def test_the_environment_is_the_one_that_was_set() raises:
    var run = command(_SHELL, _sh('printf %s "$CHOSEN"'))
    run.env = Optional[List[String]]([String("CHOSEN=yes")])
    assert_equal(_text(run.output()), "yes")


def test_an_environment_nobody_set_is_this_process_s_own() raises:
    var run = command(_SHELL, _sh("exit 0"))
    var seen = run.environ()
    # Every process has a `PATH`, and the search that found the shell used it,
    # so the copy handed to the child has to have it too.
    var found = False
    for entry in seen:
        if entry.startswith("PATH="):
            found = True
    assert_true(found, "the inherited environment should have a PATH")


def test_input_written_to_the_pipe_reaches_the_program() raises:
    var run = command(_SHELL, _sh("cat"))
    var into = run.stdin_pipe()
    var out = run.stdout_pipe()
    run.start()
    _ = into.write_string("through the pipe")
    # Closing this is what tells the program there is no more input. Without
    # it the program waits for input that is never coming and so does the wait
    # below.
    into.close()
    var got = read_all(out)
    out.close()
    run.wait()
    assert_equal(_text(got), "through the pipe")


def test_the_complaint_pipe_carries_standard_error() raises:
    var run = command(_SHELL, _sh("printf sorry >&2"))
    var complaints = run.stderr_pipe()
    run.start()
    var got = read_all(complaints)
    complaints.close()
    run.wait()
    assert_equal(_text(got), "sorry")


def test_an_extra_descriptor_reaches_the_child_as_number_three() raises:
    var ends = pipe()
    var run = command(_SHELL, _sh("printf extra >&3"))
    var extra = List[Int](capacity=1)
    extra.append(ends[1].fd())
    run.extra_files = extra^
    run.run()
    ends[1].close()
    var got = read_all(ends[0])
    ends[0].close()
    assert_equal(_text(got), "extra")


def test_a_command_cannot_be_started_twice() raises:
    var run = command(_SHELL, _sh("exit 0"))
    run.start()
    with assert_raises(contains="already been started"):
        run.start()
    run.wait()


def test_a_command_cannot_be_waited_for_twice() raises:
    var run = command(_SHELL, _sh("exit 0"))
    run.run()
    with assert_raises(contains="already been waited for"):
        run.wait()


def test_waiting_for_a_command_that_never_started_is_refused() raises:
    var run = command(_SHELL, _sh("exit 0"))
    with assert_raises(contains="has not been started"):
        run.wait()


def test_capturing_a_stream_that_was_already_set_is_refused() raises:
    var ends = pipe()
    var run = command(_SHELL, _sh("exit 0"))
    run.stdout = ends[1].fd()
    with assert_raises(contains="stdout is already set"):
        _ = run.output()
    with assert_raises(contains="stdout is already set"):
        _ = run.combined_output()
    ends[0].close()
    ends[1].close()


def test_asking_for_the_same_pipe_twice_is_refused() raises:
    var run = command(_SHELL, _sh("exit 0"))
    var first = run.stdout_pipe()
    with assert_raises(contains="stdout is already set"):
        _ = run.stdout_pipe()
    first.close()


def test_the_process_id_is_minus_one_until_it_has_started() raises:
    var run = command(_SHELL, _sh("exit 0"))
    assert_equal(run.process_id(), -1)
    assert_false(Bool(run.process_state()))
    run.start()
    assert_true(run.process_id() > 0)
    run.wait()


def test_a_running_command_can_be_killed() raises:
    var run = command(_SHELL, _sh("trap '' INT; sleep 30"))
    run.start()
    run.kill()
    try:
        run.wait()
        assert_true(False, "a killed command should not have exited cleanly")
    except e:
        assert_true(matches(e, ErrExit))
        assert_equal(String(ExitError.of(e).value()), "signal: killed")


def test_a_command_that_has_not_started_cannot_be_signalled() raises:
    var run = command(_SHELL, _sh("exit 0"))
    with assert_raises(contains="has not been started"):
        run.kill()


def test_a_program_found_by_its_own_path_is_the_one_that_runs() raises:
    var dir = mkdir_temp("", "cmd-direct-")
    var path = join([dir, "chosen"])
    write_file(
        path, "#!/bin/sh\nprintf mine\n".as_bytes(), FileMode(UInt32(0o755))
    )
    var run = command(path)
    var got = _text(run.output())
    remove_all(dir)
    assert_equal(got, "mine")
