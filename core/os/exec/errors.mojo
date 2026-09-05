"""The two failures this package has, and the records behind them.

`ExecError` is a name that could not be turned into a program: the search found
nothing, or what it found cannot be run, or it was found in the working
directory and refused for it. `ExitError` is a program that ran and did not
exit with zero, which is a different thing entirely and is the one callers most
often want to tell apart, because a command that returns 1 has usually answered
the question rather than failed at it.

Both are read back from a raised error with `of`, the same shape `PathError`
and `LinkError` have in `core.os`, so a caller catches once and asks which kind
of failure it was holding.

Go calls the first one `exec.Error`. The bare name cannot be used here, because
a struct called `Error` inside this package would shadow the built in `Error`
that every raise in it is made of, and the two would then be indistinguishable
in a signature.
"""

from core.errors import Code, Report, capture
from core.errors.codes import ErrDot, ErrExit, ErrNotFound
from core.os import ProcessState

comptime _NOT_FOUND = "executable file not found in $PATH"
"""Go's wording for a search that found nothing."""

comptime _REFUSED_DOT = (
    "cannot run executable found relative to current directory"
)
"""Go's wording for a name that resolved into the working directory."""


def _exec_error(
    name: String, why: String, code: Code, path: String = String("")
) -> Error:
    """The raise every failed lookup in this package makes.

    Go's `exec.Error` prints as `exec: "ls": executable file not found in
    $PATH` and this is that sentence, with the name also on the record so that
    a caller can have it without reading the message back.

    `path` is what the search found, and there is one only for the refusal that
    has something to show: a name resolved into the working directory. Go
    returns that path beside the error and this cannot, because a raise has no
    second value, so it goes on the record instead.
    """
    var report = (
        Report(String('exec: "') + name + '": ' + why)
        .with_code(code)
        .with_field("name", name)
    )
    if path:
        return report^.with_field("path", path).error()
    return report^.error()


def _exit_error(state: ProcessState) -> Error:
    """The raise for a command that ran and did not exit with zero.

    The process id and the raw wait status go on the record, which is what
    `ExitError.of` reads back, so the record a caller inspects is the same one
    `wait` had rather than a second guess at it.
    """
    return (
        Report(state.string())
        .with_code(ErrExit)
        .with_field("pid", String(state.pid()))
        .with_field("status", String(state.sys()))
        .error()
    )


struct ExecError(Copyable, Movable, Writable):
    """A name that could not be turned into a program. Go's `exec.Error`.

    Raised by `look_path` and by `command`, and never by a command that ran.
    Built from a raised error by `of` rather than by hand, and every field is a
    copy, so it outlives the `Error` it came from.

    Go's has a `Name` and an `Err`, where the second is one of two sentinels or
    the failure of the last file that was looked at. The sentinel is the code
    on the record here, so the two questions worth asking it are the two
    booleans below and `matches(e, ErrNotFound)` answers the same thing.
    """

    var name: String
    """The name that was looked up, as the caller wrote it."""

    var not_found: Bool
    """Whether nothing runnable was found anywhere the search looked."""

    var refused_dot: Bool
    """Whether it was found in the working directory and refused for it."""

    def __init__(
        out self, var name: String, not_found: Bool, refused_dot: Bool
    ):
        self.name = name^
        self.not_found = not_found
        self.refused_dot = refused_dot

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as an `Error`, or nothing if it did not come from here."""
        var value = capture(e)
        var name = value.field("name")
        if not name:
            return None
        var code = value.code()
        if code != ErrNotFound and code != ErrDot:
            return None
        return Self(name.value(), code == ErrNotFound, code == ErrDot)

    def write_to[W: Writer](self, mut writer: W):
        writer.write('exec: "', self.name, '": ')
        if self.refused_dot:
            writer.write(_REFUSED_DOT)
        else:
            writer.write(_NOT_FOUND)


struct ExitError(Copyable, Movable, Writable):
    """A program that ran and did not exit with zero. Go's `exec.ExitError`.

    The command was found, started and finished, so this says something about
    the program rather than about this library. A compiler that found a mistake
    and a grep that matched nothing both end this way, and neither is a failure
    of the machinery, which is why Go gives it a type of its own and why a
    caller that treats every error the same is usually wrong.

    Go embeds an `*os.ProcessState` and adds the standard error `Output`
    captured behind the caller's back. The state is here; the bytes are not,
    because a `core.errors` record holds strings and standard error is not
    promised to be text. `Cmd.captured_stderr` is where they are, and the
    docstring on `Cmd.output` says so.
    """

    var state: ProcessState
    """How it finished. `exit_code`, `exited` and `success` are all on it."""

    def __init__(out self, var state: ProcessState):
        self.state = state^

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as an `ExitError`, or nothing if the command did not run."""
        var value = capture(e)
        if value.code() != ErrExit:
            return None
        var pid = value.field("pid")
        var status = value.field("status")
        if not pid or not status:
            return None
        try:
            return Self(ProcessState(Int(pid.value()), Int(status.value())))
        except:
            return None

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.state)
