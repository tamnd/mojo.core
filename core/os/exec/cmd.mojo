"""A command to run, and the four ways to run it. Go's `exec.Cmd`.

`command` builds one, `start` starts it, `wait` collects it, `run` is the two
together, and `output` and `combined_output` are `run` with the child's output
kept. Everything else on the record is a setting: where to run, with what
environment, and which descriptors the child gets.

## The one thing that is not Go's

Go copies a stream that is not already a file on a goroutine of its own, which
is how `Stdin` can be any `io.Reader` and how `Output` can capture two streams
at once without either of them filling and stopping the child. There are no
goroutines here, so a single thread has to do all the copying that is going to
be done, and a single thread cannot drain two pipes at once: whichever one it
is not reading fills up, the child blocks writing to it, and neither side moves
again.

So the streams here are descriptors. A caller who has a file gives its
descriptor and no copying happens at all, which is the case Go optimises for
too. `combined_output` gives the child one pipe for both streams and drains
that one pipe, which is safe on one thread. `output` gives the child a pipe for
standard output and a temporary file for standard error, and drains the pipe: a
file never blocks the program writing to it, so there is nothing left to
deadlock. That is the whole deviation, and it costs one file in the temporary
directory for the length of a command whose standard error was not wanted
anywhere else.

## Where the captured bytes live

Go returns the output beside the error, so a command that failed still hands
back what it printed. A raise carries no second value, so the bytes go onto the
`Cmd` instead: `captured_output` and `captured_stderr` are filled in before
either of the capturing calls raises, and a caller that catches an `ExitError`
reads them off the `Cmd` it still has in its hand.
"""

from core.errors import Report
from core.errors.codes import ErrInvalid
from core.os import (
    DEV_NULL,
    File,
    ProcAttr,
    Process,
    ProcessState,
    Signal,
    create_temp,
    environ,
    new_file,
    remove,
    start_process,
)
from core.syscall import FD_CLOEXEC, F_SETFD, O_RDONLY, O_WRONLY, SEEK_SET
from core.syscall import close as _sys_close
from core.syscall import fcntl as _sys_fcntl
from core.syscall import lseek as _sys_lseek
from core.syscall import open as _sys_open
from core.syscall import pipe as _sys_pipe
from core.syscall import read

# `read` comes in under its own name rather than with the `_sys_` prefix the
# rest of them have, because `read` is an argument convention keyword and
# `import read as` does not parse. `core/os/file.mojo` does the same thing.

from .errors import _exit_error
from .lookpath import look_path

comptime _NOT_SET = -1
"""A stream nobody chose, which becomes `/dev/null` for the child."""

comptime _BLOCK = 32 * 1024
"""How much a capture loop asks for at a time. Twice a pipe's own buffer."""


def _cloexec_pipe() raises -> Tuple[Int, Int]:
    """A pipe whose ends do not survive an exec.

    Both ends and not only the parent's, because the end the child needs is
    placed into a slot and `start_process` clears the flag on exactly the
    descriptors it is told to place. A pipe left inheritable is a child holding
    the write end of its own input, which is a child that never reads the end
    of it and never exits.
    """
    var ends = _sys_pipe()
    try:
        _ = _sys_fcntl(ends[0], F_SETFD, FD_CLOEXEC)
        _ = _sys_fcntl(ends[1], F_SETFD, FD_CLOEXEC)
    except e:
        try:
            _sys_close(ends[0])
            _sys_close(ends[1])
        except:
            pass
        raise e
    return ends


def _drain(fd: Int) raises -> List[Byte]:
    """Everything `fd` has until it ends. Does not close it."""
    var out = List[Byte]()
    var room = List[Byte](length=_BLOCK, fill=0)
    while True:
        var got = read(fd, Span(room))
        if got <= 0:
            break
        out.extend(Span(room)[0:got])
    return out^


def _rewound(fd: Int) raises -> List[Byte]:
    """Everything in an open file, from the start. For the captured stderr."""
    _ = _sys_lseek(fd, 0, SEEK_SET)
    return _drain(fd)


struct Cmd(Movable):
    """A program to run, and everything about how to run it. Go's `exec.Cmd`.

    ```mojo
    from core.os.exec import command

    def main() raises:
        var run = command("/bin/echo", [String("hello")])
        var out = run.output()
        print(String(from_utf8_lossy=Span(out)))  # => hello
    ```

    Built by `command` rather than by hand, because the argument vector has a
    rule about its first element that a struct literal would let a caller get
    wrong.

    One `Cmd` runs one command once. Starting it twice raises, because the
    second start would take the descriptors the first is using and leave the
    first process unwaited for. Go says the same thing in a sentence and this
    says it with a raise.

    Move only. A copy would be two records naming one process, and whichever of
    them waited second would be asking the operating system about a number that
    has gone back into the pool.
    """

    var path: String
    """The program to run, as a path. `command` fills it in from the search."""

    var args: List[String]
    """The whole argument vector, `args[0]` being what the program calls itself.

    `command` puts the name it was given in front, which is the convention
    every program on this platform is written to expect. A caller who wants
    something else assigns to this afterwards, which is how a login shell comes
    to be started as `-sh`.
    """

    var env: Optional[List[String]]
    """The child's environment. Nothing means a copy of this process's own.

    A list literal at a call site needs the type written out, as
    `Optional[List[String]]([String("PATH=/bin")])`, because a bare literal is
    an `Array` and Mojo will not turn one into the other on the way in.
    """

    var dir: String
    """The directory to run in. Empty means this process's own.

    Changed in the child after the fork and before the exec, so nothing about
    this process moves. It does not affect the search `command` has already
    done: a relative `path` is resolved by the child against this directory,
    which is a trap Go has too, and the way out of it is an absolute path.
    """

    var stdin: Int
    """The descriptor the child reads from. -1 means `/dev/null`."""

    var stdout: Int
    """The descriptor the child writes to. -1 means `/dev/null`."""

    var stderr: Int
    """The descriptor the child complains to. -1 means `/dev/null`."""

    var extra_files: List[Int]
    """Descriptors the child gets from three upwards. Go's `ExtraFiles`.

    `extra_files[0]` becomes the child's descriptor three. Nothing else crosses
    over, because everything `core.os` opens is close on exec.
    """

    var setsid: Bool
    """Whether the child starts a session of its own. See `os.ProcAttr`."""

    var setpgid: Bool
    """Whether the child leads a process group of its own. See `os.ProcAttr`."""

    var _process: Optional[Process]
    var _state: Optional[ProcessState]
    var _output: List[Byte]
    var _stderr: List[Byte]
    var _close_after_start: List[Int]
    var _close_after_wait: List[Int]

    def __init__(out self, var path: String, var args: List[String]):
        """Take a resolved path and a whole argument vector. `command` is the door.
        """
        self.path = path^
        self.args = args^
        self.env = None
        self.dir = String("")
        self.stdin = _NOT_SET
        self.stdout = _NOT_SET
        self.stderr = _NOT_SET
        self.extra_files = []
        self.setsid = False
        self.setpgid = False
        self._process = None
        self._state = None
        self._output = []
        self._stderr = []
        self._close_after_start = []
        self._close_after_wait = []

    def string(self) -> String:
        """The command as a person would write it. Go's `Cmd.String`.

        For a log line and for nothing else. The pieces are joined with spaces
        and nothing is quoted or escaped, so an argument with a space in it
        reads as two and a string built from this cannot be handed to a shell.
        Go's carries the same warning.
        """
        var out = self.path.copy()
        for i in range(1, len(self.args)):
            out += " "
            out += self.args[i]
        return out^

    def environ(self) -> List[String]:
        """The environment the child will get. Go's `Cmd.Environ`.

        This process's own when nothing was set, read now rather than when the
        `Cmd` was built, so a variable set since then is in it.
        """
        if self.env:
            return self.env.value().copy()
        return environ()

    def process_id(self) -> Int:
        """The child's process id, or -1 before it has started.

        Go's field is a `*os.Process` and a caller signals through it. There is
        no `Process` to hand out here without copying one, which the type
        allows and its docstring warns about, so `signal` and `kill` are
        methods on this and the number is here for a log line.
        """
        if self._process:
            return self._process.value().pid
        return -1

    def process_state(self) -> Optional[ProcessState]:
        """How it finished, or nothing before `wait`. Go's `Cmd.ProcessState`.
        """
        return self._state.copy()

    def captured_output(self) -> List[Byte]:
        """What `output` or `combined_output` caught, and nothing otherwise.

        Filled in before either of them raises, so a command that failed can
        still be asked what it printed. Go returns the same bytes beside the
        error, which a raise has no room for.
        """
        return self._output.copy()

    def captured_stderr(self) -> List[Byte]:
        """What `output` caught on standard error, and nothing otherwise.

        Go hangs these bytes on the `ExitError` it returns. A `core.errors`
        record holds strings and standard error is not promised to be text, so
        they stay here instead.
        """
        return self._stderr.copy()

    def signal(self, sig: Signal) raises:
        """Send `sig` to the running child. Go's `cmd.Process.Signal`."""
        if not self._process:
            raise _refused("signal", "command has not been started")
        self._process.value().signal(sig)

    def kill(self) raises:
        """Stop the running child at once. Go's `cmd.Process.Kill`."""
        if not self._process:
            raise _refused("kill", "command has not been started")
        self._process.value().kill()

    def start(mut self) raises:
        """Start the program and return without waiting. Go's `Cmd.Start`.

        Every descriptor this opened for the child is closed in this process
        the moment the child has it, which is what lets a pipe reach its end
        when the child exits. A descriptor the caller set is the caller's and
        is left alone.

        The child is running when this returns and has to be collected, so a
        `start` that is never followed by a `wait` is a zombie. `run` is the
        call that cannot get that wrong.
        """
        if self._process:
            raise _refused("start", "command has already been started")

        var files = List[Int](capacity=3 + len(self.extra_files))
        files.append(self._stream(self.stdin, O_RDONLY))
        files.append(self._stream(self.stdout, O_WRONLY))
        files.append(self._stream(self.stderr, O_WRONLY))
        for fd in self.extra_files:
            files.append(fd)

        var attr = ProcAttr(
            dir=self.dir.copy(),
            env=self.env.copy(),
            files=files^,
            setsid=self.setsid,
            setpgid=self.setpgid,
        )
        try:
            self._process = Optional[Process](
                start_process(self.path, self.args, attr)
            )
        except e:
            self._close_started()
            raise e
        self._close_started()

    def wait(mut self) raises:
        """Wait for the child and report what it did. Go's `Cmd.Wait`.

        Returns without a value when the program exited with zero and raises
        `ErrExit` otherwise, with the status on the record for `ExitError.of`
        to read back. That is the split worth knowing: a raise from here is a
        program that ran and disagreed, and a raise from `start` is a program
        that never ran.
        """
        var state = self._collect("wait")
        if not state.success():
            raise _exit_error(state)

    def run(mut self) raises:
        """Start the program and wait for it. Go's `Cmd.Run`.

        The call to reach for. Everything it can raise, `start` and `wait` can
        raise, and `ExitError.of` tells the two apart.
        """
        self.start()
        self.wait()

    def output(mut self) raises -> List[Byte]:
        """Run it and give back what it wrote to standard output. Go's `Output`.

        Standard error goes to a temporary file, which is read into
        `captured_stderr` and then removed, so a command that failed can still
        be asked what it complained about. The reason it is a file rather than
        a second pipe is in this file's own docstring, and so is the reason the
        bytes are here rather than on the error.

        Refuses when either stream has already been set, because there would be
        two answers to where the output went. Go refuses for the same reason.
        """
        if self.stdout != _NOT_SET:
            raise _refused("output", "stdout is already set")
        if self.stderr != _NOT_SET:
            raise _refused("output", "stderr is already set")

        var scratch = create_temp("", "core-exec-stderr-")
        var named = scratch.name()
        self.stderr = scratch.fd()

        var ends = _cloexec_pipe()
        self.stdout = ends[1]
        self._close_after_start.append(ends[1])
        self._close_after_wait.append(ends[0])

        self.start()
        self._output = _drain(ends[0])
        var state = self._collect("output")
        self._stderr = _rewound(scratch.fd())
        scratch.close()
        try:
            remove(named)
        except:
            pass
        if not state.success():
            raise _exit_error(state)
        return self._output.copy()

    def combined_output(mut self) raises -> List[Byte]:
        """Run it and give back both streams, interleaved. Go's `CombinedOutput`.

        One pipe for both, which is what makes this safe on one thread and also
        what makes the order of the two streams the order the child wrote them
        in rather than anything this library arranged.

        Refuses when either stream has already been set, for the same reason
        `output` does.
        """
        if self.stdout != _NOT_SET:
            raise _refused("combined_output", "stdout is already set")
        if self.stderr != _NOT_SET:
            raise _refused("combined_output", "stderr is already set")

        var ends = _cloexec_pipe()
        self.stdout = ends[1]
        self.stderr = ends[1]
        self._close_after_start.append(ends[1])
        self._close_after_wait.append(ends[0])

        self.start()
        self._output = _drain(ends[0])
        var state = self._collect("combined_output")
        if not state.success():
            raise _exit_error(state)
        return self._output.copy()

    def stdin_pipe(mut self) raises -> File:
        """A pipe to write the child's input into. Go's `Cmd.StdinPipe`.

        Closed by the caller, and closing it is what tells the child there is
        no more input. A child reading to the end of its input and a caller
        that never closes this is the deadlock this whole file is about, and
        here it is the caller's to avoid, because the descriptor is theirs.
        """
        if self.stdin != _NOT_SET:
            raise _refused("stdin_pipe", "stdin is already set")
        var ends = _cloexec_pipe()
        self.stdin = ends[0]
        self._close_after_start.append(ends[0])
        return new_file(ends[1], String("|1"))

    def stdout_pipe(mut self) raises -> File:
        """A pipe to read the child's output from. Go's `Cmd.StdoutPipe`.

        Read it to the end before calling `wait`, which is Go's rule too and
        for a reason worth stating: `wait` waits for the child, the child is
        waiting for room in this pipe, and a caller waiting for the child has
        stopped making room.
        """
        if self.stdout != _NOT_SET:
            raise _refused("stdout_pipe", "stdout is already set")
        var ends = _cloexec_pipe()
        self.stdout = ends[1]
        self._close_after_start.append(ends[1])
        return new_file(ends[0], String("|0"))

    def stderr_pipe(mut self) raises -> File:
        """A pipe to read the child's complaints from. Go's `Cmd.StderrPipe`.

        The same rule as `stdout_pipe`, and the same trap doubled: a caller
        that takes both pipes and reads one of them to the end before starting
        on the other is a caller whose child is blocked writing to the one that
        is not being read. One thread can drain one pipe. Two streams at once
        want `combined_output`, or a file apiece.
        """
        if self.stderr != _NOT_SET:
            raise _refused("stderr_pipe", "stderr is already set")
        var ends = _cloexec_pipe()
        self.stderr = ends[1]
        self._close_after_start.append(ends[1])
        return new_file(ends[0], String("|0"))

    def _collect(mut self, op: String) raises -> ProcessState:
        """Wait for the child and remember how it went, without judging it.

        The judgement belongs to the caller, because `wait` raises on a non
        zero exit and the capturing calls have a temporary file to clean up
        before they do the same thing.
        """
        if not self._process:
            raise _refused(op, "command has not been started")
        if self._state:
            raise _refused(op, "command has already been waited for")
        var running = self._process.value().copy()
        var state = running.wait()
        self._process = Optional[Process](running^)
        self._state = Optional[ProcessState](state.copy())
        self._close_waited()
        return state^

    def _stream(mut self, chosen: Int, flags: Int) raises -> Int:
        """The descriptor a slot gets, opening `/dev/null` when nobody chose.

        Go opens the same file for the same reason. A closed descriptor zero is
        not the same thing: a program that reads it gets `EBADF` rather than
        the end of its input, and plenty of programs are not written for that.
        """
        if chosen != _NOT_SET:
            return chosen
        var opened = _sys_open(DEV_NULL, flags, 0)
        self._close_after_start.append(opened)
        return opened

    def _close_started(mut self):
        """Close what this process opened for the child and no longer needs.

        A failure closing a descriptor this owns says nothing a caller could
        act on and the descriptor is gone either way, so it is dropped.
        """
        for fd in self._close_after_start:
            try:
                _sys_close(fd)
            except:
                pass
        self._close_after_start.clear()

    def _close_waited(mut self):
        """Close what was kept open until the child had finished with it."""
        for fd in self._close_after_wait:
            try:
                _sys_close(fd)
            except:
                pass
        self._close_after_wait.clear()


def command(name: String, var args: List[String] = []) raises -> Cmd:
    """A `Cmd` for `name` with `args`. Go's `exec.Command`.

    ```mojo
    from core.os.exec import command

    def main() raises:
        var run = command("/bin/sh", [String("-c"), "exit 0"])
        run.run()
        print(run.process_state().value().success())  # => True
    ```

    `name` is looked up with `look_path` unless it already has a separator in
    it, so `sh` is found on `PATH` and `./sh` is the file in front of you.
    `args` is what the program gets after its own name; the name goes in front
    automatically, which is the one thing `start_process` leaves to the caller
    and the one thing a caller most often forgets.

    Go records a failed lookup in `Cmd.Err` and returns it later from `Run`, so
    that `Command` can be written inside a struct literal. This raises instead,
    because nothing here needs a `Cmd` to exist before its name has been
    resolved, and an error field nobody reads is worse than a raise nobody can
    miss.
    """
    var argv = List[String](capacity=len(args) + 1)
    argv.append(name)
    argv.extend(args^)
    return Cmd(look_path(name), argv^)


def _refused(op: String, why: String) -> Error:
    """A caller's mistake about the order of things, before any call is made."""
    return (
        Report(String("exec: ") + op + ": " + why)
        .with_code(ErrInvalid)
        .with_field("op", op)
        .error()
    )
