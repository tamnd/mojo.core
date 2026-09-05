"""The environment of the process. Go's `os/env.go`.

Eight functions, and the first thing to know about all of them is that nothing
here is cached. Go copies the environment into a Go slice at start up and serves
every read from that copy, which is faster and which means `os.Setenv` and a
`setenv` from a C library linked into the same program disagree from the moment
either of them runs, forever. Reading through to libc every time is slower and
always right, and a library that cannot see the other half of its own process is
worse than a slow one.

None of it is safe against another thread changing the environment at the same
time, and that is not fixable at this layer. The array libc keeps can be
replaced by a `setenv` from anywhere, including from C, and there is no lock
either side of that boundary to take. The strings are copied out before they are
handed over, so what a caller ends up holding is its own, but a read racing a
write can still see the array mid replacement. Go says the same thing about the
same functions.

`expand` is the odd one out and touches nothing outside its argument. It is
string work, and it is here because Go puts it here and because `expand_env` is
the reason anybody wants it.
"""

from core.errors import Report
from core.errors.codes import ErrInvalid
from core.io.fs.errors import _errno_of
from core.syscall import clearenv as _sys_clearenv
from core.syscall import environ as _sys_environ
from core.syscall import getenv as _sys_getenv
from core.syscall import setenv as _sys_setenv
from core.syscall import unsetenv as _sys_unsetenv

from .errors import new_syscall_error
from .file import _has_nul


def getenv(key: String) -> String:
    """The value of a variable, or the empty string when it is not set.

    ```mojo
    from core.os import getenv

    def main():
        print(getenv("PATH") != "")  # => True
    ```

    Go's `Getenv`, including the part that loses information: a variable set to
    the empty string and a variable that was never set both come back as `""`.
    `lookup_env` is the one that tells them apart, and the difference is not
    academic, since an empty `TZ` means UTC and no `TZ` at all means the host's
    own zone.
    """
    var found = _sys_getenv(key)
    if found:
        return found.value()
    return String()


def lookup_env(key: String) -> Optional[String]:
    """The value of a variable, or nothing when it is not set. Go's `LookupEnv`.

    ```mojo
    from core.os import lookup_env

    def main():
        print(lookup_env("A_NAME_NOTHING_USES"))  # => None
    ```

    Go returns the value and a `Bool` beside it. An `Optional` says both at
    once and cannot be read wrong by ignoring the second half, which is the one
    mistake the pair invites.
    """
    return _sys_getenv(key)


def setenv(key: String, value: String) raises:
    """Set a variable, replacing whatever it held. Go's `Setenv`.

    ```mojo
    from core.os import getenv, setenv

    def main():
        setenv("MOJO_CORE_EXAMPLE", "a value")
        print(getenv("MOJO_CORE_EXAMPLE"))  # => a value
    ```

    A name with a zero byte in it is refused here for the same reason a path
    with one is: a C string stops at the first zero, so the layer below would
    set a variable nobody named. An empty name and a name with an `=` in it are
    refused by the platform, which reports `EINVAL`, so those come back as a
    `SyscallError` rather than being tested for twice.
    """
    if _has_nul(key) or _has_nul(value):
        raise (
            Report("setenv: invalid argument")
            .with_code(ErrInvalid)
            .with_field("op", "setenv")
            .error()
        )
    try:
        _sys_setenv(key, value)
    except e:
        raise _wrapped("setenv", e)


def unsetenv(key: String) raises:
    """Remove a variable. Go's `Unsetenv`.

    Removing one that was never there succeeds, which is what makes this safe
    to call in a cleanup path without asking first.
    """
    if _has_nul(key):
        raise (
            Report("unsetenv: invalid argument")
            .with_code(ErrInvalid)
            .with_field("op", "unsetenv")
            .error()
        )
    try:
        _sys_unsetenv(key)
    except e:
        raise _wrapped("unsetenv", e)


def clearenv() raises:
    """Remove every variable. Go's `Clearenv`.

    Rarely what a program wants. A child process started after this inherits
    nothing, which takes away `PATH` and the locale along with whatever was
    being cleared, so the usual thing is to build the child's environment
    rather than to empty the parent's.
    """
    try:
        _sys_clearenv()
    except e:
        raise _wrapped("clearenv", e)


def environ() -> List[String]:
    """Every variable, each one a `name=value` string. Go's `Environ`.

    ```mojo
    from core.os import environ

    def main():
        print(len(environ()) > 0)  # => True
    ```

    The order is the platform's and means nothing. A name can appear twice if
    something put it there twice, which C allows and neither Go nor this
    filters out, and the first of the two is the one `getenv` answers with.
    """
    return _sys_environ()


def _is_special(c: Byte) -> Bool:
    """Whether this is one of the shell's own one byte names.

    `$*`, `$#`, `$$`, `$@`, `$!`, `$?`, `$-` and `$0` through `$9`. None of them
    is ever in the environment, so `expand_env` replaces each with nothing, and
    they are recognised anyway so that `$1x` is the name `1` followed by an `x`
    rather than the name `1x`. Go has the same list for the same reason.
    """
    if c >= Byte(ord("0")) and c <= Byte(ord("9")):
        return True
    return (
        c == Byte(ord("*"))
        or c == Byte(ord("#"))
        or c == Byte(ord("$"))
        or c == Byte(ord("@"))
        or c == Byte(ord("!"))
        or c == Byte(ord("?"))
        or c == Byte(ord("-"))
    )


def _is_name_byte(c: Byte) -> Bool:
    """Whether this byte can be part of an unbraced name. Go's `isAlphaNum`."""
    return (
        c == Byte(ord("_"))
        or (c >= Byte(ord("0")) and c <= Byte(ord("9")))
        or (c >= Byte(ord("a")) and c <= Byte(ord("z")))
        or (c >= Byte(ord("A")) and c <= Byte(ord("Z")))
    )


def _shell_name(s: String, at: Int) -> Tuple[String, Int]:
    """The name starting at `at`, and how many bytes of `s` it took up.

    Go's `getShellName`, and the awkward cases are all Go's. An empty name with
    a width above zero means the spelling was broken and the bytes are eaten,
    an empty name with a width of zero means the `$` was not the start of
    anything and stays as it is, and a name comes back without its braces.

    `at` is the byte after the `$` and is inside the string, because the caller
    only asks when there is one.
    """
    var bytes = s.as_bytes()
    var n = len(bytes)
    if bytes[at] == Byte(ord("{")):
        if (
            at + 2 < n
            and _is_special(bytes[at + 1])
            and bytes[at + 2] == Byte(ord("}"))
        ):
            return (String(s[byte = at + 1 : at + 2]), 3)
        var i = at + 1
        while i < n:
            if bytes[i] == Byte(ord("}")):
                if i == at + 1:
                    # `${}` names nothing. Eat both braces and the dollar.
                    return (String(), 2)
                return (String(s[byte = at + 1 : i]), i + 1 - at)
            i += 1
        # `${` with no closing brace. Eat the brace and leave the rest.
        return (String(), 1)
    if _is_special(bytes[at]):
        return (String(s[byte = at : at + 1]), 1)
    var i = at
    while i < n and _is_name_byte(bytes[i]):
        i += 1
    return (String(s[byte=at:i]), i - at)


def expand[mapping: def(String) capturing[_] -> String](s: String) -> String:
    """Replace every `$name` and `${name}` using `mapping`. Go's `Expand`.

    ```mojo
    from core.os import expand

    def upper(name: String) raises -> String:
        return name.upper()

    def main():
        print(expand[upper]("a $small ${thing}"))  # => a SMALL THING
    ```

    `mapping` is a compile time parameter rather than a value, because a
    function cannot be stored in a Mojo value and passed in. It is called once
    per name, in the order the names appear, and it is given the name without
    the `$` and without the braces.

    The rules are the shell's as Go writes them down. A `$` at the very end of
    the string, or one followed by a byte that cannot start a name, is left
    alone. `${` with no closing brace eats the brace and keeps what follows.
    `${}` disappears. A name outside braces runs to the first byte that is not
    a letter, a digit or an underscore.
    """
    var bytes = s.as_bytes()
    var n = len(bytes)
    var out = String()
    var kept = 0
    var j = 0
    var replaced = False
    while j < n:
        if bytes[j] == Byte(ord("$")) and j + 1 < n:
            replaced = True
            out += s[byte=kept:j]
            var found = _shell_name(s, j + 1)
            var name = found[0]
            var width = found[1]
            if name.byte_length() == 0 and width == 0:
                # A dollar that begins nothing. Go keeps it and so does this.
                out += "$"
            elif name.byte_length() > 0:
                out += mapping(name)
            j += width
            kept = j + 1
        j += 1
    if not replaced:
        return s
    out += s[byte=kept:]
    return out^


def expand_env(s: String) -> String:
    """`expand` with the environment as the mapping. Go's `ExpandEnv`.

    ```mojo
    from core.os import expand_env, setenv

    def main():
        setenv("MOJO_CORE_WHO", "world")
        print(expand_env("hello, $MOJO_CORE_WHO"))  # => hello, world
    ```

    A name that is not set becomes nothing rather than staying as it was, which
    is what a shell does and what makes this unsuitable for a template: there is
    no way to tell an empty variable from a missing one in the output, and a
    typo in a name is silent.
    """

    @parameter
    def from_env(name: String) -> String:
        return getenv(name)

    return expand[from_env](s)


def _wrapped(call: StringSlice[ImmStaticOrigin], e: Error) -> Error:
    """A `SyscallError` for a failed environment call, or the error unchanged.

    Go wraps each of these in `NewSyscallError`, and the wrapping is what puts
    the call's name in front of the platform's own wording. There is nothing
    else to add: none of these has a path, so a `PathError` would have an empty
    field where the useful one goes.
    """
    var reported = new_syscall_error(call, _errno_of(e))
    if reported:
        return reported.take()
    return e
