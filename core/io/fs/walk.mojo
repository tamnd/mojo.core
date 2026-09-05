"""What a tree walk calls, and the two answers that steer it. Go's
`fs.WalkDirFunc`, `fs.SkipDir` and `fs.SkipAll`.

`walk_dir` is here too, walking any `FS`. `core.path.filepath.walk_dir` walks a
real disk with the same callback, and the two are different code over different
things: this one asks a file system value for a listing and that one makes
system calls. The callback type lives here for the reason Go put it here, which
is that a helper written for one walk has to work with the other or everybody
writes it twice.

## Raising is how the callback answers

Go's callback returns an error and the walk reads it. Here it raises, and the
walk catches. `SkipDir` and `SkipAll` are the two raises that mean something
other than failure, and a walk turns both of them back into an ordinary return
rather than passing them on, so a caller never sees one come out.

Anything else raised by the callback stops the walk and comes out of it
unchanged, which is Go's rule as well: the callback is the only thing that
decides whether a failure is fatal.
"""

from core.errors import ErrorValue, Report, capture, matches
from core.errors.codes import SkipAll, SkipDir
from core.path import join

from core.path import base as _base

from .direntry import DirEntry, file_info_to_dir_entry
from .fs import FS
from .info import FileInfo
from .mode import FileMode
from .read import read_dir, stat

comptime WalkDirFunc = def(
    String, DirEntry, Optional[ErrorValue]
) raises capturing[_] -> None
"""The callback a tree walk makes, once per name. Go's `fs.WalkDirFunc`.

The first argument is the path, which begins with the root the walk was given.
The second is the entry, which knows its own name and what kind of file it is
without a second call. The third is a failure that happened while trying to
reach or read that name, and it is the whole reason the callback is handed one
at all: a walk over somebody's home directory hits a directory it may not read,
and only the caller knows whether that ends the walk or is a line in a report.

The third argument is `None` when nothing went wrong, and when it is not, the
entry is what was known before the failure. Go passes a nil `DirEntry` in the
one case where nothing at all is known, which is a root that could not be
stat'ed, and a caller who forgets to check the error dereferences nil. Here the
entry in that case holds the base name of the root and no type, so the same
mistake reads a name that is true rather than ending the process.

A callback that does not raise is accepted, so the common case of a walk that
cannot fail does not have to write `raises` on a function that never does.
"""


def skip_dir() -> Error:
    """The raise that tells a walk to leave this directory alone.

    ```mojo
    from core.errors import ErrorValue
    from core.io.fs import DirEntry, skip_dir

    def main():
        @parameter
        def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]) raises:
            if entry.name() == ".git":
                raise skip_dir()
            print(path)
    ```

    Handed to `core.path.filepath.walk_dir`, that one prints every path under a
    tree and never goes into a `.git`. It is not imported here because this
    package sits underneath that one.

    Go returns `fs.SkipDir` and there is nothing to return here, so this builds
    the raise instead. It exists rather than leaving every callback to write
    `Report(...).with_code(SkipDir).error()` for itself, which is three calls
    and a message somebody has to invent for a thing that is not a failure.
    """
    return Report("skip this directory").with_code(SkipDir).error()


def skip_all() -> Error:
    """The raise that tells a walk to stop, with nothing wrong.

    The one to reach for when a callback has found what it came for. `skip_dir`
    from a callback that was handed a file only skips the rest of that one
    directory, which is not what somebody who means to stop usually wants.
    """
    return Report("skip the rest of the walk").with_code(SkipAll).error()


def walk_dir[visit: WalkDirFunc, F: FS](fsys: F, root: String) raises:
    """Call `visit` for `root` and everything under it. Go's `fs.WalkDir`.

    ```mojo
    from core.errors import ErrorValue
    from core.io.fs import DirEntry, FS, walk_dir


    def names[F: FS](fsys: F) raises:
        @parameter
        def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]):
            if not err:
                print(path)

        walk_dir[visit](fsys, ".")
    ```

    `root` is visited first, whether or not it is a directory, and every name
    under it follows in sorted order, because that is the order `read_dir`
    promises. The paths handed to the callback start with `root`, so a walk
    from `"."` reports `a/b` and a walk from `"a"` reports `a/b` as well.

    A failure is handed to the callback rather than raised here, in the two
    cases Go has: the root could not be stat'ed, and a directory could not be
    listed. In the first case the entry holds the base name of the root and no
    type, which is where Go passes nil; in the second it is the directory's own
    entry, which is real.

    `SkipDir` and `SkipAll` raised by the callback are handled and do not come
    out of here. Anything else does, unchanged.

    Links are not followed, and there is nothing here that would follow one: a
    listing says what each name is and this walks the ones that say directory.
    """
    try:
        var held = Optional[FileInfo]()
        var failed = Optional[ErrorValue]()
        try:
            held = Optional[FileInfo](stat(fsys, root))
        except e:
            failed = Optional[ErrorValue](capture(e))
        if failed:
            visit(root, _unknown_entry(root), failed)
        else:
            _walk_dir[visit](fsys, root, file_info_to_dir_entry(held.take()))
    except e:
        if matches(e, SkipDir) or matches(e, SkipAll):
            return
        raise e


def _unknown_entry(path: String) -> DirEntry:
    """The entry for a root nothing is known about.

    Its base name, which is true, and no type, so `is_dir` is false. Only ever
    handed to a callback beside the failure that explains why there is nothing
    better. `core.path.filepath` has the same helper for the same reason.
    """
    return DirEntry(dir="", name=_base(path), type=FileMode(0))


def _walk_dir[
    visit: WalkDirFunc, F: FS
](fsys: F, path: String, var entry: DirEntry) raises:
    """One entry, and everything under it if it is a directory."""
    var is_dir = entry.is_dir()

    var refused = Optional[ErrorValue]()
    try:
        visit(path, entry, None)
    except e:
        refused = Optional[ErrorValue](capture(e))
    if refused or not is_dir:
        # A `SkipDir` about a directory has done its job by stopping the
        # descent, so it goes no further. About a file it means the rest of the
        # directory the file is in, which is the caller of this one to decide.
        if refused and not (refused.value().matches(SkipDir) and is_dir):
            raise refused.value().error()
        return

    var entries = List[DirEntry]()
    var failed = Optional[ErrorValue]()
    try:
        entries = read_dir(fsys, path)
    except e:
        failed = Optional[ErrorValue](capture(e))

    if failed:
        # A second call, this time to report the listing. The callback can let
        # the walk carry on, which it then does over an empty listing.
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
            _walk_dir[visit](fsys, child, found.copy())
        except e:
            # A `SkipDir` that reached here came from a callback given a file,
            # so it means the rest of this directory rather than that one name.
            if matches(e, SkipDir):
                break
            raise e
