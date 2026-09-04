"""One directory entry, read out of the platform's own `struct dirent`.

Same reasoning as `stat.mojo`, and the same machinery. The structure is 1048
bytes on macOS and 280 on Linux, `d_type` is at offset 20 there and 18 here,
and macOS has a `d_namlen` that Linux does not, so a layout typed from one
platform's headers reads a neighbouring field on the other and returns a
plausible answer. The offsets come from `core/syscall/baseline/*.json` by way
of `abi.mojo`.

Unlike `Stat`, this does not keep the bytes. A `struct stat` is written into a
buffer the caller owns and lives as long as the caller wants it to. A directory
entry is a pointer into memory the C library owns and reuses on the next call,
so the fields are copied out while the pointer is still good and the pointer
itself never leaves `readdir`.
"""

from .abi import (
    DT_BLK,
    DT_CHR,
    DT_DIR,
    DT_FIFO,
    DT_LNK,
    DT_REG,
    DT_SOCK,
    DT_UNKNOWN,
    OFFSET_DIRENT_D_INO,
    OFFSET_DIRENT_D_NAME,
    OFFSET_DIRENT_D_TYPE,
    SIZEOF_DIRENT,
    SIZEOF_INO_T,
)

comptime _Foreign = AnyOrigin[mut=False]
"""What a pointer into the C library's own memory is borrowed from.

There is no origin that says "somebody else owns this and will reuse it", so
the entry is read through this and copied out at once, and the pointer does not
leave the constructor below.
"""

comptime _TYPE_WIDTH = OFFSET_DIRENT_D_NAME - OFFSET_DIRENT_D_TYPE
"""How wide `d_type` is.

Derived rather than recorded, the way `stat.mojo` derives the width of
`tv_nsec`. `d_name` is the field immediately after `d_type` on all three
platforms, so the distance between them is the size of the one in front. It
comes out as one byte everywhere, which is what `unsigned char` should be, but
saying so directly would be a coincidence written down as a fact.
"""

comptime _NAME_ROOM = SIZEOF_DIRENT - OFFSET_DIRENT_D_NAME
"""The most a name field can hold, which is 1027 here and 261 on Linux.

Only a guard. `d_name` is a zero terminated string by POSIX and the scan in
`readdir` stops at the terminator, which is always inside the entry the library
handed back. The entry can be shorter than the whole structure, so reading this
many bytes unconditionally would run off the end of somebody else's buffer, and
the number is here to bound a loop that should never reach it rather than to
size a copy.
"""


struct Dirent(Copyable, Movable, Writable):
    """One entry in a directory, with the fields copied out of the C library's.

    Build one with `readdir` in this package. Nothing here borrows: the name is
    a `String` this owns, because the buffer it was read from belongs to the C
    library and is reused by the next call.
    """

    var ino: UInt64
    """The inode number, unique on the device the directory is on.

    Zero on a Linux entry that has been deleted while the directory was open,
    which is the one case Go's `os` package throws entries away for.
    """

    var kind: Int
    """What the entry is: one of the `DT_` constants.

    `kind` rather than `type`, which is close enough to a Mojo keyword to be
    worth avoiding, and rather than `mode`, which is the other numbering. The
    `DT_` values are not the `S_IF` values and one cannot be compared against
    the other: `DT_DIR` is 4 and `S_IFDIR` is 16384.

    This is often `DT_UNKNOWN`, and that is not an error. Several file systems,
    XFS and some network ones among them, do not carry the type in the
    directory and expect a caller who needs it to `lstat` the entry. There are
    deliberately no `is_dir`-style helpers here, because every one of them
    would have to answer False for a directory on such a file system, which is
    a wrong answer that looks like a right one. Deciding to fall back to
    `lstat` is `core.os`'s job, and it is what Go's `os.DirEntry` does.
    """

    var name: String
    """The entry's name, with no directory in front of it.

    `.` and `..` are entries like any other and are handed back. Skipping them
    is a policy this layer does not have, and Go skips them in `os` rather than
    in `syscall` for the same reason.
    """

    def __init__(out self, ino: UInt64, kind: Int, var name: String):
        """Hold what one entry said."""
        self.ino = ino
        self.kind = kind
        self.name = name^

    def __init__(out self, *, unsafe_from_address: Int):
        """Copy the fields out of a `struct dirent` at this address.

        The address has to be one `readdir` in this package just returned and
        nothing else, which is why the argument is spelled the way it is and
        why this lives here rather than being written out at the call site.
        Reading a structure at an address is what the whole package does, and
        it belongs next to the offsets it is done with.

        A byte at a time and little endian first, for the reasons `Stat`
        gives: the offsets are not all aligned for the width of the field
        there, and every platform this library supports is little endian.
        """
        var raw = Pointer[UInt8, _Foreign](
            unsafe_from_address=unsafe_from_address
        )

        self.ino = 0
        for i in range(SIZEOF_INO_T):
            self.ino |= UInt64(
                raw[unsafe_offset=OFFSET_DIRENT_D_INO + i]
            ) << UInt64(8 * i)

        self.kind = 0
        for i in range(_TYPE_WIDTH):
            self.kind |= Int(raw[unsafe_offset=OFFSET_DIRENT_D_TYPE + i]) << (
                8 * i
            )

        self.name = String()
        for i in range(_NAME_ROOM):
            var byte = raw[unsafe_offset=OFFSET_DIRENT_D_NAME + i]
            if byte == 0:
                break
            self.name += chr(Int(byte))

    def write_to[W: Writer](self, mut writer: W):
        """The name and the type, for a failing assertion to name."""
        writer.write(self.name)
        writer.write(" (")
        writer.write(_kind_name(self.kind))
        writer.write(")")


def _kind_name(kind: Int) -> StaticString:
    """The `DT_` constant's own spelling, for a message.

    A number in a failing assertion says nothing, and `DT_UNKNOWN` in one says
    the whole story: the file system did not carry the type and the caller
    needs to ask for it.
    """
    if kind == DT_REG:
        return "DT_REG"
    if kind == DT_DIR:
        return "DT_DIR"
    if kind == DT_LNK:
        return "DT_LNK"
    if kind == DT_FIFO:
        return "DT_FIFO"
    if kind == DT_SOCK:
        return "DT_SOCK"
    if kind == DT_BLK:
        return "DT_BLK"
    if kind == DT_CHR:
        return "DT_CHR"
    if kind == DT_UNKNOWN:
        return "DT_UNKNOWN"
    return "an unrecorded DT value"
