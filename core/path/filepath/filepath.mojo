"""The lexical half of `core.path.filepath`, which is most of it.

Everything here reads the string it was given and nothing else. `abs`,
`eval_symlinks`, `glob`, `walk` and `walk_dir` are the other half and are the
ones that ask a disk; they are not written yet.
"""

from core.errors import Report
from core.errors.codes import ErrInvalidPath, ErrRelPath
from core.io import Byte
from core.io.fs import valid_path
from core.path import base as slash_base
from core.path import clean as slash_clean
from core.path import dir as slash_dir
from core.path import ext as slash_ext
from core.path import is_abs as slash_is_abs
from core.path import is_match as slash_is_match
from core.path import join as slash_join
from core.path import split as slash_split

comptime SEPARATOR = Int32(ord("/"))
"""What separates the elements of a path on this host. Go's `Separator`."""

comptime LIST_SEPARATOR = Int32(ord(":"))
"""What separates the paths in a list such as `PATH`. Go's `ListSeparator`."""

comptime _SEP = Byte(ord("/"))
comptime _LIST_SEP = Byte(ord(":"))
comptime _DOT = Byte(ord("."))
comptime _NUL = Byte(0)


def clean[o: ImmOrigin](path: StringSlice[o]) -> String:
    """The shortest host path meaning the same thing. Go's `filepath.Clean`.

    ```mojo
    from core.path.filepath import clean

    print(clean("/usr//local/../bin/./ls"))  # => /usr/bin/ls
    ```

    Repeated separators collapse, every `.` element goes, and every inner `..`
    goes along with the element in front of it. The empty path cleans to `"."`.

    Lexical, which is the word that matters and is why this is not the same
    question as `eval_symlinks`. If `/usr/local` is a link to `/opt`, then
    `clean("/usr/local/../bin")` is `/usr/bin` and the file the input named is
    somewhere else entirely. Go's `Clean` says the same about itself.
    """
    return slash_clean(path)


def to_slash[o: ImmOrigin](path: StringSlice[o]) -> String:
    """`path` with every separator turned into a slash. Go's `ToSlash`.

    The two hosts this library supports separate with a slash, so this is the
    path it was given. It is here rather than deleted because it is the line
    where a host path becomes a `core.path` one, and a program that draws that
    line is a program that still draws it on a host that separates with
    something else. `from_slash` is the way back.

    An owned `String` rather than a view of the argument, because on such a
    host the answer is a different string and a signature that told the truth
    on this one would have to change on that one.
    """
    return String(path)


def from_slash[o: ImmOrigin](path: StringSlice[o]) -> String:
    """`path` with every slash turned into a separator. Go's `FromSlash`.

    The other direction of `to_slash`, and on this host the same answer: what
    it was given. `localize` is the stricter version of this question and the
    one to reach for when the name came from outside the program, since it
    refuses a name that would escape rather than converting it.
    """
    return String(path)


def split_list[o: ImmOrigin](path: StringSlice[o]) -> List[String]:
    """A list of paths cut at the list separator. Go's `SplitList`.

    ```mojo
    from core.path.filepath import split_list

    print(len(split_list("/usr/bin:/bin")))  # => 2
    ```

    What `PATH` and its relatives are made of. The empty string is no paths at
    all rather than one empty path, which is Go's answer and the useful one,
    and every other string has one more element than it has separators, so a
    leading or trailing separator gives an empty element that is a real element.
    """
    var out = List[String]()
    var raw = path.as_bytes()
    if len(raw) == 0:
        return out^

    var start = 0
    for i in range(len(raw) + 1):
        if i == len(raw) or raw[i] == _LIST_SEP:
            out.append(String(path[byte=start:i]))
            start = i + 1
    return out^


def volume_name[o: ImmOrigin](path: StringSlice[o]) -> StringSlice[o].Immutable:
    """The leading volume name, which on this host is nothing. Go's
    `VolumeName`.

    On Windows this is `C:` or the host and share of a network path, and it is
    the part of a path that the rest of these functions must not take apart. On
    the hosts here there is no such part, so the answer is always empty. A view
    into the argument rather than a `String`, because it is always a prefix of
    it.
    """
    return path[byte=0:0]


def is_abs[o: ImmOrigin](path: StringSlice[o]) -> Bool:
    """Whether `path` names a place without needing a working directory. Go's
    `filepath.IsAbs`.

    One byte on this host: a path is absolute when it begins with a separator.
    Not the same question as `is_local`, which asks whether a path stays inside
    the directory it is relative to, and the two are not opposites: `a/../..`
    is neither absolute nor local.
    """
    return slash_is_abs(path)


def is_local[o: ImmOrigin](path: StringSlice[o]) -> Bool:
    """Whether `path` stays inside the directory it is relative to. Go's
    `IsLocal`.

    ```mojo
    from core.path.filepath import is_local

    print(is_local("a/b"))  # => True
    print(is_local("../a"))  # => False
    ```

    True for a path that is not empty, not absolute, and does not climb out
    with `..`. It is the question to ask about a name that arrived from
    somewhere else and is about to be joined onto a directory, because a name
    that answers true cannot name anything outside that directory.

    Lexical like everything else here, so it does not know about symbolic
    links: a local path can still lead out of the tree if something in it is a
    link, and `eval_symlinks` is the one that asks.
    """
    var raw = path.as_bytes()
    if len(raw) == 0 or raw[0] == _SEP:
        return False

    # Cleaning is only needed when there is something to clean, and a path with
    # no dot element in it is already as short as it goes.
    var dots = False
    var start = 0
    for i in range(len(raw) + 1):
        if i == len(raw) or raw[i] == _SEP:
            var elem = raw[start:i]
            if len(elem) == 1 and elem[0] == _DOT:
                dots = True
                break
            if len(elem) == 2 and elem[0] == _DOT and elem[1] == _DOT:
                dots = True
                break
            start = i + 1
    if not dots:
        return True

    var short = clean(path)
    return not (short == ".." or short.startswith("../"))


def localize[o: ImmOrigin](path: StringSlice[o]) raises -> String:
    """A slash separated name as a path on this host. Go's `Localize`.

    ```mojo
    from core.path.filepath import localize

    print(localize("a/b"))  # => a/b
    ```

    The name has to be one `core.io.fs.valid_path` accepts, so it is relative,
    already clean, not empty and valid UTF-8, and it has to hold no byte this
    host refuses in a file name, which here is only NUL. Anything else raises
    `ErrInvalidPath`.

    This is the safe way in from a name that came from outside the program, an
    entry in an archive or a field in a request. `from_slash` converts and asks
    nothing; this refuses, and what it refuses is every name that would have
    named a file the sender was not entitled to name. The result always answers
    true to `is_local`.
    """
    if not valid_path(path):
        raise (
            Report("filepath: invalid path")
            .with_field("path", String(path))
            .with_code(ErrInvalidPath)
            .error()
        )
    var raw = path.as_bytes()
    for i in range(len(raw)):
        # A NUL ends a file name in every system call this host has, so a name
        # with one in it would be cut short rather than refused, and the file
        # opened would not be the file named.
        if raw[i] == _NUL:
            raise (
                Report("filepath: invalid path")
                .with_field("path", String(path))
                .with_code(ErrInvalidPath)
                .error()
            )
    return String(path)


def split[
    o: ImmOrigin
](path: StringSlice[o]) -> Tuple[
    StringSlice[o].Immutable, StringSlice[o].Immutable
]:
    """`path` cut after its last separator: the directory and the file. Go's
    `filepath.Split`.

    ```mojo
    from core.path.filepath import split

    var dir, file = split("/usr/bin/ls")
    print(dir, file)  # => /usr/bin/ ls
    ```

    The separator stays on the directory, so the two halves put back together
    are the path they came from, unchanged and uncleaned.
    """
    return slash_split(path)


def join(elem: List[String]) -> String:
    """The elements run together with separators, cleaned. Go's
    `filepath.Join`.

    ```mojo
    from core.path.filepath import join

    print(join(["/usr", "bin", "ls"]))  # => /usr/bin/ls
    ```

    Empty elements are skipped, so joining onto an empty first element gives a
    relative path rather than an absolute one. Nothing but empty elements gives
    the empty string.

    The result is cleaned, which is the part worth knowing when one of the
    elements came from somewhere else: `join(["/srv", "../etc/passwd"])` is
    `/etc/passwd` and not a path under `/srv`. `is_local` on the element, or
    `localize` if it arrived as a slash separated name, is what answers that
    before the join rather than after it.

    Go takes these as a variadic and Mojo has no variadic that survives being
    passed on, so this takes a list, as `core.path.join` does.
    """
    return slash_join(elem)


def ext[o: ImmOrigin](path: StringSlice[o]) -> StringSlice[o].Immutable:
    """The extension, dot included, or nothing. Go's `filepath.Ext`.

    ```mojo
    from core.path.filepath import ext

    print(ext("/home/me/notes.tar.gz"))  # => .gz
    ```

    The suffix from the last dot in the last element, so a dot in a directory
    above the file is not an extension and a name with no dot has none.
    """
    return slash_ext(path)


def base[o: ImmOrigin](path: StringSlice[o]) -> String:
    """The last element of `path`. Go's `filepath.Base`.

    ```mojo
    from core.path.filepath import base

    print(base("/usr/bin/ls"))  # => ls
    ```

    Trailing separators come off first. The empty path gives `"."` and a path
    of nothing but separators gives one separator, and those two answers are
    why this returns an owned `String` rather than a view.
    """
    return slash_base(path)


def dir[o: ImmOrigin](path: StringSlice[o]) -> String:
    """Everything but the last element, cleaned. Go's `filepath.Dir`.

    ```mojo
    from core.path.filepath import dir

    print(dir("/usr/bin/ls"))  # => /usr/bin
    ```

    This is `clean` of the first half of `split`, so the empty path gives
    `"."`, a path whose only separators are leading ones gives one separator,
    and nothing else comes back with a trailing separator. It is not `base`'s
    complement, because it cleans and `base` does not.
    """
    return slash_dir(path)


def is_match[
    o1: ImmOrigin, o2: ImmOrigin
](pattern: StringSlice[o1], name: StringSlice[o2]) raises -> Bool:
    """Whether `name` matches the shell pattern `pattern`. Go's
    `filepath.Match`.

    ```mojo
    from core.path.filepath import is_match

    print(is_match("*.mojo", "main.mojo"))  # => True
    ```

    The same patterns `core.path.is_match` takes, with `*` and `?` stopping at
    the host separator rather than at a slash, which on this host is the same
    rule. All of `name` has to match, not a piece of it, so this answers a
    question about one name and `glob`, when it is written, is the one that
    goes looking for the names.

    Raises with `ErrBadPattern` when the pattern is malformed, which is the only
    failure there is. A name that does not match is `False` and not an error.
    """
    return slash_is_match(pattern, name)


def rel[
    ob: ImmOrigin, ot: ImmOrigin
](basepath: StringSlice[ob], targpath: StringSlice[ot]) raises -> String:
    """The path from `basepath` to `targpath`. Go's `Rel`.

    ```mojo
    from core.path.filepath import rel

    print(rel("/a/b", "/a/b/c/d"))  # => c/d
    print(rel("/a/b/c", "/a/d"))  # => ../../d
    ```

    `join(basepath, rel(basepath, targpath))` names the same file as
    `targpath`, which is the property this exists for. Both paths are cleaned
    first, so the answer is in terms of what they mean rather than how they
    were spelled.

    Raises `ErrRelPath` when reading the two strings cannot answer it, which is
    when one is absolute and the other is not, or when the base climbs out with
    a `..` whose name only the working directory knows.

    Lexical, so if `basepath` or anything above `targpath` is a symbolic link,
    the answer is right about the names and can be wrong about the files.
    """
    var base_ = clean(basepath)
    var targ = clean(targpath)
    if targ == base_:
        return "."
    if base_ == ".":
        base_ = ""

    var b = base_.as_bytes()
    var t = targ.as_bytes()
    var bl = len(b)
    var tl = len(t)

    # `is_abs` would answer this on a host where a path can be rooted without
    # starting at the root, and this is the question Go asks instead, so that
    # the two halves are compared the same way whatever they start with.
    var base_slashed = bl > 0 and b[0] == _SEP
    var targ_slashed = tl > 0 and t[0] == _SEP
    if base_slashed != targ_slashed:
        raise _no_route(basepath, targpath)

    # Walk both paths one element at a time until they stop agreeing. `b0` and
    # `t0` are where the current element starts and `bi` and `ti` are where it
    # ends, so when the loop breaks the two tails are what has to be undone and
    # what has to be walked.
    var b0 = 0
    var bi = 0
    var t0 = 0
    var ti = 0
    while True:
        while bi < bl and b[bi] != _SEP:
            bi += 1
        while ti < tl and t[ti] != _SEP:
            ti += 1
        if not _same(t[t0:ti], b[b0:bi]):
            break
        if bi < bl:
            bi += 1
        if ti < tl:
            ti += 1
        b0 = bi
        t0 = ti

    if bi - b0 == 2 and b[b0] == _DOT and b[b0 + 1] == _DOT:
        # The base still has a `..` in it after cleaning, so it names a
        # directory above the one everything is relative to, and what that
        # directory is called is not in either string.
        raise _no_route(basepath, targpath)

    if b0 != bl:
        # Base elements left over, so the answer goes up before it comes down.
        var seps = 0
        for i in range(b0, bl):
            if b[i] == _SEP:
                seps += 1

        var size = 2 + seps * 3
        if tl != t0:
            size += 1 + tl - t0
        var buf = List[Byte](capacity=size)
        buf.append(_DOT)
        buf.append(_DOT)
        for _ in range(seps):
            buf.append(_SEP)
            buf.append(_DOT)
            buf.append(_DOT)
        if t0 != tl:
            buf.append(_SEP)
            buf.extend(t[t0:tl])
        var up = String(from_utf8_lossy=Span(buf))
        return clean(up.as_string_slice().as_imm())

    return String(from_utf8_lossy=t[t0:tl])


def _same[a: Origin, b: Origin](x: Span[Byte, a], y: Span[Byte, b]) -> Bool:
    """Whether two path elements are the same one.

    Byte for byte on this host. Go compares this way behind a `sameWord` that
    is case folding on Windows, and the name is kept so that the place where
    that would go is visible.
    """
    if len(x) != len(y):
        return False
    for i in range(len(x)):
        if x[i] != y[i]:
            return False
    return True


def _no_route[
    ob: ImmOrigin, ot: ImmOrigin
](basepath: StringSlice[ob], targpath: StringSlice[ot]) -> Error:
    """The failure both of `rel`'s refusals raise, with Go's message."""
    return (
        Report(
            String(
                "Rel: can't make ",
                targpath,
                " relative to ",
                basepath,
            )
        )
        .with_field("base", String(basepath))
        .with_field("target", String(targpath))
        .with_code(ErrRelPath)
        .error()
    )
