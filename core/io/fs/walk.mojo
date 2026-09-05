"""What a tree walk calls, and the two answers that steer it. Go's
`fs.WalkDirFunc`, `fs.SkipDir` and `fs.SkipAll`.

The walk itself is not here yet. `core.path.filepath.walk_dir` walks a real
disk with this callback, and `walk_dir` over an `FS` arrives with the rest of
the trait, which issue #178 tracks. The type lives here rather than there for
the reason Go put it here: the two walks are different code over different
things and a callback written for one has to be the same callback the other
takes, or every helper anybody writes has to be written twice.

## Raising is how the callback answers

Go's callback returns an error and the walk reads it. Here it raises, and the
walk catches. `SkipDir` and `SkipAll` are the two raises that mean something
other than failure, and a walk turns both of them back into an ordinary return
rather than passing them on, so a caller never sees one come out.

Anything else raised by the callback stops the walk and comes out of it
unchanged, which is Go's rule as well: the callback is the only thing that
decides whether a failure is fatal.
"""

from core.errors import ErrorValue, Report
from core.errors.codes import SkipAll, SkipDir

from .direntry import DirEntry

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
