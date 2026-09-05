"""Files and directories with names nobody else has. Go's `CreateTemp` and
`MkdirTemp`.

The same idea twice. The caller gives a directory and a pattern, the last `*`
in the pattern is replaced with a random number, and the thing is created with
`O_EXCL`, which makes the creation itself the test of whether the name was
free. Nothing looks first and creates second. A look followed by a create is a
race with every other program on the machine, and on a directory everyone can
write to, that race is the one an attacker wins.

A name that was taken is not a failure. The call tries again with a new number,
up to ten thousand times, and only then gives up. That bound is Go's and it is
there so that a directory that cannot be written to for some other reason fails
in a moment rather than spinning.

The two halves of the security argument are the unguessable name and the
permissions. A file is created 0600 and a directory 0700, so even a name that
somehow was guessed is not one anybody else can open. Neither call removes what
it made: the caller knows when it is finished with it and this does not.

The random part comes from `core.math.rand`, which is seeded from the operating
system and keeps a generator per thread, and that is the same source Go uses
here. It does not have to be unguessable by somebody determined, because
`O_EXCL` and the permission bits are what make the call safe. It does have to
differ between two processes started in the same second, which a counter seeded
from the clock would not.
"""

from core.errors.codes import ErrInvalid
from core.io import Byte
from core.io.fs import ErrExist, FileMode
from core.math.rand import uint32
from core.syscall import O_CREAT as O_CREATE
from core.syscall import O_EXCL, O_RDWR

from .calls import mkdir
from .dirs import temp_dir
from .errors import is_exist
from .file import File, _refused, open_file
from .path import is_path_separator

comptime _ATTEMPTS = 10000
"""How many names to try before giving up. Go's number.

Ten thousand collisions in a row does not happen by chance against a 32 bit
number, so reaching this bound means something else is wrong, most likely a
directory that cannot be written to. Without a bound that case is a loop that
never ends and never says why.
"""

comptime _STAR = Byte(ord("*"))
"""The one character in a pattern that is not part of the name."""


def _split_pattern(
    op: StringSlice[ImmStaticOrigin], pattern: String
) raises -> Tuple[String, String]:
    """A pattern split at its last `*`, or the whole thing and an empty tail.

    A pattern is a name and not a path, so a separator anywhere in it is
    refused. Letting one through would put the file somewhere the caller did
    not name, and a caller that wants a subdirectory passes it as the
    directory. The refusal carries the pattern as its path, which is what Go
    does, because the pattern is what the caller got wrong.
    """
    var bytes = pattern.as_bytes()
    for byte in bytes:
        if is_path_separator(byte):
            raise _refused(
                op, pattern, "pattern contains path separator", ErrInvalid
            )
    var star = -1
    for i in range(len(bytes)):
        if bytes[i] == _STAR:
            star = i
    if star < 0:
        return (pattern, String(""))
    return (String(pattern[byte=:star]), String(pattern[byte = star + 1 :]))


def _join(dir: String, name: String) -> String:
    """`dir` and `name` with exactly one separator between them.

    Not `path.filepath.join`, which cleans what it is given. Here the directory
    came from the caller or from `temp_dir` and the name is about to be created
    under it, so cleaning could change which directory is meant.
    """
    var room = dir.byte_length()
    if room > 0 and is_path_separator(dir.as_bytes()[room - 1]):
        return String(dir, name)
    return String(dir, "/", name)


def _exhausted(
    op: StringSlice[ImmStaticOrigin], prefix: String, suffix: String
) -> Error:
    """The raise for ten thousand names in a row that were all taken.

    The path is the prefix, a star and the suffix rather than the last name
    tried, because the last name is an accident of the random number and the
    pattern is what somebody reading the message can act on.
    """
    return _refused(op, String(prefix, "*", suffix), "file exists", ErrExist)


def create_temp(dir: String, pattern: String) raises -> File:
    """A new file nobody else has, open for reading and writing. Go's `CreateTemp`.

    ```mojo
    from core.os import create_temp, remove

    def main():
        var f = create_temp("", "note-*.txt")
        var name = f.name()
        _ = f.write_string("hello\\n")
        f.close()
        remove(name)
    ```

    An empty `dir` means `temp_dir`. The last `*` in `pattern` is where the
    random part goes, and a pattern with no `*` has it added at the end, so
    `note-*.txt` gives something like `note-1889507691.txt` and `note-` gives
    `note-1889507691`.

    The file is created with `O_EXCL` and mode 0600, and the caller closes it
    and removes it. Neither happens here, because this does not know when the
    caller is finished with the file, and a temporary file that removes itself
    at an unrelated moment is worse than one that is left behind.

    A pattern holding a path separator raises `ErrInvalid` and nothing is
    created.
    """
    var parent = dir
    if parent == "":
        parent = temp_dir()
    var parts = _split_pattern("createtemp", pattern)
    var prefix = _join(parent, parts[0])
    var suffix = parts[1]
    for _ in range(_ATTEMPTS):
        var name = String(prefix, uint32(), suffix)
        try:
            return open_file(name, O_RDWR | O_CREATE | O_EXCL, FileMode(0o600))
        except e:
            if not is_exist(e):
                raise e
    raise _exhausted("createtemp", prefix, suffix)


def mkdir_temp(dir: String, pattern: String) raises -> String:
    """A new directory nobody else has. Gives back its name. Go's `MkdirTemp`.

    ```mojo
    from core.os import mkdir_temp, remove

    def main():
        var place = mkdir_temp("", "work-*")
        print(place != "")  # => True
        remove(place)
    ```

    The same rules as `create_temp`: an empty `dir` means `temp_dir`, the last
    `*` is where the random part goes, and a pattern holding a path separator
    raises `ErrInvalid`. The directory is made 0700 and is not removed here, so
    the caller removes it, with `remove_all` if it put anything in it.
    """
    var parent = dir
    if parent == "":
        parent = temp_dir()
    var parts = _split_pattern("mkdirtemp", pattern)
    var prefix = _join(parent, parts[0])
    var suffix = parts[1]
    for _ in range(_ATTEMPTS):
        var name = String(prefix, uint32(), suffix)
        try:
            mkdir(name, FileMode(0o700))
            return name^
        except e:
            if not is_exist(e):
                raise e
    raise _exhausted("mkdirtemp", prefix, suffix)
