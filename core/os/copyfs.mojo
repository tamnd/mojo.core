"""A whole file system written out onto the disk. Go's `CopyFS`.

One function, and it is here rather than in `core.io.fs` because only one end of
it is a file system: it reads through the `FS` trait and writes through this
package, so it is where a virtual tree becomes real files. Unpacking an archive
into a directory is the case it is for.
"""

from core.errors import ErrorValue
from core.io import copy
from core.io.fs import DirEntry, ErrInvalid, FS, FileMode, walk_dir
from core.io.fs.errors import _refused
from core.syscall import O_CREAT, O_EXCL, O_WRONLY

from .file import open_file
from .path import mkdir_all


def copy_fs[F: FS](dir: String, fsys: F) raises:
    """Copy everything in `fsys` into the directory `dir`. Go's `CopyFS`.

    ```mojo
    from core.os import copy_fs, dir_fs

    def main():
        copy_fs("/tmp/copy", dir_fs("/etc/ssl"))
    ```

    `dir` is created if it is not there, along with any parent it needs, and so
    is every directory under it. A directory is made with `0o777` less the
    umask, which is what a directory the caller did not describe should be, and
    a file is made with `0o666` or whatever permission bits the source file has,
    which is Go's rule and the reason an executable stays executable.

    Nothing is overwritten. Each file is created with `O_EXCL`, so a name that
    already exists in `dir` stops the copy with `EEXIST` rather than replacing
    what is there. That is the deliberate part: this is for filling an empty
    directory, and a caller merging into a full one wants to make that decision
    per file rather than have this make it for them.

    Only directories and regular files are copied. Anything else, a symbolic
    link included, stops the copy with `ErrInvalid`, because there is no way to
    ask an `FS` what a link points at and writing the link's contents out as a
    file would be a lie. Go refuses the same thing for the same reason.

    A failure part way through leaves what was already copied where it is.
    There is no undo here and nothing is written to a temporary name first, so a
    caller who needs all or nothing copies into a directory of their own making
    and renames it afterwards.
    """

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]) raises:
        if err:
            raise err.value().error()
        var made = _under(dir, path)
        if entry.is_dir():
            mkdir_all(made, FileMode(0o777))
            return
        if not entry.type().is_regular():
            raise _refused("copy_fs", path, "not a regular file", ErrInvalid)
        var src = fsys.open(path)
        var perm = FileMode(0o666) | src.stat().mode().perm()
        var dst = open_file(made, O_WRONLY | O_CREAT | O_EXCL, perm)
        # A failed copy leaves through here and both files close themselves on
        # the way, the same arrangement `write_file` has: closing in an `except`
        # block could put the close's own failure where the copy's fields are.
        _ = copy(dst, src)
        dst.close()
        src.close()

    walk_dir[visit](fsys, ".")


def _under(dir: String, path: String) -> String:
    """The disk path for a walked name, with the root of the walk as `dir`.

    `walk_dir` from `"."` reports the root as `"."` and everything else as a
    slash separated name below it, which is exactly the shape this has to
    prefix. There is no cleaning to do and no escape to check for: a valid `FS`
    name has no leading slash, no `.` element and no `..` element, and `walk_dir`
    builds every name it reports out of `read_dir` entries.
    """
    if path == ".":
        return dir
    return dir + "/" + path
