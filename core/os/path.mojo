"""The few facts about this host's paths that Go keeps in `os`, and the two
operations that walk one.

`core.path.filepath` is where path handling lives and it declares the same
separator under its own name. These are here because Go has them here, and Go
has them here because `os` is older than `path/filepath` and code that only
wanted the character should not have to import a whole package for it.

Both platforms this library targets separate with a slash and list with a
colon, which is why these are constants and not questions asked at run time.

`mkdir_all` and `remove_all` are here for the same reason: Go keeps them in
`os/path.go`, away from the calls they are built out of, because neither one is
a system call. Each is a walk with a rule about what to ignore, and the rule is
the whole of the design.

The path handling in this file is written out by hand rather than delegated to
`core.path.filepath`, which is exactly what Go does and for the same reason:
`os` sits underneath `path/filepath` in the import graph, so the dependency
cannot go that way.
"""

from core.errors import capture
from core.io import Byte
from core.io.fs import FileInfo, FileMode
from core.io.fs.direntry import _is_dot
from core.io.fs.errors import _errno_of, _path_error
from core.syscall import (
    AT_REMOVEDIR,
    EACCES,
    EINVAL,
    EISDIR,
    ENOENT,
    ENOTDIR,
    EPERM,
    O_CLOEXEC,
    O_DIRECTORY,
    O_NOFOLLOW,
    O_RDONLY,
    Dirent,
    Errno,
)
from core.syscall import close as _sys_close
from core.syscall import closedir as _sys_closedir
from core.syscall import dup as _sys_dup
from core.syscall import fdopendir as _sys_fdopendir
from core.syscall import open as _sys_open
from core.syscall import openat as _sys_openat
from core.syscall import readdir as _sys_readdir
from core.syscall import unlinkat as _sys_unlinkat

from .calls import mkdir, remove
from .stat import lstat, stat

comptime PATH_SEPARATOR = Int32(ord("/"))
"""What separates the elements of a path on this host. Go's `PathSeparator`."""

comptime PATH_LIST_SEPARATOR = Int32(ord(":"))
"""What separates the paths in a list such as `PATH`. Go's `PathListSeparator`.
"""

comptime DEV_NULL = "/dev/null"
"""The name of the null device. Go's `DevNull`.

Opening it for writing gives a file that accepts everything and keeps nothing,
which is what a program wants when a caller asked for output it does not want.
`core.io.Discard` is the version that does not involve the kernel.
"""


def is_path_separator(c: Byte) -> Bool:
    """Whether this byte separates path elements. Go's `IsPathSeparator`.

    One byte and one answer here. On Windows Go says yes to both the backslash
    and the slash, which is why the question is a function rather than a
    comparison against the constant, and keeping it a function is what lets
    that host arrive without every caller changing.
    """
    return Int32(Int(c)) == PATH_SEPARATOR


def mkdir_all(path: String, perm: FileMode) raises:
    """Make a directory and every parent it needs. Go's `MkdirAll`.

    ```mojo
    from core.io.fs import FileMode
    from core.os import mkdir_all

    def main():
        mkdir_all("/tmp/one/two/three", FileMode(0o755))
    ```

    A path that is already a directory all the way down is success and no call
    is made, which is the reason the function exists: a program that wants a
    place to write should not have to know whether it is the first one to want
    it. A plain file sitting where a directory was wanted is not success and
    raises `ENOTDIR` naming the whole path.

    Every directory it makes gets `perm`, less the process umask, and a
    directory that was already there keeps whatever it had. Go does the same,
    and the consequence is worth knowing: this is not a way to fix the
    permissions on a tree.

    Not atomic, and nothing here pretends otherwise. Two programs calling this
    on the same path at once both succeed, because a level that is already
    there is checked again and accepted.
    """
    var found = Optional[FileInfo]()
    try:
        found = Optional(stat(path))
    except:
        pass
    if found:
        if found.value().is_dir():
            return
        raise _path_error("mkdir", path, Errno(ENOTDIR))

    # Walk back over any trailing separators and then over the last element,
    # which leaves the parent. Written out here rather than borrowed from
    # `core.path.filepath`, which sits above this package.
    var bytes = path.as_bytes()
    var i = len(bytes) - 1
    while i >= 0 and is_path_separator(bytes[i]):
        i -= 1
    while i >= 0 and not is_path_separator(bytes[i]):
        i -= 1
    if i > 0:
        mkdir_all(String(path[byte=0:i]), perm)

    try:
        mkdir(path, perm)
    except e:
        # The number is taken now, before anything else can fail. A second
        # failure would put its own record where this one's fields are.
        var why = _errno_of(e)
        # `foo/.` names a directory that `mkdir` refuses and that is
        # nonetheless there, which is the case this second look is for.
        var again = Optional[FileInfo]()
        try:
            again = Optional(lstat(path))
        except:
            pass
        if again and again.value().is_dir():
            return
        raise _path_error("mkdir", path, why)


def remove_all(path: String) raises:
    """Remove a path and everything under it. Go's `RemoveAll`.

    ```mojo
    from core.os import remove_all

    def main():
        remove_all("/tmp/a-tree-that-may-not-be-there")
    ```

    A path that is not there is success, which is the other half of what makes
    this the call to reach for when cleaning up: the caller does not have to
    know what state it is in.

    The walk goes by descriptor rather than by name. Each level opens the
    directory it is about to empty and removes the entries relative to that
    descriptor with `unlinkat`, so a name read a moment ago is removed inside
    the directory it was read from and nowhere else. Building a path out of the
    name and calling `remove` on it would resolve the whole path again, and
    something that moved a directory in between could send the removal
    somewhere the caller never named. Go changed to this shape for that reason
    and this follows it.

    Symbolic links are removed rather than followed, since the entry is
    unlinked before anything is opened and the open that does happen refuses to
    follow a link.

    A path ending in `.` is refused with `EINVAL`, because `foo/.` names a
    directory that cannot be removed by that name and a caller who wrote it
    almost certainly meant `foo`.
    """
    if path.byte_length() == 0:
        return
    if _ends_with_dot(path):
        raise _path_error("removeall", path, Errno(EINVAL))

    # The whole call, when the path names one file or one empty directory.
    try:
        remove(path)
        return
    except e:
        if _errno_of(e).value == ENOENT:
            return

    var split = _split_path(path)
    var parent = 0
    try:
        parent = _sys_open(split[0], O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0)
    except e:
        var why = _errno_of(e)
        if why.value == ENOENT or why.value == ENOTDIR:
            return
        raise _path_error("open", split[0], why)

    var failure = Errno(0)
    var failed_at = String()
    try:
        _remove_all_from(parent, split[1])
    except e:
        failure = _errno_of(e)
        failed_at = _path_of(e, split[1])
    _sys_close(parent)
    if failure:
        raise _path_error("unlinkat", String(split[0], "/", failed_at), failure)


def _remove_all_from(parent: Int, base: String) raises:
    """Remove `base` inside the directory `parent` is open on, contents first.

    Named relative to the descriptor at every step, and it recurses rather than
    keeping its own stack, so the depth of the tree is the depth of the call
    stack. That is Go's arrangement too, and a tree deep enough to matter is a
    tree the platform's own path limit has already refused.
    """
    var first = Errno(0)
    try:
        _sys_unlinkat(parent, base, 0)
        return
    except e:
        first = _errno_of(e)
    if first.value == ENOENT:
        return

    # `EISDIR` is the plain answer that this is a directory. `EPERM` and
    # `EACCES` are what a caller who may not write the parent gets, and the
    # entry may still be a directory whose contents can be removed, so all
    # three go on to look. Anything else is the answer.
    if first.value != EISDIR and first.value != EPERM and first.value != EACCES:
        raise _path_error("unlinkat", base, first)

    var fd = 0
    try:
        fd = _sys_openat(
            parent,
            base,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
            0,
        )
    except e:
        var why = _errno_of(e)
        if why.value == ENOENT:
            return
        # Not a directory after all, or a link. The failure worth reporting is
        # the one from the removal rather than the one from the second look.
        raise _path_error("unlinkat", base, first)

    var failure = Errno(0)
    var failed_at = String()
    try:
        for name in _names_in(fd, base):
            _remove_all_from(fd, name)
    except e:
        failure = _errno_of(e)
        failed_at = _path_of(e, base)
    _sys_close(fd)
    if failure:
        raise _path_error("unlinkat", String(base, "/", failed_at), failure)

    try:
        _sys_unlinkat(parent, base, AT_REMOVEDIR)
    except e:
        var why = _errno_of(e)
        if why.value != ENOENT and why.value != ENOTDIR:
            raise _path_error("unlinkat", base, why)


def _names_in(fd: Int, name: String) raises -> List[String]:
    """Every name in the directory `fd` is open on, without `.` and `..`.

    Reads the lot before returning any of it. Removing entries while a
    directory is being read is defined by POSIX only for the entry that was
    just read, and reading first costs one list of names against a rule that
    differs between file systems.

    `fdopendir` takes the descriptor over and `closedir` closes it, so it is
    given a copy and the caller keeps its own.
    """
    var handle = _sys_fdopendir(_sys_dup(fd))
    var out = List[String]()
    var failure = Errno(0)
    while True:
        var found = Optional[Dirent]()
        try:
            found = _sys_readdir(handle)
        except e:
            failure = _errno_of(e)
        if failure or not found:
            break
        var entry = found.take()
        if _is_dot(entry.name):
            continue
        out.append(String(entry.name))
    _sys_closedir(handle)
    if failure:
        raise _path_error("readdirent", name, failure)
    return out^


def _path_of(e: Error, fallback: String) -> String:
    """The path a failure named, or the name we were working on.

    The record is read straight away by the caller, before anything else can
    raise, which is why this takes the error rather than being asked later.
    """
    var held = capture(e).field("path")
    if held:
        return held.value()
    return fallback


def _ends_with_dot(path: String) -> Bool:
    """Whether the path's last element is `.`. Go's `endsWithDot`.

    `.` and anything ending in `/.`, which name a directory that cannot be
    removed by that name.
    """
    if path == ".":
        return True
    var bytes = path.as_bytes()
    if (
        len(bytes) >= 2
        and bytes[len(bytes) - 1] == Byte(ord("."))
        and is_path_separator(bytes[len(bytes) - 2])
    ):
        return True
    return False


def _split_path(path: String) -> Tuple[String, String]:
    """A path as a directory and a last element. Go's `splitPath`.

    `.` for the directory when there is no separator, `/` when the separator is
    the first byte, and trailing separators are dropped first so that `a/b/`
    splits the same way `a/b` does.
    """
    var bytes = path.as_bytes()
    var start = 0
    # All but one leading separator, so `//a` is `/` and `a` rather than `/`
    # and `/a`.
    while (
        len(bytes) - start > 1
        and is_path_separator(bytes[start])
        and is_path_separator(bytes[start + 1])
    ):
        start += 1

    var end = len(bytes)
    while end - start > 1 and is_path_separator(bytes[end - 1]):
        end -= 1

    var i = end - 1
    while i > start:
        i -= 1
        if is_path_separator(bytes[i]):
            var dir = String(path[byte=start:i]) if i > start else String("/")
            return (dir, String(path[byte = i + 1 : end]))
    return (String("."), String(path[byte=start:end]))
