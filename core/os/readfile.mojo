"""A whole file in one call, in each direction. Go's `ReadFile` and `WriteFile`.

Two functions that open a file, do one thing to it and close it. They exist
because that is what most programs want from a configuration file or a small
data file, and writing the four lines by hand is where a forgotten `close`
comes from.

Neither one is for a large file. `read_file` puts the whole thing in memory, so
a caller working with something that does not fit should open it and read
through a buffer instead.
"""

from core.errors import matches
from core.errors.codes import EOF
from core.io import Byte
from core.io.fs import FileMode
from core.syscall import O_CREAT, O_TRUNC, O_WRONLY

from .file import open, open_file

comptime _FIRST_READ = 512
"""What to ask for when `stat` has nothing useful to say about the size."""


def read_file(name: String) raises -> List[Byte]:
    """The whole contents of a file. Go's `ReadFile`.

    ```mojo
    from core.os import read_file

    def main():
        print(len(read_file("/etc/hosts")))
    ```

    The end of the file is not an error here, which is the difference from
    `File.read`: reaching it is the successful outcome, so an empty file gives
    back an empty list rather than raising.

    The size `stat` reports sizes the buffer and is not trusted as the answer.
    It is right almost always and wrong in two cases that matter: a file under
    `/proc` reports zero and has contents, and an ordinary file can grow
    between the `stat` and the last read. So the loop runs until the file says
    there is no more, and the size only decides how much room is asked for
    first.

    A failure part way through closes the file and raises, and nothing partial
    comes back. There is no useful way to hand over half a file and say so.
    """
    var f = open(name)
    var size = _FIRST_READ
    try:
        var found = f.stat()
        if found.size() > 0:
            size = Int(found.size())
    except:
        pass

    var out = List[Byte](capacity=size)
    var room = List[Byte](length=size, fill=0)
    while True:
        var n = 0
        try:
            n = f.read(Span(room))
        except e:
            if matches(e, EOF):
                break
            # The file closes itself as this leaves, which is what the
            # destructor is for. Closing here would put its own record where
            # this failure's fields are.
            raise e
        for i in range(n):
            out.append(room[i])
    f.close()
    return out^


def write_file[
    o: ImmOrigin
](name: String, data: Span[Byte, o], perm: FileMode) raises:
    """Create or truncate a file and write `data` to it. Go's `WriteFile`.

    ```mojo
    from core.io.fs import FileMode
    from core.os import write_file

    def main():
        write_file("/tmp/note", "hello\\n".as_bytes(), FileMode(0o644))
    ```

    `perm` applies to a file this creates and to no other, less the process
    umask. A file that was already there keeps the permissions it had and is
    truncated, which is Go's behaviour and is the part worth knowing: this is
    not a way to fix the mode on a file.

    The close is part of the call and its failure is reported, because a write
    that reached a buffer and not the disk is a failure the caller has to hear
    about and `close` is where it surfaces. A write that failed is the failure
    that gets raised, since it happened first and explains more.

    Not atomic. A reader looking at the same time can see a file that is half
    written. A caller who needs the change to be all or nothing writes a
    temporary file beside it and renames it over the top.
    """
    var f = open_file(name, O_WRONLY | O_CREAT | O_TRUNC, perm)
    # A failed write leaves through here and the file closes itself on the way,
    # which is why there is no `close` in an `except` block: closing there
    # could put its own record where the write failure's fields are.
    _ = f.write(data)
    f.close()
