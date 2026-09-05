"""The operating system, with the number it failed with kept.

Go's `syscall`, in the part of it the rest of this library needs. Mojo's own
`std.os` gives file handles and very little else, and it reports a failed call
as a string with the errno thrown away, which makes "the file was not there"
indistinguishable from "the directory was not searchable" to anything trying to
decide what to do next. Everything above this needs the real thing.

Start with `open`, `read`, `write` and `close` for descriptors, `stat` and its
two siblings for what the platform knows about a path, `opendir` and `readdir`
for what is in a directory, `clock_gettime` for what time it is, and `Errno`
for what a failure was.

Every constant the platform defines comes out of here, because a caller
comparing an errno against `ENOENT` should not have to know that the number
came from a generated module. The sizes and the offsets do not: `SIZEOF_STAT`
and its neighbours are in `core.syscall.abi` for whoever is laying out a
structure to hand to a call this package does not bind, and nobody else needs
them.

## Where the numbers come from

Nothing in this package is typed from a manual page. A small C program under
`tools/baseline` asks the host's own headers for the size of every type and
structure, the offset of every field and the value of every constant, and the
answers are recorded in `core/syscall/baseline/<platform>.json`.
`tools/gen/syscall.py` turns the three recorded tables into `abi.mojo`, where
each fact is a `comptime` chosen by target. `pixi run baseline` checks the
recorded table against the host's headers on all three platforms on every CI
run, and `pixi run generated-check` fails if `abi.mojo` has drifted from them.

The reason for all of that machinery is that this is the layer where being
wrong does not look like being wrong. `struct stat` is 144 bytes on macOS and
on Linux x86-64 and 128 on Linux arm64. `st_size` is at offset 96 on macOS and
48 on Linux. `mode_t` is two bytes on macOS and four on Linux. `EAGAIN` is 35
on macOS and 11 on Linux, and 35 on Linux means `EDEADLK`. Every one of those
compiles cleanly on the platform it was written on and returns a believable
number somewhere else.

## What is not here

`ioctl` is not bound. It is variadic, so it would need the same C wrapper
`open` and `fcntl` already go through, and nothing in this library calls it
yet. `core/syscall/shim/README.md` has the reasoning.

No call here retries on `EINTR`, and no path is checked for an interior zero
byte. Both are policy, both belong to whoever is deciding what a failure means,
and that is `core.os` rather than this.

Sockets, processes and signals are not bound yet. The constants for all three
are already in `abi.mojo`, because the C program that records them costs
nothing extra and a constant recorded early is one nobody types by hand later.
"""

from .abi import (
    ABSENT,
    AF_INET,
    AF_INET6,
    AF_UNIX,
    AT_FDCWD,
    AT_REMOVEDIR,
    AT_SYMLINK_NOFOLLOW,
    CLOCK_MONOTONIC,
    CLOCK_REALTIME,
    DT_BLK,
    DT_CHR,
    DT_DIR,
    DT_FIFO,
    DT_LNK,
    DT_REG,
    DT_SOCK,
    DT_UNKNOWN,
    E2BIG,
    EACCES,
    EADDRINUSE,
    EADDRNOTAVAIL,
    EAFNOSUPPORT,
    EAGAIN,
    EALREADY,
    EBADF,
    EBUSY,
    ECANCELED,
    ECHILD,
    ECONNABORTED,
    ECONNREFUSED,
    ECONNRESET,
    EDEADLK,
    EDESTADDRREQ,
    EDOM,
    EDQUOT,
    EEXIST,
    EFAULT,
    EFBIG,
    EHOSTDOWN,
    EHOSTUNREACH,
    EIDRM,
    EILSEQ,
    EINPROGRESS,
    EINTR,
    EINVAL,
    EIO,
    EISCONN,
    EISDIR,
    ELOOP,
    EMFILE,
    EMLINK,
    EMSGSIZE,
    ENAMETOOLONG,
    ENETDOWN,
    ENETRESET,
    ENETUNREACH,
    ENFILE,
    ENOBUFS,
    ENODEV,
    ENOENT,
    ENOEXEC,
    ENOLCK,
    ENOMEM,
    ENOPROTOOPT,
    ENOSPC,
    ENOSYS,
    ENOTCONN,
    ENOTDIR,
    ENOTEMPTY,
    ENOTRECOVERABLE,
    ENOTSOCK,
    ENOTSUP,
    ENOTTY,
    ENXIO,
    EOPNOTSUPP,
    EOVERFLOW,
    EOWNERDEAD,
    EPERM,
    EPIPE,
    EPROTONOSUPPORT,
    EPROTOTYPE,
    ERANGE,
    EROFS,
    ESHUTDOWN,
    ESPIPE,
    ESRCH,
    ETIMEDOUT,
    ETXTBSY,
    EWOULDBLOCK,
    EXDEV,
    FD_CLOEXEC,
    F_DUPFD,
    F_DUPFD_CLOEXEC,
    F_GETFD,
    F_GETFL,
    F_SETFD,
    F_SETFL,
    NAME_MAX,
    O_ACCMODE,
    O_APPEND,
    O_CLOEXEC,
    O_CREAT,
    O_DIRECTORY,
    O_EXCL,
    O_NOFOLLOW,
    O_NONBLOCK,
    O_RDONLY,
    O_RDWR,
    O_SYNC,
    O_TRUNC,
    O_WRONLY,
    PATH_MAX,
    SEEK_CUR,
    SEEK_END,
    SEEK_SET,
    SIGABRT,
    SIGALRM,
    SIGBUS,
    SIGCHLD,
    SIGCONT,
    SIGEMT,
    SIGFPE,
    SIGHUP,
    SIGILL,
    SIGINFO,
    SIGINT,
    SIGIO,
    SIGKILL,
    SIGPIPE,
    SIGPROF,
    SIGPWR,
    SIGQUIT,
    SIGSEGV,
    SIGSTKFLT,
    SIGSTOP,
    SIGSYS,
    SIGTERM,
    SIGTRAP,
    SIGTSTP,
    SIGTTIN,
    SIGTTOU,
    SIGURG,
    SIGUSR1,
    SIGUSR2,
    SIGVTALRM,
    SIGWINCH,
    SIGXCPU,
    SIGXFSZ,
    SOCK_DGRAM,
    SOCK_STREAM,
    S_IFBLK,
    S_IFCHR,
    S_IFDIR,
    S_IFIFO,
    S_IFLNK,
    S_IFMT,
    S_IFREG,
    S_IFSOCK,
    S_ISGID,
    S_ISUID,
    S_ISVTX,
    WNOHANG,
    WUNTRACED,
)
from .calls import (
    chdir,
    chmod,
    clock_gettime,
    close,
    closedir,
    create,
    dup,
    fchdir,
    fchmod,
    fcntl,
    fdopendir,
    fstat,
    fsync,
    ftruncate,
    getcwd,
    getenv,
    getpid,
    link,
    lseek,
    lstat,
    mkdir,
    open,
    opendir,
    pread,
    pwrite,
    read,
    readdir,
    readlink,
    rename,
    rmdir,
    setenv,
    stat,
    symlink,
    unlink,
    unlinkat,
    unsetenv,
    write,
)
from .dir import Dirent
from .errno import Errno, errno, set_errno
from .stat import Stat, Timespec
