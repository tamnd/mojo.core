"""The two failures that are not about one path, and the three predicates.

`PathError` covers a call made on a single path and lives in `core.io.fs`,
where Go declares it. The two here are the ones that do not fit that shape: a
call made on two paths at once, and a call made on no path at all.

The predicates are here rather than beside `PathError` because Go puts them
here. `io/fs` declares the sentinels and `os` declares the questions, which
reads oddly until you remember that `os.IsExist` predates `errors.Is` by years
and the sentinels were extracted out from under it afterwards.
"""

from core.errors import Code, Report, capture, matches
from core.io.fs import ErrExist, ErrNotExist, ErrPermission
from core.io.fs.errors import _errno_of, _sentinel, _timeout
from core.syscall import Errno


def _says(e: Error, code: Code) -> Bool:
    """Whether `e` means `code`, whether or not it was tagged with it.

    The tag is the first answer and covers everything raised through `core.os`.
    The errno is the second and covers an error caught straight out of
    `core.syscall`, which records the number but no sentinel, because a package
    that low has no business deciding that `ENOENT` is a category.

    Go arrives at the same place from the other direction: `syscall.Errno` has
    an `Is` method, so `errors.Is(syscall.ENOENT, fs.ErrNotExist)` is true and
    `os.IsNotExist` answers for a bare errno as readily as for a `*PathError`.
    A predicate that answered only for wrapped errors would be a trap, since
    the wrapping is invisible at the call site.
    """
    return matches(e, code) or _sentinel(_errno_of(e)) == code


def is_exist(e: Error) -> Bool:
    """Whether `e` says something was already there. Go's `IsExist`.

    True for `EEXIST` and for `ENOTEMPTY`. Go's own documentation says to
    prefer `errors.Is(err, fs.ErrExist)`, and `matches(e, ErrExist)` is that
    call; this is here because Go has it and because it reads better inside a
    condition.
    """
    return _says(e, ErrExist)


def is_not_exist(e: Error) -> Bool:
    """Whether `e` says nothing was there. Go's `IsNotExist`.

    True for `ENOENT`, which covers a missing final element and a missing
    directory anywhere along the path. This is the distinction a caller usually
    wants: an open that failed this way can be retried as a create, and one
    that failed any other way cannot.

    ```mojo
    from core.os import is_not_exist, stat

    def main():
        try:
            _ = stat("/no/such/file")
        except e:
            print(is_not_exist(e))  # True
    ```
    """
    return _says(e, ErrNotExist)


def is_permission(e: Error) -> Bool:
    """Whether `e` says the caller is not allowed. Go's `IsPermission`.

    True for `EACCES` and for `EPERM`. Which of the two arrives depends on the
    operation rather than on the caller, so asking about the pair is the only
    question with a stable answer.
    """
    return _says(e, ErrPermission)


struct LinkError(Copyable, Movable, Writable):
    """A call on two paths that failed. Go's `os.LinkError`.

    `rename`, `link` and `symlink` are the three, and a failure in any of them
    is about the pair rather than about either one: a rename across two file
    systems fails with `EXDEV` and neither path on its own explains it.

    Built from a raised error by `of` rather than by hand, and every field is a
    copy, so it outlives the `Error` it came from.
    """

    var op: String
    """The call that failed: `rename`, `link`, `symlink`."""

    var old: String
    """The path that already exists."""

    var new: String
    """The path that was going to."""

    var err: Errno
    """The number the platform left behind."""

    def __init__(
        out self, var op: String, var old: String, var new: String, err: Errno
    ):
        self.op = op^
        self.old = old^
        self.new = new^
        self.err = err

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as a `LinkError`, or nothing if it did not come from here.

        A `PathError` has an `op` and a `path` and this has an `op`, an `old`
        and a `new`, so the two never answer for each other's errors.
        """
        var value = capture(e)
        var op = value.field("op")
        var old = value.field("old")
        var new = value.field("new")
        if not op or not old or not new:
            return None
        return Self(op.value(), old.value(), new.value(), _errno_of(e))

    def unwrap(self) -> Errno:
        """The failure on its own. Go's `Unwrap`."""
        return self.err

    def error(self) -> String:
        """The message Go's `Error` builds, character for character.

        `rename /a /b: cross-device link`.
        """
        return (
            self.op
            + " "
            + self.old
            + " "
            + self.new
            + ": "
            + self.err.message()
        )

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.error())


struct SyscallError(Copyable, Movable, Writable):
    """A call that failed and had no path to name. Go's `os.SyscallError`.

    `chdir`, `pipe`, `getwd` and the rest: the operation is worth saying and
    there is nothing else to say, so this is the errno with the call's name in
    front of it.
    """

    var syscall: String
    """The call that failed, in the platform's spelling: `chdir`, `pipe`."""

    var err: Errno
    """The number the platform left behind."""

    def __init__(out self, var syscall: String, err: Errno):
        self.syscall = syscall^
        self.err = err

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as a `SyscallError`, or nothing if it did not come from here.

        An error with a `path` on it is a `PathError` and is not this, which is
        the one case worth ruling out: every call in `core.syscall` records an
        `op`, and the ones made on a path record a path beside it.
        """
        var value = capture(e)
        var call = value.field("op")
        if not call or value.field("path"):
            return None
        return Self(call.value(), _errno_of(e))

    def unwrap(self) -> Errno:
        """The failure on its own. Go's `Unwrap`."""
        return self.err

    def timeout(self) -> Bool:
        """Whether the call gave up waiting rather than failing. Go's `Timeout`.
        """
        return _timeout(self.err)

    def error(self) -> String:
        """The message Go's `Error` builds: `chdir: permission denied`."""
        return self.syscall + ": " + self.err.message()

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.error())


def new_syscall_error(
    call: StringSlice[ImmStaticOrigin], err: Errno
) -> Optional[Error]:
    """An error for a failed call, or nothing when the call succeeded.

    Go's `NewSyscallError`, including the part that looks like an oversight and
    is not: it returns nil for a nil error, so a caller writes
    `return NewSyscallError("chdir", err)` with no branch in front of it and
    the success path costs one comparison. An `Optional` is that same shape
    here, and `Errno(0)` is the nil.

    ```mojo
    from core.os import new_syscall_error
    from core.syscall import EACCES, Errno

    print(new_syscall_error("chdir", Errno(0)))  # => None
    print(new_syscall_error("chdir", Errno(EACCES)).value())
    ```
    """
    if not err:
        return None
    return (
        Report(String(call) + ": " + err.message())
        .with_code(_sentinel(err))
        .with_field("op", String(call))
        .with_field("errno", String(err.value))
        .error()
    )


def _link_error[
    a: ImmOrigin, b: ImmOrigin
](
    op: StringSlice[ImmStaticOrigin],
    old: StringSlice[a],
    new: StringSlice[b],
    err: Errno,
) -> Error:
    """The raise every two path operation in this library makes.

    One place, so the message and the four fields cannot drift apart and
    `LinkError.of` has one shape to read. The message is Go's: the operation,
    both paths, a colon and what the platform calls the failure.
    """
    return (
        Report(
            String(op)
            + " "
            + String(old)
            + " "
            + String(new)
            + ": "
            + err.message()
        )
        .with_code(_sentinel(err))
        .with_field("op", String(op))
        .with_field("old", String(old))
        .with_field("new", String(new))
        .with_field("errno", String(err.value))
        .error()
    )
