"""The numbers this platform's C headers gave us.

Generated from `core/syscall/baseline/*.json` by `tools/gen/syscall.py`. Do not
edit: re-record a baseline with `pixi run baseline --record` and run `pixi run
gen`. `pixi run generated-check` fails on a diff.

Every binding here is a `comptime` chosen by target, so the constant folds to
one number while the program is built and nothing is decided at run time. The
three platforms are macOS arm64, Linux x86-64 and Linux arm64.

Names follow the headers. A constant keeps its own name, `sizeof(T)` becomes
`SIZEOF_T`, and the offset of a field becomes `OFFSET_<STRUCT>_<FIELD>`. The
offsets carry a prefix the headers do not have because an offset and a value
are both plain integers, and a package that reads structures out of a byte
buffer is exactly where handing one to the other goes unnoticed.

A fact a platform does not have is `ABSENT` on that platform. See its
docstring.
"""

from std.sys import CompilationTarget

comptime _MACOS = CompilationTarget.is_macos()
"""True when building for macOS. The odd one out on most of this file."""

comptime _LINUX_X86 = CompilationTarget.is_linux() and CompilationTarget.is_x86()
"""True when building for Linux x86-64.

The two Linux architectures are not interchangeable. `struct stat` is 144 bytes
on x86-64 and 128 on arm64, with `st_mode` at 24 and 16, and `O_DIRECTORY` is
65536 and 16384. A binding written on one of them and assumed to hold for
Linux is wrong on the other and does not say so.
"""

comptime _LINUX_ARM = CompilationTarget.is_linux() and not CompilationTarget.is_x86()
"""True when building for Linux arm64. The other side of `_LINUX_X86`."""

comptime ABSENT: Int = -0x7FFF_FFFF_FFFF_FFFF
"""The value of a fact the platform being built for does not have.

`SIGINFO` exists on macOS and not on Linux; `SIGPWR` is the other way round.
Rather than leave the name undefined on one platform, which would turn a
portability mistake into a spelling error somewhere unrelated, the name is
always there and holds this.

It is not zero and not minus one, because both of those are real answers in
this file. It is Int64's minimum plus one, so a caller who passes it to the
kernel gets a clear failure and a reader who sees it in a message knows at once
what it is.
"""


# The sizes. A buffer allocated from the wrong one of these is a structure the
# kernel writes past the end of, which is the worst way for any of this to be
# wrong.
comptime SIZEOF_BLKCNT_T: Int = 8
comptime SIZEOF_BLKSIZE_T: Int = 8 if _LINUX_X86 else 4
comptime SIZEOF_DEV_T: Int = 4 if _MACOS else 8
comptime SIZEOF_GID_T: Int = 4
comptime SIZEOF_INO_T: Int = 8
comptime SIZEOF_MODE_T: Int = 2 if _MACOS else 4
comptime SIZEOF_NLINK_T: Int = 2 if _MACOS else (8 if _LINUX_X86 else 4)
comptime SIZEOF_OFF_T: Int = 8
comptime SIZEOF_PID_T: Int = 4
comptime SIZEOF_PTHREAD_COND_T: Int = 48
comptime SIZEOF_PTHREAD_MUTEX_T: Int = 64 if _MACOS else (
    40 if _LINUX_X86 else 48
)
comptime SIZEOF_PTHREAD_RWLOCK_T: Int = 200 if _MACOS else 56
comptime SIZEOF_PTHREAD_T: Int = 8
comptime SIZEOF_SIZE_T: Int = 8
comptime SIZEOF_SOCKLEN_T: Int = 4
comptime SIZEOF_SSIZE_T: Int = 8
comptime SIZEOF_DIRENT: Int = 1048 if _MACOS else 280
comptime SIZEOF_SOCKADDR: Int = 16
comptime SIZEOF_SOCKADDR_IN: Int = 16
comptime SIZEOF_SOCKADDR_IN6: Int = 28
comptime SIZEOF_SOCKADDR_STORAGE: Int = 128
comptime SIZEOF_SOCKADDR_UN: Int = 106 if _MACOS else 110
comptime SIZEOF_STAT: Int = 128 if _LINUX_ARM else 144
comptime SIZEOF_TIMESPEC: Int = 16
comptime SIZEOF_TIMEVAL: Int = 16
comptime SIZEOF_TIME_T: Int = 8
comptime SIZEOF_UID_T: Int = 4


# The offsets, grouped by the structure they are inside. A field read at the
# wrong one of these returns a number that looks like an answer.

# struct dirent
comptime OFFSET_DIRENT_D_INO: Int = 0
comptime OFFSET_DIRENT_D_NAME: Int = 21 if _MACOS else 19
comptime OFFSET_DIRENT_D_NAMLEN: Int = 18 if _MACOS else ABSENT
comptime OFFSET_DIRENT_D_RECLEN: Int = 16
comptime OFFSET_DIRENT_D_TYPE: Int = 20 if _MACOS else 18

# struct sockaddr_in
comptime OFFSET_SOCKADDR_IN_SIN_ADDR: Int = 4
comptime OFFSET_SOCKADDR_IN_SIN_FAMILY: Int = 1 if _MACOS else 0
comptime OFFSET_SOCKADDR_IN_SIN_PORT: Int = 2

# struct sockaddr_in6
comptime OFFSET_SOCKADDR_IN6_SIN6_ADDR: Int = 8
comptime OFFSET_SOCKADDR_IN6_SIN6_PORT: Int = 2

# struct sockaddr_un
comptime OFFSET_SOCKADDR_UN_SUN_PATH: Int = 2

# struct stat
comptime OFFSET_STAT_ST_ATIM: Int = 32 if _MACOS else 72
comptime OFFSET_STAT_ST_BIRTHTIM: Int = 80 if _MACOS else ABSENT
comptime OFFSET_STAT_ST_BLKSIZE: Int = 112 if _MACOS else 56
comptime OFFSET_STAT_ST_BLOCKS: Int = 104 if _MACOS else 64
comptime OFFSET_STAT_ST_CTIM: Int = 64 if _MACOS else 104
comptime OFFSET_STAT_ST_DEV: Int = 0
comptime OFFSET_STAT_ST_GID: Int = 20 if _MACOS else (32 if _LINUX_X86 else 28)
comptime OFFSET_STAT_ST_INO: Int = 8
comptime OFFSET_STAT_ST_MODE: Int = 4 if _MACOS else (24 if _LINUX_X86 else 16)
comptime OFFSET_STAT_ST_MTIM: Int = 48 if _MACOS else 88
comptime OFFSET_STAT_ST_NLINK: Int = 6 if _MACOS else (16 if _LINUX_X86 else 20)
comptime OFFSET_STAT_ST_RDEV: Int = 24 if _MACOS else (40 if _LINUX_X86 else 32)
comptime OFFSET_STAT_ST_SIZE: Int = 96 if _MACOS else 48
comptime OFFSET_STAT_ST_UID: Int = 16 if _MACOS else (28 if _LINUX_X86 else 24)

# struct timespec
comptime OFFSET_TIMESPEC_TV_NSEC: Int = 8
comptime OFFSET_TIMESPEC_TV_SEC: Int = 0

# struct timeval
comptime OFFSET_TIMEVAL_TV_SEC: Int = 0
comptime OFFSET_TIMEVAL_TV_USEC: Int = 8


# Flags for `open`. The access modes are the same everywhere and every other
# bit in this group moves: `O_CREAT` is 512 on macOS and 64 on Linux, and
# `O_DIRECTORY` is different on all three.
comptime O_ACCMODE: Int = 3
comptime O_APPEND: Int = 8 if _MACOS else 1024
comptime O_CLOEXEC: Int = 16777216 if _MACOS else 524288
comptime O_CREAT: Int = 512 if _MACOS else 64
comptime O_DIRECTORY: Int = 1048576 if _MACOS else (
    65536 if _LINUX_X86 else 16384
)
comptime O_EXCL: Int = 2048 if _MACOS else 128
comptime O_NOFOLLOW: Int = 256 if _MACOS else (131072 if _LINUX_X86 else 32768)
comptime O_NONBLOCK: Int = 4 if _MACOS else 2048
comptime O_RDONLY: Int = 0
comptime O_RDWR: Int = 2
comptime O_SYNC: Int = 128 if _MACOS else 1052672
comptime O_TRUNC: Int = 1024 if _MACOS else 512
comptime O_WRONLY: Int = 1

# Where an offset given to `lseek` is measured from.
comptime SEEK_CUR: Int = 1
comptime SEEK_END: Int = 2
comptime SEEK_SET: Int = 0

# The `*at` family. `AT_FDCWD` is the directory descriptor standing for the
# process working directory, and it is negative on both platforms because a
# real descriptor never is.
comptime AT_FDCWD: Int = -2 if _MACOS else -100
comptime AT_REMOVEDIR: Int = 128 if _MACOS else 512
comptime AT_SYMLINK_NOFOLLOW: Int = 32 if _MACOS else 256

# Commands for `fcntl`, and the one descriptor flag it reads and sets.
comptime FD_CLOEXEC: Int = 1
comptime F_DUPFD: Int = 0
comptime F_DUPFD_CLOEXEC: Int = 67 if _MACOS else 1030
comptime F_GETFD: Int = 1
comptime F_GETFL: Int = 3
comptime F_SETFD: Int = 2
comptime F_SETFL: Int = 4

# The file mode bits. `S_IFMT` is the mask that selects the type out of a mode,
# and the rest of the `S_IF` group are the types it selects.
comptime S_IFBLK: Int = 24576
comptime S_IFCHR: Int = 8192
comptime S_IFDIR: Int = 16384
comptime S_IFIFO: Int = 4096
comptime S_IFLNK: Int = 40960
comptime S_IFMT: Int = 61440
comptime S_IFREG: Int = 32768
comptime S_IFSOCK: Int = 49152
comptime S_ISGID: Int = 1024
comptime S_ISUID: Int = 2048
comptime S_ISVTX: Int = 512

# The file type a directory entry reports, which is a different numbering from
# the mode bits above and cannot be substituted for it.
comptime DT_BLK: Int = 6
comptime DT_CHR: Int = 2
comptime DT_DIR: Int = 4
comptime DT_FIFO: Int = 1
comptime DT_LNK: Int = 10
comptime DT_REG: Int = 8
comptime DT_SOCK: Int = 12
comptime DT_UNKNOWN: Int = 0

# Options for `waitpid`.
comptime WNOHANG: Int = 1
comptime WUNTRACED: Int = 2

# The errno table. These are the numbers a failing call leaves behind, and
# around half of them disagree across platforms in a way that is worse than
# disagreeing: `EAGAIN` is 35 on macOS and 11 on Linux, and 35 on Linux is
# `EDEADLK`. A number compared against the wrong platform's constant does not
# fail to match, it matches the wrong thing, so nothing above this layer should
# ever see a bare number.
comptime E2BIG: Int = 7
comptime EACCES: Int = 13
comptime EADDRINUSE: Int = 48 if _MACOS else 98
comptime EADDRNOTAVAIL: Int = 49 if _MACOS else 99
comptime EAFNOSUPPORT: Int = 47 if _MACOS else 97
comptime EAGAIN: Int = 35 if _MACOS else 11
comptime EALREADY: Int = 37 if _MACOS else 114
comptime EBADF: Int = 9
comptime EBUSY: Int = 16
comptime ECANCELED: Int = 89 if _MACOS else 125
comptime ECHILD: Int = 10
comptime ECONNABORTED: Int = 53 if _MACOS else 103
comptime ECONNREFUSED: Int = 61 if _MACOS else 111
comptime ECONNRESET: Int = 54 if _MACOS else 104
comptime EDEADLK: Int = 11 if _MACOS else 35
comptime EDESTADDRREQ: Int = 39 if _MACOS else 89
comptime EDOM: Int = 33
comptime EDQUOT: Int = 69 if _MACOS else 122
comptime EEXIST: Int = 17
comptime EFAULT: Int = 14
comptime EFBIG: Int = 27
comptime EHOSTDOWN: Int = 64 if _MACOS else 112
comptime EHOSTUNREACH: Int = 65 if _MACOS else 113
comptime EIDRM: Int = 90 if _MACOS else 43
comptime EILSEQ: Int = 92 if _MACOS else 84
comptime EINPROGRESS: Int = 36 if _MACOS else 115
comptime EINTR: Int = 4
comptime EINVAL: Int = 22
comptime EIO: Int = 5
comptime EISCONN: Int = 56 if _MACOS else 106
comptime EISDIR: Int = 21
comptime ELOOP: Int = 62 if _MACOS else 40
comptime EMFILE: Int = 24
comptime EMLINK: Int = 31
comptime EMSGSIZE: Int = 40 if _MACOS else 90
comptime ENAMETOOLONG: Int = 63 if _MACOS else 36
comptime ENETDOWN: Int = 50 if _MACOS else 100
comptime ENETRESET: Int = 52 if _MACOS else 102
comptime ENETUNREACH: Int = 51 if _MACOS else 101
comptime ENFILE: Int = 23
comptime ENOBUFS: Int = 55 if _MACOS else 105
comptime ENODEV: Int = 19
comptime ENOENT: Int = 2
comptime ENOEXEC: Int = 8
comptime ENOLCK: Int = 77 if _MACOS else 37
comptime ENOMEM: Int = 12
comptime ENOPROTOOPT: Int = 42 if _MACOS else 92
comptime ENOSPC: Int = 28
comptime ENOSYS: Int = 78 if _MACOS else 38
comptime ENOTCONN: Int = 57 if _MACOS else 107
comptime ENOTDIR: Int = 20
comptime ENOTEMPTY: Int = 66 if _MACOS else 39
comptime ENOTRECOVERABLE: Int = 104 if _MACOS else 131
comptime ENOTSOCK: Int = 38 if _MACOS else 88
comptime ENOTSUP: Int = 45 if _MACOS else 95
comptime ENOTTY: Int = 25
comptime ENXIO: Int = 6
comptime EOPNOTSUPP: Int = 102 if _MACOS else 95
comptime EOVERFLOW: Int = 84 if _MACOS else 75
comptime EOWNERDEAD: Int = 105 if _MACOS else 130
comptime EPERM: Int = 1
comptime EPIPE: Int = 32
comptime EPROTONOSUPPORT: Int = 43 if _MACOS else 93
comptime EPROTOTYPE: Int = 41 if _MACOS else 91
comptime ERANGE: Int = 34
comptime EROFS: Int = 30
comptime ESHUTDOWN: Int = 58 if _MACOS else 108
comptime ESPIPE: Int = 29
comptime ESRCH: Int = 3
comptime ETIMEDOUT: Int = 60 if _MACOS else 110
comptime ETXTBSY: Int = 26
comptime EWOULDBLOCK: Int = 35 if _MACOS else 11
comptime EXDEV: Int = 18

# The signal table, which disagrees across platforms in the same way the errno
# table does, and which is not the same length on both.
comptime SIGABRT: Int = 6
comptime SIGALRM: Int = 14
comptime SIGBUS: Int = 10 if _MACOS else 7
comptime SIGCHLD: Int = 20 if _MACOS else 17
comptime SIGCONT: Int = 19 if _MACOS else 18
comptime SIGEMT: Int = 7 if _MACOS else ABSENT
comptime SIGFPE: Int = 8
comptime SIGHUP: Int = 1
comptime SIGILL: Int = 4
comptime SIGINFO: Int = 29 if _MACOS else ABSENT
comptime SIGINT: Int = 2
comptime SIGIO: Int = 23 if _MACOS else 29
comptime SIGKILL: Int = 9
comptime SIGPIPE: Int = 13
comptime SIGPROF: Int = 27
comptime SIGPWR: Int = ABSENT if _MACOS else 30
comptime SIGQUIT: Int = 3
comptime SIGSEGV: Int = 11
comptime SIGSTKFLT: Int = ABSENT if _MACOS else 16
comptime SIGSTOP: Int = 17 if _MACOS else 19
comptime SIGSYS: Int = 12 if _MACOS else 31
comptime SIGTERM: Int = 15
comptime SIGTRAP: Int = 5
comptime SIGTSTP: Int = 18 if _MACOS else 20
comptime SIGTTIN: Int = 21
comptime SIGTTOU: Int = 22
comptime SIGURG: Int = 16 if _MACOS else 23
comptime SIGUSR1: Int = 30 if _MACOS else 10
comptime SIGUSR2: Int = 31 if _MACOS else 12
comptime SIGVTALRM: Int = 26
comptime SIGWINCH: Int = 28
comptime SIGXCPU: Int = 24
comptime SIGXFSZ: Int = 25

# Socket address families and socket types.
comptime AF_INET: Int = 2
comptime AF_INET6: Int = 30 if _MACOS else 10
comptime AF_UNIX: Int = 1
comptime SOCK_DGRAM: Int = 2
comptime SOCK_STREAM: Int = 1

# The two length limits. `PATH_MAX` is 1024 on macOS and 4096 on Linux, so a
# buffer sized by the smaller one truncates paths the other platform accepts.
comptime NAME_MAX: Int = 255
comptime PATH_MAX: Int = 1024 if _MACOS else 4096
