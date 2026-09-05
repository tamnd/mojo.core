"""The calls that take a path and do something to it. Go's `os`.

One call apiece, and what each of them adds over `core.syscall` is the same
three things: a name with a zero byte in it is refused before the kernel sees
part of it, an interrupted call is made again, and a failure comes back as a
`PathError` or a `LinkError` carrying the operation, the path or paths and the
number the platform left behind.

`mkdir_all` and `remove_all` are the two with real work in them and they are in
`path.mojo`, which is where Go keeps them and for the same reason: they are
written in terms of the calls here rather than being calls themselves.
"""

from core.errors.codes import ErrInvalid
from core.io.fs import FileMode
from core.io.fs.errors import _errno_of, _path_error, _path_error_from
from core.syscall import ENOTDIR, Errno
from core.syscall import chdir as _sys_chdir
from core.syscall import chmod as _sys_chmod
from core.syscall import chown as _sys_chown
from core.syscall import getcwd as _sys_getcwd
from core.syscall import lchown as _sys_lchown
from core.syscall import link as _sys_link
from core.syscall import mkdir as _sys_mkdir
from core.syscall import readlink as _sys_readlink
from core.syscall import rename as _sys_rename
from core.syscall import rmdir as _sys_rmdir
from core.syscall import symlink as _sys_symlink
from core.syscall import truncate as _sys_truncate
from core.syscall import unlink as _sys_unlink

from .errors import _link_error, new_syscall_error
from .file import _has_nul, _interrupted, _refused, _syscall_mode


def _check[
    o: ImmOrigin
](op: StringSlice[ImmStaticOrigin], path: StringSlice[o]) raises:
    """Refuse a name with a zero byte in it before anything is called.

    A C string ends at the first zero, so the layer below would hand the kernel
    the part in front of it and act on a file the caller did not name. Go
    refuses the same names with the same `ErrInvalid`, and the refusal never
    reaches the platform, so it carries no errno.
    """
    if _has_nul(path):
        raise _refused(op, path, "invalid argument", ErrInvalid)


def mkdir(name: String, perm: FileMode) raises:
    """Make one directory. Go's `Mkdir`.

    ```mojo
    from core.io.fs import FileMode
    from core.os import mkdir

    def main():
        mkdir("/tmp/one-level", FileMode(0o755))
    ```

    One level. The parent has to be there already, and a name that is there
    already fails with `ErrExist` whatever kind of thing it is. `mkdir_all` is
    the one that makes a whole path and treats an existing directory as
    success.

    `perm` is what the directory gets after the process umask has been taken
    off it, so a test that wants an exact mode sets it with `chmod` afterwards.
    """
    _check("mkdir", name)
    while True:
        try:
            _sys_mkdir(name, _syscall_mode(perm))
            return
        except e:
            if _interrupted(e):
                continue
            raise _path_error_from("mkdir", name, e)


def remove(name: String) raises:
    """Remove a file or an empty directory. Go's `Remove`.

    The platform has two calls here and the caller has one name, so this tries
    `unlink` and then `rmdir` rather than asking `stat` which of the two to
    make. That is Go's arrangement and it is cheaper on average, since two
    calls only happen when the first one failed, and it is also the only
    version with no window in it: a `stat` followed by the matching call can be
    given a directory and hand a file to `rmdir` because the name changed
    meaning in between.

    Which failure gets reported is Go's rule as well. `rmdir` on a plain file
    says `ENOTDIR`, which describes the call rather than the file, so in that
    one case the `unlink` failure is the honest one and it is the one raised.
    """
    _check("remove", name)
    var first = Errno(0)
    try:
        _sys_unlink(name)
        return
    except e:
        first = _errno_of(e)

    var second = Errno(0)
    try:
        _sys_rmdir(name)
        return
    except e:
        second = _errno_of(e)

    var reported = first
    if second.value != ENOTDIR:
        reported = second
    raise _path_error("remove", name, reported)


def rename(old: String, new: String) raises:
    """Move a name to another name. Go's `Rename`.

    Replaces `new` when it is there, which is the platform's behaviour and not
    something this checks first, because a check followed by a rename is two
    operations and something else can act between them. Both paths have to be
    on the same file system: crossing one fails with `EXDEV`, and neither path
    on its own explains that, which is why this raises a `LinkError`.
    """
    _check("rename", old)
    _check("rename", new)
    try:
        _sys_rename(old, new)
    except e:
        raise _link_error("rename", old, new, _errno_of(e))


def link(old: String, new: String) raises:
    """Make `new` a second name for the file `old` names. Go's `Link`.

    A hard link, so the two names are the same file and removing either one
    leaves the other working. Directories cannot be linked this way and neither
    can a file on another file system.
    """
    _check("link", old)
    _check("link", new)
    try:
        _sys_link(old, new)
    except e:
        raise _link_error("link", old, new, _errno_of(e))


def symlink(old: String, new: String) raises:
    """Make `new` a symbolic link holding the text `old`. Go's `Symlink`.

    `old` is not looked at. A link to a name that is not there is made without
    complaint and starts working the moment something arrives at that name,
    which is the whole difference between a symbolic link and a hard one, and
    it is why the arguments are in this order: the text first, the name second,
    exactly as the platform takes them.
    """
    _check("symlink", old)
    _check("symlink", new)
    try:
        _sys_symlink(old, new)
    except e:
        raise _link_error("symlink", old, new, _errno_of(e))


def readlink(name: String) raises -> String:
    """The text a symbolic link holds. Go's `Readlink`.

    What comes back is what was written into the link and nothing more. It can
    be relative, in which case it means relative to the directory the link is
    in rather than to the working directory, and it can name something that is
    not there. `core.path.filepath.eval_symlinks` is the one that follows a
    whole chain and gives back a real path.
    """
    _check("readlink", name)
    try:
        return _sys_readlink(name)
    except e:
        raise _path_error_from("readlink", name, e)


def chmod(name: String, mode: FileMode) raises:
    """Set the permission bits on a path. Go's `Chmod`.

    Only the bits a `FileMode` can carry into a mode word: the nine
    permissions, setuid, setgid and sticky. The rest of the type half says what
    kind of file this is, which is not something a caller sets, so it is
    dropped rather than refused. Follows a symbolic link, since the link's own
    permissions mean nothing on either platform here.
    """
    _check("chmod", name)
    while True:
        try:
            _sys_chmod(name, _syscall_mode(mode))
            return
        except e:
            if _interrupted(e):
                continue
            raise _path_error_from("chmod", name, e)


def chown(name: String, uid: Int, gid: Int) raises:
    """Set the owner and the group of a path. Go's `Chown`.

    `-1` for either one leaves it alone. Follows a symbolic link, which is why
    `lchown` exists beside it. An ordinary user can only give a file to the
    owner it already has, so anything else raises `ErrPermission` for everybody
    but root.
    """
    _check("chown", name)
    while True:
        try:
            _sys_chown(name, uid, gid)
            return
        except e:
            if _interrupted(e):
                continue
            raise _path_error_from("chown", name, e)


def lchown(name: String, uid: Int, gid: Int) raises:
    """The same, on the link rather than through it. Go's `Lchown`.

    A symbolic link has an owner of its own, and it is what decides who may
    remove the link out of a sticky directory, so the two calls are not
    interchangeable even though the link's own permissions are.
    """
    _check("lchown", name)
    while True:
        try:
            _sys_lchown(name, uid, gid)
            return
        except e:
            if _interrupted(e):
                continue
            raise _path_error_from("lchown", name, e)


def truncate(name: String, size: Int64) raises:
    """Set the length of a file named by path. Go's `Truncate`.

    Opens nothing, so it works on a file the caller may shorten but may not
    open for writing. Growing a file this way leaves a hole that reads back as
    zeros, exactly as writing past the end does.
    """
    _check("truncate", name)
    while True:
        try:
            _sys_truncate(name, Int(size))
            return
        except e:
            if _interrupted(e):
                continue
            raise _path_error_from("truncate", name, e)


def chdir(dir: String) raises:
    """Move the working directory. Go's `Chdir`.

    Process wide, which is worth saying out loud: it changes what every
    relative path in the program means, including in code that has no idea this
    was called. `File.chdir` is the same move to a directory already open, and
    `core.path.filepath.abs` is usually the better answer.
    """
    _check("chdir", dir)
    while True:
        try:
            _sys_chdir(dir)
            return
        except e:
            if _interrupted(e):
                continue
            raise _path_error_from("chdir", dir, e)


def getwd() raises -> String:
    """The working directory, as an absolute path. Go's `Getwd`.

    Resolved by the kernel, so every symbolic link along the way is already
    followed and the answer does not have to be the path the program used to
    get here. On macOS a name under `/tmp` comes back under `/private/tmp` for
    that reason.

    Raises a `SyscallError` rather than a `PathError`, since there is no path
    to name: the call is the whole story.
    """
    try:
        return _sys_getcwd()
    except e:
        var reported = new_syscall_error("getwd", _errno_of(e))
        if reported:
            raise reported.take()
        raise e
