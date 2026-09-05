"""The calls that ask about the process rather than about a file.

Almost all of these cannot fail, so what is left to assert is that the number
coming back is the platform's own answer rather than a zero from a call that
was not made. The way to tell those apart is a relationship between two calls:
a pid is positive and is not its own parent's, a page size is a power of two,
and the effective ids match the real ones unless somebody arranged otherwise.

`exit` is not tested here and cannot be, since a test that called it would take
the runner down with it. What it does is one line of C and the part worth being
careful about is what its docstring says about destructors.
"""

from std.testing import assert_equal, assert_true

from core.errors import field
from core.syscall import (
    EBADF,
    close,
    getegid,
    geteuid,
    getgid,
    getgroups,
    gethostname,
    getpagesize,
    getpid,
    getppid,
    getuid,
    pipe,
    read,
    write,
)

comptime Byte = UInt8
"""What a buffer is made of, as everywhere else in this suite."""


def test_the_process_id_is_positive() raises:
    assert_true(getpid() > 0)


def test_the_parent_is_another_process() raises:
    # A test runner is started by something, so the parent is a real process
    # and is not this one. It can be 1 when the parent has already exited and
    # this was handed to init, which is why the assertion is about what it is
    # not rather than about what it is.
    var parent = getppid()
    assert_true(parent > 0)
    assert_true(parent != getpid())


def test_the_user_ids_are_not_negative() raises:
    # Root is zero and every other user is above it, so the useful assertion is
    # that nothing came back as the minus one a failed call would give.
    assert_true(getuid() >= 0)
    assert_true(geteuid() >= 0)
    assert_true(getgid() >= 0)
    assert_true(getegid() >= 0)


def test_the_effective_ids_match_the_real_ones_here() raises:
    # True of a test runner, which nobody has made set-user-id, and worth
    # asserting because it is what says the four calls are four calls rather
    # than one call bound four times.
    assert_equal(getuid(), geteuid())
    assert_equal(getgid(), getegid())


def test_the_groups_are_a_list_of_ids() raises:
    # The list can be empty, which is what a container with no supplementary
    # groups gives, so nothing here asserts a length. What it does assert is
    # that every entry is an id rather than whatever was in the buffer, which
    # is how a wrong size would show up.
    for group in getgroups():
        assert_true(group >= 0)


def test_the_page_size_is_a_power_of_two() raises:
    # 4,096 on Linux x86-64 and 16,384 on Apple silicon. Neither number is
    # asserted, because the point of the call is that the same binary runs on
    # machines that disagree.
    var size = getpagesize()
    assert_true(size > 0)
    assert_equal(size & (size - 1), 0)


def test_the_host_has_a_name() raises:
    # Not asserted against anything, since the name is whatever the machine was
    # configured with and the runners and the laptops all differ. An empty
    # answer would be the buffer coming back untouched.
    var name = gethostname()
    assert_true(name.byte_length() > 0)


def test_a_pipe_carries_bytes_from_one_end_to_the_other() raises:
    var ends = pipe()
    var reader = ends[0]
    var writer = ends[1]
    var sent = String("through the pipe")
    assert_equal(write(writer, sent.as_bytes()), sent.byte_length())

    var room = List[Byte](length=64, fill=0)
    var got = read(reader, Span(room))
    var back = String()
    for i in range(got):
        back += chr(Int(room[i]))
    close(reader)
    close(writer)
    assert_equal(back, sent)


def test_the_two_ends_of_a_pipe_are_different_descriptors() raises:
    # The read end comes back first, which is the order C fills its array in
    # and the order everything written against this will assume.
    var ends = pipe()
    assert_true(ends[0] != ends[1])
    assert_true(ends[0] >= 0)
    close(ends[0])
    close(ends[1])


def test_a_pipe_end_is_a_real_descriptor() raises:
    # Nothing about pipes, and here because closing the same number twice is
    # what says these came from the kernel rather than being two integers
    # somebody made up.
    var ends = pipe()
    close(ends[0])
    close(ends[1])
    try:
        close(ends[0])
        raise Error("closing a descriptor twice should have failed")
    except e:
        assert_equal(field(e, "errno").value(), String(EBADF))
