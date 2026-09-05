"""Finding a program by name. `core.os.exec.look_path`.

`PATH` is process wide, so every test here sets it, does its one thing and puts
it back. The programs looked for are made in a temporary directory rather than
found on the system, because what is on the system differs between the two
platforms this builds for and a test that depended on it would be a test that
passes in one place.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.errors import capture, matches
from core.errors.codes import ErrDot, ErrNotFound
from core.io.fs import FileMode
from core.os import (
    chdir,
    chmod,
    getenv,
    getwd,
    mkdir_temp,
    remove_all,
    setenv,
    write_file,
)
from core.os.exec import ExecError, look_path
from core.path.filepath import join


def _runnable(dir: String, name: String) raises -> String:
    """A file in `dir` that could be executed, and its path."""
    var path = join([dir, name])
    write_file(path, "#!/bin/sh\nexit 0\n".as_bytes(), FileMode(UInt32(0o644)))
    chmod(path, FileMode(UInt32(0o755)))
    return path^


def _plain(dir: String, name: String) raises -> String:
    """A file in `dir` that could not be executed, and its path."""
    var path = join([dir, name])
    write_file(path, "not a program\n".as_bytes(), FileMode(UInt32(0o644)))
    return path^


def test_a_name_is_found_in_the_first_directory_that_has_it() raises:
    var first = mkdir_temp("", "look-first-")
    var second = mkdir_temp("", "look-second-")
    var wanted = _runnable(first, "chosen")
    _ = _runnable(second, "chosen")
    var before = getenv("PATH")
    setenv("PATH", first + ":" + second)
    var found = look_path("chosen")
    setenv("PATH", before)
    remove_all(first)
    remove_all(second)
    assert_equal(found, wanted)


def test_a_directory_earlier_on_the_path_does_not_win_without_the_file() raises:
    # The ordering rule stated the other way round, which is the half that
    # catches a search that stops at the first directory rather than the first
    # match.
    var first = mkdir_temp("", "look-empty-")
    var second = mkdir_temp("", "look-full-")
    var wanted = _runnable(second, "chosen")
    var before = getenv("PATH")
    setenv("PATH", first + ":" + second)
    var found = look_path("chosen")
    setenv("PATH", before)
    remove_all(first)
    remove_all(second)
    assert_equal(found, wanted)


def test_a_file_nobody_may_execute_is_not_a_program() raises:
    var dir = mkdir_temp("", "look-plain-")
    _ = _plain(dir, "chosen")
    var before = getenv("PATH")
    setenv("PATH", dir)
    var failed = False
    try:
        _ = look_path("chosen")
    except e:
        failed = True
        assert_true(matches(e, ErrNotFound))
    setenv("PATH", before)
    remove_all(dir)
    assert_true(failed, "a file with no execute bit should not be found")


def test_a_directory_with_the_right_name_is_not_a_program() raises:
    # Directories have the execute bit set and mean something else by it, so a
    # search that looked only at the permission bits would find one.
    var dir = mkdir_temp("", "look-dir-")
    _ = mkdir_temp(dir, "chosen")
    var before = getenv("PATH")
    setenv("PATH", dir)
    var failed = False
    try:
        _ = look_path("chosen")
    except:
        failed = True
    setenv("PATH", before)
    remove_all(dir)
    assert_true(failed, "a directory should not be found as a program")


def test_a_name_with_a_separator_is_not_searched_for() raises:
    var dir = mkdir_temp("", "look-direct-")
    var made = _runnable(dir, "chosen")
    var before = getenv("PATH")
    setenv("PATH", "/nowhere-at-all")
    var found = look_path(made)
    setenv("PATH", before)
    remove_all(dir)
    assert_equal(found, made)


def test_a_path_that_names_nothing_is_refused_without_a_search() raises:
    with assert_raises(contains="executable file not found"):
        _ = look_path("/no-such-directory-anywhere/nothing")


def test_a_name_nobody_has_installed_is_not_found() raises:
    var before = getenv("PATH")
    setenv("PATH", "/nowhere-at-all")
    var failed = False
    try:
        _ = look_path("chosen")
    except e:
        failed = True
        assert_true(matches(e, ErrNotFound))
    setenv("PATH", before)
    assert_true(failed, "nothing should have been found on an empty path")


def test_a_program_found_through_an_empty_entry_is_refused() raises:
    # The corner this whole file is about. An empty entry means the working
    # directory, and a program found that way is one somebody may have left
    # there, so Go has refused to run it since 1.19 and so does this.
    var dir = mkdir_temp("", "look-dot-")
    _ = _runnable(dir, "chosen")
    var before = getenv("PATH")
    var here = getwd()
    chdir(dir)
    setenv("PATH", ":/nowhere-at-all")
    var failed = False
    try:
        _ = look_path("chosen")
    except e:
        failed = True
        assert_true(matches(e, ErrDot))
        var bad = ExecError.of(e)
        assert_true(Bool(bad))
        assert_true(bad.value().refused_dot)
        assert_equal(bad.value().name, "chosen")
    setenv("PATH", before)
    chdir(here)
    remove_all(dir)
    assert_true(failed, "a program in the working directory should be refused")


def test_the_refusal_says_which_path_it_found() raises:
    # The path is on the record rather than in the message, so a caller who did
    # mean it can read it back and run it deliberately, which is the only way
    # out of this refusal. It has no leading dot, because the join that built it
    # cleans the path and Go hands back the same cleaned name.
    var dir = mkdir_temp("", "look-dot-path-")
    _ = _runnable(dir, "chosen")
    var before = getenv("PATH")
    var here = getwd()
    chdir(dir)
    # Two empty entries rather than one empty string, because an empty `PATH`
    # splits into no entries at all and would be searched nowhere.
    setenv("PATH", ":")
    var found = String("")
    try:
        _ = look_path("chosen")
    except e:
        found = capture(e).field("path").or_else(String(""))
    setenv("PATH", before)
    chdir(here)
    remove_all(dir)
    assert_equal(found, "chosen")


def test_an_error_from_somewhere_else_is_not_read_as_this_one() raises:
    var other = Error("something else entirely")
    assert_true(not ExecError.of(other))
