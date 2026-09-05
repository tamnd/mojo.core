"""Starting a process, and finding out how it ended.

Go splits this between `syscall.ForkExec` and `syscall.Wait4`, and the split is
in the same place here. What is different is that the fork and the exec are one
call rather than two halves of a Go function with a warning above it: the child
between them is in `core/syscall/shim/spawn.c`, because the calls that are safe
in there are a fixed short list and nothing in Mojo promises to stay on it. The
shim's own comment says that at length and is the thing to read before changing
any of this.

What is left on this side is everything that is a decision. Which descriptors
the child gets, what its environment is and whether it leads a process group
are all arguments, built here out of Mojo values and handed over as C arrays.
Nothing in the C decides anything.

A wait status is taken apart here rather than in C, which is what Go does too.
The layout is the same on both platforms this library builds for: the low seven
bits are the signal that killed the process, zero meaning it exited, and the
next eight are the exit status. `WIFEXITED` and its siblings are macros rather
than functions, so a shim entry point for each would be five more C functions
for arithmetic that is already written down in the manual.
"""

from std.ffi import external_call

from .calls import Byte, _cstr, _fail
from .errno import Errno, errno

comptime SPAWN_SETSID: Int = 1
"""Start the child in a session of its own. Go's `SysProcAttr.Setsid`.

A new session has no controlling terminal, so the child does not get a
keyboard interrupt meant for the program that started it, and nothing it does
can take the terminal away. This is what a program being turned into a daemon
asks for.
"""

comptime SPAWN_SETPGID: Int = 2
"""Put the child in a process group. Go's `SysProcAttr.Setpgid`.

With a `pgid` of zero the child leads a group of its own, which is the useful
case: everything it starts inherits the group, so one `kill` to the negated
group id reaches the child and every descendant at once. A pipeline that has to
be stopped as a unit needs this and nothing else does.
"""


def spawn(
    path: String,
    argv: List[String],
    envp: List[String],
    fds: List[Int],
    dir: Optional[String],
    flags: Int,
    pgid: Int,
) raises -> Int:
    """Run `path` as a new process. Gives back its process id.

    `argv` is the whole vector including the program's own name in the first
    slot, as C wants it, and this does not put one there. Go's `ForkExec` has
    the same rule, and `core.os.exec` is where the convenience of not writing
    the name twice lives.

    `fds[i]` becomes descriptor `i` in the child, and -1 leaves that number
    closed. Three entries is the usual case. Everything else this process has
    open is closed on exec, which is a property of how `core.syscall` opens
    things rather than something arranged here.

    `dir` is a directory to change to first, or nothing for the working
    directory this process has. A relative `path` is resolved after the change,
    which is C's order and Go's, and is why a caller that wants the program
    found relative to the caller rather than to `dir` has to make it absolute
    first. An empty string is the same as nothing, because that is how the shim
    is told there is no directory and there is no other name it could be.

    The failure is the child's as often as it is this process's, and both
    arrive as an errno with nothing to tell them apart. `ENOENT` from here
    almost always means the executable was not found, but it can also mean the
    directory was not, and neither the shim nor this can say which because the
    only thing that crossed back was a number.
    """
    var name = _cstr(path)
    var into = _cstr(dir.value() if dir else String(""))

    # The strings first and all of them, then the arrays of addresses. Taking
    # an address as each string is made would be taking one from a list that is
    # about to be reallocated by the next append.
    var texts = List[List[Byte]]()
    for arg in argv:
        texts.append(_cstr(arg))
    for entry in envp:
        texts.append(_cstr(entry))

    var arg_slots = List[Int](capacity=len(argv) + 1)
    for i in range(len(argv)):
        arg_slots.append(Int(texts[i].unsafe_ptr()))
    arg_slots.append(0)

    var env_slots = List[Int](capacity=len(envp) + 1)
    for i in range(len(envp)):
        env_slots.append(Int(texts[len(argv) + i].unsafe_ptr()))
    env_slots.append(0)

    var table = List[Int32](capacity=len(fds) if fds else 1)
    for fd in fds:
        table.append(Int32(fd))
    if not fds:
        # An empty list has no buffer to take an address from, and C is being
        # given a count of zero anyway, so the pointer only has to be a real
        # one. This costs a four byte allocation on a call nobody makes.
        table.append(Int32(-1))

    var failure = Int32(0)
    var pid = external_call["core_syscall_spawn", Int32](
        name.unsafe_ptr(),
        arg_slots.unsafe_ptr(),
        env_slots.unsafe_ptr(),
        table.unsafe_ptr(),
        Int32(len(fds)),
        into.unsafe_ptr(),
        Int32(flags),
        Int32(pgid),
        Pointer(to=failure),
    )
    # Everything the call read has to outlive it, and nothing below refers to
    # any of it, so without this the last use of each is before the call.
    _ = name^
    _ = into^
    _ = texts^
    _ = arg_slots^
    _ = env_slots^
    _ = table^
    if pid < 0:
        _fail("spawn", Errno(Int(failure)))
    return Int(pid)


def waitpid(pid: Int, options: Int) raises -> Tuple[Int, Int]:
    """Wait for a child. Gives back the process id and its raw wait status.

    Go's `syscall.Wait4` without the resource usage, which nothing in this
    library reports yet. `pid` is a process id, or -1 for any child, and
    `options` is `WNOHANG` or zero.

    With `WNOHANG` and no child ready, the process id comes back as zero and
    the status means nothing. That is C's answer and it is passed on rather
    than turned into a failure, because a caller polling for a child that has
    not finished is not a caller that has gone wrong.

    The status is the platform's own encoding and is meant to be read by
    `exited`, `exit_status` and `signaled` below rather than looked at.
    """
    var status = Int32(0)
    var got = external_call["waitpid", Int32](
        Int32(pid), Pointer(to=status), Int32(options)
    )
    if got < 0:
        _fail("waitpid", errno())
    return (Int(got), Int(status))


def kill(pid: Int, sig: Int) raises:
    """Send `sig` to a process. Go's `syscall.Kill`.

    A negative `pid` is a process group rather than a process, which is C's
    rule and the reason `SPAWN_SETPGID` is worth having: a child started in its
    own group is reached along with everything it started by killing the
    negation of its process id.

    Signal zero sends nothing and checks. It fails with `ESRCH` when there is
    no such process and `EPERM` when there is one this process may not signal,
    which is how `core.os` finds out whether a child is still there.
    """
    if external_call["kill", Int32](Int32(pid), Int32(sig)) < 0:
        _fail("kill", errno())


def getpgid(pid: Int) raises -> Int:
    """The process group `pid` is in. Go's `syscall.Getpgid`.

    Zero means this process, as it does everywhere in this family of calls.
    """
    var group = external_call["getpgid", Int32](Int32(pid))
    if group < 0:
        _fail("getpgid", errno())
    return Int(group)


def setpgid(pid: Int, pgid: Int) raises:
    """Move a process into a process group. Go's `syscall.Setpgid`.

    Both arguments take zero to mean this process, so `setpgid(0, 0)` is a
    process making a group of its own. A child can only be moved before it
    execs, which is a window this process does not have, so in practice the
    only useful call from here is about this process. A child that has to lead
    a group is started with `SPAWN_SETPGID` instead, where the move happens on
    the far side of the fork and cannot be lost to a race with the exec.
    """
    if external_call["setpgid", Int32](Int32(pid), Int32(pgid)) < 0:
        _fail("setpgid", errno())


def exited(status: Int) -> Bool:
    """Whether the process ended by returning or calling exit. C's `WIFEXITED`.

    The low seven bits hold the signal that killed it, so all zero means
    nothing did.
    """
    return status & 0x7F == 0


def exit_status(status: Int) -> Int:
    """The value the process exited with. C's `WEXITSTATUS`.

    Meaningless unless `exited` is true, and the eight bits are all there is: a
    program returning 256 exits with 0 and the operating system is where that
    is decided.
    """
    return (status >> 8) & 0xFF


def signaled(status: Int) -> Bool:
    """Whether a signal ended the process. C's `WIFSIGNALED`.

    The low seven bits are zero for an exit and `0x7f` for a process that
    stopped rather than died, and this is true for everything else, which is
    the signal numbers.

    C writes it as `((signed char)(((status) & 0x7f) + 1) >> 1) > 0`, and the
    cast to a signed char is the whole of what makes it work: `0x7f` plus one
    is `0x80`, which is minus 128 in a signed byte and so is not above zero.
    Written in Mojo without the cast the same expression says a stopped process
    was killed by signal 127, so the two comparisons are here instead.
    """
    var low = status & 0x7F
    return low != 0 and low != 0x7F


def term_signal(status: Int) -> Int:
    """The signal that ended the process. C's `WTERMSIG`.

    Meaningless unless `signaled` is true.
    """
    return status & 0x7F


def core_dumped(status: Int) -> Bool:
    """Whether the process left a core file. C's `WCOREDUMP`.

    The bit is not in POSIX and both platforms here use `0x80` for it. A system
    configured not to write core files never sets it, so false means either
    that no dump was written or that the question does not apply.

    Only a process a signal killed can have dumped, and the bit means something
    else in a status that says anything else, so it is only read when `signaled`
    is true. C leaves that to the caller and documents it in a sentence; Go's
    `WaitStatus.CoreDump` does what this does, and the reason both of them
    bother is that a continued status has every bit set.
    """
    return signaled(status) and status & 0x80 != 0


def stopped(status: Int) -> Bool:
    """Whether the process is stopped rather than finished. C's `WIFSTOPPED`.

    Only ever seen by a caller that asked for it with `WUNTRACED`, which
    nothing in this library does yet. It is here because `exited` and
    `signaled` are both false for a stopped process, and a caller reading only
    those two would conclude something impossible.
    """
    return status & 0xFF == 0x7F


def stop_signal(status: Int) -> Int:
    """The signal that stopped the process. C's `WSTOPSIG`.

    Meaningless unless `stopped` is true.
    """
    return (status >> 8) & 0xFF
