"""The five questions asked of a file system rather than of a file. Go's
`fs.ReadFile`, `fs.ReadDir`, `fs.Stat`, `fs.ReadLink` and `fs.Lstat`.

Each one is the same shape: if the file system implements the question itself,
ask it, and otherwise work the answer out by opening the name. Go writes that
as a type assertion and this reads a capability bit, which is the same choice
in both halves and is argued in `fs.mojo`.

The fallback is not a consolation prize. `read_dir` over a file system that
only knows how to open things is one open, one listing and one close, which is
what Go does and is what makes a two line file system useful with everything in
this package.
"""

from core.errors import ErrorValue, capture
from core.errors.codes import ErrInvalid
from core.io import Byte, read_all
from core.sort import slice

from .direntry import DirEntry
from .errors import _refused
from .fs import FS, READ_DIR_FILE, READ_DIR_FS, READ_FILE_FS, READ_LINK_FS
from .fs import STAT_FS
from .info import FileInfo


def _sorted_entries(mut entries: List[DirEntry]):
    """A listing in the order Go promises, which is by name.

    The order a file system hands entries back in is its own business and can
    change between two runs of the same program. A listing that was not sorted
    would give a program output that moves for no reason a reader can see.
    """
    var view = Span(entries)

    @parameter
    def by_name(i: Int, j: Int) -> Bool:
        return view[i].name() < view[j].name()

    slice[by_name](view)


def read_dir[F: FS](fsys: F, name: String) raises -> List[DirEntry]:
    """The contents of the directory at `name`, sorted by name. Go's `ReadDir`.

    A file system with `READ_DIR_FS` answers this itself and is trusted to
    sort, which is the contract Go's `ReadDirFS` carries. Everything else has
    the name opened, the file asked for all of its entries at once, and the
    list sorted here.

    A file that is not a directory raises, and the raise is the file system's
    own: on a host file system it is `ENOTDIR` with the path on it. A file
    system whose files cannot be read as directories at all raises
    `ErrUnsupported` naming `readdir`.
    """
    if fsys.capabilities() & READ_DIR_FS:
        return fsys.read_dir(name)

    var file = fsys.open(name)
    if not (file.capabilities() & READ_DIR_FILE):
        # The file opened, so the close is worth making before the refusal.
        file.close()
        raise _refused("readdir", name, "not implemented", ErrInvalid)

    var found = List[DirEntry]()
    var failed = Optional[ErrorValue]()
    try:
        found = file.read_dir(-1)
    except e:
        failed = Optional[ErrorValue](capture(e))
    _close_quietly(file^)
    if failed:
        raise failed.value().error()
    _sorted_entries(found)
    return found^


def stat[F: FS](fsys: F, name: String) raises -> FileInfo:
    """What is known about `name`. Go's `Stat`.

    On a symbolic link this describes what the link points at, because the
    generic version opens the name and opening a link opens its target.
    `lstat` is the one that describes the link, and it needs a file system that
    says it knows about links.
    """
    if fsys.capabilities() & STAT_FS:
        return fsys.stat(name)

    var file = fsys.open(name)
    var found = Optional[FileInfo]()
    var failed = Optional[ErrorValue]()
    try:
        found = Optional[FileInfo](file.stat())
    except e:
        failed = Optional[ErrorValue](capture(e))
    _close_quietly(file^)
    if failed:
        raise failed.value().error()
    return found.take()


def read_file[F: FS](fsys: F, name: String) raises -> List[Byte]:
    """The whole contents of `name`. Go's `ReadFile`.

    The end of the file is not a failure here, which is the same rule
    `core.os.read_file` follows: a read that reached the end has the bytes and
    nothing went wrong. A file that cannot be read to the end raises with the
    bytes that did arrive on `errors.partial`.
    """
    if fsys.capabilities() & READ_FILE_FS:
        return fsys.read_file(name)

    var file = fsys.open(name)
    var got = List[Byte]()
    var failed = Optional[ErrorValue]()
    try:
        got = read_all(file)
    except e:
        failed = Optional[ErrorValue](capture(e))
    _close_quietly(file^)
    if failed:
        raise failed.value().error()
    return got^


def read_link[F: FS](fsys: F, name: String) raises -> String:
    """The target of the symbolic link at `name`. Go's `ReadLink`.

    There is no generic version and there cannot be one: opening a link opens
    what it points at, so a file system that does not answer this itself has no
    way to be asked. A file system without `READ_LINK_FS` raises `ErrInvalid`
    naming `readlink`, which is the failure Go's own type assertion produces.
    """
    if fsys.capabilities() & READ_LINK_FS:
        return fsys.read_link(name)
    raise _refused("readlink", name, "not implemented", ErrInvalid)


def lstat[F: FS](fsys: F, name: String) raises -> FileInfo:
    """What is known about `name`, without following a final link. Go's
    `Lstat`.

    Same rule as `read_link`, and for the same reason. `stat` is the question
    every file system can answer and this is the question only one that knows
    about links can.
    """
    if fsys.capabilities() & READ_LINK_FS:
        return fsys.lstat(name)
    raise _refused("lstat", name, "not implemented", ErrInvalid)


def _close_quietly[F: FS](var file: F.File):
    """Close a file that was opened to answer one question, dropping a failure.

    Go defers the close in all four of these and its failure goes nowhere. That
    is the right answer for a read: nothing was written, so a close has nothing
    to report that the read did not already say, and letting it raise would
    replace a real failure with a less useful one.

    It is also the rule about the error record. The failure being carried past
    this call is a captured `ErrorValue`, which owns its record, so a close that
    fails here overwrites the thread's slot without touching what is about to
    be raised.
    """
    try:
        file.close()
    except:
        pass
