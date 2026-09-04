"""The entry points with no format string. Go's `Print`, `Println` and
`Sprint`.

There is nothing to check here, because there is no format string to check.
Every argument is printed the way `%v` would print it and the only question
left is where the spaces go, which Go answers differently for the two families:

`Print` adds a space between two arguments **when neither of them is a string**.
That rule looks arbitrary until you write `fmt.Print("x = ", x)`, which is the
call it exists for: the caller put the space in the string and Go not adding a
second one is the whole point. `Println` adds a space between every pair and a
newline at the end, no exceptions.

Whether an argument is a string is a question about its type, and here that is
known while the program is built, so the spaces are decided then. Go decides
the same thing at run time with a type switch.

The names are Go's. `print` shadows the builtin in any file that imports it by
that name, which is worth knowing before you write the import, and the way to
avoid it is to import the package rather than the name:

```mojo
import core.fmt

def main() raises:
    core.fmt.print("x = ", 3)
    core.fmt.println("done")
```
"""

from core.io import Writer

from .kind import TEXT, kind_of
from .out import to_stdout
from .value import one


def sprint[*Ts: AnyType](*args: *Ts) raises -> String:
    """Every argument as `%v` would print it, with Go's spacing. Go's
    `Sprint`."""
    var out = String()
    comptime for i in range(len(Ts)):
        comptime if i > 0:
            # The space goes in only when neither side of the join is a
            # string, which is Go's `Sprint` rule and not its `Sprintln` one.
            comptime if kind_of[Ts[i - 1]]() != TEXT and kind_of[
                Ts[i]
            ]() != TEXT:
                out += " "
        one[ord("v")](out, 0, -1, -1, args[i])
    return out^


def sprintln[*Ts: AnyType](*args: *Ts) raises -> String:
    """Every argument as `%v` would print it, spaced and with a newline. Go's
    `Sprintln`."""
    var out = String()
    comptime for i in range(len(Ts)):
        comptime if i > 0:
            out += " "
        one[ord("v")](out, 0, -1, -1, args[i])
    out += "\n"
    return out^


def print[*Ts: AnyType](*args: *Ts) raises:
    """Go's `Print`, on standard output.

    Go gives back the byte count and an error. Nothing here can fail, since the
    text is built before any of it is written, and a count nobody reads is a
    count that goes stale.
    """
    to_stdout(sprint(*args))


def println[*Ts: AnyType](*args: *Ts) raises:
    """Go's `Println`, on standard output."""
    to_stdout(sprintln(*args))


def fprint[W: Writer, *Ts: AnyType](mut dst: W, *args: *Ts) raises -> Int:
    """Go's `Fprint`: the text to a writer, and how many bytes that took."""
    var out = sprint(*args)
    return dst.write(out.as_bytes())


def fprintln[W: Writer, *Ts: AnyType](mut dst: W, *args: *Ts) raises -> Int:
    """Go's `Fprintln`."""
    var out = sprintln(*args)
    return dst.write(out.as_bytes())


def append[*Ts: AnyType](mut dst: List[Byte], *args: *Ts) raises -> Int:
    """Go's `Append`: onto the end of `dst`, and how many bytes that took."""
    var out = sprint(*args)
    dst.extend(out.as_bytes())
    return out.byte_length()


def appendln[*Ts: AnyType](mut dst: List[Byte], *args: *Ts) raises -> Int:
    """Go's `Appendln`."""
    var out = sprintln(*args)
    dst.extend(out.as_bytes())
    return out.byte_length()
