"""What the process can say about itself, as `core.os` presents it.

The eight ids are thin over `core.syscall` and are tested there against the
platform. What is worth asserting here is the part `core.os` adds and the part
that is not the same call on both platforms: `executable` reads a link on Linux
and asks libSystem on macOS, `args` turns the runtime's argument list into
strings, and `pipe` puts both ends into `File` values that close themselves.

`exit` is not tested and cannot be from inside the suite, since a test that
called it would take the runner down with it. What it does is one call and the
part worth being careful about is what its docstring promises about
destructors.
"""

from std.testing import assert_equal, assert_true

from core.io import read_all
from core.os import (
    args,
    executable,
    getegid,
    geteuid,
    getgid,
    getgroups,
    getpagesize,
    getpid,
    getppid,
    getuid,
    hostname,
    pipe,
    stat,
)


def test_the_ids_come_back_and_are_not_a_failed_call() raises:
    # Minus one is what every one of these gives when the binding is wrong, so
    # the assertion that catches a mistake is the same one for all of them.
    assert_true(getpid() > 0)
    assert_true(getppid() > 0)
    assert_true(getuid() >= 0)
    assert_true(geteuid() >= 0)
    assert_true(getgid() >= 0)
    assert_true(getegid() >= 0)


def test_this_process_is_not_its_own_parent() raises:
    assert_true(getpid() != getppid())


def test_the_groups_are_a_list_of_ids() raises:
    # The list can be empty in a container with no supplementary groups, so
    # nothing here asserts a length.
    for group in getgroups():
        assert_true(group >= 0)


def test_the_page_size_is_a_power_of_two() raises:
    var size = getpagesize()
    assert_true(size >= 4096)
    assert_equal(size & (size - 1), 0)


def test_the_host_has_a_name() raises:
    # Whatever the machine was configured with, so there is nothing to compare
    # it against. An empty answer is the failure this catches.
    assert_true(hostname().byte_length() > 0)


def test_the_arguments_start_with_something() raises:
    # The runner is started with at least a program name, and `argv[0]` is
    # whatever the parent put there, so the assertion is that there is a first
    # entry and that it is not empty rather than that it is a path.
    var given = args()
    assert_true(len(given) > 0)
    assert_true(given[0].byte_length() > 0)


def test_the_executable_is_an_absolute_path_to_a_real_file() raises:
    # The one call in this file that is written twice, once for each platform,
    # so this is the test that says both spellings agree about what they are
    # for. `stat` rather than `lstat`, since Linux answers with a resolved path
    # and macOS can answer with a link.
    var path = executable()
    assert_true(path.startswith("/"))
    var about = stat(path)
    assert_true(about.size() > 0)


def test_the_executable_is_the_same_answer_twice() raises:
    # Nothing caches it, and on macOS the relative branch joins the working
    # directory, so a second call has to give the same string as the first.
    assert_equal(executable(), executable())


def test_a_pipe_carries_bytes_from_one_end_to_the_other() raises:
    # The ends are used where they sit rather than moved into two names,
    # because Mojo cannot move a value out of a tuple. See the docstring on
    # `pipe`.
    var ends = pipe()
    assert_equal(ends[1].write_string("through the pipe"), 16)
    ends[1].close()
    var got = read_all(ends[0])
    ends[0].close()
    assert_equal(String(from_utf8_lossy=Span(got)), "through the pipe")


def test_a_reader_sees_the_end_only_after_the_writer_is_closed() raises:
    # The whole reason a pipe is easy to get wrong. `read_all` runs to the end
    # of the stream, so this test would never return if closing the write end
    # did not produce one.
    var ends = pipe()
    _ = ends[1].write_string("one")
    _ = ends[1].write_string(" and two")
    ends[1].close()
    var got = read_all(ends[0])
    ends[0].close()
    assert_equal(String(from_utf8_lossy=Span(got)), "one and two")


def test_the_two_ends_are_different_files() raises:
    var ends = pipe()
    assert_true(ends[0].fd() != ends[1].fd())
    assert_equal(ends[0].name(), "|0")
    assert_equal(ends[1].name(), "|1")
