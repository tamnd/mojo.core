"""An open file, and the four ways to get one. Go's `os.File`.

This is the first type in the library that owns something the kernel handed
over, and the rules it settles are the ones every later owner of a descriptor
follows.

It closes itself. Go leaves that to a finalizer, which runs at some point after
the garbage collector notices, or never; here the destructor runs at the last
use of the value and calls `close`. What a destructor cannot do is raise, so
the error from that close has nowhere to go, and a caller who wrote to the file
still has to call `close` and look at what it says. A write that reached the
kernel has not reached the disk, and `close` is where a full file system or a
failing device is finally reported. The automatic close is there so that a file
opened for reading, or a file on an error path, does not leak a descriptor.

The descriptor is closed once. `close` sets the field to a value no descriptor
has, so a second `close` raises `ErrClosed` rather than closing whatever number
the kernel handed out next, and the destructor after an explicit close does
nothing.

Every method here goes through the `core.io` traits, which is the point of
having written them. A `File` is a `Reader`, a `Writer`, a `Seeker`, a
`Closer`, a `ReaderAt`, a `WriterAt` and a `StringWriter`, so `core.bufio`,
`core.io.copy` and everything else built on those traits works over a real file
with no adapter in between.

Two things this package does that `core.syscall` deliberately does not. It
retries a call interrupted by a signal, because `core/syscall/calls.mojo` says
in its own documentation that the retry policy belongs to whoever knows whether
the caller wanted to see the interruption, and a `File` without a deadline does
not. And it refuses a path with a zero byte in it, because a C string ends at
the first zero and a truncated path names a different file; the layer below
cannot refuse it without deciding policy either.
"""

from core.errors import Code, Report
from core.errors.codes import EOF, ErrClosed, ErrInvalid, ErrUnexpectedEOF
from core.io import (
    Byte,
    Closer,
    Reader as IoReader,
    ReaderAt,
    Seeker,
    StringWriter,
    Writer as IoWriter,
    WriterAt,
)
from core.io.fs import FileInfo, FileMode, MODE_PERM, MODE_SETGID, MODE_SETUID
from core.io.fs import MODE_STICKY
from core.io.fs.errors import _errno_of, _path_error_from
from core.syscall import (
    EINTR,
    F_GETFL,
    O_APPEND,
    O_CREAT,
    O_RDONLY,
    O_RDWR,
    O_TRUNC,
    S_ISGID,
    S_ISUID,
    S_ISVTX,
    Stat,
)
from core.syscall import close as _sys_close
from core.syscall import fchdir as _sys_fchdir
from core.syscall import fchmod as _sys_fchmod
from core.syscall import fcntl as _sys_fcntl
from core.syscall import fstat as _sys_fstat
from core.syscall import fsync as _sys_fsync
from core.syscall import ftruncate as _sys_ftruncate
from core.syscall import lseek as _sys_lseek
from core.syscall import open as _sys_open
from core.syscall import pread as _sys_pread
from core.syscall import pwrite as _sys_pwrite
from core.syscall import read
from core.syscall import write as _sys_write

# Every one of those carries a `_sys_` prefix because this file declares its
# own `open` and `create` and calling the platform's would otherwise be a
# question of which one the reader thinks is meant. `read` is the exception,
# imported under its own name, because `read` is an argument convention
# keyword and `import read as` does not parse.

comptime _CLOSED = -1
"""What `_fd` holds once the descriptor is gone. No real one is negative."""


def _refused[
    o: ImmOrigin
](
    op: StringSlice[ImmStaticOrigin],
    path: StringSlice[o],
    why: StringSlice[ImmStaticOrigin],
    code: Code,
) -> Error:
    """A failure this package decided on, before any call reached the kernel.

    There are two: a file that is already closed and a path this library will
    not pass down. Neither has an errno, because neither of them asked the
    platform anything, so neither carries the `errno` field and `PathError.of`
    is empty for both. That is the honest answer rather than an omission: a
    `PathError` here holds the number the platform left behind, and there is no
    number. `matches(e, ErrClosed)` and `errors.field(e, "path")` both work,
    which is what a caller actually asks.

    The wording is Go's, `file already closed` and `invalid argument`, because
    it is the message a person recognises from a Go program that did the same
    thing.
    """
    return (
        Report(String(op) + " " + String(path) + ": " + String(why))
        .with_code(code)
        .with_field("op", String(op))
        .with_field("path", String(path))
        .error()
    )


def _closed[
    o: ImmOrigin
](op: StringSlice[ImmStaticOrigin], path: StringSlice[o]) -> Error:
    """The raise for a method called on a file that has already been closed."""
    return _refused(op, path, "file already closed", ErrClosed)


def _interrupted(e: Error) -> Bool:
    """Whether a signal arrived before the call did anything. `EINTR`.

    A call that was interrupted having already moved bytes returns the count
    instead, so this only ever answers about a call that did nothing, and
    retrying it is always safe.
    """
    return _errno_of(e).value == EINTR


def _has_nul[o: ImmOrigin](path: StringSlice[o]) -> Bool:
    """Whether the path holds a zero byte, which no file name can."""
    for byte in path.as_bytes():
        if byte == 0:
            return True
    return False


def _syscall_mode(perm: FileMode) -> Int:
    """A `FileMode` as the mode word `open` and `chmod` take. Go's `syscallMode`.

    The nine permission bits are the same nine numbers on both sides, and the
    three that are not, setuid, setgid and sticky, sit in the type half of a
    `FileMode` and in the top of the platform's mode word. Everything else in
    the type half describes what a file is rather than what may be done to it
    and has no place in a mode argument, so it is dropped.
    """
    var out = Int(perm.perm().value)
    if perm & MODE_SETUID:
        out |= S_ISUID
    if perm & MODE_SETGID:
        out |= S_ISGID
    if perm & MODE_STICKY:
        out |= S_ISVTX
    return out


struct File(
    Closer,
    IoReader,
    IoWriter,
    Movable,
    ReaderAt,
    Seeker,
    StringWriter,
    WriterAt,
):
    """One open file. Go's `os.File`.

    ```mojo
    from core.io import read_all
    from core.os import open

    def main():
        var f = open("/etc/hosts")
        var text = read_all(f)
        f.close()
        print(len(text))
    ```

    Not `Copyable`. Two copies would hold one descriptor and the first of them
    to be destroyed would close the file underneath the other, so the type that
    owns a kernel resource is moved rather than copied, exactly as
    `bufio.Writer` is for a much cheaper reason.
    """

    var _fd: Int
    """The descriptor, or `_CLOSED` once it has been given back."""

    var _name: String
    """The name it was opened with, unchanged. Go keeps this too."""

    var _append: Bool
    """Whether it was opened with `O_APPEND`, which `write_at` has to refuse."""

    var _owns: Bool
    """Whether the destructor closes it.

    True for every file this package opens. False for the three standard
    streams, which name descriptors the process was given and did not open.
    """

    def __init__(out self, fd: Int, var name: String, append: Bool, owns: Bool):
        """Take a descriptor. Private; `new_file` is the public door."""
        self._fd = fd
        self._name = name^
        self._append = append
        self._owns = owns

    def __deinit__(deinit self):
        """Close the descriptor if this file still owns one.

        The error is dropped, because a destructor has nobody to raise to.
        `close` is the method that reports it, and any file that was written to
        should be closed explicitly for that reason.

        This runs at the last use of the value rather than at the end of the
        enclosing scope, which is what Mojo does with every value and is
        earlier than Go's `defer` would be. A file read to the end and then not
        mentioned again is already closed by the next statement.
        """
        if self._owns and self._fd != _CLOSED:
            try:
                _sys_close(self._fd)
            except:
                pass

    def fd(self) -> Int:
        """The descriptor underneath. Go's `Fd`.

        Still owned by this file. Handing it to something that closes it leaves
        this file holding a number the kernel has given to somebody else.
        """
        return self._fd

    def name(self) -> String:
        """The name this file was opened with. Go's `Name`.

        Whatever the caller passed, not a cleaned or absolute version of it,
        and it is the path that appears in every error this file raises.
        """
        return self._name

    def close(mut self) raises:
        """Give the descriptor back. Go's `Close`.

        The one method a caller who wrote to the file must not skip. Bytes
        accepted by `write` have reached the kernel and not the disk, and a
        full file system or a failing device is reported here, at the last
        moment anything can be reported at all.

        Raises `ErrClosed` on a file that is already closed, which is Go's
        behaviour, and the descriptor is marked gone before the call, so a
        close that fails does not leave a number this file would try again.
        """
        if self._fd == _CLOSED:
            raise _closed("close", self._name)
        var fd = self._fd
        self._fd = _CLOSED
        try:
            _sys_close(fd)
        except e:
            raise _path_error_from("close", self._name, e)

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """Read into `into` and return how many bytes arrived. Go's `Read`.

        Raises `EOF` at the end of the file, having moved nothing, which is the
        `core.io` rule. A short read is not the end and not an error: a pipe
        hands over what it has, and a caller who needs the span filled wants
        `core.io.read_full`.

        Reading into an empty span returns zero without asking the kernel
        anything, so it cannot be used to test for the end.
        """
        if self._fd == _CLOSED:
            raise _closed("read", self._name)
        if len(into) == 0:
            return 0
        var n = 0
        while True:
            try:
                n = read(self._fd, into)
                break
            except e:
                if _interrupted(e):
                    continue
                raise _path_error_from("read", self._name, e)
        if n == 0:
            raise Report("read " + self._name + ": end of input").with_code(
                EOF
            ).error()
        return n

    def read_at[
        o: Origin[mut=True]
    ](self, into: Span[Byte, o], offset: Int64) raises -> Int:
        """Read at `offset` without moving the file offset. Go's `ReadAt`.

        Fills the span or reaches the end, so a short result means the end and
        raises `EOF` with the count on `errors.partial`. That is the `ReaderAt`
        contract here and Go's, and it is why this loops where `read` does not.

        The file offset is untouched, so this and `read` can be used on one
        file without either disturbing the other, and two of these may run at
        once.
        """
        if self._fd == _CLOSED:
            raise _closed("read", self._name)
        if offset < 0:
            raise _refused("readat", self._name, "negative offset", ErrInvalid)
        var moved = 0
        var at = Int(offset)
        while moved < len(into):
            var n = 0
            try:
                n = _sys_pread(self._fd, into[moved:], at)
            except e:
                if _interrupted(e):
                    continue
                raise _path_error_from("read", self._name, e)
            if n == 0:
                raise (
                    Report("read " + self._name + ": end of input")
                    .with_code(EOF)
                    .with_count(moved)
                    .error()
                )
            moved += n
            at += n
        return moved

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        """Write all of `data` and return how much went. Go's `Write`.

        Loops until everything has been accepted, which is what Go's does and
        what the `Writer` contract here requires: a write that accepted less
        than it was given has to raise, with the count on `errors.partial`.

        A kernel that accepts nothing and reports no failure would loop
        forever, so that case raises `ErrUnexpectedEOF`, the same sentinel Go
        uses for it.
        """
        if self._fd == _CLOSED:
            raise _closed("write", self._name)
        var moved = 0
        while moved < len(data):
            var n = 0
            try:
                n = _sys_write(self._fd, data[moved:])
            except e:
                if _interrupted(e):
                    continue
                raise _path_error_from("write", self._name, e, moved)
            if n == 0:
                raise (
                    Report("write " + self._name + ": nothing was accepted")
                    .with_code(ErrUnexpectedEOF)
                    .with_count(moved)
                    .error()
                )
            moved += n
        return moved

    def write_at[
        o: Origin
    ](mut self, data: Span[Byte, o], offset: Int64) raises -> Int:
        """Write `data` at `offset`, leaving the file offset alone. Go's `WriteAt`.

        Refused on a file opened with `O_APPEND`, because Linux ignores the
        offset on such a descriptor and appends instead, so the call would
        quietly write somewhere other than where it was told to. Go refuses it
        for the same reason.
        """
        if self._fd == _CLOSED:
            raise _closed("write", self._name)
        if self._append:
            raise _refused(
                "writeat",
                self._name,
                "invalid use of write_at on a file opened with O_APPEND",
                ErrInvalid,
            )
        if offset < 0:
            raise _refused("writeat", self._name, "negative offset", ErrInvalid)
        var moved = 0
        var at = Int(offset)
        while moved < len(data):
            var n = 0
            try:
                n = _sys_pwrite(self._fd, data[moved:], at)
            except e:
                if _interrupted(e):
                    continue
                raise _path_error_from("write", self._name, e, moved)
            if n == 0:
                raise (
                    Report("write " + self._name + ": nothing was accepted")
                    .with_code(ErrUnexpectedEOF)
                    .with_count(moved)
                    .error()
                )
            moved += n
            at += n
        return moved

    def write_string(mut self, s: String) raises -> Int:
        """Write a string and return how many bytes went. Go's `WriteString`.

        The bytes of the string as they already are. Nothing is copied and
        nothing is validated: a `String` holds UTF-8 and a file holds bytes.
        """
        return self.write(s.as_bytes())

    def seek(mut self, offset: Int64, whence: Int) raises -> Int64:
        """Move the file offset and return where it ended up. Go's `Seek`.

        `whence` is `core.io.SEEK_START`, `SEEK_CURRENT` or `SEEK_END`, which
        are the platform's three numbers. Seeking past the end is allowed and
        writing there leaves a hole, exactly as it does in C.
        """
        if self._fd == _CLOSED:
            raise _closed("seek", self._name)
        try:
            return Int64(_sys_lseek(self._fd, Int(offset), whence))
        except e:
            raise _path_error_from("seek", self._name, e)

    def stat(self) raises -> FileInfo:
        """What the host says about this open file. Go's `Stat`.

        `fstat` on the descriptor, not a second `stat` on the name, so the
        answer is about the file this value holds and not about whatever
        happens to hold that name now. On a file that has been unlinked, which
        has no name any more, this still answers.
        """
        if self._fd == _CLOSED:
            raise _closed("stat", self._name)
        var got = Stat()
        try:
            got = _sys_fstat(self._fd)
        except e:
            raise _path_error_from("stat", self._name, e)
        return FileInfo(path=self._name, stat=got)

    def sync(self) raises:
        """Push what has been written out towards the device. Go's `Sync`.

        `fsync`, and on macOS that is weaker than it sounds: it gets the data
        to the drive and does not make the drive commit it, which needs `fcntl`
        with `F_FULLFSYNC`. Go reaches for that constant here and this does not
        yet; `core/syscall/calls.mojo` carries the same warning over `fsync`.
        """
        if self._fd == _CLOSED:
            raise _closed("sync", self._name)
        try:
            _sys_fsync(self._fd)
        except e:
            raise _path_error_from("sync", self._name, e)

    def truncate(self, size: Int64) raises:
        """Set the length of the file. Go's `Truncate`.

        Growing it adds zeros without allocating anything, and shrinking it
        throws the tail away. The file offset does not move, so a truncate to
        something shorter than the current position leaves the position past
        the end, which is allowed.
        """
        if self._fd == _CLOSED:
            raise _closed("truncate", self._name)
        try:
            _sys_ftruncate(self._fd, Int(size))
        except e:
            raise _path_error_from("truncate", self._name, e)

    def chmod(self, mode: FileMode) raises:
        """Set the permission bits. Go's `Chmod`.

        On the descriptor rather than on the name, so it cannot land on a
        different file than the one this value holds. The umask does not apply
        to a mode set this way, unlike the one passed to `open_file`.
        """
        if self._fd == _CLOSED:
            raise _closed("chmod", self._name)
        try:
            _sys_fchmod(self._fd, _syscall_mode(mode))
        except e:
            raise _path_error_from("chmod", self._name, e)

    def chdir(self) raises:
        """Make this directory the process working directory. Go's `Chdir`.

        Process wide, so it changes what every relative path in the program
        means, including in threads that were in the middle of resolving one.
        It is here because Go has it; a program that wants a directory to
        resolve names against wants to hold the directory instead.
        """
        if self._fd == _CLOSED:
            raise _closed("chdir", self._name)
        try:
            _sys_fchdir(self._fd)
        except e:
            raise _path_error_from("chdir", self._name, e)

    def capabilities(self) -> Int:
        """Neither fast path, for now.

        `write_to` and `read_from` on a file want `sendfile` on Linux and
        `copy_file_range` where it exists, which is the only way either would
        beat a copy through the caller's buffer. Neither is bound yet, so
        offering the methods would mean advertising a fast path that is not
        one. Issue #168 says so and issue #28 carries the rest.
        """
        return 0


def new_file(fd: Int, var name: String) raises -> File:
    """Take ownership of a descriptor the caller already has. Go's `NewFile`.

    The file closes this descriptor when it is destroyed, so the caller is
    handing it over rather than lending it. A descriptor that came from
    `core.syscall.open`, from a library, or from a process that inherited it is
    what this is for.

    Raises when `fd` is not an open descriptor, which is Go's nil return. The
    check is `fcntl` with `F_GETFL`, and the same call reports whether the
    descriptor is in append mode, which `write_at` needs to know and cannot ask
    later.
    """
    var flags = 0
    try:
        flags = _sys_fcntl(fd, F_GETFL, 0)
    except e:
        raise _path_error_from("fcntl", name, e)
    return File(fd, name^, (flags & O_APPEND) != 0, True)


def open_file(var name: String, flag: Int, perm: FileMode) raises -> File:
    """Open a file with the flags and mode spelled out. Go's `OpenFile`.

    The general one, of which `open` and `create` are the two common cases.
    `flag` is `O_RDONLY`, `O_WRONLY` or `O_RDWR`, one of them, with any of
    `O_APPEND`, `O_CREATE`, `O_EXCL`, `O_SYNC` and `O_TRUNC` added to it.

    `perm` is what a created file gets, and only a created file: it is ignored
    when nothing is created, and what survives of it is what the process umask
    leaves, which is why a test that asserts a mode sets it with `chmod`
    afterwards.

    ```mojo
    from core.io.fs import FileMode
    from core.os import O_CREATE, O_EXCL, O_WRONLY, open_file

    def main():
        var f = open_file("/tmp/note", O_WRONLY | O_CREATE | O_EXCL, FileMode(0o600))
        _ = f.write_string("hello\\n")
        f.close()
    ```

    A name with a zero byte in it raises `ErrInvalid` and no call is made. The
    layer below would pass the part before the zero to the kernel, because a C
    string cannot do anything else, and open a file the caller did not name.
    """
    if _has_nul(name):
        raise _refused("open", name, "invalid argument", ErrInvalid)
    var fd = 0
    try:
        fd = _sys_open(name, flag, _syscall_mode(perm))
    except e:
        raise _path_error_from("open", name, e)
    return File(fd, name^, (flag & O_APPEND) != 0, True)


def open(var name: String) raises -> File:
    """Open a file for reading. Go's `Open`.

    `open_file(name, O_RDONLY, FileMode(0))`, which is the call nine out of ten
    readers want.
    """
    return open_file(name^, O_RDONLY, FileMode(0))


def create(var name: String) raises -> File:
    """Create a file, or empty an existing one, for reading and writing.
    Go's `Create`.

    `open_file(name, O_RDWR | O_CREATE | O_TRUNC, FileMode(0o666))`. The mode
    is Go's, and the umask takes bits out of it, so the file usually lands at
    `0o644`. It truncates without asking, which is the trap in the name: a
    caller who wants to fail rather than overwrite wants `O_EXCL`.
    """
    return open_file(name^, O_RDWR | O_CREAT | O_TRUNC, FileMode(0o666))


def stdin() -> File:
    """Descriptor zero, where input arrives. Go's `Stdin`.

    A function rather than a variable, because there are no package level
    variables here. The `File` it returns does not own the descriptor, so
    dropping it does not close it: a helper that took a temporary `stdout()`
    and closed descriptor one on the way out would end the program's output for
    reasons nothing in the source would explain. Go never faces the question,
    since its three are globals that are never collected.

    This names descriptor zero whether or not anything is open on it, exactly
    as Go's does.
    """
    return File(0, String("/dev/stdin"), False, False)


def stdout() -> File:
    """Descriptor one, where output goes. Go's `Stdout`.

    Does not own the descriptor. See `stdin`.
    """
    return File(1, String("/dev/stdout"), False, False)


def stderr() -> File:
    """Descriptor two, where complaints go. Go's `Stderr`.

    Does not own the descriptor. See `stdin`.
    """
    return File(2, String("/dev/stderr"), False, False)
