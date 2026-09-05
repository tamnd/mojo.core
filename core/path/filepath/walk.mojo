"""Visiting every name under a directory. Go's `Walk` and `WalkDir`.

Two walks of the same tree, one callback each, and the difference is what the
callback is handed. `walk_dir` gives a `DirEntry`, which knows its name and
what kind of file it is out of the directory read that found it. `walk` gives a
`FileInfo`, which costs a `lstat` per name whether or not the callback wanted
one. `walk_dir` is the one to reach for, and `walk` is here because Go's is and
because a callback that needs the size or the modification time of everything
would have made that call anyway.

Neither follows a symbolic link. A link is reported as a link and the walk does
not go through it, which is what keeps a tree with a link back to its own
parent from being a walk that never ends.

Names come in sorted order, which means a directory is read whole before any of
it is visited. Go makes the same trade and says so: the memory is the price of
output that does not move between two runs over the same tree.

## The callback raises its answer

Go's callback returns an error and the walk reads it. Here it raises, and the
three answers are the same three: raise nothing and the walk carries on, raise
`SkipDir` and it leaves this directory alone, raise `SkipAll` and it stops
without a failure. Anything else stops the walk and comes out of it.

`SkipDir` from a callback that was handed a file rather than a directory skips
the rest of the directory that file is in. That is Go's rule, it is not what
most people guess, and it is the reason a callback that means to stop entirely
should raise `SkipAll`.
"""

from core.errors import ErrorValue, capture, matches
from core.io.fs import (
    DirEntry,
    FileInfo,
    FileMode,
    SkipAll,
    SkipDir,
    WalkDirFunc,
    file_info_to_dir_entry,
)
from core.os import lstat, open, read_dir
from core.sort import slice
from core.time import Time

from .filepath import base, join

comptime WalkFunc = def(
    String, FileInfo, Optional[ErrorValue]
) raises capturing[_] -> None
"""The callback `walk` makes, once per name. Go's `WalkFunc`.

The path, what the host says about it, and a failure that got in the way of
finding that out. The path starts with the root the walk was given, joined with
`join`, so a walk rooted at `x/../dir` reports `dir/a` and not `x/../dir/a`.

The third argument is `None` when nothing went wrong. It carries something in
two cases, which are Go's two: a `lstat` that failed, on the root or on any
name under it, and a directory whose listing could not be read. In the first
case the info is a placeholder holding the base name and nothing else, since
nothing else was ever learned; in the second it is the directory's own info,
which is real.

Go passes a nil `FileInfo` for that first case and a caller who forgets to
check the error dereferences nil. The placeholder is here so that the same
mistake reads a name that is true instead of ending the process.
"""


def _unknown(path: String) -> FileInfo:
    """The info for a name nothing is known about.

    The base name, because it is the one thing that is certainly true, and
    zeros for the rest. Only ever handed to a callback alongside the failure
    that explains why there is nothing better.
    """
    return FileInfo(name=base(path), size=0, mode=FileMode(0), mod_time=Time())


def _unknown_entry(path: String) -> DirEntry:
    """The same, as a `DirEntry`. No type, so `is_dir` is false."""
    return DirEntry(dir="", name=base(path), type=FileMode(0))


def _sorted_names(mut names: List[String]):
    """Put a directory's names in the order a walk reports them, by name."""
    var view = Span(names)

    @parameter
    def by_name(i: Int, j: Int) -> Bool:
        return view[i] < view[j]

    slice[by_name](view)


def _read_dir_names(path: String) raises -> List[String]:
    """Every name in a directory, sorted, without asking about any of them.

    Go's `readDirNames`, and the reason `walk` does not simply call `read_dir`:
    the entries would carry a type this is about to `lstat` for anyway.
    """
    var dir = open(path)
    var names = dir.readdirnames(0)
    dir.close()
    _sorted_names(names)
    return names^


def walk[visit: WalkFunc](root: String) raises:
    """Call `visit` for `root` and everything under it. Go's `Walk`.

    ```mojo
    from core.errors import ErrorValue
    from core.io.fs import FileInfo
    from core.path.filepath import walk

    def main():
        @parameter
        def visit(path: String, info: FileInfo, err: Optional[ErrorValue]):
            if not err:
                print(path, info.size())

        walk[visit]("/etc/ssl")
    ```

    `root` itself is visited first, whether it is a directory or not. A failure
    reaching any name is handed to `visit` rather than raised here, so the
    callback decides whether a directory it may not read ends the walk.

    `SkipDir` and `SkipAll` raised by `visit` are handled and do not come out.
    Anything else does, unchanged.
    """
    try:
        var held = Optional[FileInfo]()
        var failed = Optional[ErrorValue]()
        try:
            held = Optional[FileInfo](lstat(root))
        except e:
            failed = Optional[ErrorValue](capture(e))
        if failed:
            visit(root, _unknown(root), failed)
        else:
            _walk[visit](root, held.take())
    except e:
        if matches(e, SkipDir) or matches(e, SkipAll):
            return
        raise e


def _walk[visit: WalkFunc](path: String, var info: FileInfo) raises:
    """One name, and everything under it if it is a directory."""
    if not info.is_dir():
        visit(path, info, None)
        return

    var names = List[String]()
    var failed = Optional[ErrorValue]()
    try:
        names = _read_dir_names(path)
    except e:
        failed = Optional[ErrorValue](capture(e))

    # The callback is told about the directory and about the failed read in
    # one call, and either of those two ends the descent: there is nothing to
    # descend into when the read failed, and the callback has said no when it
    # raised. What the callback raised is what comes out, because the callback
    # is allowed to swallow the read failure and is allowed to add one.
    var refused = Optional[ErrorValue]()
    try:
        visit(path, info, failed)
    except e:
        refused = Optional[ErrorValue](capture(e))
    if refused:
        raise refused.value().error()
    if failed:
        return

    for ref name in names:
        var child = join([path, name])
        var child_info = Optional[FileInfo]()
        var child_failed = Optional[ErrorValue]()
        try:
            child_info = Optional[FileInfo](lstat(child))
        except e:
            child_failed = Optional[ErrorValue](capture(e))

        if child_failed:
            try:
                visit(child, _unknown(child), child_failed)
            except e:
                if not matches(e, SkipDir):
                    raise e
        else:
            var child_is_dir = child_info.value().is_dir()
            try:
                _walk[visit](child, child_info.take())
            except e:
                if not child_is_dir or not matches(e, SkipDir):
                    raise e


def walk_dir[visit: WalkDirFunc](root: String) raises:
    """Call `visit` for `root` and everything under it. Go's `WalkDir`.

    ```mojo
    from core.errors import ErrorValue
    from core.io.fs import DirEntry
    from core.path.filepath import walk_dir

    def main():
        @parameter
        def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]):
            if not err and entry.is_dir():
                print(path)

        walk_dir[visit]("/etc/ssl")
    ```

    The same walk as `walk` with one call per name saved: the entry already
    knows whether it is a directory, so nothing is asked about a name the
    callback did not ask about. Prefer this one.

    `SkipDir` and `SkipAll` raised by `visit` are handled and do not come out.
    Anything else does, unchanged.
    """
    try:
        var held = Optional[FileInfo]()
        var failed = Optional[ErrorValue]()
        try:
            held = Optional[FileInfo](lstat(root))
        except e:
            failed = Optional[ErrorValue](capture(e))
        if failed:
            visit(root, _unknown_entry(root), failed)
        else:
            _walk_dir[visit](root, file_info_to_dir_entry(held.take()))
    except e:
        if matches(e, SkipDir) or matches(e, SkipAll):
            return
        raise e


def _walk_dir[visit: WalkDirFunc](path: String, var entry: DirEntry) raises:
    """One entry, and everything under it if it is a directory."""
    var is_dir = entry.is_dir()

    var refused = Optional[ErrorValue]()
    try:
        visit(path, entry, None)
    except e:
        refused = Optional[ErrorValue](capture(e))
    if refused or not is_dir:
        if refused and not (refused.value().matches(SkipDir) and is_dir):
            raise refused.value().error()
        return

    var entries = List[DirEntry]()
    var failed = Optional[ErrorValue]()
    try:
        entries = read_dir(path)
    except e:
        failed = Optional[ErrorValue](capture(e))

    if failed:
        # A second call, this time to report the read. The callback can let the
        # walk carry on, which it then does over an empty listing.
        var again = Optional[ErrorValue]()
        try:
            visit(path, entry, failed)
        except e:
            again = Optional[ErrorValue](capture(e))
        if again:
            if not again.value().matches(SkipDir):
                raise again.value().error()
            return

    for ref found in entries:
        var child = join([path, found.name()])
        try:
            _walk_dir[visit](child, found.copy())
        except e:
            # A `SkipDir` that reached here came from a callback given a file,
            # so it means the rest of this directory rather than that one name.
            if matches(e, SkipDir):
                break
            raise e
