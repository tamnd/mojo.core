"""Finding a program by name. Go's `exec.LookPath`.

This is the whole of what `PATH` means, and it is short because `PATH` is a
simple idea with one nasty corner. The simple idea is that a name with no
separator in it is looked for in each directory of `PATH` in order and the
first runnable file wins. The nasty corner is the empty entry, which means the
working directory, and which is how a directory somebody else can write ends up
being searched before `/usr/bin`.
"""

from core.os import getenv, stat
from core.path.filepath import is_abs, join, split_list
from core.strings import contains

from .errors import _NOT_FOUND, _REFUSED_DOT, _exec_error
from core.errors.codes import ErrDot, ErrNotFound


def _runnable(path: String) -> Bool:
    """Whether `path` names a file this process could execute.

    Go asks the kernel with `faccessat` and `X_OK` and falls back on the
    permission bits when the platform has no such call. Only the fallback is
    here, because `access` is not bound in `core.syscall` yet, and it is the
    weaker test: it says whether anybody may run the file rather than whether
    this process may. A file that passes here and fails at the exec reports
    `EACCES` from `start`, which is the honest place for the answer, since
    permission can change between the question and the exec anyway.
    """
    try:
        var info = stat(path)
        if info.mode().is_dir():
            return False
        return (Int(info.mode().perm().value) & 0o111) != 0
    except:
        return False


def look_path(file: String) raises -> String:
    """Find `file` on `PATH` and give back the path to it. Go's `LookPath`.

    ```mojo
    from core.os.exec import look_path

    def main() raises:
        print(look_path("sh").endswith("/sh"))  # => True
    ```

    A name with a separator anywhere in it is not searched for at all: it is a
    path, it is checked, and it is given back or refused. That is how a caller
    says they meant the file in front of them, and it is the answer to the
    refusal below.

    A name with no separator is looked for in each directory of `PATH` in turn,
    and the first one holding a file anybody may execute wins. An empty entry
    in `PATH` means the working directory, which is where the refusal comes in:
    a program found that way is a program somebody may have left there, and Go
    has refused to run it since 1.19 rather than quietly doing what an attacker
    arranged. The raise carries `ErrDot` and has the path that was found on the
    record under `path`, so a caller who really did mean it can read it back
    and run it deliberately.

    Raises `ErrNotFound` when nothing anywhere was runnable. That covers a name
    nobody has installed and a name that is installed and not executable, which
    Go tells apart by the error it kept from the last directory it looked in.
    They are one answer here, because the useful question is whether the search
    succeeded and the errno of the last directory looked in is rarely the one
    that explains why.
    """
    if contains(file, "/"):
        if _runnable(file):
            return file
        raise _exec_error(file, _NOT_FOUND, ErrNotFound)

    for directory in split_list(getenv("PATH")):
        # An empty entry is the working directory. Go spells it as a dot and
        # so does this, because a relative path is what makes the refusal
        # below possible: an absolute one cannot have come from here.
        # `place` and not `where`, because `where` is a keyword the formatter
        # will not parse as a name.
        var place = directory if directory else String(".")
        var candidate = join([place, file])
        if not _runnable(candidate):
            continue
        if not is_abs(candidate):
            raise _exec_error(file, _REFUSED_DOT, ErrDot, candidate)
        return candidate

    raise _exec_error(file, _NOT_FOUND, ErrNotFound)
