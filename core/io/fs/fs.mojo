"""A file system as a value. Go's `fs.FS`, `fs.File` and the optional
interfaces beside them.

Go's `FS` is one method, `Open`, and the smallness is the whole idea: anything
that can produce a readable thing from a name is a file system, so a directory
on disk is one, a zip archive is one, a map in a test is one, and a function
that takes an `FS` can be handed any of them. Go then layers optional
interfaces on top, `ReadDirFS`, `StatFS` and the rest, which a file system
implements when it can answer that question faster than the generic code can
work it out.

Both halves of that need a run time type assertion and there is none here, so
both halves are the mechanism `core.io` already uses for the same problem.
`capabilities` is an `Int` of bits, the optional methods are declared on the
trait with default bodies that raise, and a file system that implements one
overrides two things: the method that does the work and the bit that admits to
it. The free functions in this package read the bits and either call the
method or fall back to opening the file, which is exactly the shape of Go's
`if fsys, ok := fsys.(ReadDirFS); ok`.

## The bits are allocated once

The capability word is one `Int` and a type has one `capabilities` method,
however many traits it implements. `core.io` owns 1 and 2 and this package
takes the next six, so a type that is both a `Reader` and an `FS` can answer
for both without the two sets of bits meaning different things in the same
word. A bit is claimed in one place in the library and never reused.

## Names are not paths

Every name here is slash separated, unrooted, has no `.` or `..` element and
no empty element, and `.` alone is the root. `valid_path` in `name.mojo` is
where that rule is written down and it is checked by the file system rather
than by every caller. It is what keeps a file system value from being talked
out of its own tree, and it is worth being strict about on a platform that
would have forgiven the mistake.
"""

from core.errors import Report
from core.errors.codes import ErrUnsupported
from core.io import Byte, Closer, Reader

from .direntry import DirEntry
from .info import FileInfo

comptime READ_DIR_FILE = 4
"""The open file implements `read_dir`. Go's `fs.ReadDirFile`."""

comptime READ_DIR_FS = 8
"""The file system implements `read_dir`. Go's `fs.ReadDirFS`."""

comptime STAT_FS = 16
"""The file system implements `stat`. Go's `fs.StatFS`."""

comptime READ_FILE_FS = 32
"""The file system implements `read_file`. Go's `fs.ReadFileFS`."""

comptime GLOB_FS = 64
"""The file system implements `glob`. Go's `fs.GlobFS`."""

comptime READ_LINK_FS = 128
"""The file system implements `read_link` and `lstat`. Go's `fs.ReadLinkFS`."""


trait File(Closer, Deinitable, Reader):
    """One open file, from any file system. Go's `fs.File`.

    Three things: it reads, it closes, and it can say what it is. `read` and
    `close` come from `core.io`, so a file is already a `core.io.Reader` and
    everything written against that works on one, and `stat` is the third.

    `read_dir` is here rather than on a separate type for the reason the module
    docstring gives. Go's `ReadDirFile` is an optional interface a caller type
    asserts for; here it is a method with a default that raises and the
    `READ_DIR_FILE` bit to say the default was overridden.
    """

    def stat(self) raises -> FileInfo:
        """What is known about this open file. Go's `Stat`.

        About the file this value holds rather than about whatever holds its
        name now, which is the difference between `fstat` and a second `stat`
        and matters for a file that has been renamed or unlinked since.
        """
        ...

    def read_dir(mut self, n: Int) raises -> List[DirEntry]:
        """The next `n` entries of this directory. Go's `ReadDirFile.ReadDir`.

        A positive `n` reads at most that many and raises `EOF` when there are
        none left, so a loop ends on the failure rather than on an empty list.
        Anything else reads what remains and stops at the end without raising.
        The position is kept on the file, so two calls of five entries read the
        first five and the second five.

        The default raises, which is the case Go reports as a failed type
        assertion. A file that answers this sets `READ_DIR_FILE`.
        """
        raise Report("fs: this file cannot be read as a directory").with_code(
            ErrUnsupported
        ).error()


trait ReadDirFile(File):
    """A file that is a directory. Go's `fs.ReadDirFile`.

    A name for the bound rather than a trait with a method of its own, the
    same arrangement `core.io.ReadWriter` has. A type that means this
    implements `read_dir` and sets `READ_DIR_FILE`.
    """

    pass


trait FS(Deinitable, Movable):
    """Somewhere files come from. Go's `fs.FS`.

    ```mojo
    from core.io import read_all
    from core.io.fs import FS


    def first_line[F: FS](fsys: F, name: String) raises -> String:
        var file = fsys.open(name)
        var text = read_all(file)
        file.close()
        return String(from_utf8_lossy=text)
    ```

    One method that has to be written, `open`, and six that come with a default
    that raises. A file system whose implementation of one of the six is better
    than the generic version overrides it and sets the matching bit; one that
    does not implement any of them writes `open` and nothing else, and every
    function in this package still works on it.
    """

    comptime File: File
    """What `open` gives back.

    Go has an interface here and this is an associated type, so a file system
    over a disk says `comptime File = core.os.File` and one over an archive
    says its own type. The caller of a generic function gets the real type
    rather than an erased one, which is why reading from an opened file costs
    nothing it would not have cost without the trait.
    """

    def open(self, name: String) raises -> Self.File:
        """The file at `name`, opened for reading. Go's `Open`.

        `name` follows the rule in the module docstring, and a name that does
        not is refused with `ErrInvalid` rather than interpreted. Go says the
        same thing and adds that a file system must not be talked into
        reaching outside itself by a name; that is what makes the rule worth
        checking rather than assuming.

        Opening a directory is allowed and is how the generic `read_dir` works
        on a file system that does not implement its own.
        """
        ...

    def capabilities(self) -> Int:
        """Which of the six optional methods this file system implements.

        Zero, unless the type says otherwise. Setting a bit without overriding
        the method it advertises gets the raising default, which is a clear
        failure at the first call rather than a wrong answer.
        """
        return 0

    def read_dir(self, name: String) raises -> List[DirEntry]:
        """The contents of the directory at `name`, sorted. Go's `ReadDirFS`.

        Set `READ_DIR_FS`. The generic version opens the name and asks the file
        for its entries, which costs an open and a close that a file system
        holding a directory listing already in memory does not need to pay.
        """
        raise Report("fs: this file system has no read_dir").with_code(
            ErrUnsupported
        ).error()

    def stat(self, name: String) raises -> FileInfo:
        """What is known about `name`. Go's `StatFS`.

        Set `STAT_FS`. The generic version opens the name, asks the file and
        closes it.
        """
        raise Report("fs: this file system has no stat").with_code(
            ErrUnsupported
        ).error()

    def read_file(self, name: String) raises -> List[Byte]:
        """The whole contents of `name`. Go's `ReadFileFS`.

        Set `READ_FILE_FS`. The generic version opens the name and reads until
        the end, which for a file system holding the bytes already is a copy it
        did not have to make.
        """
        raise Report("fs: this file system has no read_file").with_code(
            ErrUnsupported
        ).error()

    def glob(self, pattern: String) raises -> List[String]:
        """The names matching `pattern`. Go's `GlobFS`.

        Set `GLOB_FS`. The generic version walks the directories the pattern
        names and matches inside each, and a file system with an index of its
        own names can do better.
        """
        raise Report("fs: this file system has no glob").with_code(
            ErrUnsupported
        ).error()

    def read_link(self, name: String) raises -> String:
        """The target of the symbolic link at `name`. Go's `ReadLinkFS`.

        Set `READ_LINK_FS`, which covers this and `lstat` together, because a
        file system that knows about links knows both. There is no generic
        version: a link cannot be read through `open`, since opening a link
        opens what it points at.
        """
        raise Report("fs: this file system has no read_link").with_code(
            ErrUnsupported
        ).error()

    def lstat(self, name: String) raises -> FileInfo:
        """What is known about `name`, without following a final link. Go's
        `ReadLinkFS.Lstat`.

        Set `READ_LINK_FS`. The difference from `stat` is the whole point: on a
        symbolic link this describes the link and `stat` describes what it
        points at.
        """
        raise Report("fs: this file system has no lstat").with_code(
            ErrUnsupported
        ).error()


trait ReadDirFS(FS):
    """A file system that lists its own directories. Go's `fs.ReadDirFS`."""

    pass


trait StatFS(FS):
    """A file system that stats without opening. Go's `fs.StatFS`."""

    pass


trait ReadFileFS(FS):
    """A file system that reads a whole file at once. Go's `fs.ReadFileFS`."""

    pass


trait GlobFS(FS):
    """A file system that matches patterns itself. Go's `fs.GlobFS`."""

    pass


trait ReadLinkFS(FS):
    """A file system that knows about symbolic links. Go's `fs.ReadLinkFS`."""

    pass


trait SubFS(FS):
    """A file system that can root itself at a subtree. Go's `fs.SubFS`.

    The one optional interface that is not a bit and a default method, because
    what it returns is another file system and there is no interface to return
    it as. It is an associated type, so a file system that implements this says
    what kind of file system a subtree of it is.

    `sub` in `sub.mojo` does not consult this, for that reason: a generic
    function cannot ask whether its `F` happens to implement a trait, and the
    answer here changes the return type rather than only the code that runs. A
    caller holding a file system that implements this calls the method; every
    other caller gets `Subtree`, which is what Go's own fallback builds.
    """

    comptime Sub: FS
    """What `sub` gives back, which is a file system in its own right."""

    def sub(self, dir: String) raises -> Self.Sub:
        """This file system rooted at `dir`. Go's `Sub`."""
        ...
