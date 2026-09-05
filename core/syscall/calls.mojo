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

Three calls do not reach libc directly. `open`, `openat` and `fcntl` are
variadic in C, and `external_call` emits a call of fixed arity, which is the
wrong convention for an anonymous argument on Apple silicon and the right one
everywhere else. All three go through a wrapper with a real prototype in
`core/syscall/shim/varargs.c`, whose README says why that file exists and what
the alternatives were.
"""

from std.ffi import external_call
from std.sys import CompilationTarget

from core.errors import Report

from .abi import PATH_MAX, SIZEOF_TIMESPEC
from .dir import Dirent, _Foreign
from .errno import Errno, errno, set_errno
from .stat import Stat, Timespec

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


def openat(dirfd: Int, path: String, flags: Int, mode: Int) raises -> Int:
    """Open a name relative to an already open directory. Gives the descriptor.

    `AT_FDCWD` for `dirfd` means the process working directory and makes this
    `open`. Anything else means the name is resolved inside that directory and
    nowhere else, which is what a walk wants: a path resolved a second time can
    name something else by then, and on a shared machine that is not a
    theoretical worry.

    Goes through the same shim `open` does, and for the same reason.
    """
    var raw = _cstr(path)
    var fd = external_call["core_syscall_openat4", Int32](
        Int32(dirfd), raw.unsafe_ptr(), Int32(flags), UInt32(mode)
    )
    if fd < 0:
        _fail("openat", errno())
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


def pread[
    o: Origin[mut=True]
](fd: Int, into: Span[Byte, o], offset: Int) raises -> Int:
    """Read into the span from a stated offset, leaving the file offset alone.

    Gives back how many bytes arrived, zero at the end of the file, and may be
    fewer than the span holds exactly as `read` may. The descriptor's own
    offset is not consulted and not moved, which is what makes this the call to
    build `io.ReaderAt` on: two readers can share one descriptor and neither
    disturbs the other.

    A pipe, a socket or a terminal has no offset to read from and fails with
    `ESPIPE`.
    """
    var n = external_call["pread", Int](
        Int32(fd), into.unsafe_ptr(), len(into), offset
    )
    if n < 0:
        _fail("pread", errno())
    return n


def pwrite[o: Origin](fd: Int, data: Span[Byte, o], offset: Int) raises -> Int:
    """Write the span at a stated offset, leaving the file offset alone.

    The counterpart of `pread` and the same caveats: a short write is not an
    error, and a descriptor with no offset fails with `ESPIPE`.

    A descriptor opened with `O_APPEND` ignores the offset on Linux and writes
    at the end anyway, which POSIX allows and Go documents rather than works
    around. `core.os` says the same thing in `File.write_at` and refuses the
    call instead, because a write that lands somewhere other than where it was
    asked to is worse than one that does not happen.
    """
    var n = external_call["pwrite", Int](
        Int32(fd), data.unsafe_ptr(), len(data), offset
    )
    if n < 0:
        _fail("pwrite", errno())
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


def truncate(path: String, size: Int) raises:
    """Set the length of a file named by path, growing it with zeros if need be.

    The same call as `ftruncate` against a name rather than a descriptor, and
    it opens nothing, so it works on a file the caller has no right to open for
    writing but does have the right to shorten. Growing a file this way leaves
    a hole rather than blocks, exactly as a write past the end does.
    """
    var raw = _cstr(path)
    if external_call["truncate", Int32](raw.unsafe_ptr(), size) < 0:
        _fail("truncate", errno())


def chown(path: String, uid: Int, gid: Int) raises:
    """Set the owner and the group of a path. Follows a symbolic link.

    `-1` for either one leaves it alone, which is how the platform says change
    one and not the other, and it is why these are signed here even though the
    ids themselves are not. An ordinary user can only give a file to the owner
    it already has, so anything else is `EPERM` for everybody but root.
    """
    var raw = _cstr(path)
    var failed = external_call["chown", Int32](
        raw.unsafe_ptr(), Int32(uid), Int32(gid)
    )
    if failed < 0:
        _fail("chown", errno())


def lchown(path: String, uid: Int, gid: Int) raises:
    """Set the owner and the group of a path, on the link rather than through it.

    The `lstat` of `chown`. A symbolic link has an owner of its own, and it is
    what decides who may remove the link out of a sticky directory, so the two
    calls are not interchangeable even though the link's own permissions mean
    nothing.
    """
    var raw = _cstr(path)
    var failed = external_call["lchown", Int32](
        raw.unsafe_ptr(), Int32(uid), Int32(gid)
    )
    if failed < 0:
        _fail("lchown", errno())


def fchown(fd: Int, uid: Int, gid: Int) raises:
    """Set the owner and the group of an already open file."""
    var failed = external_call["fchown", Int32](
        Int32(fd), Int32(uid), Int32(gid)
    )
    if failed < 0:
        _fail("fchown", errno())


def fsync(fd: Int) raises:
    """Push everything written to this descriptor out towards the device.

    On macOS this is weaker than it sounds. `fsync` gets the data to the drive
    and does not make the drive commit it, and `fcntl` with `F_FULLFSYNC` is
    what does. `fcntl` is bound now, and `F_FULLFSYNC` is not recorded in the
    baseline, because it exists on macOS alone and nothing has asked for it
    yet. Go reaches for it in `os.File.Sync`, so `core.os` is where that gets
    recorded and used, and until then this paragraph is the warning.
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


def opendir(path: String) raises -> Int:
    """Start reading a directory. Gives back a handle to close later.

    The handle is C's `DIR *` as a plain integer, because Mojo's pointers
    cannot be null and cannot carry an origin that means "the C library owns
    this". Nothing here reads through it: it goes back to `readdir` and
    `closedir` and nowhere else. Passing anything that did not come out of here
    is undefined behaviour in C and will be undefined behaviour here.

    This is `opendir` rather than Go's `Getdents`, which reads raw entries out
    of a descriptor with a different name and a different structure on each
    platform. `opendir`, `readdir` and `closedir` are the same three functions
    on all three of ours, and this library is already linking libc.

    Owning the handle is `core.os`'s job. Nothing at this layer closes anything
    for you, exactly as nothing closes a descriptor from `open`.
    """
    var raw = _cstr(path)
    var handle = external_call["opendir", Int](raw.unsafe_ptr())
    if handle == 0:
        _fail("opendir", errno())
    return handle


def fdopendir(fd: Int) raises -> Int:
    """Start reading the directory an open descriptor already names.

    The same handle `opendir` gives back, from a descriptor rather than from a
    path, which is how a caller who already holds a directory reads it without
    resolving its name a second time and getting whatever holds that name now.

    The handle takes the descriptor over. `closedir` closes it, so a caller who
    wants to keep using the descriptor afterwards passes a `dup` of it in and
    keeps the original, which is what `core.os.File` does.

    The descriptor has to have been opened for reading and has to be a
    directory. Anything else fails with `ENOTDIR` or `EBADF`.
    """
    var handle = external_call["fdopendir", Int](Int32(fd))
    if handle == 0:
        _fail("fdopendir", errno())
    return handle


def readdir(dir: Int) raises -> Optional[Dirent]:
    """The next entry, or nothing at the end of the directory.

    Nothing and a failure are the same return value in C, a null pointer, and
    the only thing telling them apart is errno, so it is cleared before the
    call and read after it. That is the same dance `lseek` does and the second
    reason `set_errno` is public.

    The fields are copied out before this returns. The entry C hands back
    points into a buffer the library owns and reuses on the next call, so a
    `Dirent` that borrowed it would be pointing at the following entry by the
    time anybody looked.

    Every entry is handed back, `.` and `..` included, and `kind` is often
    `DT_UNKNOWN`. Both are the platform's answers and filtering them is a
    policy this layer does not have.
    """
    set_errno(Errno(0))
    var entry = external_call["readdir", Int](dir)
    if entry == 0:
        var failure = errno()
        if failure:
            _fail("readdir", failure)
        return None
    return Dirent(unsafe_from_address=entry)


def closedir(dir: Int) raises:
    """Finish with a directory handle.

    The handle is unusable afterwards whether this succeeded or not, which is
    the same rule `close` follows and for the same reason: the resource is gone
    and calling again reaches whatever took its place.
    """
    if external_call["closedir", Int32](dir) < 0:
        _fail("closedir", errno())


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


def fchdir(fd: Int) raises:
    """Move the process working directory to an already open directory.

    Process wide in the same way `chdir` is. What it buys over `chdir` is that
    the destination is the directory the caller already holds rather than a
    name that has to be resolved again, so nothing can have moved underneath it
    in between.
    """
    if external_call["fchdir", Int32](Int32(fd)) < 0:
        _fail("fchdir", errno())


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


def utimensat(
    dirfd: Int, path: String, atime: Timespec, mtime: Timespec, flags: Int
) raises:
    """Set the access and modification times on a path.

    `atime` is the first time and `mtime` the second, in that order, because
    that is the order the C array is in and swapping them is a mistake nothing
    would report. A nanosecond field of `UTIME_OMIT` leaves that one timestamp
    alone and `UTIME_NOW` sets it to the clock, and those two are the only
    values outside the range zero to a billion that are not an error.

    `dirfd` is `AT_FDCWD` for a path resolved from the working directory, and
    `flags` is `AT_SYMLINK_NOFOLLOW` to set the times on a symlink itself
    rather than on what it points at.
    """
    var raw = _cstr(path)
    var times = List[Byte](length=2 * SIZEOF_TIMESPEC, fill=0)
    atime.platform_bytes(Span(times), 0)
    mtime.platform_bytes(Span(times), SIZEOF_TIMESPEC)
    var failed = external_call["utimensat", Int32](
        Int32(dirfd), raw.unsafe_ptr(), times.unsafe_ptr(), Int32(flags)
    )
    if failed < 0:
        _fail("utimensat", errno())


def getpid() -> Int:
    """This process. It cannot fail, which is why it does not raise."""
    return Int(external_call["getpid", Int32]())


def getppid() -> Int:
    """The process that started this one. Cannot fail.

    The answer changes underneath a program: when the parent exits first, the
    child is handed to init and this starts saying 1. So it is a fact about
    right now rather than about how the program was started, and code that
    wants to know who started it has to ask before the parent can go away.
    """
    return Int(external_call["getppid", Int32]())


def getuid() -> Int:
    """The real user id, which is who started the program. Cannot fail."""
    return Int(external_call["getuid", UInt32]())


def geteuid() -> Int:
    """The effective user id, which is whose permissions apply. Cannot fail.

    The two differ on a set-user-id program, where the real id is the person
    at the keyboard and the effective id is the owner of the file. A check
    about whether something can be opened wants this one, and even then the
    honest way to find out is to open it and read the failure.
    """
    return Int(external_call["geteuid", UInt32]())


def getgid() -> Int:
    """The real group id. Cannot fail. See `getuid`."""
    return Int(external_call["getgid", UInt32]())


def getegid() -> Int:
    """The effective group id. Cannot fail. See `geteuid`."""
    return Int(external_call["getegid", UInt32]())


def getgroups() raises -> List[Int]:
    """Every group this process belongs to. Go's `syscall.Getgroups`.

    Asked twice, because there is no fixed size to ask with: the limit is 16 on
    macOS and 65,536 on Linux, and a buffer sized for either is the wrong size
    on the other. The first call passes a size of zero, which POSIX defines as
    a request for the count and leaves the buffer alone, and the second asks
    for that many.

    Whether the effective group id is in the list is the platform's business
    and not the same answer everywhere, so a caller that wants to know about it
    should ask `getegid` rather than search this.
    """
    var ignored = Array[UInt32, 1](fill=0)
    var count = external_call["getgroups", Int32](
        Int32(0), Pointer(to=ignored[0])
    )
    if count < 0:
        _fail("getgroups", errno())
    var out = List[Int]()
    if count == 0:
        return out^
    var room = List[UInt32](capacity=Int(count))
    for _ in range(Int(count)):
        room.append(0)
    var got = external_call["getgroups", Int32](count, room.unsafe_ptr())
    if got < 0:
        _fail("getgroups", errno())
    for i in range(Int(got)):
        out.append(Int(room[i]))
    return out^


def getpagesize() -> Int:
    """How many bytes the kernel maps at a time. Cannot fail.

    4,096 on Linux x86-64 and 16,384 on Apple silicon, and neither number is
    worth writing down anywhere, which is why this is a call rather than a
    constant in `abi.mojo`: the same binary runs on machines that disagree.
    """
    return Int(external_call["getpagesize", Int32]())


comptime _HOSTNAME_ROOM: Int = 512
"""How much room `gethostname` is given.

Not a number out of a header, which is why it is here and not in `abi.mojo`.
Linux caps a host name at 64 bytes and macOS at 255, so anything at or above
256 is enough on every host in the matrix, and this is doubled again because
the cost of the extra bytes is a stack frame nobody will notice and the cost of
being wrong is a truncated name that looks real.
"""


def gethostname() raises -> String:
    """The name this machine calls itself.

    Not in Go's `syscall` on every platform, which is why `os.Hostname` is the
    one worth reaching for. It is a name the machine was configured with rather
    than anything the network agrees on, so it is not a way to find an address
    and is not promised to be unique outside one administrator's idea of it.

    A name too long for the buffer is reported rather than handed back short,
    because the platforms disagree about whether truncation is an error and
    about whether what they wrote is even terminated.
    """
    var room = Array[Byte, _HOSTNAME_ROOM](fill=0)
    var failed = external_call["gethostname", Int32](
        Pointer(to=room[0]), Int(_HOSTNAME_ROOM)
    )
    if failed < 0:
        _fail("gethostname", errno())
    var out = String()
    var ended = False
    for i in range(_HOSTNAME_ROOM):
        if room[i] == 0:
            ended = True
            break
        out += chr(Int(room[i]))
    if not ended:
        raise Report(
            String(
                "gethostname: the name fills all ",
                _HOSTNAME_ROOM,
                " bytes and there is no way to ask how much longer it is",
            )
        ).error()
    return out


def pipe() raises -> Tuple[Int, Int]:
    """A pipe. Gives back the read end and then the write end, in that order.

    Go's `syscall.Pipe` fills a two element array and this returns the pair,
    because the array form only exists in C to work around C not having one.

    Both ends are ordinary descriptors and both have to be closed. The one that
    catches everybody is that a reader sees the end of the pipe only when every
    copy of the write end is closed, including the copy a forked child still
    holds and the copy the writer forgot it kept.
    """
    var ends = Array[Int32, 2](fill=0)
    if external_call["pipe", Int32](Pointer(to=ends[0])) < 0:
        _fail("pipe", errno())
    return (Int(ends[0]), Int(ends[1]))


def exit(code: Int):
    """End the process now. Go's `syscall.Exit`. Does not return.

    This is C's `_exit` rather than its `exit`, so no `atexit` handler runs and
    nothing buffered in C's own standard library is flushed. That is what Go
    does and it is the right end of the choice: a library ending a process
    should not be running teardown that some other library registered.

    Nothing on the Mojo side is cleaned up either. No destructor runs, so a
    `File` holding an unwritten buffer loses it. A program that has written
    something closes it and returns from `main`, and calls this only when there
    is a status to report and nothing left to save.
    """
    external_call["_exit", NoneType](Int32(code))


def _ns_get_executable_path() raises -> String:
    """What macOS says this program was loaded from. Not a system call.

    `_NSGetExecutablePath` is in libSystem and has no Go counterpart, which is
    why the name is private: `core.os.executable` is the public way to ask, and
    it is the one that knows Linux answers the same question by reading a link
    in `/proc`. The buffer sizing is here because a buffer is a C problem.

    The path is whatever the loader was handed. It can be relative, it can hold
    `..` and it can name a symbolic link, and none of that is fixed up here.

    The whole body is behind a `comptime if`, so on Linux there is no reference
    to the symbol left to link against. A caller there gets the raise, and the
    only caller there is is `core.os.executable`, which reads `/proc/self/exe`
    on that platform and never comes here.
    """
    comptime if not CompilationTarget.is_macos():
        raise Report(
            "executable: _NSGetExecutablePath is a macOS function and this is"
            " not macOS"
        ).error()
    var room = Array[Byte, PATH_MAX](fill=0)
    var room_size = UInt32(PATH_MAX)
    var failed = external_call["_NSGetExecutablePath", Int32](
        Pointer(to=room[0]), Pointer(to=room_size)
    )
    if failed != 0:
        raise Report(
            String(
                "executable: the path is ",
                room_size,
                " bytes long, which is more than this platform's own limit of ",
                PATH_MAX,
            )
        ).error()
    var out = String()
    for i in range(PATH_MAX):
        if room[i] == 0:
            break
        out += chr(Int(room[i]))
    return out


def getenv(name: String) -> Optional[String]:
    """The value of an environment variable, or nothing if it is not set.

    Go's `syscall.Getenv`, which reports the same two cases with a second
    return value. A variable set to the empty string is set, and telling that
    apart from unset is the whole reason this is an `Optional` rather than a
    `String` that comes back empty either way: `TZ=""` means UTC and no `TZ` at
    all means the host's own zone.

    The environment is process wide and libc reuses one buffer per name, so the
    value is copied out before this returns, exactly as `readdir` copies an
    entry out. Nothing here locks: a program calling `setenv` from one thread
    while another reads is a data race in C and stays one here.
    """
    var raw = _cstr(name)
    var value = external_call["getenv", Int](raw.unsafe_ptr())
    if value == 0:
        return None
    return _from_cstr(value)


def setenv(name: String, value: String) raises:
    """Set an environment variable, replacing any value it already had.

    Go's `syscall.Setenv`. Process wide and not thread safe, which is C's rule
    and not one this layer can improve on: the strings libc hands out of
    `getenv` are the ones this overwrites.
    """
    var raw_name = _cstr(name)
    var raw_value = _cstr(value)
    var failed = external_call["setenv", Int32](
        raw_name.unsafe_ptr(), raw_value.unsafe_ptr(), Int32(1)
    )
    if failed < 0:
        _fail("setenv", errno())


def unsetenv(name: String) raises:
    """Remove an environment variable. Go's `syscall.Unsetenv`.

    Removing one that was never there succeeds, which is what C does and what
    makes this safe to call in a test's cleanup without checking first.
    """
    var raw = _cstr(name)
    if external_call["unsetenv", Int32](raw.unsafe_ptr()) < 0:
        _fail("unsetenv", errno())


def environ() -> List[String]:
    """Every variable in the environment, each one a `name=value` string.

    Go's `syscall.Environ`. The order is the platform's and means nothing, and
    a name can appear twice if something put it there twice, which C allows and
    neither Go nor this filters out.

    The strings are copied out one at a time as the array is walked, for the
    same reason `getenv` copies: what libc hands over is the storage it is
    using, and a `setenv` from any thread can free it. Copying does not make
    the walk safe, since the array itself can be replaced underneath it, and no
    layer below `core.os` can fix that. It makes the result safe to keep.

    `environ` is a variable rather than a call, and Mojo has no way to name a C
    variable, so this goes through `core_syscall_environ` in the shim. The
    directory's README says why that is and what macOS does differently.
    """
    var block = external_call["core_syscall_environ", Int]()
    var found = List[String]()
    if block == 0:
        return found^
    var slots = Pointer[Int, _Foreign](unsafe_from_address=block)
    var i = 0
    while True:
        var entry = slots[unsafe_offset=i]
        if entry == 0:
            break
        found.append(_from_cstr(entry))
        i += 1
    return found^


def clearenv() raises:
    """Remove every variable in the environment. Go's `syscall.Clearenv`.

    Written as a read of `environ` and an `unsetenv` for each name rather than
    a call to C's `clearenv`, which glibc has and macOS does not. The names are
    all collected before the first removal, because removing a name moves the
    entries after it and a walk that removed as it went would skip every other
    one.

    A name with no `=` in it cannot be produced by `setenv` and can be put
    there by a parent that used `execve` directly. There is no name to hand
    `unsetenv`, so it stays, where glibc's `clearenv` would have taken it away
    with everything else. That is a real difference and it is written down here
    rather than worked around, because the way around it is writing to the
    array itself, and then this file owns storage libc believes it owns.
    """
    var entries = environ()
    var names = List[String]()
    for entry in entries:
        var cut = entry.find("=")
        if cut > 0:
            names.append(String(entry[byte=0:cut]))
    for name in names:
        unsetenv(name)


def _from_cstr(address: Int) -> String:
    """The zero terminated string at this address, copied.

    Read a byte at a time to the terminator, because a C string carries no
    length and there is nothing to ask. Built lossily from the bytes rather
    than a character at a time, so a value that is not UTF-8 arrives with a
    replacement character instead of being re-encoded into something longer
    than what was there.
    """
    var raw = Pointer[Byte, _Foreign](unsafe_from_address=address)
    var bytes = List[Byte]()
    var i = 0
    while True:
        var byte = raw[unsafe_offset=i]
        if byte == 0:
            break
        bytes.append(byte)
        i += 1
    return String(from_utf8_lossy=Span(bytes))


def clock_gettime(clock: Int) raises -> Timespec:
    """Read one of the platform's clocks. `clock` is a `CLOCK_` constant.

    `CLOCK_REALTIME` counts from the epoch and is what a file timestamp or a
    date is measured against. It can be set, and it can go backwards, so an
    interval measured with it is only as good as whatever last adjusted it.
    `CLOCK_MONOTONIC` counts from a start the platform does not describe and
    cannot be set, so it is the one an elapsed time is measured with and the
    one whose readings mean nothing on their own.

    Neither number is converted here. The pair is exactly what the kernel
    wrote, and what a wall clock reading and a monotonic reading add up to is
    `core.time`'s decision rather than this layer's.

    This is `clock_gettime` on all three platforms rather than `mach_absolute_time`
    on macOS, which needs `mach_timebase_info` and a multiply to become
    nanoseconds and has been the slower of the two since macOS 10.12 gained
    this one.
    """
    var raw = Array[Byte, SIZEOF_TIMESPEC](fill=0)
    var failed = external_call["clock_gettime", Int32](
        Int32(clock), Pointer(to=raw[0])
    )
    if failed < 0:
        _fail("clock_gettime", errno())
    return Timespec(platform_bytes=Span(raw))
