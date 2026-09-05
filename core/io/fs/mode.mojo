"""A file's type and its permission bits in one value. Go's `fs.FileMode`.

The bits mean the same thing on every platform, which is the whole point of the
type: a mode read on one host and written on another describes the same file.
The type lives in the top thirteen bits and the ordinary Unix `rwxrwxrwx`
permissions in the bottom nine, and nothing in between is used.

That independence is why `_of_platform_mode` is a switch and not a mask.
`S_IFDIR` is `0o040000` on both platforms this library builds for, and reading
`st_mode` as though the type bits were already `FileMode` bits would be a
coincidence written down as a fact. The switch is what Go does and it is what
keeps `MODE_DIR` a fact about this library rather than about the host.
"""

from core.syscall import (
    S_IFBLK,
    S_IFCHR,
    S_IFDIR,
    S_IFIFO,
    S_IFLNK,
    S_IFMT,
    S_IFSOCK,
    S_ISGID,
    S_ISUID,
    S_ISVTX,
)

comptime _LETTERS = StaticString("dalTLDpSugct?")
"""One letter per type bit, most significant first. Go's `str` in `String`.

The order is the order of the constants below, so the letter for a bit is at
the index the shift counts down from. Changing either without the other writes
a mode string that names the wrong bit.
"""

comptime _RWX = StaticString("rwxrwxrwx")
"""The nine permission letters, owner then group then other."""


struct FileMode(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """What kind of file this is and who may do what to it.

    ```mojo
    from core.io.fs import MODE_DIR, FileMode

    print(FileMode(0o755) | MODE_DIR)  # => drwxr-xr-x
    print(FileMode(0o644))  # => -rw-r--r--
    ```

    A struct rather than a bare `UInt32` so that a permission number and a mode
    cannot be passed to each other's parameters, and so that `is_dir` reads as
    a question about the file rather than as arithmetic.
    """

    var value: UInt32
    """The bits, in Go's layout. Public because the layout is public API."""

    def __init__(out self, value: UInt32):
        """Hold a set of bits already in Go's layout.

        For a number that came out of a `struct stat`, this is the wrong door:
        `FileInfo` builds one through the switch in `_of_platform_mode`, which
        is the only thing that knows how to translate a platform's layout.
        """
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        """Whether these describe the same type and the same permissions."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether these differ in any bit."""
        return self.value != other.value

    def __or__(self, other: Self) -> Self:
        """Both sets of bits. How a mode is built out of the constants."""
        return Self(self.value | other.value)

    def __and__(self, other: Self) -> Self:
        """The bits in both. How a mode is masked down to a question."""
        return Self(self.value & other.value)

    def __invert__(self) -> Self:
        """Every bit this one does not have, for clearing a mask."""
        return Self(~self.value)

    def __bool__(self) -> Bool:
        """Whether any bit is set.

        So that `mode & MODE_TYPE` reads as a condition, which is the shape Go
        writes as `!= 0` and the shape `is_regular` is the negation of.
        """
        return self.value != 0

    def is_dir(self) -> Bool:
        """Whether this is a directory. Go's `IsDir`.

        ```mojo
        from core.io.fs import MODE_DIR, FileMode

        print((FileMode(0o755) | MODE_DIR).is_dir())  # => True
        ```
        """
        return self.value & MODE_DIR.value != 0

    def is_regular(self) -> Bool:
        """Whether this is an ordinary file. Go's `IsRegular`.

        Not a bit of its own: an ordinary file is one with no type bit set at
        all, which is why a file whose type nothing could work out carries
        `MODE_IRREGULAR` rather than nothing.

        ```mojo
        from core.io.fs import FileMode

        print(FileMode(0o644).is_regular())  # => True
        ```
        """
        return self.value & MODE_TYPE.value == 0

    def perm(self) -> Self:
        """Just the nine permission bits. Go's `Perm`.

        ```mojo
        from core.io.fs import MODE_DIR, FileMode

        print((FileMode(0o755) | MODE_DIR).perm())  # => -rwxr-xr-x
        ```
        """
        return self & MODE_PERM

    def type(self) -> Self:
        """Just the type bits. Go's `Type`.

        The set bits, not the kind as a number, so two files are the same kind
        when their types are equal and an ordinary file's type is empty.
        """
        return self & MODE_TYPE

    def string(self) -> String:
        """The `drwxr-xr-x` form `ls` writes. Go's `String`.

        A letter for every type bit that is set, in the order of the constants,
        then the nine permission letters with a dash for each bit that is not.
        A file with no type bit at all leads with a single dash, so the string
        is always at least ten characters and the permissions always start at
        the same column.

        ```mojo
        from core.io.fs import MODE_SETUID, FileMode

        print(FileMode(0o755).string())  # => -rwxr-xr-x
        print((FileMode(0o755) | MODE_SETUID).string())  # => urwxr-xr-x
        ```
        """
        var out = String()
        var letters = _LETTERS.as_bytes()
        for i in range(len(letters)):
            if self.value & (UInt32(1) << UInt32(32 - 1 - i)) != 0:
                out += chr(Int(letters[i]))
        if not out:
            out += "-"
        var rwx = _RWX.as_bytes()
        for i in range(9):
            if self.value & (UInt32(1) << UInt32(9 - 1 - i)) != 0:
                out += chr(Int(rwx[i]))
            else:
                out += "-"
        return out^

    def write_to[W: Writer](self, mut writer: W):
        """The same string, so `String(mode)` and a failing assertion agree."""
        writer.write(self.string())


comptime MODE_DIR = FileMode(UInt32(1) << 31)
"""`d`: a directory. The one bit every platform is required to report."""

comptime MODE_APPEND = FileMode(UInt32(1) << 30)
"""`a`: append only. Plan 9 sets this and neither platform here does."""

comptime MODE_EXCLUSIVE = FileMode(UInt32(1) << 29)
"""`l`: exclusive use. Plan 9 again."""

comptime MODE_TEMPORARY = FileMode(UInt32(1) << 28)
"""`T`: a temporary file. Plan 9 again."""

comptime MODE_SYMLINK = FileMode(UInt32(1) << 27)
"""`L`: a symbolic link. Only ever seen through `lstat`, since `stat` follows
the link and reports whatever is at the other end."""

comptime MODE_DEVICE = FileMode(UInt32(1) << 26)
"""`D`: a device. Set on its own for a block device and beside
`MODE_CHAR_DEVICE` for a character one."""

comptime MODE_NAMED_PIPE = FileMode(UInt32(1) << 25)
"""`p`: a named pipe, which is a FIFO in the file system."""

comptime MODE_SOCKET = FileMode(UInt32(1) << 24)
"""`S`: a unix domain socket."""

comptime MODE_SETUID = FileMode(UInt32(1) << 23)
"""`u`: run as the owner rather than as the caller."""

comptime MODE_SETGID = FileMode(UInt32(1) << 22)
"""`g`: run as the owning group rather than as the caller's."""

comptime MODE_CHAR_DEVICE = FileMode(UInt32(1) << 21)
"""`c`: a character device. Only meaningful with `MODE_DEVICE` beside it."""

comptime MODE_STICKY = FileMode(UInt32(1) << 20)
"""`t`: sticky. On a directory it means only an owner may delete their own
entries, which is what makes `/tmp` shareable."""

comptime MODE_IRREGULAR = FileMode(UInt32(1) << 19)
"""`?`: something else. The file is not ordinary and nothing more is known,
which is the answer for a kind this library has no constant for."""

comptime MODE_TYPE = (
    MODE_DIR
    | MODE_SYMLINK
    | MODE_NAMED_PIPE
    | MODE_SOCKET
    | MODE_DEVICE
    | MODE_CHAR_DEVICE
    | MODE_IRREGULAR
)
"""Every bit that says what kind of file this is.

The mask `type` applies. `MODE_APPEND`, `MODE_EXCLUSIVE`, `MODE_TEMPORARY`,
`MODE_SETUID`, `MODE_SETGID` and `MODE_STICKY` are not in it: they say how the
file behaves, not what it is, and a setuid program is still an ordinary file.
"""

comptime MODE_PERM = FileMode(0o777)
"""The nine `rwxrwxrwx` bits and nothing else.

Not `0o7777`. The set and sticky bits live in the top of a `FileMode` here even
though the platform keeps them in the low twelve of an `st_mode`, which is the
translation `of_platform_mode` does.
"""


def _of_platform_mode(st_mode: UInt32) -> FileMode:
    """A `struct stat`'s `st_mode` as a `FileMode`. Go's `fillFileStatFromSys`.

    ```mojo
    from core.io.fs.mode import _of_platform_mode

    print(_of_platform_mode(0o100644))  # => -rw-r--r--
    print(_of_platform_mode(0o040755))  # => drwxr-xr-x
    ```

    Private because Go's is: a caller reaches a mode through `FileInfo.mode`
    and never has an `st_mode` in their hands to translate. It is here rather
    than in `info.mojo` so that the switch sits next to the constants it names.

    The low nine bits carry across unchanged, because those nine mean the same
    thing in both layouts and always have. Everything above them is translated:
    the type through a switch on `S_IFMT`, and the set and sticky bits from the
    three the platform keeps just above the permissions to the three this type
    keeps at the top.

    A type the switch does not recognise produces no type bit, which reads as
    an ordinary file. That is Go's behaviour and it is the conservative answer:
    the alternative is `MODE_IRREGULAR`, which Go reserves for the file systems
    that can say a file is odd without saying how.
    """
    var out = FileMode(st_mode & 0o777)
    var kind = Int(st_mode) & S_IFMT
    if kind == S_IFBLK:
        out = out | MODE_DEVICE
    elif kind == S_IFCHR:
        out = out | MODE_DEVICE | MODE_CHAR_DEVICE
    elif kind == S_IFDIR:
        out = out | MODE_DIR
    elif kind == S_IFIFO:
        out = out | MODE_NAMED_PIPE
    elif kind == S_IFLNK:
        out = out | MODE_SYMLINK
    elif kind == S_IFSOCK:
        out = out | MODE_SOCKET
    # S_IFREG is the remaining case and sets nothing, which is what makes an
    # ordinary file the mode with no type bits.

    if Int(st_mode) & S_ISGID != 0:
        out = out | MODE_SETGID
    if Int(st_mode) & S_ISUID != 0:
        out = out | MODE_SETUID
    if Int(st_mode) & S_ISVTX != 0:
        out = out | MODE_STICKY
    return out
