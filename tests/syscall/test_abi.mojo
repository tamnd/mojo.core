"""The generated constants, checked for the mistakes generation can still make.

`pixi run baseline` already compares every recorded number against the host's
own headers, and `pixi run generated-check` already fails if `abi.mojo` has
drifted from the recordings. So there is no point asserting a value here: that
would be a fourth copy of the same number and the one nobody re-records.

What is worth asserting is the shape. A generator that picked the wrong branch
of a ternary, or emitted `ABSENT` where a real value belongs, or gave two
different constants the same number, produces a file that passes both of those
checks and is still wrong. These are the relationships between the constants
that hold on every platform, which is what a generator can break and a
recording cannot.
"""

from std.testing import assert_equal, assert_not_equal, assert_true

from core.syscall import (
    ABSENT,
    AT_FDCWD,
    EAGAIN,
    EDEADLK,
    ENOENT,
    EWOULDBLOCK,
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
    O_TRUNC,
    O_WRONLY,
    PATH_MAX,
    S_IFBLK,
    S_IFCHR,
    S_IFDIR,
    S_IFIFO,
    S_IFLNK,
    S_IFMT,
    S_IFREG,
    S_IFSOCK,
    SEEK_CUR,
    SEEK_END,
    SEEK_SET,
    SIGINT,
    SIGKILL,
    SIGSEGV,
    SIGTERM,
)
from core.syscall.abi import (
    OFFSET_STAT_ST_MODE,
    OFFSET_STAT_ST_SIZE,
    SIZEOF_MODE_T,
    SIZEOF_OFF_T,
    SIZEOF_STAT,
    SIZEOF_TIMESPEC,
)


def test_nothing_needed_here_is_absent() raises:
    # ABSENT is what the generator emits for a constant one platform does not
    # define, and a caller reading one by accident gets a number that is not a
    # plausible anything. None of these is allowed to be one.
    var required = [
        O_RDONLY,
        O_WRONLY,
        O_RDWR,
        O_CREAT,
        O_TRUNC,
        O_APPEND,
        O_EXCL,
        O_NONBLOCK,
        O_CLOEXEC,
        O_DIRECTORY,
        O_NOFOLLOW,
        S_IFMT,
        S_IFREG,
        S_IFDIR,
        S_IFLNK,
        SEEK_SET,
        SEEK_CUR,
        SEEK_END,
        ENOENT,
        PATH_MAX,
        SIGINT,
        SIGKILL,
        SIGTERM,
        SIGSEGV,
    ]
    for value in required:
        assert_not_equal(value, ABSENT)


def test_the_access_modes_are_the_three_the_mask_holds() raises:
    assert_equal(O_RDONLY, 0)
    assert_equal(O_WRONLY, 1)
    assert_equal(O_RDWR, 2)
    assert_equal(O_ACCMODE, 3)
    assert_equal(O_RDWR & O_ACCMODE, O_RDWR)


def test_the_open_flags_are_distinct_bits() raises:
    # Every one of these is a single bit and no two of them are the same bit.
    # A generator that picked the macOS value for one and the Linux value for
    # its neighbour produces a pair that overlaps, and the call then does two
    # things or neither.
    var flags = [
        O_CREAT,
        O_TRUNC,
        O_APPEND,
        O_EXCL,
        O_NONBLOCK,
        O_DIRECTORY,
        O_NOFOLLOW,
    ]
    for value in flags:
        assert_true(value != 0)
        assert_equal(value & (value - 1), 0)
    for i in range(len(flags)):
        for j in range(i + 1, len(flags)):
            assert_equal(flags[i] & flags[j], 0)


def test_the_seek_constants_are_the_three_posix_gives() raises:
    assert_equal(SEEK_SET, 0)
    assert_equal(SEEK_CUR, 1)
    assert_equal(SEEK_END, 2)


def test_the_file_types_all_fit_inside_the_mask() raises:
    # S_IFMT is 0o170000 everywhere and every type is a value inside it. A
    # type read from the wrong platform's headers is either outside the mask or
    # equal to another one, and both make a predicate answer about the wrong
    # kind of file.
    var types = [S_IFREG, S_IFDIR, S_IFLNK, S_IFIFO, S_IFSOCK, S_IFBLK, S_IFCHR]
    for value in types:
        assert_equal(value & S_IFMT, value)
    for i in range(len(types)):
        for j in range(i + 1, len(types)):
            assert_not_equal(types[i], types[j])


def test_at_fdcwd_is_negative() raises:
    # It has to be, because it shares a namespace with real descriptors, which
    # are never negative. macOS and Linux picked different negative numbers.
    assert_true(AT_FDCWD < 0)


def test_eagain_and_ewouldblock_are_the_same_number() raises:
    # They are on both platforms, and code that checks only one of them is
    # correct because of it. EDEADLK is here because it is the trap: it is 11
    # on macOS and 35 on Linux, exactly the two numbers EAGAIN takes, swapped.
    assert_equal(EAGAIN, EWOULDBLOCK)
    assert_not_equal(EAGAIN, EDEADLK)


def test_the_layout_facts_hold_together() raises:
    # Sizes and offsets are in `core.syscall.abi` rather than re-exported, so
    # this is the one file that imports them. Every field has to fit inside the
    # structure it is in, which is the check that catches a size taken from one
    # platform and an offset from another.
    assert_true(SIZEOF_STAT > 0)
    assert_true(OFFSET_STAT_ST_MODE + SIZEOF_MODE_T <= SIZEOF_STAT)
    assert_true(OFFSET_STAT_ST_SIZE + SIZEOF_OFF_T <= SIZEOF_STAT)
    assert_equal(SIZEOF_OFF_T, 8)
    assert_true(SIZEOF_TIMESPEC >= 16)
