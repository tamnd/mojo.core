"""One name read out of a directory. Go's `fs.DirEntry`.

The cheap half of a `FileInfo`. Reading a directory gives back a name and, on
every file system worth the word, what kind of thing that name is, and a
program listing a tree wants exactly those two and nothing else. Asking the
host for the rest costs a call per entry, so `info` is a separate question and
the caller decides whether to ask it.

Go's is an interface and this is a struct, the same choice `FileInfo` made and
for the same reason: there are no trait objects here, and a listing has to be
able to hold entries from a host directory and from an archive in one list.

`info` is a fresh answer rather than a copy of one taken earlier, which is
Go's behaviour and matters more than it looks. Between the read and the
question the entry can be renamed or removed, and an `info` that answered from
a snapshot would describe a file that is no longer there while looking exactly
like one that is.
"""

from core.syscall import (
    DT_BLK,
    DT_CHR,
    DT_DIR,
    DT_FIFO,
    DT_LNK,
    DT_REG,
    DT_SOCK,
)
from core.syscall import Dirent, Stat
from core.syscall import lstat as _sys_lstat

from .errors import _path_error_from
from .info import FileInfo
from .mode import (
    MODE_CHAR_DEVICE,
    MODE_DEVICE,
    MODE_DIR,
    MODE_IRREGULAR,
    MODE_NAMED_PIPE,
    MODE_SOCKET,
    MODE_SYMLINK,
    MODE_TYPE,
    FileMode,
)


def _of_dirent_kind(kind: Int) -> Optional[FileMode]:
    """The type bits a `DT_` constant means, or nothing when it means nothing.

    `DT_UNKNOWN` is the case worth naming. Several file systems do not carry
    the kind in the directory at all and answer it for every entry, so this
    gives back an empty optional rather than a plausible mode, and whoever
    read the directory does an `lstat` to find out. Anything this does not
    recognise is treated the same way, because a number this library has not
    seen is not evidence about the file.
    """
    if kind == DT_REG:
        return Optional(FileMode(0))
    if kind == DT_DIR:
        return Optional(MODE_DIR)
    if kind == DT_LNK:
        return Optional(MODE_SYMLINK)
    if kind == DT_FIFO:
        return Optional(MODE_NAMED_PIPE)
    if kind == DT_SOCK:
        return Optional(MODE_SOCKET)
    if kind == DT_BLK:
        return Optional(MODE_DEVICE)
    if kind == DT_CHR:
        return Optional(MODE_DEVICE | MODE_CHAR_DEVICE)
    return Optional[FileMode]()


struct DirEntry(Copyable, Movable, Writable):
    """One entry in a directory: a name and what kind of file it is.

    ```mojo
    from core.io.fs import MODE_DIR, FileInfo, FileMode, file_info_to_dir_entry
    from core.time import unix

    def main():
        var mode = FileMode(0o755) | MODE_DIR
        var info = FileInfo(name="src", size=0, mode=mode, mod_time=unix(0, 0))
        var entry = file_info_to_dir_entry(info^)
        print(entry.name(), entry.is_dir())  # => src True
    ```

    `core.os.read_dir` is where these come from in a program that reads a host
    directory, and it hands back a list of them.

    Copyable, because a listing is a list of these and a caller sorts, filters
    and keeps them. Nothing in it borrows from the directory it was read out
    of, which is already closed by the time a caller sees one.
    """

    var _name: String
    """The name on its own, with no directory in front of it."""

    var _type: FileMode
    """The type bits, and no permission bits. Go's `Type` says the same."""

    var _dir: String
    """The directory this was read from, for `info` to ask about.

    Empty for an entry that did not come from the host, which is the case
    `file_info_to_dir_entry` builds and where `_info` is filled in instead.
    """

    var _info: Optional[FileInfo]
    """The whole answer, when it is already known.

    Filled in for an entry built from a `FileInfo`, and for a host entry whose
    directory did not report a kind, since finding the kind out cost a call
    whose answer there is no reason to throw away.
    """

    def __init__(
        out self,
        *,
        var dir: String,
        var name: String,
        type: FileMode,
        var info: Optional[FileInfo] = None,
    ):
        """An entry read out of a host directory.

        `dir` is the directory the name was read from, and `info` is the answer
        to `info` when it is already in hand.
        """
        self._dir = dir^
        self._name = name^
        self._type = type & MODE_TYPE
        self._info = info^

    def __init__(out self, *, var info: FileInfo):
        """An entry that carries its whole answer. Go's `FileInfoToDirEntry`.

        For a file system with no host underneath it, where the listing was
        built out of records rather than read out of a directory.
        """
        self._dir = String()
        self._name = info.name()
        self._type = info.mode().type()
        self._info = Optional(info^)

    def name(self) -> String:
        """The name, with no directory in front of it. Go's `Name`."""
        return self._name

    def is_dir(self) -> Bool:
        """Whether this names a directory. Go's `IsDir`.

        Does not follow a symbolic link, so a link to a directory answers
        False, which is what `MODE_SYMLINK` in the type bits means.
        """
        return self._type.is_dir()

    def type(self) -> FileMode:
        """The type bits, without the permissions. Go's `Type`.

        Free: it came out of the directory read, or out of the one `lstat`
        that had to be done because the directory did not report it.
        """
        return self._type

    def info(self) raises -> FileInfo:
        """Everything about the file, asked now. Go's `Info`.

        One `lstat`, unless the answer is already held, and it describes the
        link rather than its target for the same reason `Type` does. Raises a
        `PathError` with `ErrNotExist` when the entry has gone between the
        directory read and this call, which is a race no ordering avoids and
        the reason this can fail at all.
        """
        if self._info:
            return self._info.value().copy()
        var path = String(self._dir, "/", self._name)
        try:
            return FileInfo(path=path, stat=_sys_lstat(path))
        except e:
            raise _path_error_from("lstat", path, e)

    def write_to[W: Writer](self, mut writer: W):
        """The kind letter, a space and the name. Go's `FormatDirEntry`.

        `d etc` for a directory and `- hosts` for an ordinary file, with a
        slash after the name of a directory, which is the form Go writes and
        is meant for a person reading a listing rather than for a parser.
        """
        writer.write(self._type.string()[byte=0])
        writer.write(" ")
        writer.write(self._name)
        if self.is_dir():
            writer.write("/")


def file_info_to_dir_entry(var info: FileInfo) -> DirEntry:
    """An entry that answers out of an info already in hand.
    Go's `FileInfoToDirEntry`.

    ```mojo
    from core.io.fs import FileMode, FileInfo, file_info_to_dir_entry
    from core.time import unix

    def main():
        var info = FileInfo(
            name="notes.txt", size=12, mode=FileMode(0o644), mod_time=unix(0, 0)
        )
        print(file_info_to_dir_entry(info^).name())  # => notes.txt
    ```

    Go returns nil for a nil info and there is no nil here, so the argument is
    a value and the case does not arise.
    """
    return DirEntry(info=info^)


def format_dir_entry(entry: DirEntry) -> String:
    """An entry as one line of a listing. Go's `FormatDirEntry`.

    The kind letter, a space, the name, and a slash if it is a directory.
    """
    return String(entry)


def _is_dot(name: StringSlice) -> Bool:
    """Whether this is `.` or `..`, the two entries a caller never wants.

    Go drops them in `os` rather than in `syscall`, and so does this library,
    because they are real entries and a layer that binds the platform has no
    business deciding they are uninteresting.
    """
    return name == "." or name == ".."


def _entry_of(dir: String, found: Dirent) raises -> DirEntry:
    """One entry out of one platform entry, asking `lstat` if it has to.

    `dir` is the path the directory was opened with, and it is what the entry
    remembers so that `info` has something to ask about later. The `lstat` is
    the `DT_UNKNOWN` case and its answer is kept, since a call already paid
    for should not be paid for twice.
    """
    var name = String(found.name)
    var kind = _of_dirent_kind(found.kind)
    if kind:
        return DirEntry(dir=dir, name=name^, type=kind.value())
    var path = String(dir, "/", name)
    var found_stat = Stat()
    try:
        found_stat = _sys_lstat(path)
    except e:
        raise _path_error_from("lstat", path, e)
    var info = FileInfo(path=path, stat=found_stat)
    var type = info.mode().type()
    return DirEntry(dir=dir, name=name^, type=type, info=info^)
