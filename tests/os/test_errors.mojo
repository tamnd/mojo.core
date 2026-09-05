"""The three predicates, and the two error shapes that are not about one path.

The predicates are asked of failures the kernel produced, because that is the
only version of the question worth answering. `is_exist` is a claim about which
numbers a platform uses for "it was already there", and an error built in this
file to carry `EEXIST` proves only that the builder and the reader agree.
`ENOTEMPTY` is the case that makes the point: it is 66 on macOS and 39 on Linux
and nothing about it looks like `EEXIST`, but a caller removing a directory
wants the same answer for both.

`LinkError` has no producer yet, since `rename`, `link` and `symlink` are not
in `core.os` until the file half of this package lands. It is built here
through `_link_error`, the same builder those three will use, so the shape the
reader expects is pinned before there is anything writing it.
"""

from std.testing import (
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from core.errors import ErrUnsupported, Report, matches
from core.io.fs import PathError
from core.io.fs.errors import _path_error
from core.os import (
    LinkError,
    SyscallError,
    is_exist,
    is_not_exist,
    is_permission,
    new_syscall_error,
    stat,
)
from core.os.errors import _link_error
from core.syscall import (
    EACCES,
    EAGAIN,
    EEXIST,
    ENOENT,
    ENOSYS,
    ENOTSUP,
    EOPNOTSUPP,
    EPERM,
    ETIMEDOUT,
    EXDEV,
    Errno,
    chdir,
    close,
    create,
    getpid,
    mkdir,
    rmdir,
    unlink,
)


def _scratch(name: String) raises -> String:
    var place = String("/tmp/mojo-core-oserr-", getpid(), "-", name)
    try:
        rmdir(place)
    except:
        pass
    mkdir(place, 0o700)
    return place


def test_is_exist_for_a_directory_that_is_already_there() raises:
    var place = _scratch("twice")
    var raised = False
    try:
        mkdir(place, 0o700)
    except e:
        raised = True
        assert_true(is_exist(e))
        assert_false(is_not_exist(e))
        assert_false(is_permission(e))
    assert_true(raised, "a second mkdir of the same path did not raise")
    rmdir(place)


def test_is_exist_for_a_directory_that_is_not_empty() raises:
    """`ENOTEMPTY` and not `EEXIST`, and the same answer either way.

    This is the pairing `_sentinel` exists for. A caller removing a directory
    and getting a number it has never heard of would go down the wrong branch,
    and the number differs between the two platforms this library builds for.
    """
    var place = _scratch("full")
    var inside = String(place, "/inside.txt")
    close(create(inside, 0o644))

    var raised = False
    try:
        rmdir(place)
    except e:
        raised = True
        assert_true(is_exist(e))
        assert_false(is_not_exist(e))
    assert_true(raised, "rmdir of a directory with a file in it did not raise")

    unlink(inside)
    rmdir(place)


def test_is_not_exist_for_a_remove_of_nothing() raises:
    var place = _scratch("gone")
    var raised = False
    try:
        unlink(String(place, "/never.txt"))
    except e:
        raised = True
        assert_true(is_not_exist(e))
        assert_false(is_exist(e))
        assert_false(is_permission(e))
    assert_true(raised, "unlink of a missing file did not raise")
    rmdir(place)


def test_the_predicates_answer_for_a_bare_syscall_error() raises:
    """Not only for one that came back out of `core.os` carrying a sentinel.

    `core.syscall` records the number and no sentinel, on the grounds that a
    package that close to the kernel has no business deciding that `ENOENT` is
    a category. The predicates read the number when there is no sentinel, which
    is how Go behaves for a bare `syscall.Errno` and is the only way a caller
    can use them without knowing which layer raised what they caught.
    """
    var place = _scratch("layers")
    var path = String(place, "/missing.txt")

    var low = False
    try:
        unlink(path)
    except e:
        low = True
        # Straight out of `core.syscall`: a number and no code.
        assert_true(is_not_exist(e))

    var high = False
    try:
        _ = stat(path)
    except e:
        high = True
        # Through `core.os`: the same answer, from the code this time.
        assert_true(is_not_exist(e))

    assert_true(low and high)
    rmdir(place)


def test_the_predicates_are_false_for_an_unrelated_error() raises:
    """An error with neither a code nor an errno is none of the three.

    The alternative would be a predicate that says "not there" about a parse
    failure, which is worse than one that says nothing.
    """
    var e = Report("something else went wrong").error()
    assert_false(is_exist(e))
    assert_false(is_not_exist(e))
    assert_false(is_permission(e))


def test_the_fourth_group_go_writes_down() raises:
    """`ENOSYS`, `ENOTSUP` and `EOPNOTSUPP` all mean `ErrUnsupported`.

    Go's `syscall.Errno.Is` has four cases and this is the one with no
    predicate in `os` in front of it, so it is asked through `matches`, which
    is what Go's own documentation tells a caller to use for the other three
    as well.

    There is no way to make a kernel produce one of these on demand, so this is
    the one row in the mapping tested against an error built here rather than
    against a call that failed. Naming that is better than leaving the three
    numbers untested because the shape of the test would be inconsistent.
    """
    for number in [ENOSYS, ENOTSUP, EOPNOTSUPP]:
        var e = new_syscall_error("fallocate", Errno(number)).value()
        assert_true(matches(e, ErrUnsupported))
        assert_false(is_not_exist(e))
        assert_false(is_permission(e))


def test_a_syscall_error_from_a_real_failure() raises:
    """`chdir` into a directory that is not there.

    The call names itself and there is no path on the record, which is the
    shape `SyscallError` reads and the shape `PathError` refuses.
    """
    var place = _scratch("chdir")
    var raised = False
    try:
        chdir(String(place, "/nowhere"))
    except e:
        raised = True
        var failed = SyscallError.of(e)
        assert_true(Bool(failed))
        assert_equal(failed.value().syscall, "chdir")
        assert_equal(failed.value().unwrap().value, ENOENT)
        assert_false(failed.value().timeout())
        assert_equal(failed.value().error(), String(e))
        assert_false(Bool(PathError.of(e)))
    assert_true(raised, "chdir into a missing directory did not raise")
    rmdir(place)


def test_a_path_error_is_not_a_syscall_error() raises:
    """The `path` field is what tells them apart, and only one has it."""
    var e = _path_error("open", "/no/such/file", Errno(ENOENT))
    assert_true(Bool(PathError.of(e)))
    assert_false(Bool(SyscallError.of(e)))
    assert_false(Bool(LinkError.of(e)))


def test_new_syscall_error_is_empty_for_a_call_that_worked() raises:
    """Go returns nil for a nil error so the caller writes no branch.

    An `Optional` is that same shape here and `Errno(0)` is the nil, which is
    what makes `return new_syscall_error("chdir", err)` a correct line rather
    than one that manufactures a failure out of a success.
    """
    assert_false(Bool(new_syscall_error("chdir", Errno(0))))


def test_new_syscall_error_carries_the_sentinel() raises:
    """So a caller can ask the predicates about what it built.

    The message is the call, a colon and the platform's own wording, which is
    Go's `SyscallError.Error` character for character.
    """
    var made = new_syscall_error("chdir", Errno(EACCES))
    assert_true(Bool(made))
    var e = made.value()
    assert_true(is_permission(e))
    assert_false(is_not_exist(e))
    assert_equal(String(e), String("chdir: ", Errno(EACCES).message()))

    var read = SyscallError.of(e)
    assert_true(Bool(read))
    assert_equal(read.value().syscall, "chdir")
    assert_equal(read.value().unwrap().value, EACCES)
    assert_equal(read.value().error(), String(e))


def test_a_link_error_names_both_paths() raises:
    """A rename across two file systems is about the pair and not about either.

    `EXDEV` is the reason the type exists: neither path on its own is wrong and
    a message naming one of them explains nothing.
    """
    var e = _link_error("rename", "/one/a", "/two/b", Errno(EXDEV))
    var failed = LinkError.of(e)
    assert_true(Bool(failed))
    assert_equal(failed.value().op, "rename")
    assert_equal(failed.value().old, "/one/a")
    assert_equal(failed.value().new, "/two/b")
    assert_equal(failed.value().unwrap().value, EXDEV)
    assert_equal(
        failed.value().error(),
        String("rename /one/a /two/b: ", Errno(EXDEV).message()),
    )
    assert_equal(String(e), failed.value().error())
    assert_equal(String(failed.value()), failed.value().error())

    # It is not either of the other two, which have a `path` or nothing at all
    # where this has an `old` and a `new`.
    assert_false(Bool(PathError.of(e)))


def test_a_link_error_still_answers_the_predicates() raises:
    """The sentinel goes on it the same way, so `is_exist` works on a rename
    that failed because the destination was already there."""
    var e = _link_error("link", "/a", "/b", Errno(EEXIST))
    assert_true(is_exist(e))
    assert_false(is_not_exist(e))


def test_timeout_is_asked_of_the_errno() raises:
    """Go has it so these types satisfy `net.Error`, and the question is the
    same one: did the call give up waiting, as opposed to failing outright.

    `EAGAIN` and `EWOULDBLOCK` are the same number on both platforms here, so
    the two names cannot be told apart and both are covered by the one row.
    """
    var timed_out = new_syscall_error("read", Errno(ETIMEDOUT)).value()
    assert_true(SyscallError.of(timed_out).value().timeout())

    var again = new_syscall_error("read", Errno(EAGAIN)).value()
    assert_true(SyscallError.of(again).value().timeout())

    var refused = new_syscall_error("read", Errno(EACCES)).value()
    assert_false(SyscallError.of(refused).value().timeout())

    var missing = _path_error("open", "/no/such/file", Errno(ENOENT))
    assert_false(PathError.of(missing).value().timeout())


def test_two_errnos_that_mean_one_thing_are_still_two_numbers() raises:
    """The predicates collapse them and nothing else does.

    A caller who needs to tell `EACCES` from `EPERM` still can, which matters
    because they arrive from different operations and only one of them is ever
    fixed by changing a mode.
    """
    # Each error is read before the next one is raised, because the record
    # lives in a slot that the next raise on this thread overwrites. Reading it
    # into a `PathError` is what makes it outlive the slot, which is the same
    # reason `capture` exists.
    var denied_error = _path_error("open", "/a", Errno(EACCES))
    var denied_is_permission = is_permission(denied_error)
    var denied = PathError.of(denied_error).value().copy()

    var refused_error = _path_error("chown", "/a", Errno(EPERM))
    var refused_is_permission = is_permission(refused_error)
    var refused = PathError.of(refused_error).value().copy()

    assert_true(denied_is_permission)
    assert_true(refused_is_permission)
    assert_not_equal(denied.unwrap().value, refused.unwrap().value)
    assert_not_equal(denied.error(), refused.error())
