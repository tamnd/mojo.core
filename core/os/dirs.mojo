"""The four directories the environment names. Go's `os`.

`temp_dir`, `user_home_dir`, `user_cache_dir` and `user_config_dir`. Every one
of them is a variable lookup and a rule about what to do when the variable is
not set, and the rules are Go's.

Three of the four fail rather than guess. That is worth stating plainly, because
the alternative looks helpful and is not: a program that writes its state into a
directory nobody asked for is a program whose state is somewhere its user will
not think to look, and on a machine with no `HOME` at all, such as a daemon
started by init, the guess would be the root directory. `temp_dir` is the
exception and falls back to `/tmp`, because that path is in the standard and is
there on every host this library builds for.

macOS is where the answers differ. The cache and configuration directories there
are the two `Library` paths that the platform's own tools use, and the XDG
variables are not consulted at all, which is what Go does and what makes a file
written by a Mojo program land where a macOS user would look for it.
"""

from std.sys import CompilationTarget

from core.errors import Report
from core.errors.codes import ErrInvalid

from .env import getenv
from .path import is_path_separator


def temp_dir() -> String:
    """Where to put a file nothing needs to keep. Go's `TempDir`.

    ```mojo
    from core.os import temp_dir

    def main():
        print(temp_dir() != "")  # => True
    ```

    `TMPDIR` when it is set and `/tmp` when it is not. The directory is not
    created, not checked and not guaranteed to be writable, and it is shared
    with every other program on the machine, so a caller that is about to write
    something wants `create_temp` rather than a name of its own devising.
    """
    var named = getenv("TMPDIR")
    if named != "":
        return named
    return String("/tmp")


def _needed(call: StringSlice[ImmStaticOrigin], why: String) -> Error:
    """A refusal for a directory whose variable is not set.

    No errno, because nothing was called, which is the same arrangement the
    refusals in `file.mojo` use. The message names the variables rather than the
    call, since the variables are what the caller has to fix.
    """
    return (
        Report(String(call, ": ", why))
        .with_code(ErrInvalid)
        .with_field("op", String(call))
        .error()
    )


def user_home_dir() raises -> String:
    """The home directory of the user running this. Go's `UserHomeDir`.

    `HOME`, and a failure when it is not set. Nothing here reads the password
    database, which is what a shell does when `HOME` is missing, because that is
    `os/user`'s job and Go does not do it here either.
    """
    var home = getenv("HOME")
    if home == "":
        raise _needed("userhomedir", String("$HOME is not defined"))
    return home


def _under_home(
    call: StringSlice[ImmStaticOrigin],
    variable: StringSlice[ImmStaticOrigin],
    tail: StringSlice[ImmStaticOrigin],
) raises -> String:
    """The XDG variable, or the named place under `HOME`. Go's shape, twice.

    A relative XDG path is refused rather than resolved against the working
    directory. Go refuses it too, and it is the right answer: the variable is
    documented as absolute, and a relative one would put a cache wherever the
    program happened to be started from.
    """

    comptime if not CompilationTarget.is_macos():
        var named = getenv(String(variable))
        if named != "":
            var bytes = named.as_bytes()
            if not is_path_separator(bytes[0]):
                raise _needed(
                    call, String("the path in $", variable, " is relative")
                )
            return named
    var home = getenv("HOME")
    if home == "":
        raise _needed(
            call, String("neither $", variable, " nor $HOME is defined")
        )
    return String(home, tail)


def user_cache_dir() raises -> String:
    """Where to put a file that can be regenerated. Go's `UserCacheDir`.

    `XDG_CACHE_HOME`, then `$HOME/.cache`, and `$HOME/Library/Caches` on macOS.
    The directory is not created; a caller makes its own subdirectory under this
    one with `mkdir_all`, which is what Go's documentation says to do.
    """

    comptime if CompilationTarget.is_macos():
        return _under_home("usercachedir", "XDG_CACHE_HOME", "/Library/Caches")
    return _under_home("usercachedir", "XDG_CACHE_HOME", "/.cache")


def user_config_dir() raises -> String:
    """Where to put a file the user is meant to keep. Go's `UserConfigDir`.

    `XDG_CONFIG_HOME`, then `$HOME/.config`, and
    `$HOME/Library/Application Support` on macOS. The difference from
    `user_cache_dir` is entirely about what a machine may throw away, and it is
    the caller who knows which of the two a given file is.
    """

    comptime if CompilationTarget.is_macos():
        return _under_home(
            "userconfigdir",
            "XDG_CONFIG_HOME",
            "/Library/Application Support",
        )
    return _under_home("userconfigdir", "XDG_CONFIG_HOME", "/.config")
