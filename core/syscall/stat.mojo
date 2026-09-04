"""What the platform says about a file, read out of its own `struct stat`.

Go declares `syscall.Stat_t` per platform in generated code and lets the
compiler lay it out. There is no way to declare a C structure in Mojo and be
sure the layout matches, so this keeps the bytes exactly as the kernel wrote
them and reads a field at the offset the platform's headers reported.

That indirection is the point rather than a workaround. `struct stat` is 144
bytes on macOS and on Linux x86-64 and 128 on Linux arm64, with `st_mode` at
offset 4, 24 and 16 respectively, and `st_size` at 96 on macOS and 48 on both
Linux architectures. A structure typed by hand from one platform's headers
compiles everywhere and reads a neighbouring field on the other two, which is
not a crash, it is a plausible number. The offsets here come from
`core/syscall/baseline/*.json`, which `pixi run baseline` compares against the
host's own headers on all three platforms on every run.

The widths come from the same place. `mode_t` is two bytes on macOS and four on
Linux, and `nlink_t` is two, eight and four across the three, so even a
correctly placed field read at the wrong width picks up part of the next one.
"""

from .abi import (
    OFFSET_STAT_ST_ATIM,
    OFFSET_STAT_ST_BLKSIZE,
    OFFSET_STAT_ST_BLOCKS,
    OFFSET_STAT_ST_CTIM,
    OFFSET_STAT_ST_DEV,
    OFFSET_STAT_ST_GID,
    OFFSET_STAT_ST_INO,
    OFFSET_STAT_ST_MODE,
    OFFSET_STAT_ST_MTIM,
    OFFSET_STAT_ST_NLINK,
    OFFSET_STAT_ST_RDEV,
    OFFSET_STAT_ST_SIZE,
    OFFSET_STAT_ST_UID,
    OFFSET_TIMESPEC_TV_NSEC,
    OFFSET_TIMESPEC_TV_SEC,
    S_IFBLK,
    S_IFCHR,
    S_IFDIR,
    S_IFIFO,
    S_IFLNK,
    S_IFMT,
    S_IFREG,
    S_IFSOCK,
    SIZEOF_BLKCNT_T,
    SIZEOF_BLKSIZE_T,
    SIZEOF_DEV_T,
    SIZEOF_GID_T,
    SIZEOF_INO_T,
    SIZEOF_MODE_T,
    SIZEOF_NLINK_T,
    SIZEOF_OFF_T,
    SIZEOF_STAT,
    SIZEOF_TIME_T,
    SIZEOF_TIMESPEC,
    SIZEOF_UID_T,
)


comptime _NSEC_WIDTH = SIZEOF_TIMESPEC - OFFSET_TIMESPEC_TV_NSEC
"""How wide the nanosecond field is.

`tv_nsec` is a `long` rather than a `time_t`, and while the two happen to be
the same size on all three platforms, saying so would be a coincidence written
down as a fact. What the baseline does record is where the field starts and how
big the whole structure is, and the field is the last one in it.
"""


def _unsigned[
    o: Origin
](raw: Span[UInt8, o], offset: Int, width: Int) -> UInt64:
    """`width` bytes at `offset`, least significant first.

    Byte at a time rather than through a cast, for two reasons. The offsets the
    platform reports are not all aligned for the width of the field there, and
    a misaligned load is undefined rather than merely slow. And every platform
    this library supports is little endian, so assembling the number here is
    the same work the cast would have done.
    """
    var out = UInt64(0)
    for i in range(width):
        out |= UInt64(raw[offset + i]) << UInt64(8 * i)
    return out


def _signed[o: Origin](raw: Span[UInt8, o], offset: Int, width: Int) -> Int:
    """The same, for a field whose C type is signed.

    `off_t`, `time_t` and `blkcnt_t` are all signed, and a size or a timestamp
    that came back negative is a real answer worth being able to see rather
    than an enormous positive one.

    A field narrower than the machine word has its sign bit spread over the
    rest by hand. One the same width needs nothing done to it, and must not
    have this arithmetic applied, because the mask it would need does not fit
    in the type the mask is built in.
    """
    var out = _unsigned(raw, offset, width)
    if width < 8 and out & (UInt64(1) << UInt64(8 * width - 1)) != 0:
        out |= ~UInt64(0) << UInt64(8 * width)
    return Int(out)


struct Timespec(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """A time, as the file system keeps it: whole seconds and nanoseconds."""

    var sec: Int
    """Seconds since the epoch. Signed, because a file can be older than it."""

    var nsec: Int
    """Nanoseconds within the second, always zero or more."""

    def __init__(out self, sec: Int, nsec: Int):
        """Hold a time the platform gave us."""
        self.sec = sec
        self.nsec = nsec

    def __init__[o: Origin](out self, *, platform_bytes: Span[UInt8, o]):
        """Read one out of a `struct timespec` the platform filled in.

        For a buffer that holds nothing but the structure, which is what a
        clock reading is. The three inside a `struct stat` are read by `Stat`
        instead, because there the structure is at an offset in a larger one
        and the whole point of `Stat` is that nothing outside it knows where.
        """
        self.sec = _signed(
            platform_bytes, OFFSET_TIMESPEC_TV_SEC, SIZEOF_TIME_T
        )
        self.nsec = _signed(
            platform_bytes, OFFSET_TIMESPEC_TV_NSEC, _NSEC_WIDTH
        )

    def __eq__(self, other: Self) -> Bool:
        """Whether these are the same instant."""
        return self.sec == other.sec and self.nsec == other.nsec

    def __ne__(self, other: Self) -> Bool:
        """Whether these are different instants."""
        return not (self == other)

    def write_to[W: Writer](self, mut writer: W):
        """Seconds and nanoseconds, for a failing assertion to name."""
        writer.write(self.sec)
        writer.write(".")
        writer.write(self.nsec)


struct Stat(Copyable, Movable):
    """One file's `struct stat`, kept as bytes and read through the baseline.

    Build one with `stat`, `lstat` or `fstat` in this package. The accessors
    are the only supported way in: the buffer is the platform's business and
    its size and shape change under you.
    """

    var raw: Array[UInt8, SIZEOF_STAT]
    """The bytes the kernel wrote, untouched.

    Public because a package that binds a call taking a `struct stat` needs to
    hand its address over, and there is nothing to hide: reading it any way
    other than through the accessors needs the same offsets they use.
    """

    def __init__(out self):
        """Room for a `struct stat`, zeroed.

        Zeroed rather than left alone so that a failed call leaves a buffer
        that reads as zeros rather than as whatever was on the stack, which is
        the difference between an obviously empty answer and a believable one.
        """
        self.raw = Array[UInt8, SIZEOF_STAT](fill=0)

    def _unsigned(self, offset: Int, width: Int) -> UInt64:
        """`width` bytes of this buffer at `offset`, unsigned."""
        return _unsigned(Span(self.raw), offset, width)

    def _signed(self, offset: Int, width: Int) -> Int:
        """`width` bytes of this buffer at `offset`, signed."""
        return _signed(Span(self.raw), offset, width)

    def _time(self, offset: Int) -> Timespec:
        """The `struct timespec` at `offset`.

        The three timestamps are a nested structure rather than a pair of
        fields, and macOS calls them `st_atimespec` where POSIX calls them
        `st_atim`. The probe records both under the POSIX name, so there is one
        name here.
        """
        return Timespec(
            self._signed(offset + OFFSET_TIMESPEC_TV_SEC, SIZEOF_TIME_T),
            self._signed(offset + OFFSET_TIMESPEC_TV_NSEC, _NSEC_WIDTH),
        )

    def dev(self) -> UInt64:
        """The device the file is on."""
        return self._unsigned(OFFSET_STAT_ST_DEV, SIZEOF_DEV_T)

    def ino(self) -> UInt64:
        """The inode number, unique on that device."""
        return self._unsigned(OFFSET_STAT_ST_INO, SIZEOF_INO_T)

    def mode(self) -> UInt32:
        """The type and the permission bits together.

        Mask with `S_IFMT` for the type, or use `is_dir` and its siblings. The
        low twelve bits are the permissions and the set and sticky bits.
        """
        return UInt32(self._unsigned(OFFSET_STAT_ST_MODE, SIZEOF_MODE_T))

    def nlink(self) -> UInt64:
        """How many directory entries point at this file."""
        return self._unsigned(OFFSET_STAT_ST_NLINK, SIZEOF_NLINK_T)

    def uid(self) -> UInt32:
        """The owner."""
        return UInt32(self._unsigned(OFFSET_STAT_ST_UID, SIZEOF_UID_T))

    def gid(self) -> UInt32:
        """The owning group."""
        return UInt32(self._unsigned(OFFSET_STAT_ST_GID, SIZEOF_GID_T))

    def rdev(self) -> UInt64:
        """The device this file *is*, for a block or character device."""
        return self._unsigned(OFFSET_STAT_ST_RDEV, SIZEOF_DEV_T)

    def size(self) -> Int:
        """The length in bytes, or for a symlink the length of its target."""
        return self._signed(OFFSET_STAT_ST_SIZE, SIZEOF_OFF_T)

    def blksize(self) -> Int:
        """The block size the file system would rather be read in."""
        return self._signed(OFFSET_STAT_ST_BLKSIZE, SIZEOF_BLKSIZE_T)

    def blocks(self) -> Int:
        """How many 512 byte blocks are actually allocated.

        Five hundred and twelve regardless of what `blksize` says, on both
        platforms. A sparse file has fewer of these than its size implies.
        """
        return self._signed(OFFSET_STAT_ST_BLOCKS, SIZEOF_BLKCNT_T)

    def atime(self) -> Timespec:
        """When the contents were last read."""
        return self._time(OFFSET_STAT_ST_ATIM)

    def mtime(self) -> Timespec:
        """When the contents were last written."""
        return self._time(OFFSET_STAT_ST_MTIM)

    def ctime(self) -> Timespec:
        """When the inode was last changed.

        Not the creation time, on either platform. A chmod moves this and
        leaves `mtime` alone. macOS does record a creation time and Linux does
        not, which is why it is not here.
        """
        return self._time(OFFSET_STAT_ST_CTIM)

    def is_dir(self) -> Bool:
        """Whether this is a directory."""
        return self.mode() & UInt32(S_IFMT) == UInt32(S_IFDIR)

    def is_regular(self) -> Bool:
        """Whether this is an ordinary file."""
        return self.mode() & UInt32(S_IFMT) == UInt32(S_IFREG)

    def is_symlink(self) -> Bool:
        """Whether this is a symbolic link.

        Only ever true from `lstat`. `stat` follows the link and reports what
        is at the other end.
        """
        return self.mode() & UInt32(S_IFMT) == UInt32(S_IFLNK)

    def is_fifo(self) -> Bool:
        """Whether this is a named pipe."""
        return self.mode() & UInt32(S_IFMT) == UInt32(S_IFIFO)

    def is_socket(self) -> Bool:
        """Whether this is a unix domain socket."""
        return self.mode() & UInt32(S_IFMT) == UInt32(S_IFSOCK)

    def is_block_device(self) -> Bool:
        """Whether this is a block device."""
        return self.mode() & UInt32(S_IFMT) == UInt32(S_IFBLK)

    def is_char_device(self) -> Bool:
        """Whether this is a character device."""
        return self.mode() & UInt32(S_IFMT) == UInt32(S_IFCHR)

    def permissions(self) -> UInt32:
        """The mode with the type taken off, which is what chmod sets."""
        return self.mode() & 0o7777
