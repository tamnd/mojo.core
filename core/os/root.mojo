"""A directory that names cannot climb out of. Go's `os.Root`.

`core.os.dir_fs` puts a prefix in front of a name and refuses `..`, and that is
a name rule: a symbolic link inside the tree that points outside it is followed,
because the open that follows it is an ordinary open. This is the other thing.
A `Root` holds the directory open and resolves every name one element at a time
with `openat`, refusing to follow a link at any step, so no name and no link
anywhere under it can reach a file outside it.

The difference matters when the tree is not the program's own. An archive
being unpacked, a directory a user uploaded into, a repository checked out from
somewhere else: in all three the contents were chosen by somebody else and a
link pointing at `/etc/passwd` costs nothing to make.

## How a name is resolved

The name is split on slashes and walked element by element from the root, and
each element is opened relative to the directory the walk is standing in. The
opens use `O_NOFOLLOW`, so a link is never followed by the kernel. A link the
walk lands on is read with `readlinkat` and its text is spliced into the
remaining elements, which resolves it inside the walk rather than inside the
kernel, and that is where the rules get applied: a link holding an absolute
path is refused, and one holding enough `..` to leave the root is refused.

`..` moves back up the walk's own stack of open directories rather than being
handed to the kernel, which is what makes it checkable. Standing at the root
with a `..` still to go is the escape, and it is refused.

Forty links is the limit, which is Linux's, and reaching it raises `ELOOP` the
way the kernel would.

## What is refused, and how

An absolute name, a name that escapes with `..` and a link that does either one
all raise a `PathError` carrying `ErrInvalid` and the sentence `path escapes
from parent`, which is Go's wording. Nothing was asked of the platform in that
case, so the record has no `errno` field.

## What this does not promise

The last element of a name is resolved and then operated on in two steps, and
something else can change what it names in between. Every operation here uses
the form that does not follow a link, so what a race can produce is a report
about a link rather than about its target, or a failure. It cannot produce an
operation on a file outside the root, which is the promise.

An empty path element is dropped, so `a//b` and `a/b` are the same name and a
trailing slash means nothing. Go refuses some of those and this does not; the
difference is a name that would have failed now working, never the reverse.
"""

from core.errors.codes import ErrInvalid
from core.io import Byte
from core.io.fs import (
    READ_DIR_FS,
    READ_FILE_FS,
    READ_LINK_FS,
    STAT_FS,
    DirEntry,
    FileInfo,
    FileMode,
    FS,
    valid_path,
)
from core.io.fs.errors import _errno_of, _path_error, _refused
from core.syscall import (
    AT_REMOVEDIR,
    AT_SYMLINK_NOFOLLOW,
    EINVAL,
    ELOOP,
    EMLINK,
    ENOTDIR,
    O_APPEND,
    O_CLOEXEC,
    O_CREAT,
    O_DIRECTORY,
    O_NOFOLLOW,
    O_RDONLY,
    O_RDWR,
    O_TRUNC,
    O_WRONLY,
    Errno,
    Stat,
)
from core.syscall import close as _sys_close
from core.syscall import dup as _sys_dup
from core.syscall import fchmodat as _sys_fchmodat
from core.syscall import fchownat as _sys_fchownat
from core.syscall import fstatat as _sys_fstatat
from core.syscall import linkat as _sys_linkat
from core.syscall import mkdirat as _sys_mkdirat
from core.syscall import open as _sys_open
from core.syscall import openat as _sys_openat
from core.syscall import readlinkat as _sys_readlinkat
from core.syscall import renameat as _sys_renameat
from core.syscall import symlinkat as _sys_symlinkat
from core.syscall import unlinkat as _sys_unlinkat
from core.syscall import utimensat as _sys_utimensat
from core.time import Time

from .calls import _timespec_of
from .dir import _sort_by_name
from .file import File as OsFile
from .file import _closed, _has_nul, _syscall_mode
from .path import _remove_all_from
from .readfile import _read_all_of

comptime _MAX_SYMLINKS = 40
"""How many links one name may go through. Linux's number, and Go's."""

comptime _ESCAPES = "path escapes from parent"
"""The sentence every refusal in this file is reported with. Go's wording."""

comptime _NO_ROOT = -1
"""What `_fd` holds once a `Root` has been closed."""


def _split(name: String) -> List[String]:
    """A slash separated name as its elements, without the empty ones and `.`.

    Written out here rather than borrowed from `core.path.filepath`, which sits
    above this package, and it is a different rule anyway: nothing is cleaned
    and `..` is kept, because `..` is a step the walk has to take and check
    rather than a thing to cancel out beforehand. Cancelling `a/../b` down to
    `b` on the way in would answer about a directory the walk never entered,
    which is wrong whenever `a` is a link.
    """
    var out = List[String]()
    var start = 0
    var bytes = name.as_bytes()
    for i in range(len(bytes) + 1):
        if i < len(bytes) and bytes[i] != Byte(ord("/")):
            continue
        if i > start:
            var part = String(name[byte=start:i])
            if part != ".":
                out.append(part^)
        start = i + 1
    return out^


def _splice(
    var parts: List[String], at: Int, var into: List[String]
) -> List[String]:
    """`parts` with the element at `at` replaced by all of `into`.

    What resolving a symbolic link does to the rest of a name: the link's own
    element is gone and the text it held stands in its place, so the walk keeps
    going through the target's elements with the same rules applied to each.
    """
    var out = List[String]()
    for i in range(at):
        out.append(parts[i])
    for i in range(len(into)):
        out.append(into[i])
    for i in range(at + 1, len(parts)):
        out.append(parts[i])
    return out^


struct _Resolved(Movable):
    """Where a walk finished: a directory it holds open and a last element.

    The directories are opened on the way down and closed when this is
    destroyed, so a walk that raises part way through leaks nothing. The root's
    own descriptor is held separately and is never closed here, because the
    `Root` owns it and outlives this.
    """

    var _root: Int
    """The root's descriptor, borrowed for as long as this lives."""

    var _open: List[Int]
    """The directories the walk opened, deepest last. Owned."""

    var final: String
    """The last element, to be named relative to `parent`.

    `.` when the name resolved to the root itself, or to a directory the walk
    stepped back into with `..`, which is the one case where there is no last
    element to name.
    """

    def __init__(out self, root: Int):
        """Standing at the root with nothing resolved yet."""
        self._root = root
        self._open = List[Int]()
        self.final = String(".")

    def __deinit__(deinit self):
        """Give back every directory the walk opened.

        The failures are dropped, because a destructor has nobody to raise to
        and a descriptor is gone whatever `close` returned.
        """
        for fd in self._open:
            try:
                _sys_close(fd)
            except:
                pass

    def parent(self) -> Int:
        """The directory `final` is named relative to."""
        if len(self._open) == 0:
            return self._root
        return self._open[len(self._open) - 1]

    def _at_root(self) -> Bool:
        """Whether the walk is standing on the root itself."""
        return len(self._open) == 0

    def _push(mut self, fd: Int):
        """Step into a directory the walk has just opened."""
        self._open.append(fd)

    def _pop(mut self) -> Bool:
        """Step back out of one. False at the root, which is the escape."""
        if len(self._open) == 0:
            return False
        var fd = self._open.pop()
        try:
            _sys_close(fd)
        except:
            pass
        return True


def _resolve(
    root: Int,
    op: StringSlice[ImmStaticOrigin],
    name: String,
    follow_last: Bool,
) raises -> _Resolved:
    """Walk `name` from `root` and stop at its last element.

    `follow_last` says what to do when that last element is a symbolic link.
    An operation that acts through a link, `stat` and `open` among them, passes
    true and gets the link resolved like any other element. One that acts on
    the link itself, `lstat` and `remove` and `symlink` among them, passes
    false and gets the link's own name back.

    Every intermediate element is followed either way. A link in the middle of
    a path is part of the path and there is no operation that means otherwise.
    """
    if _has_nul(name):
        raise _refused(op, name, "invalid argument", ErrInvalid)
    if name.byte_length() == 0:
        raise _refused(op, name, "invalid argument", ErrInvalid)
    if name.as_bytes()[0] == Byte(ord("/")):
        raise _refused(op, name, _ESCAPES, ErrInvalid)

    var out = _Resolved(root)
    var parts = _split(name)
    var followed = 0
    var i = 0
    while i < len(parts):
        var part = parts[i]
        var last = i == len(parts) - 1
        if part == "..":
            if not out._pop():
                raise _refused(op, name, _ESCAPES, ErrInvalid)
            i += 1
            continue
        if last and not follow_last:
            out.final = part^
            return out^

        var fd = 0
        var why = Errno(0)
        try:
            fd = _sys_openat(
                out.parent(),
                part,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                0,
            )
        except e:
            why = _errno_of(e)

        if why:
            # `ELOOP` is what both platforms say when `O_NOFOLLOW` meets a
            # link. `ENOTDIR` is what `O_DIRECTORY` says about a plain file and
            # is also what some systems say about a link, and `EMLINK` is what
            # one more of them says, so all three go on to ask `readlinkat`
            # which of the two it was. That answer is the reliable one.
            if (
                why.value == ELOOP
                or why.value == ENOTDIR
                or why.value == EMLINK
            ):
                var target = String()
                var is_link = True
                try:
                    target = _sys_readlinkat(out.parent(), part)
                except:
                    is_link = False
                if is_link:
                    followed += 1
                    if followed > _MAX_SYMLINKS:
                        raise _path_error(op, name, Errno(ELOOP))
                    if target.byte_length() > 0 and target.as_bytes()[
                        0
                    ] == Byte(ord("/")):
                        raise _refused(op, name, _ESCAPES, ErrInvalid)
                    parts = _splice(parts^, i, _split(target))
                    continue
            if last:
                # Not a directory and not a link, so it is whatever the caller
                # is about to operate on. The failure belongs to the operation
                # rather than to the walk, and reporting it here would name the
                # wrong call.
                out.final = part^
                return out^
            raise _path_error(op, name, why)

        if last:
            # A directory, and the caller wants its name rather than a
            # descriptor on it, so this one is given straight back.
            try:
                _sys_close(fd)
            except:
                pass
            out.final = part^
            return out^
        out._push(fd)
        i += 1

    # Every element was `..`, or there were none at all. The root itself, or
    # whichever directory the walk stepped back into, is the target.
    return out^


def _join(root: String, name: String) -> String:
    """The name a file opened through a root carries.

    Only ever for a message and for `File.name`, so it is a concatenation and
    nothing is cleaned: the point is to say which root a name was reached
    through, and cleaning would hide a `..` the caller wrote.
    """
    if root.byte_length() == 0:
        return name
    if root.as_bytes()[root.byte_length() - 1] == Byte(ord("/")):
        return root + name
    return root + "/" + name


struct Root(Movable):
    """A directory, and every name resolved inside it. Go's `os.Root`.

    ```mojo
    from core.os import open_root

    def main() raises:
        var root = open_root("/tmp")
        var f = root.open("note")
        f.close()
        root.close()
    ```

    Not `Copyable`, for the reason `File` is not: two copies would hold one
    descriptor and the first of them destroyed would close the directory
    underneath the other.

    Every method takes a name relative to this directory and none of them can
    reach outside it. The module docstring says how, and says what a race can
    and cannot do to that promise.
    """

    var _fd: Int
    """The directory, or `_NO_ROOT` once it has been given back."""

    var _name: String
    """The name it was opened with, unchanged. Go keeps this too."""

    def __init__(out self, fd: Int, var name: String):
        """Take a directory descriptor. Private; `open_root` is the door."""
        self._fd = fd
        self._name = name^

    def __deinit__(deinit self):
        """Close the directory if this value still holds one.

        The failure is dropped, the way `File`'s is and for the same reason.
        `close` is the method that reports it.
        """
        if self._fd != _NO_ROOT:
            try:
                _sys_close(self._fd)
            except:
                pass

    def name(self) -> String:
        """The name this root was opened with. Go's `Name`.

        Whatever string was passed in, not resolved and not cleaned. A relative
        one stays relative even though the directory itself is held open and no
        longer depends on the working directory.
        """
        return self._name

    def close(mut self) raises:
        """Give the directory back. Go's `Close`.

        Every method afterwards raises `ErrClosed`. Files already opened
        through this root keep working, since each of them holds a descriptor
        of its own and nothing about it points back here.

        Closing twice is not an error, which is Go's behaviour for `Root` and
        the useful one for a value that also closes itself when destroyed.
        """
        if self._fd == _NO_ROOT:
            return
        var fd = self._fd
        self._fd = _NO_ROOT
        try:
            _sys_close(fd)
        except e:
            raise _path_error("close", self._name, _errno_of(e))

    def _live(self, op: StringSlice[ImmStaticOrigin]) raises -> Int:
        """The descriptor, or the raise every method makes once it is gone."""
        if self._fd == _NO_ROOT:
            raise _closed(op, self._name)
        return self._fd

    def open(self, name: String) raises -> OsFile:
        """The file at `name`, opened for reading. Go's `Open`."""
        return self.open_file(name, O_RDONLY, FileMode(0))

    def create(self, name: String) raises -> OsFile:
        """Create `name`, or empty it, for reading and writing. Go's `Create`.
        """
        return self.open_file(name, O_RDWR | O_CREAT | O_TRUNC, FileMode(0o666))

    def open_file(
        self, name: String, flag: Int, perm: FileMode
    ) raises -> OsFile:
        """Open `name` with the flags and mode spelled out. Go's `OpenFile`.

        The same `flag` and `perm` as `core.os.open_file`, with `O_NOFOLLOW`
        added to whatever was passed. That addition is not visible to a caller
        who did not ask for it, because the walk has already resolved the last
        element through any links it found: what it stops is a link that
        arrives between the walk and the open.

        The file's name is this root's name with the given name after it, so a
        failure reported later says which root it was reached through.
        """
        var fd = self._live("openat")
        var found = _resolve(fd, "openat", name, True)
        var opened = 0
        try:
            opened = _sys_openat(
                found.parent(),
                found.final,
                flag | O_NOFOLLOW,
                _syscall_mode(perm),
            )
        except e:
            raise _path_error("openat", name, _errno_of(e))
        return OsFile(
            opened, _join(self._name, name), (flag & O_APPEND) != 0, True
        )

    def open_root(self, name: String) raises -> Root:
        """The directory at `name`, as a root of its own. Go's `OpenRoot`.

        The new root is not tied to this one and keeps working after this one
        is closed. It is a narrower promise than this root already made, so
        nesting them buys nothing on its own; what it buys is a value to hand
        to code that should only see the subtree.
        """
        var fd = self._live("openat")
        var found = _resolve(fd, "openat", name, True)
        var opened = 0
        try:
            opened = _sys_openat(
                found.parent(),
                found.final,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                0,
            )
        except e:
            raise _path_error("openat", name, _errno_of(e))
        return Root(opened, name)

    def stat(self, name: String) raises -> FileInfo:
        """What the host says about `name`, through links. Go's `Stat`."""
        var fd = self._live("statat")
        var found = _resolve(fd, "statat", name, True)
        var got = Stat()
        try:
            got = _sys_fstatat(found.parent(), found.final, 0)
        except e:
            raise _path_error("statat", name, _errno_of(e))
        return FileInfo(path=name, stat=got)

    def lstat(self, name: String) raises -> FileInfo:
        """The same, describing a link rather than its target. Go's `Lstat`."""
        var fd = self._live("lstatat")
        var found = _resolve(fd, "lstatat", name, False)
        var got = Stat()
        try:
            got = _sys_fstatat(found.parent(), found.final, AT_SYMLINK_NOFOLLOW)
        except e:
            raise _path_error("lstatat", name, _errno_of(e))
        return FileInfo(path=name, stat=got)

    def mkdir(self, name: String, perm: FileMode) raises:
        """Make one directory. Go's `Mkdir`.

        One level, the same as `core.os.mkdir`: the parent has to be there and
        a name that is there already fails.
        """
        var fd = self._live("mkdirat")
        var found = _resolve(fd, "mkdirat", name, False)
        try:
            _sys_mkdirat(found.parent(), found.final, _syscall_mode(perm))
        except e:
            raise _path_error("mkdirat", name, _errno_of(e))

    def mkdir_all(self, name: String, perm: FileMode) raises:
        """Make a directory and every parent it needs. Go's `MkdirAll`.

        Each level is made through this root, so a link part way along the path
        is resolved under the same rules the rest of the package is, and a
        level that is already a directory is success.

        Not one walk with the levels made as it goes. Each level is a fresh
        resolution from the root, which costs a walk per level and is the
        arrangement that keeps every level checked: a directory made a moment
        ago can be replaced by a link before the next one is made.
        """
        var parts = _split(name)
        var built = String()
        for i in range(len(parts)):
            if built.byte_length() > 0:
                built += "/"
            built += parts[i]
            try:
                self.mkdir(built, perm)
            except e:
                var why = _errno_of(e)
                var found = Optional[FileInfo]()
                try:
                    found = Optional(self.stat(built))
                except:
                    pass
                if found and found.value().is_dir():
                    continue
                if why:
                    raise _path_error("mkdirat", name, why)
                raise e

    def remove(self, name: String) raises:
        """Remove a file or an empty directory. Go's `Remove`.

        Two calls where the platform has two, exactly as `core.os.remove` does,
        and the same rule about which failure is worth reporting: `rmdir` on a
        plain file says `ENOTDIR`, which describes the call rather than the
        file, so in that one case the first failure is the honest one.

        A link is removed rather than followed.
        """
        var fd = self._live("removeat")
        var found = _resolve(fd, "removeat", name, False)
        var first = Errno(0)
        try:
            _sys_unlinkat(found.parent(), found.final, 0)
            return
        except e:
            first = _errno_of(e)

        var second = Errno(0)
        try:
            _sys_unlinkat(found.parent(), found.final, AT_REMOVEDIR)
            return
        except e:
            second = _errno_of(e)

        var reported = first
        if second.value != ENOTDIR:
            reported = second
        raise _path_error("removeat", name, reported)

    def remove_all(self, name: String) raises:
        """Remove `name` and everything under it. Go's `RemoveAll`.

        A name that is not there is success, the same as `core.os.remove_all`,
        and the walk below the resolved name goes by descriptor for the reason
        that one gives: a name read a moment ago is removed inside the
        directory it was read from and nowhere else.

        A name that resolves to the root itself is refused with `EINVAL`. It is
        the only name here that would empty the directory a caller is holding
        rather than remove something inside it, and a caller who meant that
        wrote the wrong call.
        """
        var fd = self._live("removeat")
        var found = _resolve(fd, "removeat", name, False)
        if found.final == ".":
            raise _path_error("removeat", name, Errno(EINVAL))
        try:
            _remove_all_from(found.parent(), found.final)
        except e:
            raise _path_error("removeat", name, _errno_of(e))

    def chmod(self, name: String, mode: FileMode) raises:
        """Set the permission bits on `name`. Go's `Chmod`.

        Follows a link, which is `core.os.chmod`'s behaviour and the platform's
        on both hosts here.
        """
        var fd = self._live("chmodat")
        var found = _resolve(fd, "chmodat", name, True)
        try:
            _sys_fchmodat(found.parent(), found.final, _syscall_mode(mode), 0)
        except e:
            raise _path_error("chmodat", name, _errno_of(e))

    def chown(self, name: String, uid: Int, gid: Int) raises:
        """Set the owner and the group of `name`. Go's `Chown`.

        `-1` for either one leaves it alone. Follows a link.
        """
        var fd = self._live("chownat")
        var found = _resolve(fd, "chownat", name, True)
        try:
            _sys_fchownat(found.parent(), found.final, uid, gid, 0)
        except e:
            raise _path_error("chownat", name, _errno_of(e))

    def lchown(self, name: String, uid: Int, gid: Int) raises:
        """The same, on the link rather than through it. Go's `Lchown`."""
        var fd = self._live("lchownat")
        var found = _resolve(fd, "lchownat", name, False)
        try:
            _sys_fchownat(
                found.parent(), found.final, uid, gid, AT_SYMLINK_NOFOLLOW
            )
        except e:
            raise _path_error("lchownat", name, _errno_of(e))

    def chtimes(self, name: String, atime: Time, mtime: Time) raises:
        """Set the access and the modification time on `name`. Go's `Chtimes`.

        A zero `Time` for either one leaves that timestamp alone, exactly as in
        `core.os.chtimes`. Follows a link.
        """
        var fd = self._live("chtimesat")
        var found = _resolve(fd, "chtimesat", name, True)
        try:
            _sys_utimensat(
                found.parent(),
                found.final,
                _timespec_of(atime),
                _timespec_of(mtime),
                0,
            )
        except e:
            raise _path_error("chtimesat", name, _errno_of(e))

    def link(self, old: String, new: String) raises:
        """Make `new` a second name for the file `old` names. Go's `Link`.

        Both names are resolved inside this root, so neither end can be outside
        it, which is what makes a hard link safe to offer here at all: a link
        to a file outside the root would put that file inside it for good.

        `old` is not followed. A hard link to a symbolic link is a second copy
        of the link, which is what unpacking an archive means to preserve.
        """
        var fd = self._live("linkat")
        var from_end = _resolve(fd, "linkat", old, False)
        var to_end = _resolve(fd, "linkat", new, False)
        try:
            _sys_linkat(
                from_end.parent(),
                from_end.final,
                to_end.parent(),
                to_end.final,
                0,
            )
        except e:
            raise _path_error("linkat", new, _errno_of(e))

    def symlink(self, old: String, new: String) raises:
        """Make `new` a symbolic link holding the text `old`. Go's `Symlink`.

        `old` is text and is not resolved, not checked and not refused, even
        when it is absolute or climbs out with `..`. That is not a hole: a link
        made here is read back through this root like any other, and the rules
        are applied then. Refusing to write the text would also be wrong, since
        a tree being unpacked can hold a link that means something on the
        machine it came from.

        Only `new` is resolved, and it cannot be outside the root.
        """
        var fd = self._live("symlinkat")
        var found = _resolve(fd, "symlinkat", new, False)
        try:
            _sys_symlinkat(old, found.parent(), found.final)
        except e:
            raise _path_error("symlinkat", new, _errno_of(e))

    def readlink(self, name: String) raises -> String:
        """The text the link at `name` holds. Go's `Readlink`.

        What was written into the link and nothing more, so it can be absolute
        and can point outside the root. That is what the link says, and saying
        it is not the same as following it.
        """
        var fd = self._live("readlinkat")
        var found = _resolve(fd, "readlinkat", name, False)
        try:
            return _sys_readlinkat(found.parent(), found.final)
        except e:
            raise _path_error("readlinkat", name, _errno_of(e))

    def rename(self, old: String, new: String) raises:
        """Move `old` to `new`, both inside this root. Go's `Rename`.

        Replaces `new` when it is there, which is the platform's behaviour.
        Neither name is followed as a link: renaming a link moves the link.
        """
        var fd = self._live("renameat")
        var from_end = _resolve(fd, "renameat", old, False)
        var to_end = _resolve(fd, "renameat", new, False)
        try:
            _sys_renameat(
                from_end.parent(),
                from_end.final,
                to_end.parent(),
                to_end.final,
            )
        except e:
            raise _path_error("renameat", new, _errno_of(e))

    def read_file(self, name: String) raises -> List[Byte]:
        """The whole contents of `name`. Go's `ReadFile`."""
        return _read_all_of(self.open(name))

    def write_file[
        o: ImmOrigin
    ](self, name: String, data: Span[Byte, o], perm: FileMode) raises:
        """Create or truncate `name` and write `data` to it. Go's `WriteFile`.

        `perm` applies to a file this creates and to no other, less the process
        umask, which is `core.os.write_file`'s rule as well.
        """
        var f = self.open_file(name, O_WRONLY | O_CREAT | O_TRUNC, perm)
        # A failed write leaves through here and the file closes itself on the
        # way, which is why there is no `close` in an `except` block: closing
        # there could put its own record where the write failure's fields are.
        _ = f.write(data)
        f.close()

    def fs(self) raises -> RootFS:
        """This root as a `core.io.fs.FS`. Go's `FS`.

        The value gets a descriptor of its own, taken with `dup`, so it keeps
        working after this root is closed. Go's shares the root and stops
        working with it; sharing is not available here, because two values
        holding one descriptor is exactly what these types refuse to do.
        """
        var fd = self._live("dup")
        var made = 0
        try:
            made = _sys_dup(fd)
        except e:
            raise _path_error("dup", self._name, _errno_of(e))
        return RootFS(Root(made, self._name))


struct RootFS(FS):
    """A `Root` as a file system value. Go's unexported `rootFS`.

    Every name is checked by `valid_path` before it is used, the way `DirFS`
    checks one, and then handed to the root, which applies its own rules on top
    of that. The check is not what makes this safe; the root is. It is here so
    that a name refused by every other `FS` in the library is refused by this
    one too.
    """

    comptime File = OsFile

    var _root: Root
    """The directory. Owned, and closed when this is destroyed."""

    def __init__(out self, var root: Root):
        """Wrap a root. `Root.fs` is the door."""
        self._root = root^

    def capabilities(self) -> Int:
        """The four this root answers with one call each.

        `glob` is not among them, for the reason `DirFS` gives: there is no
        call that matches a pattern, so the generic version reading directories
        is already the best answer.
        """
        return READ_DIR_FS | STAT_FS | READ_FILE_FS | READ_LINK_FS

    def _check(
        self, op: StringSlice[ImmStaticOrigin], name: String
    ) raises -> String:
        """Refuse a name no `FS` accepts, before the root ever sees it."""
        if not valid_path(name):
            raise _refused(op, name, "invalid argument", ErrInvalid)
        return name

    def open(self, name: String) raises -> Self.File:
        """The file at `name`, opened for reading. Go's `Open`."""
        return self._root.open(self._check("open", name))

    def read_dir(self, name: String) raises -> List[DirEntry]:
        """The contents of the directory at `name`, sorted. Go's `ReadDir`."""
        var dir = self._root.open(self._check("read_dir", name))
        var entries = dir.read_dir(0)
        dir.close()
        _sort_by_name(entries)
        return entries^

    def stat(self, name: String) raises -> FileInfo:
        """What the host says about `name`, following links. Go's `Stat`."""
        return self._root.stat(self._check("stat", name))

    def read_file(self, name: String) raises -> List[Byte]:
        """The whole contents of `name`. Go's `ReadFile`."""
        return self._root.read_file(self._check("read_file", name))

    def read_link(self, name: String) raises -> String:
        """The target of the symbolic link at `name`. Go's `ReadLink`."""
        return self._root.readlink(self._check("read_link", name))

    def lstat(self, name: String) raises -> FileInfo:
        """What the host says about `name` itself, link and all. Go's `Lstat`.
        """
        return self._root.lstat(self._check("lstat", name))


def open_root(var name: String) raises -> Root:
    """Open `name` as a directory names cannot climb out of. Go's `OpenRoot`.

    ```mojo
    from core.os import open_root

    def main() raises:
        var root = open_root("/tmp")
        print(root.name())  # => /tmp
        root.close()
    ```

    The directory is opened once and held. Everything afterwards is resolved
    against that descriptor rather than against the name, so the root keeps
    meaning the same directory even if the name is moved or replaced, and a
    relative name keeps working across a `chdir`.

    Raises when `name` is not a directory, with `ENOTDIR`.
    """
    if _has_nul(name):
        raise _refused("open", name, "invalid argument", ErrInvalid)
    var fd = 0
    try:
        fd = _sys_open(name, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0)
    except e:
        raise _path_error("open", name, _errno_of(e))
    return Root(fd, name^)


def open_in_root(dir: String, name: String) raises -> OsFile:
    """Open `name` inside `dir`, without leaving it. Go's `OpenInRoot`.

    ```mojo
    from core.os import open_in_root

    def main() raises:
        var f = open_in_root("/tmp", "note")
        f.close()
    ```

    `open_root(dir).open(name)` and nothing else, for the case where one file
    is wanted and there is no reason to keep the directory open afterwards. A
    caller opening several files should hold the `Root`, since this pays for a
    directory open every time.
    """
    var root = open_root(dir)
    var f = root.open(name)
    root.close()
    return f^
