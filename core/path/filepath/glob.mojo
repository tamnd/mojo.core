"""Names on disk that match a pattern. Go's `Glob`.

`is_match` asks whether one name matches a pattern. This asks the directories
themselves, one level of the pattern at a time: the pattern is split at the
last separator, whatever is left of the split is globbed first, and every
answer to that is read and filtered by what was right of it.

Every level is a directory read, so a pattern with three separators in it reads
every directory that matched the first two. That is Go's shape and there is no
cheaper one: the file system is the only thing that knows what names exist.
"""

from core.errors import Report
from core.errors.codes import ErrBadPattern
from core.os import lstat, open, stat
from core.sort import slice

from .filepath import _SEP, is_match, join, split

comptime _DEPTH_LIMIT = 10000
"""How deep the split can recurse before the pattern is called malformed.

One level per separator in the pattern. Go added this bound for CVE-2022-30632,
where a pattern that was nothing but separators drove the recursion until the
stack ran out, and a program that globs a pattern from its input is exactly the
program that gets handed one.
"""

comptime _MAGIC = "*?[\\"
"""The bytes that make a pattern a pattern rather than a name.

A backslash is one of them because it escapes the others, so a pattern holding
one has to go through `is_match` even when nothing else in it is special. Go's
list has the backslash only off Windows, where it is a separator instead.
"""


def _has_meta(text: StringSlice) -> Bool:
    """Whether any of the four pattern bytes is in this text."""
    for byte in text.as_bytes():
        for magic in _MAGIC.as_bytes():
            if byte == magic:
                return True
    return False


def _clean_glob_path(path: StringSlice) -> String:
    """A directory from `split`, with its trailing separator taken off.

    `split` leaves the separator on, and every user of it here wants the
    directory as a name rather than as a prefix. The two special cases are
    Go's: nothing at all means the working directory, and a lone separator is
    the root and has nothing to take off.
    """
    if path.byte_length() == 0:
        return String(".")
    if path.byte_length() == 1 and path.as_bytes()[0] == _SEP:
        return String(path)
    return String(path[byte = : path.byte_length() - 1])


def _sorted_names(mut names: List[String]):
    """A directory's names in the order `glob` reports them, by name."""
    var view = Span(names)

    @parameter
    def by_name(i: Int, j: Int) -> Bool:
        return view[i] < view[j]

    slice[by_name](view)


def _in_dir(dir: String, pattern: String, mut out: List[String]) raises:
    """Append every name in `dir` matching `pattern`, in order.

    A directory that cannot be read is not a failure. It contributes nothing
    and the glob carries on, which is Go's rule and the only workable one for a
    pattern spanning a tree where some directory is not readable: the caller
    asked which names match, not which directories exist.

    A malformed pattern is a failure, because that came from the program rather
    than from the disk.
    """
    try:
        if not stat(dir).is_dir():
            return
    except:
        return

    var names = List[String]()
    try:
        var handle = open(dir)
        names = handle.readdirnames(0)
        handle.close()
    except:
        return
    _sorted_names(names)

    for ref name in names:
        if is_match(pattern, name):
            out.append(join([dir, name]))


def glob(pattern: String) raises -> List[String]:
    """Every name on disk matching `pattern`, sorted. Go's `Glob`.

    ```mojo
    from core.path.filepath import glob

    def main():
        for name in glob("/etc/*.conf"):
            print(name)
    ```

    The syntax is `is_match`'s, so `*` matches within one path element and
    never across a separator, `?` matches one character, `[abc]` and `[^abc]`
    are character classes, and a backslash escapes any of them. There is no
    `**`.

    No matches is an empty list and not a failure, which is Go's rule and the
    one that surprises people: a pattern naming a directory that does not exist
    gives nothing back rather than saying so. A directory that exists and
    cannot be read gives nothing back either, for the same reason, and the only
    failure this raises is `ErrBadPattern` for a pattern that is not one.

    A pattern with nothing special in it is a single `lstat`, so it either
    gives back that one name or gives back nothing.
    """
    return _glob(pattern, 0)


def _glob(pattern: String, depth: Int) raises -> List[String]:
    """`glob`, carrying how many separators deep the recursion is."""
    if depth == _DEPTH_LIMIT:
        raise _bad_pattern(pattern)

    # Ask `is_match` about the empty name first, purely to find out whether the
    # pattern is well formed, before anything touches a disk.
    _ = is_match(pattern, "")

    if not _has_meta(pattern):
        try:
            _ = lstat(pattern)
        except:
            return List[String]()
        return [pattern]

    var head, tail = split(pattern)
    var dir = _clean_glob_path(head)
    var file = String(tail)

    var out = List[String]()
    if not _has_meta(dir):
        _in_dir(dir, file, out)
        return out^

    # A pattern that splits to itself would recurse for ever. Go stops here
    # rather than at the depth limit, because the depth limit would take ten
    # thousand turns to notice.
    if dir == pattern:
        raise _bad_pattern(pattern)

    for ref parent in _glob(dir, depth + 1):
        _in_dir(parent, file, out)
    return out^


def _bad_pattern(pattern: String) -> Error:
    """The one failure `glob` has of its own."""
    return (
        Report(String("syntax error in pattern: ", pattern))
        .with_code(ErrBadPattern)
        .with_field("pattern", pattern)
        .error()
    )
