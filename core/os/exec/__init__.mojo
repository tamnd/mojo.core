"""Running another program. Go's `os/exec`.

```mojo
from core.os.exec import command

def main() raises:
    var run = command("/bin/echo", [String("hi")])
    var out = run.output()
    print(String(from_utf8_lossy=Span(out)).strip())  # => hi
```

`core.os` has `start_process`, which is the operating system call with the
sharp edges filed off but still shaped like an operating system call: an
absolute path, a whole argument vector, a table of descriptors. This package is
the layer a program actually wants. It finds the program by name on `PATH`, it
puts the name at the front of the argument vector, it opens `/dev/null` for the
streams nobody chose, it makes the pipes and closes the right ends of them at
the right moments, and it turns a non zero exit into an error rather than a
number the caller has to remember to look at.

## The three ways this differs from Go

Go copies streams on goroutines, which is what lets `Stdin` be any reader and
`Output` capture two pipes at once. There are no goroutines, so streams here
are descriptors and the two capturing calls are arranged so that one thread can
drain them without deadlocking. `cmd.mojo` says exactly how.

Go returns the captured bytes beside the error. A raise has no second value, so
they live on the `Cmd` as `captured_output` and `captured_stderr` and are
filled in before the raise.

Go has `CommandContext`, `Cmd.Cancel` and `Cmd.WaitDelay`, all of which are
about stopping a command from another goroutine while this one waits. There is
nothing to stop from, so they are not here. A caller who wants to give up on a
command starts it with `start`, does whatever waiting it wants to do, and calls
`kill`.

`ErrNotFound` and `ErrDot` are the two sentinels a failed search raises with,
re-exported from `core.errors` so that a caller who wants `matches` rather than
`ExecError.of` has them under the name Go gives them.
"""

from core.errors.codes import ErrDot, ErrNotFound

from .cmd import Cmd, command
from .errors import ExecError, ExitError
from .lookpath import look_path
