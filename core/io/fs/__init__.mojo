"""The file system as a value, and the vocabulary a file is described in.
Go's `io/fs`.

```mojo
from core.io import Byte
from core.io.fs import FS, read_file


def config[F: FS](fsys: F) raises -> List[Byte]:
    return read_file(fsys, "etc/config.toml")
```

Go's `fs.FS` is the interface a tree of files is reached through, so that a zip
archive, a directory and a map in a test all answer the same questions. It is a
trait here and it is the point of the package: `open` is the only method that
has to be written, and `read_dir`, `stat`, `read_file`, `glob`, `walk_dir` and
`sub` all work on anything that has one. `fs.mojo` says how a file system that
can answer one of those faster says so, which is a bit rather than Go's type
assertion.

Around it is the vocabulary a file is described in: the rule about names, what
a file's mode is, what is known about a file, what one entry in a directory is,
what a failed operation on a path looks like, and what a walk over a tree
calls. `WalkDirFunc`, `SkipDir` and `SkipAll` are that last one, with `skip_dir`
and `skip_all` to raise the two of them, and they are shared with
`core.path.filepath.walk_dir` so that a callback written once works with both
walks.

`os` says all four of these in Go too. It does not repeat them: `os.FileMode`
is a declared alias for `fs.FileMode` and `os.ErrNotExist` is the same value as
`fs.ErrNotExist`, so a mode compared across the two packages compares equal.
The same holds here for the same reason, and `core.os` re-exports these names
rather than declaring its own.

## The name rule

A path in this package is always slash separated, always relative, and always
already clean, whatever the host underneath spells its own paths like. That is
not a convention, it is the contract: an `fs.FS` is handed names in this one
form so that an implementation over a zip file and an implementation over a
directory cannot disagree about what `a/../b` means, and so that a name from
outside cannot walk out of the tree by being spelled a different way. Go says
the same and `valid_path` is where it says it.

## The mode is not the platform's

`FileMode` has the same bits on every host, which is what makes a mode worth
moving between two of them. The permission bits happen to be the platform's and
everything above them is not, so a `FileMode` is built from an `st_mode` by a
switch rather than a mask. `mode.mojo` has the switch and says why.
"""

from core.errors.codes import (
    ErrClosed,
    ErrExist,
    ErrInvalid,
    ErrNotExist,
    ErrPermission,
    SkipAll,
    SkipDir,
)

from .direntry import DirEntry, file_info_to_dir_entry, format_dir_entry
from .errors import PathError
from .fs import (
    GLOB_FS,
    READ_DIR_FILE,
    READ_DIR_FS,
    READ_FILE_FS,
    READ_LINK_FS,
    STAT_FS,
    FS,
    File,
    GlobFS,
    ReadDirFile,
    ReadDirFS,
    ReadFileFS,
    ReadLinkFS,
    StatFS,
    SubFS,
)
from .glob import glob
from .info import FileInfo, format_file_info
from .mode import (
    MODE_APPEND,
    MODE_CHAR_DEVICE,
    MODE_DEVICE,
    MODE_DIR,
    MODE_EXCLUSIVE,
    MODE_IRREGULAR,
    MODE_NAMED_PIPE,
    MODE_PERM,
    MODE_SETGID,
    MODE_SETUID,
    MODE_SOCKET,
    MODE_STICKY,
    MODE_SYMLINK,
    MODE_TEMPORARY,
    MODE_TYPE,
    FileMode,
)
from .name import valid_path
from .read import lstat, read_dir, read_file, read_link, stat
from .sub import Subtree, sub
from .walk import WalkDirFunc, skip_all, skip_dir, walk_dir
