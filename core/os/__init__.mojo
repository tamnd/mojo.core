"""Files, processes and the environment. Go's `os`.

```mojo
from core.os import is_not_exist, stat

def main():
    try:
        _ = stat("/no/such/file")
    except e:
        print(is_not_exist(e))  # True
```

Go's `os` is the platform with the platform's edges filed off: the same call
works on every host, a failure comes back as an error rather than as a number,
and a path is a string rather than whatever the host would rather it was. This
is that package, and what is here so far is the vocabulary the rest of it will
be written in.

## What is here

`stat` and `lstat` ask the host about a file without opening it and give back a
`FileInfo`. `FileMode` says what kind of file it is and who may do what to it.
`PathError`, `LinkError` and `SyscallError` say what failed and why, and
`is_exist`, `is_not_exist` and `is_permission` ask the question a caller
usually has.

`File` is one open file, and `open`, `create`, `open_file` and `new_file` are
the four ways to get one. It closes itself when it is destroyed and it is a
`core.io` `Reader`, `Writer`, `Seeker`, `Closer`, `ReaderAt`, `WriterAt` and
`StringWriter`, so everything written against those traits works over a real
file. `stdin`, `stdout` and `stderr` are the three descriptors the process
started with, as functions rather than as variables because this library has no
package level state.

`read_dir` lists a directory and gives back `DirEntry` values sorted by name,
and `File.read_dir`, `File.readdir` and `File.readdirnames` read one a piece at
a time. An entry knows what kind of file it names without a second call, which
is the whole reason the type is not a `FileInfo`.

`mkdir`, `remove`, `rename`, `link`, `symlink`, `readlink`, `chmod`, `chown`,
`lchown`, `truncate`, `chdir` and `getwd` are the calls that take a path and do
something to it. `mkdir_all` and `remove_all` are the two that walk one, and
`read_file` and `write_file` are a whole file in one call in each direction.

`getenv`, `lookup_env`, `setenv`, `unsetenv`, `clearenv` and `environ` are the
environment, read through the C library every time rather than out of a copy
taken at start up, so a variable set by a C library in the same process is
visible here and the other way about. `expand` replaces `$name` and `${name}` in
a string using a mapping the caller supplies and `expand_env` is that with the
environment. `temp_dir`, `user_home_dir`, `user_cache_dir` and
`user_config_dir` are the four directories the environment names.

The process ids, the temporary files and anything to do with starting a program
are still to come. Issue #28 tracks the rest.

## Names from `core.io.fs`

`FileMode`, `FileInfo`, `PathError` and the five sentinels are declared in
`core.io.fs` and re-exported here rather than declared again. Go does the same
thing with a type alias, and the reason is the one that matters: a mode read
through `core.io.fs` and a mode read through `core.os` have to be the same
type, or a file system implementation and the host's own file system stop being
interchangeable and every caller has to know which one it is holding.
"""

from core.io.fs import (
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
    ErrClosed,
    ErrExist,
    ErrInvalid,
    ErrNotExist,
    ErrPermission,
    DirEntry,
    FileInfo,
    FileMode,
    PathError,
)

from core.syscall import O_APPEND, O_EXCL, O_RDONLY, O_RDWR, O_SYNC, O_TRUNC
from core.syscall import O_CREAT as O_CREATE
from core.syscall import O_WRONLY

from .errors import (
    LinkError,
    SyscallError,
    is_exist,
    is_not_exist,
    is_permission,
    new_syscall_error,
)
from .calls import (
    chdir,
    chmod,
    chown,
    getwd,
    lchown,
    link,
    mkdir,
    readlink,
    remove,
    rename,
    symlink,
    truncate,
)
from .dir import read_dir
from .dirs import temp_dir, user_cache_dir, user_config_dir, user_home_dir
from .env import (
    clearenv,
    environ,
    expand,
    expand_env,
    getenv,
    lookup_env,
    setenv,
    unsetenv,
)
from .file import File, create, new_file, open, open_file, stderr, stdin, stdout
from .path import (
    DEV_NULL,
    PATH_LIST_SEPARATOR,
    PATH_SEPARATOR,
    is_path_separator,
    mkdir_all,
    remove_all,
)
from .readfile import read_file, write_file
from .stat import lstat, same_file, stat
