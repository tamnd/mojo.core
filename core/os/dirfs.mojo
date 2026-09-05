"""A directory on this host as a file system value. Go's `os.DirFS`.

The bridge between this package, which makes system calls with host paths, and
`core.io.fs`, which is written against a trait and knows only slash separated
names. Everything generic that takes an `FS` works on a real directory through
this, which is what makes `core.io.fs.walk_dir` and `core.io.fs.glob` useful
outside a test.

## What it does not promise

It is a name rule, not a sandbox. Every name is checked by `valid_path` before
it is used, so no name a caller writes can climb out with `..`, and that is
where the guarantee stops: a symbolic link inside the tree that points outside
it is followed, because the open that follows it is an ordinary open. Go says
the same about its own and points at `os.OpenRoot` for the case where the
answer has to hold against a hostile tree. That call is not bound here yet.

A relative root is resolved against the working directory at the time of each
call rather than at the time this was built, since what is kept is the string.
A program that chdirs after building one has changed what it means.
"""

from core.io import Byte
from core.io.fs import (
    READ_DIR_FS,
    READ_FILE_FS,
    READ_LINK_FS,
    STAT_FS,
    DirEntry,
    FileInfo,
    FS,
    valid_path,
)
from core.io.fs.errors import _refused, _with_path
from core.errors.codes import ErrInvalid

from .calls import readlink
from .dir import read_dir as _os_read_dir
from .file import File as OsFile, open as _os_open
from .readfile import read_file as _os_read_file
from .stat import lstat as _os_lstat, stat as _os_stat


struct DirFS(FS):
    """The tree under one directory, as an `fs.FS`. Go's unexported `dirFS`.

    Built by `dir_fs`. Every question is the same two steps: check the name and
    put the root in front of it, then make the ordinary call this package would
    have made anyway. A failure comes back naming the name the caller passed
    rather than the joined path, which is Go's rule as well: a caller of a file
    system value never wrote the root and has nothing to do with it in a
    message.
    """

    comptime File = OsFile

    var _dir: String
    """The root, exactly as it was given, with no slash added or taken away."""

    def __init__(out self, var dir: String):
        """Rooted at `dir`, which `dir_fs` has already checked."""
        self._dir = dir^

    def capabilities(self) -> Int:
        """Four of the six, which are the four this host answers directly.

        Each one is a single system call here, where the generic version would
        open the name, ask the open file and close it again. `glob` is not
        among them: there is no call that matches a pattern, so the generic
        version reading directories is already the best answer.
        """
        return READ_DIR_FS | STAT_FS | READ_FILE_FS | READ_LINK_FS

    def _full(
        self, op: StringSlice[ImmStaticOrigin], name: String
    ) raises -> String:
        """`name` as a path on this host. Go's `dirFS.join`.

        The check comes first and it is the whole of the name rule: no absolute
        name, no `..`, no empty element. What follows is a concatenation and
        not a `join`, so nothing is cleaned after the fact, because cleaning a
        path after joining it is how a name that should have been refused turns
        into one that works.
        """
        if not valid_path(name):
            raise _refused(op, name, "invalid argument", ErrInvalid)
        return self._dir + "/" + name

    def open(self, name: String) raises -> Self.File:
        """The file at `name` under the root, opened for reading. Go's `Open`.
        """
        var full = self._full("open", name)
        try:
            return _os_open(full)
        except e:
            raise _with_path(e, name)

    def read_dir(self, name: String) raises -> List[DirEntry]:
        """The contents of the directory at `name`, sorted. Go's `ReadDir`."""
        var full = self._full("read_dir", name)
        try:
            return _os_read_dir(full)
        except e:
            raise _with_path(e, name)

    def stat(self, name: String) raises -> FileInfo:
        """What the host says about `name`, following links. Go's `Stat`."""
        var full = self._full("stat", name)
        try:
            return _os_stat(full)
        except e:
            raise _with_path(e, name)

    def read_file(self, name: String) raises -> List[Byte]:
        """The whole contents of `name`. Go's `ReadFile`."""
        var full = self._full("read_file", name)
        try:
            return _os_read_file(full)
        except e:
            raise _with_path(e, name)

    def read_link(self, name: String) raises -> String:
        """The target of the symbolic link at `name`. Go's `ReadLink`.

        The target is whatever was written into the link and is not touched. It
        can be absolute, and it can point outside the tree, which is the honest
        answer to what the link says rather than to where it leads.
        """
        var full = self._full("read_link", name)
        try:
            return readlink(full)
        except e:
            raise _with_path(e, name)

    def lstat(self, name: String) raises -> FileInfo:
        """What the host says about `name` itself, link and all. Go's `Lstat`.
        """
        var full = self._full("lstat", name)
        try:
            return _os_lstat(full)
        except e:
            raise _with_path(e, name)


def dir_fs(var dir: String) raises -> DirFS:
    """The tree of files under `dir`, as a file system. Go's `DirFS`.

    ```mojo
    from core.io.fs import glob
    from core.os import dir_fs


    def main() raises:
        for name in glob(dir_fs("/etc"), "*.conf"):
            print(name)
    ```

    `dir_fs("/prefix").open("file")` is `open("/prefix/file")` and nothing more
    than that, which is the sentence Go's own documentation leads with. What it
    buys is that a name is checked before it is used and that the result is an
    `FS`, so every generic function in `core.io.fs` works over a real
    directory.

    An empty root is refused rather than treated as the working directory. Go
    builds the value and fails at the first call with `os: DirFS with empty
    root`; the failure is the same one either way and having it here means the
    value that exists is always usable. The working directory is spelled `"."`,
    which is a root like any other.
    """
    if dir.byte_length() == 0:
        raise _refused("dir_fs", "", "empty root", ErrInvalid)
    return DirFS(dir^)
