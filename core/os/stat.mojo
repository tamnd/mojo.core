"""Asking the host about a file without opening it. Go's `Stat` and `Lstat`.

Two calls and one question. `stat` follows symbolic links and describes
whatever is at the end of the chain, and `lstat` stops at the last one and
describes the link itself. That is the whole difference, and it is why
`lstat` is the only one of the two that can ever report `MODE_SYMLINK`.

Neither opens the file. A caller who is about to read it should open it and
ask the descriptor instead, because between a `stat` and an `open` the name can
come to mean a different file, and on a shared machine that is not a
theoretical worry.
"""

from core.io.fs import FileInfo
from core.io.fs.errors import _path_error_from
from core.syscall import Stat
from core.syscall import lstat as _sys_lstat
from core.syscall import stat as _sys_stat


def stat(path: String) raises -> FileInfo:
    """What the host says about `path`, following symbolic links. Go's `Stat`.

    ```mojo
    from core.os import stat

    def main():
        var info = stat("/etc/hosts")
        print(info.is_dir())  # False
    ```

    Raises a `PathError` with `op` of `stat`, so `is_not_exist` and
    `PathError.of` both work on what comes back.
    """
    var got = Stat()
    try:
        got = _sys_stat(path)
    except e:
        raise _path_error_from("stat", path, e)
    return FileInfo(path=path, stat=got)


def lstat(path: String) raises -> FileInfo:
    """The same, but describing a symbolic link rather than its target.
    Go's `Lstat`.

    A path whose last element is not a link gives exactly what `stat` gives, so
    this is the one to reach for when the answer has to be about the name that
    was asked about rather than about wherever it leads.
    """
    var got = Stat()
    try:
        got = _sys_lstat(path)
    except e:
        raise _path_error_from("lstat", path, e)
    return FileInfo(path=path, stat=got)


def same_file(a: FileInfo, b: FileInfo) -> Bool:
    """Whether these two describe the same file. Go's `SameFile`.

    The device and the inode, which is the only pair that answers the question:
    two names can be hard links to one file and one name can be two files a
    moment apart. Comparing the paths would get both of those wrong.

    False when either info came from something that is not this host, since
    there is nothing to compare. Go's is false in the same case, because its
    `Sys` assertion fails and it returns without looking further.

    ```mojo
    from core.os import lstat, same_file, stat

    def main():
        print(same_file(stat("/etc/hosts"), stat("/etc/hosts")))  # True
    ```
    """
    var left = a.sys()
    var right = b.sys()
    if not left or not right:
        return False
    return (
        left.value().dev() == right.value().dev()
        and left.value().ino() == right.value().ino()
    )
