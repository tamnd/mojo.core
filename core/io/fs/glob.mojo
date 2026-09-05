"""Names in a file system that match a pattern. Go's `fs.Glob`.

The pattern is `core.path.is_match`'s, so it matches one element at a time and
`*` never crosses a slash. That is what makes this walkable: `a/*/c.go` is a
listing of `a`, a match of `*` against each name in it, and a listing of each
one that matched. No directory is read that the pattern could not have reached,
which is the difference between this and reading the tree and filtering it.

A directory that cannot be read is skipped rather than reported, which is Go's
rule and is the right one for a pattern: a match asks which names exist, and a
directory that refused to say has no names to offer. A malformed pattern is the
one failure, and it is found before any directory is opened.
"""

from core.errors import Report
from core.errors.codes import ErrBadPattern
from core.io import Byte
from core.path import is_match, join, split

from .direntry import DirEntry
from .fs import FS, GLOB_FS
from .read import read_dir, stat

comptime _MAX_DEPTH = 1000
"""How many pattern elements deep the recursion below is allowed to go.

Go added this after CVE-2022-30630, where a pattern of a few thousand `*/`
pairs was enough to run a program out of stack. The number is Go's.
"""


def _bad_pattern() -> Error:
    """The raise a malformed pattern makes, matching `core.path`'s exactly.

    Written out rather than imported because `core.path`'s is private to that
    package, and it is one line. Both carry `ErrBadPattern`, so a caller
    testing what went wrong cannot tell the two apart, which is the part that
    has to stay true.
    """
    return Report("syntax error in pattern").with_code(ErrBadPattern).error()


def _has_meta(pattern: StringSlice) -> Bool:
    """Whether `pattern` has anything in it that is not a plain name.

    Go's `hasMeta`. The four bytes are the whole of the pattern language:
    without one of them a pattern is a name, and a name is looked up rather
    than searched for.
    """
    for byte in pattern.as_bytes():
        if (
            byte == Byte(ord("*"))
            or byte == Byte(ord("?"))
            or byte == Byte(ord("["))
            or byte == Byte(ord("\\"))
        ):
            return True
    return False


def glob[F: FS](fsys: F, pattern: String) raises -> List[String]:
    """The names in `fsys` matching `pattern`, sorted. Go's `Glob`.

    ```mojo
    from core.io.fs import FS, glob


    def sources[F: FS](fsys: F) raises -> List[String]:
        return glob(fsys, "*/*.mojo")
    ```

    The order is the order the directories were read in, and those come back
    sorted, so the whole list is sorted. A name that matches nothing is not a
    failure: the answer is an empty list, the same as Go's.

    A file system with `GLOB_FS` answers this itself. Everything else has the
    pattern taken apart here, one element at a time.

    The only raise is `ErrBadPattern`, for a pattern that is not one. A
    directory that could not be read is passed over silently, which is Go's
    rule and is argued in the module docstring.
    """
    if fsys.capabilities() & GLOB_FS:
        return fsys.glob(pattern)
    return _glob(fsys, pattern, 0)


def _glob[F: FS](fsys: F, pattern: String, depth: Int) raises -> List[String]:
    """`glob` without the capability check, and with the recursion counted."""
    if depth > _MAX_DEPTH:
        raise _bad_pattern()

    # Against the empty name, so that a malformed pattern is reported before
    # anything is opened rather than partway through a walk.
    _ = is_match(pattern, "")

    if not _has_meta(pattern):
        # A name rather than a pattern. It matches itself if it is there, and
        # whether it is there is the one question that has to be asked.
        try:
            _ = stat(fsys, pattern)
        except:
            return List[String]()
        return [pattern]

    var cut = split(pattern)
    var dir = _clean_glob_dir(cut[0])
    var file = String(cut[1])

    if not _has_meta(dir):
        var found = List[String]()
        _match_in(fsys, dir, file, found)
        return found^

    # A pattern that is its own directory would recur forever. Go's issue
    # 15879, which was `\\` on Windows and is unreachable here, but the guard
    # is cheap and the alternative is a hang.
    if dir == pattern:
        raise _bad_pattern()

    var found = List[String]()
    for parent in _glob(fsys, dir, depth + 1):
        _match_in(fsys, parent, file, found)
    return found^


def _clean_glob_dir(dir: StringSlice) -> String:
    """The directory half of a split pattern, without its trailing slash.

    Go's `cleanGlobPath`. The empty string is the root, because a pattern with
    no slash in it is a name in the directory being searched, and the root of
    an `fs.FS` is spelled `"."`.
    """
    if dir.byte_length() == 0:
        return "."
    if dir == "/":
        return "/"
    return String(dir[byte = 0 : dir.byte_length() - 1])


def _match_in[
    F: FS
](fsys: F, dir: String, pattern: String, mut found: List[String]) raises:
    """Append every name in `dir` matching `pattern`, joined back onto `dir`.

    Go's unexported `glob`. The listing failing is not a failure here, for the
    reason the module docstring gives; a bad pattern still is, and by the time
    this runs it has already been ruled out once.
    """
    var entries = List[DirEntry]()
    try:
        entries = read_dir(fsys, dir)
    except:
        return

    for entry in entries:
        var name = entry.name()
        if is_match(pattern, name):
            found.append(join([dir, name]))
