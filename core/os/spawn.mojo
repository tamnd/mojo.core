"""Starting another program, and what comes back when it ends. Go's `os`.

Four types and two functions. `ProcAttr` says how the new process should be
set up, `start_process` starts it, `Process` is the handle on it while it runs,
and `ProcessState` is what is left when it has finished. `Signal` is the thing
sent to a running one, and `find_process` makes a handle for a process this
program did not start.

This is the low layer, and it is deliberately close to the platform: an
argument vector rather than a command line, a list of descriptors rather than
three named streams, no search of `PATH`, and no reading of the child's output.
`core.os.exec` is the layer that does all of that, and it is written on top of
this one, exactly as Go's `os/exec` is written on top of Go's `os`.

## What a caller has to get right

The two that catch everybody are both about descriptors. The first is that a
descriptor in `ProcAttr.files` reaches the child and every other descriptor
this process has open does not, provided it was opened by `core.os`, because
everything this library opens is close on exec. A descriptor from somewhere
else is inherited whether or not anybody meant it to be.

The second is that a pipe handed to a child has to be closed in the parent. A
reader sees the end of a pipe when every copy of the write end has gone, and
the copy this process kept counts, so a parent that hands a pipe to a child and
then reads until the end without closing its own copy waits forever. That is
not a rule this library invented and there is nothing it can do about it: the
descriptor is the caller's.

## Waiting, and what a process id means afterwards

`Process.wait` collects a finished process and gives back its `ProcessState`.
Until something collects it the process stays in the table as a zombie, so a
program that starts children and never waits leaks entries until it cannot
start another. `Process.release` is the other way to say it is not coming back
for the answer.

Once a process has been collected its id belongs to the operating system again
and will be given to somebody else's program. That is why `Process` remembers
having collected it and raises `ErrProcessDone` rather than making the call: a
signal sent to a collected id is a signal sent to a stranger.
"""

from core.errors import Code, Report
from core.errors.codes import ErrInvalid, ErrProcessDone
from core.io.fs.errors import _errno_of, _path_error_from
from core.syscall import (
    EINTR,
    SIGINT,
    SIGKILL,
    SPAWN_SETPGID,
    SPAWN_SETSID,
    core_dumped,
    exit_status,
    exited,
    signal_name,
    signaled,
    stop_signal,
    stopped,
    term_signal,
)
from core.syscall import kill as _sys_kill
from core.syscall import spawn as _sys_spawn
from core.syscall import waitpid as _sys_waitpid

from .env import environ
from .errors import new_syscall_error


struct Signal(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """A signal, as a number and a name. Go's `os.Signal`.

    Go's is an interface with two methods, satisfied by `syscall.Signal`, so
    that a program on a platform with no signals can still be compiled against
    the same API. There are no such platforms here, so this is the number.

    ```mojo
    from core.os import INTERRUPT

    def main():
        print(INTERRUPT.string())  # => interrupt
    ```
    """

    var number: Int
    """The number the platform uses. `SIGINT` is 2 on both of them."""

    def __init__(out self, number: Int):
        self.number = number

    def __eq__(self, other: Self) -> Bool:
        return self.number == other.number

    def __ne__(self, other: Self) -> Bool:
        return self.number != other.number

    def string(self) -> String:
        """What the platform calls it. Go's `syscall.Signal.String`.

        A description and not a constant name, so `SIGINT` reads back as
        `interrupt`. A number the platform has no description for reads back as
        `signal 37`, which is every real time signal on Linux.
        """
        return signal_name(self.number)

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.string())


comptime INTERRUPT = Signal(SIGINT)
"""What a terminal sends when somebody presses control C. Go's `os.Interrupt`.

Deliverable everywhere and the polite way to ask a program to stop, because a
program that has arranged to catch it gets to finish what it was doing first.
"""

comptime KILL = Signal(SIGKILL)
"""The one that cannot be caught, blocked or ignored. Go's `os.Kill`.

The process stops where it is with nothing flushed and nothing cleaned up, and
a child of its own keeps running unless it was in a process group of its own
and the group was signalled. Reach for `INTERRUPT` first and for this when the
program has already been asked.
"""


struct ProcessState(Copyable, Movable, Writable):
    """A process that has finished, and how. Go's `os.ProcessState`.

    Made by `Process.wait` and by nothing else. The raw wait status is kept
    because the questions asked of it are not independent: a process that was
    signalled has no exit code and a process that exited was not signalled, and
    a record that stored the answers separately could be asked for both.

    ```mojo
    from core.os import ProcAttr, start_process

    def main() raises:
        var run = start_process(
            "/bin/sh", [String("sh"), "-c", "exit 3"], ProcAttr()
        )
        var state = run.wait()
        print(state.exit_code())  # => 3
        print(state.string())     # => exit status 3
    ```
    """

    var _pid: Int
    var _status: Int

    def __init__(out self, pid: Int, status: Int):
        self._pid = pid
        self._status = status

    def pid(self) -> Int:
        """The process this is about. Go's `ProcessState.Pid`.

        Still worth reporting and no longer worth using. The process has been
        collected by the time this record exists, so the number is back in the
        operating system's pool and may already name something else.
        """
        return self._pid

    def sys(self) -> Int:
        """The wait status the platform gave, unpicked. Go's `ProcessState.Sys`.

        Go returns a `syscall.WaitStatus`, which is this number with the same
        methods on it that `core.syscall` has as functions. Anything worth
        knowing is already a method here, and this is for the caller who has to
        pass the number somewhere else.
        """
        return self._status

    def exited(self) -> Bool:
        """Whether the process ended by returning or calling exit.

        False for a process that a signal ended, which is the case that catches
        a caller who only ever checks the exit code.
        """
        return exited(self._status)

    def exit_code(self) -> Int:
        """The status it exited with, or -1. Go's `ProcessState.ExitCode`.

        Minus one for a process a signal ended, which has no exit code at all
        rather than one that happens to be zero. Go returns the same -1 and for
        the same reason.
        """
        if not self.exited():
            return -1
        return exit_status(self._status)

    def success(self) -> Bool:
        """Whether it exited with zero. Go's `ProcessState.Success`."""
        return self.exited() and exit_status(self._status) == 0

    def string(self) -> String:
        """Go's wording, to the character. Go's `ProcessState.String`.

        `exit status 3`, `signal: killed`, `stop signal: stopped`, or
        `continued`, with ` (core dumped)` after it when there is a core file.
        A person reading a log recognises these from Go programs and from a
        shell, which is the whole reason not to invent better ones.
        """
        var out: String
        if self.exited():
            out = String("exit status ", exit_status(self._status))
        elif signaled(self._status):
            out = String("signal: ", signal_name(term_signal(self._status)))
        elif stopped(self._status):
            out = String(
                "stop signal: ", signal_name(stop_signal(self._status))
            )
        else:
            out = String("continued")
        if core_dumped(self._status):
            out += " (core dumped)"
        return out^

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.string())


struct ProcAttr(Copyable, Movable):
    """How a new process should be set up. Go's `os.ProcAttr`.

    Every field has a default that means the ordinary thing, so a caller who
    wants a program run with this process's environment and streams writes
    `ProcAttr()`.

    Go keeps the last three fields in a `syscall.SysProcAttr` behind a `Sys`
    pointer, because that structure is different on every platform and cannot
    be written portably. There is no such type here, and putting the two flags
    this library supports on the record directly is the honest version of the
    same thing: what is not here is not supported rather than hidden behind a
    pointer that is nil on the platform you are reading about.
    """

    var dir: String
    """The directory to start in. Empty means this process's own."""

    var env: Optional[List[String]]
    """The environment, each entry a `name=value` string.

    Nothing means this process's own environment, read at the moment the
    process is started rather than at start up, which is what Go does with a
    nil `Env`. An empty list is a different thing and means a child with no
    environment at all.

    A list literal at a call site needs the type written out, as
    `Optional[List[String]]([String("PATH=/bin")])`, because a bare literal is
    an `Array` and Mojo will not turn one into the other on the way in.
    """

    var files: List[Int]
    """The descriptors the child gets, by position.

    `files[i]` is the descriptor the child sees as `i`, and -1 is a slot the
    child does not have. Empty means the three this process has, which is what
    a caller who has not thought about it wants.

    Go's field is a `[]*os.File` and this is a list of numbers, because a
    `File` cannot be copied and cannot be moved out of a list, so a list of
    them could not be built at a call site. The caller passes `f.fd()` and goes
    on owning the file, which also settles the question Go's version leaves
    open of who closes it.
    """

    var setsid: Bool
    """Whether the child starts a session of its own.

    A process in its own session has no controlling terminal, so a terminal
    that sends `SIGINT` to everything in front of it does not reach the child.
    That is what a daemon wants and what an interactive child does not.
    """

    var setpgid: Bool
    """Whether the child starts a process group of its own.

    With `pgid` at zero the child leads a group named by its own process id, so
    a signal sent to the negated id reaches the child and everything it starts.
    That is the only way to stop a whole tree of processes at once.
    """

    var pgid: Int
    """The group to join when `setpgid` is set. Zero means lead a new one."""

    def __init__(
        out self,
        var dir: String = String(""),
        var env: Optional[List[String]] = None,
        var files: List[Int] = [],
        setsid: Bool = False,
        setpgid: Bool = False,
        pgid: Int = 0,
    ):
        self.dir = dir^
        self.env = env^
        self.files = files^
        self.setsid = setsid
        self.setpgid = setpgid
        self.pgid = pgid


struct Process(Copyable, Movable):
    """A process this program started or found. Go's `os.Process`.

    Made by `start_process` or by `find_process`, never by hand, because a
    handle built around a number nobody checked is a signal sent to a stranger
    waiting to happen.

    A copy of this is another name for the same process id and does not share
    the record of having been waited for. Go's is a pointer and does share it.
    So keep one: a copy that waits after the original has already waited is
    asking the operating system about an id that now belongs to somebody else,
    and the guard here cannot see it coming.
    """

    var pid: Int
    """The process id. Go's exported `Process.Pid` field."""

    var _done: Bool
    """Whether it has been collected, and so whether the id still means it."""

    def __init__(out self, pid: Int, done: Bool = False):
        self.pid = pid
        self._done = done

    def signal(self, sig: Signal) raises:
        """Send `sig` to the process. Go's `Process.Signal`.

        Raises `ErrProcessDone` for a process that has already been waited for
        or released, because the id no longer names it. A signal that the
        process has arranged to catch is delivered and this returns as soon as
        it has been queued, so a caller that wants to know what the process did
        about it waits.
        """
        if self._done:
            raise _refused_process("signal", ErrProcessDone)
        if self.pid <= 0:
            raise _refused_process("signal", ErrInvalid)
        try:
            _sys_kill(self.pid, sig.number)
        except e:
            raise _syscall_process("signal", e)

    def kill(self) raises:
        """Stop the process at once. Go's `Process.Kill`.

        `SIGKILL`, which cannot be caught, so nothing is flushed and no
        cleanup runs. It does not wait: the process is still in the table until
        something collects it, and `wait` is what does that.
        """
        self.signal(KILL)

    def release(mut self) raises:
        """Give up the handle without collecting the process. Go's `Release`.

        For a parent that starts a program and does not care what happens to
        it. The process stays in the table when it ends, so this is a leak
        unless something else collects it, and the something else on Unix is
        the init process once this one has exited.

        A caller that wants the answer calls `wait` instead, which releases the
        handle as part of collecting it.
        """
        self._done = True

    def wait(mut self) raises -> ProcessState:
        """Wait for the process to finish. Go's `Process.Wait`.

        Blocks until it has, then collects it, so the id is free afterwards and
        this handle refuses to signal. Raises `ErrProcessDone` on a second call
        rather than blocking forever on an id that is no longer this process's
        child.

        A signal arriving while this waits is not an answer about the child, so
        the call goes round again rather than failing, which is `EINTR` and is
        what Go does too.

        This waits for the process itself and not for anything it started. A
        child that left a grandchild holding the write end of a pipe is a
        parent that reads the end of that pipe only when the grandchild has
        gone too, and no amount of waiting here changes that.
        """
        if self._done:
            raise _refused_process("wait", ErrProcessDone)
        while True:
            try:
                var got = _sys_waitpid(self.pid, 0)
                self._done = True
                return ProcessState(self.pid, got[1])
            except e:
                if _errno_of(e).value != EINTR:
                    raise _syscall_process("wait", e)


def _refused_process(op: StringSlice[ImmStaticOrigin], code: Code) -> Error:
    """A failure this package decided on, with no call made and no errno."""
    var why = (
        "process already finished" if code
        == ErrProcessDone else "process not initialized"
    )
    return (
        Report(String("os: ") + String(op) + ": " + why)
        .with_code(code)
        .with_field("op", String(op))
        .error()
    )


def _syscall_process(op: StringSlice[ImmStaticOrigin], cause: Error) -> Error:
    """A platform failure on a process, with the operation in front of it."""
    var reported = new_syscall_error(op, _errno_of(cause))
    if reported:
        return reported.take()
    return cause


def find_process(pid: Int) raises -> Process:
    """A handle on a process this program did not start. Go's `FindProcess`.

    On Unix this always succeeds and checks nothing, which Go documents and
    which is worth reading twice: the process may have ended years ago and the
    id may name something else entirely. The only thing a handle from here is
    good for is sending a signal, and the only thing that says whether it
    arrived somewhere sensible is the error from the signal.

    Waiting is not among the things it is good for. A process is collected by
    its own parent and by nobody else, so `wait` on a handle from here fails
    with `ECHILD` unless this program happens to be the parent.
    """
    return Process(pid)


def start_process(
    name: String, argv: List[String], attr: ProcAttr
) raises -> Process:
    """Start `name` as a new process. Go's `StartProcess`.

    ```mojo
    from core.os import ProcAttr, start_process

    def main() raises:
        var run = start_process(
            "/bin/sh", [String("sh"), "-c", "exit 0"], ProcAttr()
        )
        print(run.wait().success())  # => True
    ```

    `name` is a path and is not searched for: no `PATH` is consulted and a bare
    `sh` is a file called `sh` in the working directory. `core.os.exec` is the
    layer that searches, and `look_path` is the call that does it.

    `argv` is the whole argument vector, so `argv[0]` is the name the program
    sees itself as and is the caller's to choose. It is conventionally the last
    element of the path and nothing enforces that, which is how `sh` starting
    as `-sh` announces a login shell.

    Nothing of this process crosses over except what `attr` says. The
    environment is `attr.env` or a copy of this one, the descriptors are
    `attr.files` or the three this process has, and every other descriptor
    stays behind because everything `core.os` opens is close on exec.

    The failure comes back as a `PathError` with the operation `fork/exec` and
    the path `name`, which is Go's wording. It covers both halves of the start:
    a failure here, such as running out of descriptors, and a failure in the
    child after the fork, such as the file not existing or not being runnable.
    The child reports its own errno back through a pipe, so a program that was
    never started is never mistaken for one that started and exited 127.
    """
    var files = attr.files.copy()
    if not files:
        files = [0, 1, 2]
    var flags = 0
    if attr.setsid:
        flags |= SPAWN_SETSID
    if attr.setpgid:
        flags |= SPAWN_SETPGID
    var env = attr.env.value().copy() if attr.env else environ()
    var dir = Optional[String](None)
    if attr.dir.byte_length() > 0:
        dir = attr.dir
    try:
        return Process(
            _sys_spawn(name, argv, env, files, dir, flags, attr.pgid)
        )
    except e:
        raise _path_error_from("fork/exec", name, e)
