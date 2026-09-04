"""The number a failing call leaves behind.

Almost every assertion here is against a constant from `abi.mojo` rather than
against a literal, which is the rule this package exists to enforce. `ENOENT`
happens to be 2 on both platforms and `EAGAIN` is 35 on macOS and 11 on Linux,
so a test written against literals would pass on one platform and fail on the
other, and a test written against the wrong literal would pass on neither for
reasons that read like a bug in the library.
"""

from std.testing import (
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from core.errors import field
from core.syscall import (
    EACCES,
    EAGAIN,
    EBADF,
    EEXIST,
    EINVAL,
    ENOENT,
    ENOTDIR,
    Errno,
    close,
    errno,
    open,
    set_errno,
    stat,
)


def test_zero_is_not_a_failure() raises:
    assert_false(Bool(Errno(0)))
    assert_true(Bool(Errno(ENOENT)))


def test_two_of_the_same_number_are_equal() raises:
    assert_equal(Errno(ENOENT), Errno(ENOENT))
    assert_not_equal(Errno(ENOENT), Errno(ENOTDIR))


def test_the_message_is_the_platforms_own() raises:
    # The exact wording belongs to the C library and differs between platforms,
    # so what is asserted is that there is a sentence rather than what it says.
    # ENOENT is "No such file or directory" on both, which is worth asserting
    # because it is the one message anybody reading a log will see.
    assert_equal(Errno(ENOENT).message(), "No such file or directory")
    assert_true(Errno(EACCES).message().byte_length() > 0)
    assert_true(Errno(EBADF).message().byte_length() > 0)


def test_a_number_no_table_has_still_says_the_number() raises:
    # Neither platform has a message for this, so the lookup fails and the
    # fallback is the number itself. Saying nothing would be worse.
    assert_equal(Errno(9999).message(), "errno 9999")


def test_write_to_is_the_message() raises:
    assert_equal(String(Errno(ENOENT)), Errno(ENOENT).message())


def test_a_failing_call_leaves_the_right_number() raises:
    try:
        _ = open("/nonexistent/nothing/here", 0, 0)
        raise Error("opening a path that is not there should have failed")
    except e:
        assert_equal(field(e, "errno").value(), String(ENOENT))
        assert_equal(field(e, "op").value(), "open")


def test_the_message_is_in_the_error_text() raises:
    try:
        _ = stat("/nonexistent/nothing/here")
        raise Error("stat of a path that is not there should have failed")
    except e:
        assert_equal(String(e), String("stat: ", Errno(ENOENT).message()))


def test_a_bad_descriptor_is_ebadf() raises:
    try:
        close(-1)
        raise Error("closing minus one should have failed")
    except e:
        assert_equal(field(e, "errno").value(), String(EBADF))


def test_set_errno_puts_a_number_back() raises:
    set_errno(Errno(EINVAL))
    assert_equal(errno(), Errno(EINVAL))
    set_errno(Errno(0))
    assert_false(Bool(errno()))


def test_the_constants_are_not_each_other() raises:
    # The reason nothing above compares against a literal. These five have
    # different numbers on every platform and two of them swap places between
    # macOS and Linux, so a literal does not fail to match, it matches
    # something else.
    var numbers = [EACCES, EAGAIN, EEXIST, EINVAL, ENOENT, ENOTDIR]
    for i in range(len(numbers)):
        for j in range(i + 1, len(numbers)):
            assert_not_equal(numbers[i], numbers[j])
