"""A file system rooted somewhere inside another one. Go's `fs.Sub`.

The point is not convenience, it is that a subtree is a file system in its own
right and cannot be talked out of itself. Handing a caller `sub(fsys, "static")`
gives them something that can only see what is under `static`, because every
name they pass is checked by `valid_path` before it has the root joined onto
it, and `valid_path` refuses `..` outright. There is no name that gets out.

Go returns the wrapped file system unchanged when the root is `"."`, and there
is nothing to return here: the answer has one type and it is `Subtree`. A
`Subtree` rooted at `"."` joins `"."` onto every name, which `core.path.join`
drops, so it costs one join and behaves as the file system it wraps.
"""

from core.errors import capture
from core.errors.codes import ErrInvalid
from core.io import Byte
from core.path import is_match, join

from .direntry import DirEntry
from .errors import _refused, _with_path
from .fs import FS, GLOB_FS, READ_DIR_FS, READ_FILE_FS, READ_LINK_FS, STAT_FS
from .glob import glob as _glob_in
from .info import FileInfo
from .name import valid_path
from .read import (
    lstat as _lstat_in,
    read_dir as _read_dir_in,
    read_file as _read_file_in,
    read_link as _read_link_in,
    stat as _stat_in,
)

comptime _SLASH = Byte(ord("/"))


struct Subtree[F: FS](FS):
    """`F` seen from one directory down. Go's unexported `subFS`.

    Every question is the same three steps: check the name, join the root onto
    it, and ask the file system underneath. What comes back is what that file
    system said, except that a failure has the root taken off the path again,
    so a caller holding a subtree never learns where it sits.

    It advertises everything the generic functions can do, because it can do
    all of them by calling those functions on the file system it wraps. The one
    exception is links, which it advertises only if the wrapped file system
    does, since there is no way to work a link out from underneath.
    """

    comptime File = Self.F.File

    var _fsys: Self.F
    """The file system this is a view of."""

    var _dir: String
    """Where in it this view is rooted, as a valid path, never with a slash on
    the end."""

    def __init__(out self, var fsys: Self.F, var dir: String):
        """Rooted at `dir`, which `sub` has already checked."""
        self._fsys = fsys^
        self._dir = dir^

    def capabilities(self) -> Int:
        """Everything that can be answered by asking the wrapped file system.

        The four generic questions are always available, since answering them
        here is one call to the free function on the inner file system, and
        that function falls back to opening a name when it has to. Links are
        passed through: a subtree of a file system that knows about them knows
        about them, and a subtree of one that does not cannot invent them.
        """
        return (
            READ_DIR_FS
            | STAT_FS
            | READ_FILE_FS
            | GLOB_FS
            | (self._fsys.capabilities() & READ_LINK_FS)
        )

    def _full(
        self, op: StringSlice[ImmStaticOrigin], name: String
    ) raises -> String:
        """`name` as the wrapped file system spells it. Go's `fullName`.

        The check is the whole security argument and it happens before the
        join, not after: a name with `..` in it is refused rather than joined
        and cleaned, because cleaning it after joining is how a path that
        escapes gets built.
        """
        if not valid_path(name):
            raise _refused(op, name, "invalid argument", ErrInvalid)
        return join([self._dir, name])

    def _short(self, name: String) -> Optional[String]:
        """`name` with the root taken off, or nothing if it is not under it.

        Go's `shorten`. The root itself becomes `"."`, which is what the root
        of a file system is called.
        """
        if name == self._dir:
            return Optional[String](".")
        var root = self._dir.byte_length()
        if (
            name.byte_length() >= root + 2
            and name.as_bytes()[root] == _SLASH
            and name[byte=:root] == self._dir
        ):
            return Optional[String](String(name[byte = root + 1 :]))
        return None

    def _shorten_error(self, cause: Error) -> Error:
        """`cause` with the root taken off whatever path it names."""
        var held = _path_of(cause)
        if held:
            var short = self._short(held.value())
            if short:
                return _with_path(cause, short.value())
        return cause

    def open(self, name: String) raises -> Self.File:
        """The file at `name` under this root. Go's `Open`."""
        var full = self._full("open", name)
        try:
            return self._fsys.open(full)
        except e:
            raise self._shorten_error(e)

    def read_dir(self, name: String) raises -> List[DirEntry]:
        """The contents of the directory at `name` under this root."""
        var full = self._full("read_dir", name)
        try:
            return _read_dir_in(self._fsys, full)
        except e:
            raise self._shorten_error(e)

    def stat(self, name: String) raises -> FileInfo:
        """What is known about `name` under this root."""
        var full = self._full("stat", name)
        try:
            return _stat_in(self._fsys, full)
        except e:
            raise self._shorten_error(e)

    def read_file(self, name: String) raises -> List[Byte]:
        """The whole contents of `name` under this root."""
        var full = self._full("read_file", name)
        try:
            return _read_file_in(self._fsys, full)
        except e:
            raise self._shorten_error(e)

    def read_link(self, name: String) raises -> String:
        """The target of the link at `name` under this root.

        The target is whatever the wrapped file system says and is not
        shortened, because it is a name rather than a path this view rewrote,
        and it may well point outside the subtree. Following it is the caller's
        decision and this view cannot open it for them.
        """
        var full = self._full("read_link", name)
        try:
            return _read_link_in(self._fsys, full)
        except e:
            raise self._shorten_error(e)

    def lstat(self, name: String) raises -> FileInfo:
        """What is known about `name` under this root, link and all."""
        var full = self._full("lstat", name)
        try:
            return _lstat_in(self._fsys, full)
        except e:
            raise self._shorten_error(e)

    def glob(self, pattern: String) raises -> List[String]:
        """The names under this root matching `pattern`. Go's `Glob`.

        The pattern is not a name, so it does not go through `_full`: it is
        checked for being a pattern at all, joined onto the root as text, and
        the answers have the root taken back off. A pattern of `"."` is the
        root and matches it.
        """
        # Against the empty name, so a malformed pattern is reported here
        # rather than as an empty list of matches.
        _ = is_match(pattern, "")
        if pattern == ".":
            return ["."]

        var found = List[String]()
        try:
            found = _glob_in(self._fsys, self._dir + "/" + pattern)
        except e:
            raise self._shorten_error(e)

        var out = List[String](capacity=len(found))
        for name in found:
            var short = self._short(name)
            if not short:
                # The wrapped file system answered with a name outside the
                # subtree it was asked about, which means it does not match
                # names the way `core.path.is_match` does.
                raise _refused(
                    "glob", name, "matched outside the subtree", ErrInvalid
                )
            out.append(short.value())
        return out^


def _path_of(cause: Error) -> Optional[String]:
    """The path a failure names, if it names one."""
    return capture(cause).field("path")


def sub[F: FS](var fsys: F, dir: String) raises -> Subtree[F]:
    """`fsys` rooted at `dir`. Go's `Sub`.

    ```mojo
    from core.io import Byte
    from core.io.fs import FS, read_file, sub


    def logo[F: FS](var fsys: F) raises -> List[Byte]:
        var static = sub(fsys^, "static")
        return read_file(static, "logo.svg")
    ```

    `dir` follows the name rule and a name that does not is refused with
    `ErrInvalid`; `"."` is allowed and gives a view of the whole thing.

    This takes the file system by value, where Go's takes an interface and
    keeps a reference to it. A file system is a value here and `FS` asks only
    that it be movable, so the subtree owns the one it was given. A caller who
    wants to keep the original hands over a copy, which a file system that is
    copyable will let them do.

    Go returns the argument itself for a root of `"."` and consults `SubFS`
    when the file system has its own answer. Neither is possible here, for the
    reason in `fs.mojo`: the result would be a different type each time. A
    caller holding a file system with its own `sub` calls that method instead
    of this function.
    """
    if not valid_path(dir):
        raise _refused("sub", dir, "invalid argument", ErrInvalid)
    return Subtree[F](fsys^, dir)
