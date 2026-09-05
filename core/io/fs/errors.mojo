"""A failed operation on a path, and the errno it came from.

Go returns a `*PathError` and the caller type asserts. There is nothing to
assert against here, so the operation, the path and the errno go on the record
as `core.errors` keeps them, and `PathError.of(e)` reads them back. That is the
same arrangement `core.strconv.NumError` uses and it works the same way.

`_sentinel` is the part worth reading twice. One condition arrives as several
numbers: a create that was told not to overwrite gets `EEXIST` and a remove
that would have emptied a directory gets `ENOTEMPTY`, and both mean the same
thing to a caller deciding what to do next. That mapping is why Go tells you to
use `os.IsExist` instead of comparing a number, and this is the only place in
the library that knows it.
"""

from core.errors import NO_CODE, Code, Report, capture
from core.errors.codes import (
    ErrExist,
    ErrNotExist,
    ErrPermission,
    ErrUnsupported,
)
from core.syscall import (
    EACCES,
    EAGAIN,
    EEXIST,
    ENOENT,
    ENOSYS,
    ENOTEMPTY,
    ENOTSUP,
    EOPNOTSUPP,
    EPERM,
    ETIMEDOUT,
    EWOULDBLOCK,
    Errno,
)


def _sentinel(err: Errno) -> Code:
    """Which sentinel this errno means, or `NO_CODE` for the rest.

    The four groups and their members are Go's `syscall.Errno.Is`, which is the
    one place Go writes this down. It is small enough to be one function here,
    and being one function is the point: a second copy of the `EEXIST` and
    `ENOTEMPTY` pairing would eventually disagree with the first.

    An errno in none of the groups keeps its number and matches no sentinel,
    which is the honest answer. `EIO` is not "the file is missing" and
    pretending otherwise would send a caller down the create path.
    """
    if err.value == ENOENT:
        return ErrNotExist
    if err.value == EEXIST or err.value == ENOTEMPTY:
        return ErrExist
    if err.value == EACCES or err.value == EPERM:
        return ErrPermission
    if err.value == ENOSYS or err.value == ENOTSUP or err.value == EOPNOTSUPP:
        return ErrUnsupported
    return NO_CODE


def _timeout(err: Errno) -> Bool:
    """Whether this errno means the call gave up waiting. Go's `Errno.Timeout`.

    `EAGAIN` and `EWOULDBLOCK` are the same number on both platforms here and
    are two names for one condition on most systems, so both are tested rather
    than one being assumed to cover the other.
    """
    return (
        err.value == EAGAIN
        or err.value == EWOULDBLOCK
        or err.value == ETIMEDOUT
    )


def _path_error[
    o: ImmOrigin
](
    op: StringSlice[ImmStaticOrigin],
    path: StringSlice[o],
    err: Errno,
    count: Int = -1,
) -> Error:
    """The raise every path operation in this library makes.

    One place, so the message and the three fields cannot drift apart and
    `PathError.of` has one shape to read. The message is Go's, to the
    character: the operation, a space, the path, a colon and what the platform
    calls the failure.

    `op` is a static string because it names the call and is a literal at every
    site. `path` is a slice because it is passed on the way in and only the
    failing call ever copies it.

    `count` is how many bytes moved before the failure, for the callers that
    have one: a write that got half way through has to say so or the caller can
    neither resume nor report honestly. Minus one means there is nothing to
    say, which is every call that is not a read or a write.
    """
    var report = (
        Report(String(op) + " " + String(path) + ": " + err.message())
        .with_code(_sentinel(err))
        .with_field("op", String(op))
        .with_field("path", String(path))
        .with_field("errno", String(err.value))
    )
    if count >= 0:
        return report^.with_count(count).error()
    return report^.error()


def _errno_of(e: Error) -> Errno:
    """The number a `core.syscall` failure left on the record, or zero.

    Every call in `core.syscall` puts the errno on the record as a field, so
    this is how a package above gets the number back out of an error it caught
    without the number ever having been part of a sentence.
    """
    var held = capture(e).field("errno")
    if not held:
        return Errno(0)
    try:
        return Errno(Int(held.value()))
    except:
        return Errno(0)


def _path_error_from[
    o: ImmOrigin
](
    op: StringSlice[ImmStaticOrigin],
    path: StringSlice[o],
    cause: Error,
    count: Int = -1,
) -> Error:
    """A `PathError` for a `core.syscall` failure that has just been caught.

    The shape every path operation above this package is written in: make the
    call, catch what the platform said, and raise it again with the operation
    and the path in front of it. The errno is carried across rather than
    reread, because by the time this runs the platform's own `errno` may have
    been overwritten by anything the catch site did.

    `count` is passed on to `_path_error`, for a read or a write that moved
    something before it failed.
    """
    return _path_error(op, path, _errno_of(cause), count)


struct PathError(Copyable, Movable, Writable):
    """An operation, the path it was made on, and why it failed.

    Built from a raised error by `of` rather than by hand, and every field is a
    copy, so it outlives the `Error` it came from.

    ```mojo
    from core.errors import matches
    from core.io.fs import ErrNotExist, PathError
    from core.io.fs.errors import _path_error
    from core.syscall import ENOENT, Errno

    def main():
        try:
            raise _path_error("stat", "/no/such/file", Errno(ENOENT))
        except e:
            print(matches(e, ErrNotExist))  # True
            var failed = PathError.of(e)
            if failed:
                print(failed.value().op)  # stat
                print(failed.value().path)  # /no/such/file
    ```

    The raise is spelled out here because `core.os` is the package that makes
    it, and this one sits underneath. In real code it is `os.stat` that fails.

    The common questions do not need this type. `os.is_not_exist(e)` asks why
    and `errors.field(e, "path")` asks which file. `PathError` is for the
    caller who wants all of it at once, usually to build their own message.
    """

    var op: String
    """The call that failed, in this library's spelling: `open`, `stat`."""

    var path: String
    """The path it was made on, exactly as the caller wrote it."""

    var err: Errno
    """The number the platform left behind.

    Go's `Err` is an `error` and can be a sentinel as well as an errno. Here
    every failure that reaches this type comes from a system call, so it is
    always a number, and the sentinel is the separate question `is_not_exist`
    and its two siblings answer.
    """

    def __init__(out self, var op: String, var path: String, err: Errno):
        self.op = op^
        self.path = path^
        self.err = err

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as a `PathError`, or nothing if it did not come from here.

        Go's `err.(*fs.PathError)`. Nothing comes back for an error raised
        somewhere else, which is the case a type assertion covers by failing
        and this covers by being empty.
        """
        var value = capture(e)
        var op = value.field("op")
        var path = value.field("path")
        var errno = value.field("errno")
        if not op or not path or not errno:
            return None
        var number = 0
        try:
            number = Int(errno.value())
        except:
            return None
        return Self(op.value(), path.value(), Errno(number))

    def unwrap(self) -> Errno:
        """The failure on its own. Go's `Unwrap`, which hands back the `Err`.

        Go needs it so that `errors.Is(err, fs.ErrNotExist)` sees through the
        wrapper. Nothing here is wrapped, so `is_not_exist(e)` already worked
        on the error itself and this is for the caller who wants the number.
        """
        return self.err

    def timeout(self) -> Bool:
        """Whether the call gave up waiting rather than failing. Go's `Timeout`.

        Go has this so a `*PathError` satisfies `net.Error`. It is the same
        question here and it is asked of the errno, which is what Go's is asked
        of once the assertion inside it has succeeded.
        """
        return _timeout(self.err)

    def error(self) -> String:
        """The message Go's `Error` builds, character for character.

        `open /no/such/file: no such file or directory`.
        """
        return self.op + " " + self.path + ": " + self.err.message()

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.error())
