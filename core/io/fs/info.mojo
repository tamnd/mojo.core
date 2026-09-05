"""What is known about one file. Go's `fs.FileInfo`.

Go declares an interface with six methods and the standard library has one
implementation of it, `os.fileStat`. Here it is a struct with those six methods
on it, because design.md says a trait costs more than it is worth when nothing
needs to be polymorphic, and because six methods is a lot to ask of every
future file system when five of them are a name, a number, a mode and a time.

The sixth is `sys`, which is Go's way back down to the platform's own record.
Go returns `any` and every caller type asserts it to `*syscall.Stat_t`. There
is no `any` here, so it is an `Optional[Stat]` instead: present for a file the
host reported on, empty for a file system that has no host underneath it, which
is exactly the set of cases where Go's assertion would have failed.
"""

from core.path import base as _path_base
from core.syscall import Stat
from core.time import RFC3339, Time, unix

from .mode import FileMode, _of_platform_mode


struct FileInfo(Copyable, Movable):
    """One file's name, size, mode and modification time.

    ```mojo
    from core.io.fs import FileInfo, FileMode
    from core.time import unix

    var info = FileInfo(
        name="notes.txt", size=12, mode=FileMode(0o644), mod_time=unix(0, 0)
    )
    print(info.name(), info.size(), info.mode())  # => notes.txt 12 -rw-r--r--
    ```

    Every field is a copy taken when the info was built, so it outlives the
    call that produced it and does not change under a caller who holds it. That
    is Go's contract too: a `FileInfo` is a snapshot and asking it a question
    twice cannot give two answers.
    """

    var _name: String
    """The last element of the path, not the whole path. Go bases it too."""

    var _size: Int
    """The length in bytes, or for a symlink the length of its target."""

    var _mode: FileMode
    """The type and the permissions, already translated out of `st_mode`."""

    var _mod_time: Time
    """When the contents were last written, to the nanosecond."""

    var _sys: Optional[Stat]
    """The platform's own record, when there was one."""

    def __init__(
        out self,
        *,
        var name: String,
        size: Int,
        mode: FileMode,
        var mod_time: Time,
    ):
        """An info for a file the host knows nothing about.

        For a file system built over something that is not the host: an
        archive, a map in a test, bytes in the binary. `sys` comes back empty,
        which is where Go's `Sys` returns nil.
        """
        self._name = name^
        self._size = size
        self._mode = mode
        self._mod_time = mod_time^
        self._sys = Optional[Stat]()

    def __init__(out self, *, path: StringSlice, stat: Stat):
        """An info for a file the host reported on. Go's `fillFileStatFromSys`.

        `path` is the whole path the call was made with and the name kept is
        its last element, which is what Go does and what makes a directory
        listing read the way a listing should. The last element is
        `core.path.base`, which this package can name because `core.path` sits
        underneath it, the same place Go's `path` sits underneath Go's `io/fs`.
        """
        self._name = _path_base(path)
        self._size = stat.size()
        self._mode = _of_platform_mode(stat.mode())
        var written = stat.mtime()
        self._mod_time = unix(written.sec, written.nsec)
        self._sys = Optional[Stat](stat.copy())

    def name(self) -> String:
        """The last element of the path. Go's `Name`."""
        return self._name.copy()

    def size(self) -> Int:
        """The length in bytes. Go's `Size`.

        For a symlink read with `lstat`, the length of the target's name rather
        than of anything at the other end of it.
        """
        return self._size

    def mode(self) -> FileMode:
        """The type and the permission bits. Go's `Mode`."""
        return self._mode

    def mod_time(self) -> Time:
        """When the contents were last written. Go's `ModTime`.

        The nanoseconds the platform recorded are kept. A file system that
        records them and a library that rounds them away is a library that says
        two files were written at the same instant when they were not.
        """
        return self._mod_time.copy()

    def is_dir(self) -> Bool:
        """Whether this is a directory. Go's `IsDir`, and the same shorthand:
        it asks the mode and nothing else."""
        return self._mode.is_dir()

    def sys(self) -> Optional[Stat]:
        """The platform's own record, or nothing. Go's `Sys`.

        Everything above is already on the five methods, so this is for the
        fields Go's interface has no room for: the inode and device that say
        whether two paths are the same file, the link count, the owner, the
        access and change times, the allocated block count. A caller who wants
        one of those is asking a question about this host and this is the door
        marked as such.
        """
        return self._sys.copy()


def format_file_info(info: FileInfo) -> String:
    """An info as one line of a long listing. Go's `FormatFileInfo`.

    ```mojo
    from core.io.fs import FileInfo, FileMode, format_file_info
    from core.time import unix

    var info = FileInfo(
        name="notes.txt", size=12, mode=FileMode(0o644), mod_time=unix(0, 0)
    )
    print(format_file_info(info))
    # => -rw-r--r-- 12 1970-01-01T00:00:00Z notes.txt
    ```

    The mode, the size, the modification time as RFC 3339 and the name, with a
    slash after the name if it is a directory. Go's order and Go's separators,
    so a listing printed here reads as one printed there.

    A function rather than the way `DirEntry` prints itself, because Go's
    `FileInfo` is an interface and this is the helper an implementation of it
    calls from its own `String`. Here the type is concrete and printing it
    directly is the obvious thing, so this stays a function to keep the name Go
    gave it findable.
    """
    var line = String(info.mode()) + " " + String(info.size()) + " "
    line += info.mod_time().format(RFC3339) + " " + info.name()
    if info.is_dir():
        line += "/"
    return line^
