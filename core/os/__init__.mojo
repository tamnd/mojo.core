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

`File` itself is not written yet, and neither is the environment or anything to
do with processes. Issue #28 tracks the rest.

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
    FileInfo,
    FileMode,
    PathError,
)

from .errors import (
    LinkError,
    SyscallError,
    is_exist,
    is_not_exist,
    is_permission,
    new_syscall_error,
)
from .stat import lstat, same_file, stat
