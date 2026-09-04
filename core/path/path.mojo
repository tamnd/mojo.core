"""Slash separated paths, taken apart and put back together. Go's `path`.

Seven functions and none of them touches a disk. A path here is text with
slashes in it, which is what a URL path is and what a `tar` entry name is, and
what these functions know about it is where the slashes fall. `core.os` is
where a name becomes a file, and `core.path.filepath` is where it becomes a
name the host operating system would recognise.

Everything is lexical, which is the property worth stating out loud because it
is the one that surprises. `clean("a/../b")` is `"b"` whether or not `a`
exists, and if `a` is a symbolic link to somewhere else then `"b"` is the wrong
answer for the file system and the right answer for a path. Go says the same
thing about the same function, and `filepath.eval_symlinks` is the one that
asks the disk.

## What is a view and what is a copy

`split` and `ext` return a `StringSlice` into the argument, because their
answers are always substrings of it. `clean`, `join`, `dir` and `base` return
an owned `String`. The first two build something that need not appear in the
input at all, `dir` is `clean` of a prefix, and `base` answers `"."` for the
empty path and `"/"` for a path of nothing but slashes, neither of which is a
piece of what it was given.

## Bytes, not runes

The functions in this file compare bytes, and `/` and `.` are ASCII, so a
multi byte character can neither contain one nor be split by one. That is why
there is no rune decoding here and why `clean` on text in any language is the
same work as `clean` on ASCII. `match` in the other file does decode, because a
character class has to know what a character is.
"""

from core.io import Byte
from core.strings import last_index_byte

comptime _SLASH = Byte(ord("/"))
comptime _DOT = Byte(ord("."))


def clean[o: ImmOrigin](path: StringSlice[o]) -> String:
    """The shortest path meaning the same thing. Go's `path.Clean`.

    ```mojo
    from core.path import clean

    print(clean("a/b/../c//./d"))  # => a/c/d
    ```

    Repeated slashes collapse, every `.` element goes, and every inner `..`
    goes along with the element in front of it. A `..` at the start of a rooted
    path goes too, because the parent of the root is the root. The result ends
    in a slash only when it is `"/"`, and the empty path cleans to `"."`.

    Purely lexical, as the package docstring says at more length: this does not
    know whether any element of the path exists or is a symbolic link, and on a
    tree where `a` is a link the answer can name a different file than the
    input did.
    """
    return _clean(path.as_bytes())


def _clean[o: Origin](raw: Span[Byte, o]) -> String:
    """`clean` over bytes, which is where the work happens.

    `join` has its result in a buffer rather than in a string when it needs
    this, and a buffer is what the loop below reads anyway, so the text half of
    the package hands the bytes over the same way `core.strings` hands them to
    `core.bytes`.
    """
    var n = len(raw)
    if n == 0:
        return "."

    # Go's Clean carries a lazybuf that holds off allocating until the output
    # diverges from the input, so that cleaning an already clean path returns
    # the string it was given. That saving is not available here, because the
    # return type is an owned `String` and a copy has to happen either way, so
    # the buffer is allocated up front and the algorithm below is Go's with the
    # laziness taken out. It is the same size: the output of Clean is never
    # longer than its input, which is what lets `w` index a fixed buffer.
    var out = List[Byte](length=n, fill=0)
    var rooted = raw[0] == _SLASH
    var w = 0
    var r = 0

    # Where a `..` has to stop backing up, because everything before it is
    # either the leading slash or a run of `..` that has nowhere to go.
    var dotdot = 0

    if rooted:
        out[0] = _SLASH
        w = 1
        r = 1
        dotdot = 1

    while r < n:
        if raw[r] == _SLASH:
            # An empty element, which is what two slashes in a row are.
            r += 1
        elif raw[r] == _DOT and (r + 1 == n or raw[r + 1] == _SLASH):
            # A `.` element, which names the directory it is already in.
            r += 1
        elif (
            raw[r] == _DOT
            and r + 1 < n
            and raw[r + 1] == _DOT
            and (r + 2 == n or raw[r + 2] == _SLASH)
        ):
            # A `..` element. Back up over the element in front of it if there
            # is one to back up over.
            r += 2
            if w > dotdot:
                w -= 1
                while w > dotdot and out[w] != _SLASH:
                    w -= 1
            elif not rooted:
                # Nothing left to remove and no root to stop at, so the `..`
                # stays and nothing after it may back up past it.
                if w > 0:
                    out[w] = _SLASH
                    w += 1
                out[w] = _DOT
                w += 1
                out[w] = _DOT
                w += 1
                dotdot = w
        else:
            # A real element. It needs a slash in front of it unless it is the
            # first thing written after the root or the first thing at all.
            if (rooted and w != 1) or (not rooted and w != 0):
                out[w] = _SLASH
                w += 1
            while r < n and raw[r] != _SLASH:
                out[w] = raw[r]
                w += 1
                r += 1

    if w == 0:
        return "."
    return String(from_utf8_lossy=Span(out)[0:w])


def split[
    o: ImmOrigin
](path: StringSlice[o]) -> Tuple[
    StringSlice[o].Immutable, StringSlice[o].Immutable
]:
    """`path` cut after its last slash: the directory and the name. Go's
    `path.Split`.

    ```mojo
    from core.path import split

    var dir, file = split("static/img/logo.png")
    print(dir, file)  # => static/img/ logo.png
    ```

    The slash stays on the directory, so the two halves put back together are
    the path they came from, unchanged and uncleaned. A path with no slash in
    it gives an empty directory and the whole path as the name.
    """
    var n = path.byte_length()
    var i = last_index_byte(path, _SLASH)
    return (path[byte = 0 : i + 1], path[byte = i + 1 : n])


def join(elem: List[String]) -> String:
    """The elements run together with slashes, cleaned. Go's `path.Join`.

    ```mojo
    from core.path import join

    print(join(["static", "img", "logo.png"]))  # => static/img/logo.png
    ```

    Empty elements are skipped rather than turned into empty path elements, so
    `join(["a", "", "b"])` is `"a/b"` and not `"a//b"`. No elements at all, or
    nothing but empty ones, gives the empty string rather than `"."`, which is
    the one place in this package where an empty answer is not `"."`.

    Go takes these as a variadic and Mojo has no variadic that survives being
    passed on, so this takes a list. `core.strings.join` takes a list of
    `StringSlice` and this takes a list of `String`, because the pieces of a
    path are usually names a caller owns rather than cuts of a longer string,
    and because a list of slices has to name one origin for all of them, which
    two names from two places do not have.
    """
    var size = 0
    for e in elem:
        size += e.byte_length()
    if size == 0:
        return ""

    # One allocation: every element plus at most one slash between each pair.
    var buf = List[Byte](capacity=size + len(elem) - 1)
    for e in elem:
        if len(buf) > 0 or e.byte_length() > 0:
            if len(buf) > 0:
                buf.append(_SLASH)
            buf.extend(e.as_bytes())
    return _clean(Span(buf))


def ext[o: ImmOrigin](path: StringSlice[o]) -> StringSlice[o].Immutable:
    """The extension, dot included, or nothing. Go's `path.Ext`.

    ```mojo
    from core.path import ext

    print(ext("static/img/logo.png"))  # => .png
    ```

    The suffix from the last dot in the last element. A name with no dot in it
    has no extension, and so does a name whose only dot is in a directory above
    it, which is why the search stops at the first slash it meets going
    backwards. A leading dot counts, so the extension of `".profile"` is
    `".profile"`, exactly as in Go.
    """
    var raw = path.as_bytes()
    var n = len(raw)
    var i = n - 1
    while i >= 0 and raw[i] != _SLASH:
        if raw[i] == _DOT:
            return path[byte=i:n]
        i -= 1
    return path[byte=n:n]


def base[o: ImmOrigin](path: StringSlice[o]) -> String:
    """The last element of `path`. Go's `path.Base`.

    ```mojo
    from core.path import base

    print(base("static/img/logo.png"))  # => logo.png
    ```

    Trailing slashes come off first, so `base("a/b/")` is `"b"`. The empty path
    gives `"."` and a path of nothing but slashes gives `"/"`, and those two
    answers are why this returns an owned `String` while `split` and `ext`
    return a view: neither of them is a piece of the argument.
    """
    var raw = path.as_bytes()
    var end = len(raw)
    if end == 0:
        return "."
    while end > 0 and raw[end - 1] == _SLASH:
        end -= 1
    if end == 0:
        return "/"
    var start = end
    while start > 0 and raw[start - 1] != _SLASH:
        start -= 1
    return String(path[byte=start:end])


def is_abs[o: ImmOrigin](path: StringSlice[o]) -> Bool:
    """Whether `path` starts at the root. Go's `path.IsAbs`.

    One question about one byte: a slash-separated path is absolute when it
    begins with a slash. `core.path.filepath` has the same name for the harder
    version of the question, which on some hosts is about a drive letter.
    """
    var raw = path.as_bytes()
    return len(raw) > 0 and raw[0] == _SLASH


def dir[o: ImmOrigin](path: StringSlice[o]) -> String:
    """Everything but the last element, cleaned. Go's `path.Dir`.

    ```mojo
    from core.path import dir

    print(dir("static/img/logo.png"))  # => static/img
    ```

    This is `clean` of the first half of `split`, which is where its edges come
    from: the empty path gives `"."`, a path whose only slashes are leading
    ones gives `"/"`, and nothing else comes back with a trailing slash. It is
    not `base`'s complement, because it cleans and `base` does not.
    """
    var cut = split(path)
    return clean(cut[0])
