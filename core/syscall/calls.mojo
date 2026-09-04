"""The calls themselves, each one raising what the platform said went wrong.

Go's `syscall` hands back `(n, err)` and leaves the checking to the caller.
There is no pair to hand back here, so every call raises instead, with the
number on the record under `errno` and the platform's own message as the text.
`errors.field(e, "errno")` gets the number back, and comparing it against a
constant from `abi.mojo` is how a caller decides what to do next.

A result that is not a failure still comes back as a value, so `read` gives the
count and `open` gives the descriptor. A short read is not an error here any
more than it is in C.

Nothing in this package retries on `EINTR`. That is a policy decision and this
is not the layer that gets to make it: a caller with a deadline wants to see
the interruption and a caller without one wants it swallowed, and only they
know which they are. `core.os` is where the retry loop goes.

Every path is copied into a zero terminated buffer before it crosses the
boundary, by `_cstr` below. That is a copy per call and it is not optional: a
Mojo `String` knows its own length and does not carry a terminator, so handing
`as_bytes().unsafe_ptr()` to C hands over the path followed by whatever else is
in the allocation. That is not a crash either, because a `String` built by
concatenation is very often sitting in a buffer that held a longer string a
moment ago, so the call gets the right path with the tail of an older one stuck
to the end of it and fails with a plausible errno for a path nobody wrote.

A path holding an interior zero is still cut short at it, because a C string
has no way not to be. That is the truncation Go rejects rather than passes on,
and rejecting it is `core.os`'s job for the same reason the retry loop is.

The integer widths are the ones in the C prototype, so a descriptor is an `int`
and a count is a `size_t`. `read` and `write` are the exception: Mojo's own
standard library declares both symbols with an index sized descriptor, and two
declarations of one symbol in a module do not link, so those two match it.

Two calls do not reach libc directly. `open` and `fcntl` are variadic in C, and
`external_call` emits a call of fixed arity, which is the wrong convention for
an anonymous argument on Apple silicon and the right one everywhere else. Both
go through a wrapper with a real prototype in `core/syscall/shim/varargs.c`,
whose README says why that file exists and what the alternatives were.
"""

from std.ffi import external_call

from core.errors import Report

from .abi import PATH_MAX
from .errno import Errno, errno, set_errno
from .stat import Stat

comptime Byte = UInt8
"""What a buffer is made of, spelled as `core.io` spells it."""


def _cstr(path: String) -> List[Byte]:
    """A path in a buffer C can read, terminator and all.

    The caller has to keep the buffer in a variable for as long as the call
    that reads it, which every call below does. Handing
    `_cstr(path).unsafe_ptr()` straight to `external_call` would give the
    pointer and then free what it points at.
    """
    var out = List[Byte](capacity=path.byte_length() + 1)
    for byte in path.as_bytes():
        out.append(byte)
    out.append(0)
    return out^


def _fail(operation: StaticString, failure: Errno) raises:
    """Raise what the platform said, with the number kept for a caller to read.

    The message is the operating system's own wording with the call in front of
    it, which is the shape Go's `os` package produces and the shape somebody
    reading a log expects. The number is a field rather than part of the text,
    because a caller deciding what to do next should never be parsing a
    sentence.
    """
    raise (
        Report(String(operation, ": ", failure.message()))
        .with_field("errno", String(failure.value))
        .with_field("op", String(operation))
        .error()
    )


def open(path: String, flags: Int, mode: Int) raises -> Int:
    """Open a file. Gives back the descriptor.

    Three arguments, as in Go, and the mode is required rather than defaulted
    even though it means writing a zero on every open that is not creating
    anything. A default here would be a zero that arrives silently, and a file
    created with mode zero is exactly the failure the shim below exists to
    prevent, so it should not be reachable by leaving an argument off.

    The call goes through `core_syscall_open3` rather than straight to `open`,
    because C's `open` is variadic and a variadic argument cannot be passed
    correctly from Mojo on Apple silicon. See `core/syscall/shim/README.md` and
    design section 11.

    The mode is what a created file gets after the process umask has been taken
    off it, exactly as in C, and it is ignored for an open that creates
    nothing.
    """
    var raw = _cstr(path)
    var fd = external_call["core_syscall_open3", Int32](
        raw.unsafe_ptr(), Int32(flags), UInt32(mode)
    )
    if fd < 0:
        _fail("open", errno())
    return Int(fd)


def create(path: String, mode: Int) raises -> Int:
    """Create or truncate a file for writing. Gives back the descriptor.

    This is C's `creat`, which is `open` with `O_CREAT | O_WRONLY | O_TRUNC`.
    Go has `syscall.Creat` for the same reason and this keeps it, though with
    `open` taking a mode there is nothing it can do that `open` cannot.
    """
    var raw = _cstr(path)
    var fd = external_call["creat", Int32](raw.unsafe_ptr(), Int32(mode))
    if fd < 0:
        _fail("create", errno())
    return Int(fd)


def fcntl(fd: Int, cmd: Int, arg: Int) raises -> Int:
    """Ask about or change a descriptor. Gives back whatever the command returns.

    Go's `syscall.FcntlInt`, and the same three arguments. A command that takes
    no argument, `F_GETFD` and `F_GETFL` among them, reads nothing and is
    passed a zero by convention.

    Like `open`, this goes through the shim rather than calling `fcntl`
    directly, because `fcntl` is variadic too. The commands that take a pointer
    are not reachable this way and none of them are bound; file locking is the
    one that will want them.
    """
    var got = external_call["core_syscall_fcntl", Int32](
        Int32(fd), Int32(cmd), Int32(arg)
    )
    if got < 0:
        _fail("fcntl", errno())
    return Int(got)


def close(fd: Int) raises:
    """Close a descriptor.

    A failing close has usually already lost the data, and closing again is not
    the fix: the descriptor is gone whatever the call returned, so a retry
    closes whatever took the number next.
    """
    if external_call["close", Int32](Int32(fd)) < 0:
        _fail("close", errno())


def read[o: Origin[mut=True]](fd: Int, into: Span[Byte, o]) raises -> Int:
    """Read into the span.

    Gives back how many bytes arrived, which may be fewer than the span holds
    and is zero at the end of the file. Zero is not an error here; turning it
    into `io.EOF` is `core.io`'s job.
    """
    var n = external_call["read", Int](Int(fd), into.unsafe_ptr(), len(into))
    if n < 0:
        _fail("read", errno())
    return n


def write[o: Origin](fd: Int, data: Span[Byte, o]) raises -> Int:
    """Write the span.

    Gives back how many bytes were accepted, which may be fewer than were
    offered. Looping until they are all gone is the caller's business.
    """
    var n = external_call["write", Int](Int(fd), data.unsafe_ptr(), len(data))
    if n < 0:
        _fail("write", errno())
    return n


def lseek(fd: Int, offset: Int, whence: Int) raises -> Int:
    """Move the file offset. Gives back where it ended up.

    Minus one is both the failure and a legal offset, so errno is cleared
    before the call and consulted after it. This is the one call in the package
    that needs that, and it is the reason `set_errno` is public.
    """
    set_errno(Errno(0))
    var place = external_call["lseek", Int](Int32(fd), offset, Int32(whence))
    if place == -1:
        var failure = errno()
        if failure:
            _fail("lseek", failure)
    return place


def fstat(fd: Int) raises -> Stat:
    """What the platform says about an open descriptor."""
    var out = Stat()
    if external_call["fstat", Int32](Int32(fd), Pointer(to=out.raw[0])) < 0:
        _fail("fstat", errno())
    return out^


def stat(path: String) raises -> Stat:
    """What the platform says about a path, following symbolic links."""
    var out = Stat()
    var raw = _cstr(path)
    var failed = external_call["stat", Int32](
        raw.unsafe_ptr(), Pointer(to=out.raw[0])
    )
    if failed < 0:
        _fail("stat", errno())
    return out^


def lstat(path: String) raises -> Stat:
    """What the platform says about a path, not following the last link.

    This is the one that can report `is_symlink`, because `stat` follows the
    link and describes whatever is on the other end of it.
    """
    var out = Stat()
    var raw = _cstr(path)
    var failed = external_call["lstat", Int32](
        raw.unsafe_ptr(), Pointer(to=out.raw[0])
    )
    if failed < 0:
        _fail("lstat", errno())
    return out^


def ftruncate(fd: Int, size: Int) raises:
    """Set the length of an open file, growing it with zeros if need be."""
    if external_call["ftruncate", Int32](Int32(fd), size) < 0:
        _fail("ftruncate", errno())


def fsync(fd: Int) raises:
    """Push everything written to this descriptor out towards the device.

    On macOS this is weaker than it sounds. `fsync` gets the data to the drive
    and does not make the drive commit it, and `fcntl` with `F_FULLFSYNC` is
    what does. That needs the variadic call from issue #139, so the stronger
    form is not here yet and this paragraph is the warning.
    """
    if external_call["fsync", Int32](Int32(fd)) < 0:
        _fail("fsync", errno())


def dup(fd: Int) raises -> Int:
    """Copy a descriptor onto the lowest free number. Gives back the new one."""
    var made = external_call["dup", Int32](Int32(fd))
    if made < 0:
        _fail("dup", errno())
    return Int(made)


def mkdir(path: String, mode: Int) raises:
    """Make a directory, with the mode the umask leaves of it."""
    var raw = _cstr(path)
    var failed = external_call["mkdir", Int32](raw.unsafe_ptr(), Int32(mode))
    if failed < 0:
        _fail("mkdir", errno())


def rmdir(path: String) raises:
    """Remove a directory, which has to be empty."""
    var raw = _cstr(path)
    if external_call["rmdir", Int32](raw.unsafe_ptr()) < 0:
        _fail("rmdir", errno())


def unlink(path: String) raises:
    """Remove a name.

    The file itself goes when its last name and its last open descriptor are
    both gone, which is what makes a temporary file that nobody can see
    possible.
    """
    var raw = _cstr(path)
    if external_call["unlink", Int32](raw.unsafe_ptr()) < 0:
        _fail("unlink", errno())


def unlinkat(dirfd: Int, path: String, flags: Int) raises:
    """Remove a name relative to an open directory.

    `AT_FDCWD` for `dirfd` means the process working directory, and
    `AT_REMOVEDIR` in `flags` makes this an `rmdir` instead. It is here because
    the `*at` family is how a directory walk avoids re-resolving a path that
    something else may have moved underneath it.
    """
    var raw = _cstr(path)
    var failed = external_call["unlinkat", Int32](
        Int32(dirfd), raw.unsafe_ptr(), Int32(flags)
    )
    if failed < 0:
        _fail("unlinkat", errno())


def rename(from_path: String, to_path: String) raises:
    """Move a name, replacing whatever was at the destination."""
    var raw_from = _cstr(from_path)
    var raw_to = _cstr(to_path)
    var failed = external_call["rename", Int32](
        raw_from.unsafe_ptr(), raw_to.unsafe_ptr()
    )
    if failed < 0:
        _fail("rename", errno())


def link(existing: String, made: String) raises:
    """Make a second name for a file that already has one."""
    var raw_existing = _cstr(existing)
    var raw_made = _cstr(made)
    var failed = external_call["link", Int32](
        raw_existing.unsafe_ptr(), raw_made.unsafe_ptr()
    )
    if failed < 0:
        _fail("link", errno())


def symlink(target: String, made: String) raises:
    """Make a symbolic link holding the given text.

    The target is never resolved and does not have to exist, which is why the
    argument order reads backwards next to `link`. It is C's order, and Go's.
    """
    var raw_target = _cstr(target)
    var raw_made = _cstr(made)
    var failed = external_call["symlink", Int32](
        raw_target.unsafe_ptr(), raw_made.unsafe_ptr()
    )
    if failed < 0:
        _fail("symlink", errno())


def readlink(path: String) raises -> String:
    """The text a symbolic link holds.

    `readlink` neither terminates its answer nor says when the buffer was too
    small, so the buffer is `PATH_MAX` and an answer that fills it exactly is
    reported as a failure rather than handed back truncated. Go does the same,
    and a truncated path is worse than no path.
    """
    var room = Array[Byte, PATH_MAX](fill=0)
    var raw = _cstr(path)
    var n = external_call["readlink", Int](
        raw.unsafe_ptr(), Pointer(to=room[0]), Int(PATH_MAX)
    )
    if n < 0:
        _fail("readlink", errno())
    if n == PATH_MAX:
        raise Report(
            String(
                "readlink: the link is at least ",
                PATH_MAX,
                " bytes long and there is no way to ask how much longer",
            )
        ).error()
    var out = String()
    for i in range(n):
        out += chr(Int(room[i]))
    return out


def getcwd() raises -> String:
    """The process working directory."""
    var room = Array[Byte, PATH_MAX](fill=0)
    var got = external_call["getcwd", Int](Pointer(to=room[0]), Int(PATH_MAX))
    if got == 0:
        _fail("getcwd", errno())
    var out = String()
    for i in range(PATH_MAX):
        if room[i] == 0:
            break
        out += chr(Int(room[i]))
    return out


def chdir(path: String) raises:
    """Move the process working directory.

    Process wide, so it is not a thing to do from one thread while another is
    resolving a relative path. The `*at` family exists to avoid needing it.
    """
    var raw = _cstr(path)
    if external_call["chdir", Int32](raw.unsafe_ptr()) < 0:
        _fail("chdir", errno())


def chmod(path: String, mode: Int) raises:
    """Set the permission bits on a path. The umask does not apply."""
    var raw = _cstr(path)
    var failed = external_call["chmod", Int32](raw.unsafe_ptr(), Int32(mode))
    if failed < 0:
        _fail("chmod", errno())


def fchmod(fd: Int, mode: Int) raises:
    """Set the permission bits on an open descriptor."""
    if external_call["fchmod", Int32](Int32(fd), Int32(mode)) < 0:
        _fail("fchmod", errno())


def getpid() -> Int:
    """This process. It cannot fail, which is why it does not raise."""
    return Int(external_call["getpid", Int32]())
