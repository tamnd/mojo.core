"""Listing a directory. Go's `os.ReadDir`.

A directory read is two questions with very different prices. What is in here
is one call and gives a name and, on most file systems, what kind of thing the
name is. What each of those things is costs a call apiece. `read_dir` asks the
first and leaves the second to whoever wants it, which is why it hands back
`DirEntry` values and not `FileInfo` values.

This is the whole directory at once. `File.read_dir` is the same read a piece
at a time, and this is written in terms of it exactly as Go's is: open, read
everything, close, sort.
"""

from core.io.fs import DirEntry
from core.sort import slice

from .file import open


def read_dir(name: String) raises -> List[DirEntry]:
    """Everything in a directory, sorted by name. Go's `ReadDir`.

    ```mojo
    from core.os import read_dir

    def main():
        for entry in read_dir("/etc"):
            print(entry.name(), entry.is_dir())
    ```

    Sorted because the order a file system hands entries back in is its own
    business and changes between two runs of the same program on the same
    machine. Go sorts for that reason, and a program that prints a listing
    should not have output that moves for no reason a reader can see.

    `.` and `..` are dropped. Everything else is here, including the names a
    shell would hide.

    Reads the whole directory before it returns, so a failure part way through
    is a failure of the whole call and there is no half list to interpret.
    """
    var dir = open(name)
    var entries = dir.read_dir(0)
    dir.close()
    _sort_by_name(entries)
    return entries^


def _sort_by_name(mut entries: List[DirEntry]):
    """Put a listing in the order Go puts one in, by name and nothing else."""
    var view = Span(entries)

    @parameter
    def by_name(i: Int, j: Int) -> Bool:
        return view[i].name() < view[j].name()

    slice[by_name](view)
