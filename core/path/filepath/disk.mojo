"""The two path questions that need a disk to answer. Go's `Abs` and
`EvalSymlinks`.

Everything in `filepath.mojo` is a string operation and gives the same answer
on a machine with no file system at all. These two are the opposite: `abs`
needs to know where the process is standing and `eval_symlinks` needs to know
what every component of the path really is, so both can fail and both give an
answer that was only true at the moment it was taken.
"""

from core.io import Byte
from core.io.fs import MODE_SYMLINK
from core.io.fs.errors import _path_error
from core.os import getwd, lstat, readlink
from core.syscall import ELOOP, ENOTDIR, Errno

from .filepath import _SEP, clean, is_abs, join

comptime _MAX_LINKS = 255
"""How many links `eval_symlinks` follows before it calls it a loop. Go's
number.

There is no way to tell a long chain from a cycle except by giving up on one of
them, and the kernel makes the same bargain with the same kind of number when
it opens a path. Two hundred and fifty five is far past any real chain and far
short of a walk that takes noticeable time.
"""


def _at(s: String, i: Int) -> Byte:
    """One byte of a string by position.

    A function rather than a slice because the strings here are being rebuilt
    as the loop runs, and a borrow held across the rebuild is the kind of thing
    that has to be written out of the code rather than argued about.
    """
    return s.as_bytes()[i]


def abs(path: String) raises -> String:
    """`path` as an absolute path, cleaned. Go's `Abs`.

    ```mojo
    from core.path.filepath import abs

    def main():
        print(abs("/usr/../bin"))  # => /bin
    ```

    A path that is already absolute is only cleaned and nothing is asked of the
    disk. A relative one is joined onto the working directory, which is the
    single call this can fail on: a process whose working directory has been
    removed out from under it has no answer to give.

    The result is lexical, so it can name something that is not there and a
    symbolic link along the way is left as it is. `eval_symlinks` is the one
    that resolves them, and `eval_symlinks(abs(p))` is the pair Go recommends
    for a path that has to be compared with another.
    """
    if is_abs(path):
        return clean(path)
    return join([getwd(), path])


def eval_symlinks(path: String) raises -> String:
    """`path` with every symbolic link in it followed. Go's `EvalSymlinks`.

    ```mojo
    from core.path.filepath import eval_symlinks

    def main():
        print(eval_symlinks("/tmp/./"))  # => /private/tmp on macOS
    ```

    Every component is resolved, not just the last one, so a link in the middle
    of the path is followed too. The result is cleaned. A relative path stays
    relative unless a link along the way was absolute, which is Go's rule and
    is why the answer is not simply `abs` of the input.

    Every component has to exist. This is the difference between this and the
    lexical calls: `clean("a/../b")` answers without looking, and this raises if
    `a` is not there, because whether `a` is a link decides what the answer is.

    A component that is not a directory and is not the last one raises with
    `ENOTDIR`, and a chain longer than 255 links raises with `ELOOP`. Go raises
    the first as a bare errno with no path on it and the second as a message
    with no code at all, so neither can be told apart from anything else by a
    caller; both are a `PathError` here, carrying the operation, the path and
    the number.

    Not a security boundary on its own. The path this gives back was true when
    it was worked out, and a link along the way can be replaced a moment later,
    so a program that opens the result is opening a name and not the file it
    checked. `core.os.open_file` on a descriptor is what closes that window,
    and it is not written yet.
    """
    var rest = path
    var vol_len = 0
    if rest.byte_length() > 0 and _at(rest, 0) == _SEP:
        vol_len = 1
    var vol = String(rest[byte=:vol_len])
    var dest = String(vol)
    var links = 0
    var start = vol_len
    var end = vol_len

    while start < rest.byte_length():
        while start < rest.byte_length() and _at(rest, start) == _SEP:
            start += 1
        end = start
        while end < rest.byte_length() and _at(rest, end) != _SEP:
            end += 1
        if end == start:
            break

        var part = String(rest[byte=start:end])
        if part == ".":
            start = end
            continue
        if part == "..":
            # Back up one component of the answer, unless the answer is
            # already nothing but `..`, in which case one more is the only
            # honest thing to write.
            var r = _last_sep(dest, vol_len)
            if r < vol_len or String(dest[byte = r + 1 :]) == "..":
                if dest.byte_length() > vol_len:
                    dest += "/"
                dest += ".."
            else:
                var kept = String(dest[byte=:r])
                dest = kept^
            start = end
            continue

        if dest.byte_length() > 0 and _at(dest, dest.byte_length() - 1) != _SEP:
            dest += "/"
        dest += part

        var info = lstat(dest)
        if not (info.mode() & MODE_SYMLINK):
            if not info.mode().is_dir() and end < rest.byte_length():
                raise _path_error("evalsymlinks", dest, Errno(ENOTDIR))
            start = end
            continue

        links += 1
        if links > _MAX_LINKS:
            raise _path_error("evalsymlinks", path, Errno(ELOOP))

        var link = readlink(dest)
        var joined = String(link, rest[byte=end:])
        rest = joined^
        if link.byte_length() > 0 and _at(link, 0) == _SEP:
            # An absolute link throws away everything worked out so far.
            vol = String(link[byte=:1])
            vol_len = 1
            dest = String(vol)
            end = 1
        else:
            # A relative link replaces the component it was found at.
            var r = _last_sep(dest, vol_len)
            if r < vol_len:
                dest = String(vol)
            else:
                var kept = String(dest[byte=:r])
                dest = kept^
            end = 0
        start = end

    return clean(dest)


def _last_sep(s: String, floor: Int) -> Int:
    """The position of the last separator in `s` at or after `floor`.

    `floor - 1` when there is none, which the two callers test for rather than
    treating as a position, since it means the answer has no components left to
    take away.
    """
    var r = s.byte_length() - 1
    while r >= floor and _at(s, r) != _SEP:
        r -= 1
    return r
