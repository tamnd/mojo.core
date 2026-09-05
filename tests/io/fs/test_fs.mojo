"""The trait and everything written against it, over a file system in memory.

The point of `fs.FS` is that generic code works on anything with an `open`, so
the file system these tests use is the smallest one that could be written: a
list of names and their contents, with directories worked out from the names.
It implements `open` and nothing else, which means every test here goes through
the fallback path in `read.mojo` rather than through a capability bit. Go tests
the same code with `fstest.MapFS`, which is the same idea with more of it.

`core.testing.fstest` will be that package one day and this file is not it. A
`MapFS` that other tests can reach for belongs in a package with `TestFS` next
to it, and this is a test file with the parts these tests need.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.errors import ErrorValue, Report, matches
from core.errors.codes import EOF, ErrInvalid, ErrNotExist
from core.io import Byte, read_all
from core.io.fs import (
    MODE_DIR,
    DirEntry,
    FileInfo,
    FileMode,
    FS,
    File as FsFile,
    PathError,
    READ_DIR_FILE,
    file_info_to_dir_entry,
    glob,
    lstat,
    read_dir,
    read_file,
    read_link,
    skip_all,
    skip_dir,
    stat,
    sub,
    valid_path,
    walk_dir,
)
from core.io.fs.errors import _refused
from core.path import base
from core.time import Time


struct MapFile(Deinitable, FsFile, Movable):
    """One open file from a `MapFS`, which is either bytes or a listing."""

    var _info: FileInfo
    var _data: List[Byte]
    var _offset: Int
    var _entries: List[DirEntry]
    var _next: Int

    def __init__(
        out self,
        var info: FileInfo,
        var data: List[Byte],
        var entries: List[DirEntry],
    ):
        self._info = info^
        self._data = data^
        self._offset = 0
        self._entries = entries^
        self._next = 0

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        if self._offset >= len(self._data):
            raise Report("end of input").with_code(EOF).error()
        var moved = 0
        while moved < len(into) and self._offset < len(self._data):
            into[moved] = self._data[self._offset]
            moved += 1
            self._offset += 1
        return moved

    def close(mut self) raises:
        pass

    def capabilities(self) -> Int:
        return READ_DIR_FILE

    def stat(self) raises -> FileInfo:
        return self._info.copy()

    def read_dir(mut self, n: Int) raises -> List[DirEntry]:
        if not self._info.is_dir():
            raise _refused(
                "read_dir", self._info.name(), "not a directory", ErrInvalid
            )
        var out = List[DirEntry]()
        while self._next < len(self._entries):
            if n > 0 and len(out) == n:
                break
            out.append(self._entries[self._next].copy())
            self._next += 1
        if n > 0 and len(out) == 0:
            raise Report("end of input").with_code(EOF).error()
        return out^


struct MapFS(FS):
    """A file system that is a list of names. Go's `fstest.MapFS`, in small.

    Only `open` is implemented, so `capabilities` is the default zero and
    everything else in the package falls back to opening a name. Directories
    are not stored: a name with a slash in it implies the directories above it,
    which is what makes the listing worth testing.
    """

    comptime File = MapFile

    var _names: List[String]
    var _data: List[String]

    def __init__(out self, var names: List[String], var data: List[String]):
        self._names = names^
        self._data = data^

    def _held(self, name: String) -> Int:
        for i in range(len(self._names)):
            if self._names[i] == name:
                return i
        return -1

    def _is_dir(self, name: String) -> Bool:
        if name == ".":
            return True
        for held in self._names:
            if (
                held.byte_length() > name.byte_length()
                and held[byte = : name.byte_length() + 1] == name + "/"
            ):
                return True
        return False

    def _listing(self, name: String) -> List[DirEntry]:
        """The names directly under `name`, sorted, directories included."""
        var seen = List[String]()
        var kinds = List[Bool]()
        var sizes = List[Int]()
        for i in range(len(self._names)):
            var held = self._names[i]
            var rest = String("")
            if name == ".":
                rest = held.copy()
            elif (
                held.byte_length() > name.byte_length()
                and held[byte = : name.byte_length() + 1] == name + "/"
            ):
                rest = String(held[byte = name.byte_length() + 1 :])
            else:
                continue

            var cut = -1
            for j in range(rest.byte_length()):
                if rest.as_bytes()[j] == Byte(ord("/")):
                    cut = j
                    break
            var head = rest.copy()
            var is_dir = False
            if cut >= 0:
                head = String(rest[byte=:cut])
                is_dir = True

            var known = False
            for one in seen:
                if one == head:
                    known = True
            if known:
                continue
            seen.append(head.copy())
            kinds.append(is_dir)
            sizes.append(self._data[i].byte_length() if not is_dir else 0)

        # Insertion sort, since this is a test file system and the lists are
        # three names long.
        for i in range(1, len(seen)):
            var j = i
            while j > 0 and seen[j] < seen[j - 1]:
                var name = seen[j].copy()
                seen[j] = seen[j - 1].copy()
                seen[j - 1] = name^
                var kind = kinds[j]
                kinds[j] = kinds[j - 1]
                kinds[j - 1] = kind
                var size = sizes[j]
                sizes[j] = sizes[j - 1]
                sizes[j - 1] = size
                j -= 1

        var out = List[DirEntry]()
        for i in range(len(seen)):
            var mode = MODE_DIR | FileMode(0o555) if kinds[i] else FileMode(
                0o444
            )
            out.append(
                file_info_to_dir_entry(
                    FileInfo(
                        name=seen[i].copy(),
                        size=sizes[i],
                        mode=mode,
                        mod_time=Time(),
                    )
                )
            )
        return out^

    def open(self, name: String) raises -> Self.File:
        if not valid_path(name):
            raise _refused("open", name, "invalid argument", ErrInvalid)

        var at = self._held(name)
        if at >= 0:
            var info = FileInfo(
                name=base(name),
                size=self._data[at].byte_length(),
                mode=FileMode(0o444),
                mod_time=Time(),
            )
            return MapFile(info^, _bytes(self._data[at]), List[DirEntry]())

        if self._is_dir(name):
            var info = FileInfo(
                name=base(name),
                size=0,
                mode=MODE_DIR | FileMode(0o555),
                mod_time=Time(),
            )
            return MapFile(info^, List[Byte](), self._listing(name))

        raise _refused("open", name, "file does not exist", ErrNotExist)


def _bytes(text: String) -> List[Byte]:
    """The bytes of a string, as a list this file system can hand out."""
    var out = List[Byte](capacity=text.byte_length())
    for byte in text.as_bytes():
        out.append(byte)
    return out^


def _tree() -> MapFS:
    """The tree every test below uses.

    ```
    hello.txt
    a/one.txt
    a/b/two.txt
    a/b/three.md
    ```
    """
    var names: List[String] = [
        "hello.txt",
        "a/one.txt",
        "a/b/two.txt",
        "a/b/three.md",
    ]
    var data: List[String] = ["hello", "one", "two", "three"]
    return MapFS(names^, data^)


def test_open_and_read() raises:
    """The one method a file system has to have, and `core.io` over it."""
    var fsys = _tree()
    var file = fsys.open("hello.txt")
    var text = read_all(file)
    file.close()
    assert_equal(String(from_utf8_lossy=text), "hello")


def test_read_file_falls_back_to_open() raises:
    """`read_file` on a file system with no `READ_FILE_FS`."""
    var fsys = _tree()
    assert_equal(String(from_utf8_lossy=read_file(fsys, "a/b/two.txt")), "two")


def test_read_dir_is_sorted() raises:
    """The listing comes back in name order, whatever the file system did."""
    var fsys = _tree()
    var entries = read_dir(fsys, ".")
    assert_equal(len(entries), 2)
    assert_equal(entries[0].name(), "a")
    assert_true(entries[0].is_dir())
    assert_equal(entries[1].name(), "hello.txt")
    assert_false(entries[1].is_dir())


def test_read_dir_of_a_file() raises:
    """A name that is not a directory raises, and says so."""
    var fsys = _tree()
    with assert_raises():
        _ = read_dir(fsys, "hello.txt")


def test_stat_falls_back_to_open() raises:
    """`stat` with no `STAT_FS` opens the name and asks the file."""
    var fsys = _tree()
    var info = stat(fsys, "a/one.txt")
    assert_equal(info.name(), "one.txt")
    assert_equal(info.size(), 3)
    assert_false(info.is_dir())
    assert_true(stat(fsys, "a").is_dir())


def test_stat_of_a_missing_name() raises:
    """The failure is the file system's own, with the path on it."""
    var fsys = _tree()
    try:
        _ = stat(fsys, "nothing")
        assert_true(False, "stat of a missing name should raise")
    except e:
        assert_true(matches(e, ErrNotExist))
        var failed = PathError.of(e)
        assert_false(Bool(failed), "a refusal carries no errno")


def test_invalid_names_are_refused() raises:
    """`..` does not get in, and neither does an absolute name."""
    var fsys = _tree()
    for name in ["../x", "/x", "a//b", String(""), "a/./b"]:
        try:
            _ = fsys.open(name)
            assert_true(False, "opened " + name)
        except e:
            assert_true(matches(e, ErrInvalid), name)


def test_read_link_without_the_bit() raises:
    """No `READ_LINK_FS` means no generic answer, and no guess either."""
    var fsys = _tree()
    with assert_raises():
        _ = read_link(fsys, "hello.txt")
    with assert_raises():
        _ = lstat(fsys, "hello.txt")


def test_glob_matches_one_element() raises:
    """`*` stops at a slash, so a pattern names the depth it matches at."""
    var fsys = _tree()
    var found = glob(fsys, "*.txt")
    assert_equal(len(found), 1)
    assert_equal(found[0], "hello.txt")

    var deeper = glob(fsys, "a/*/*.txt")
    assert_equal(len(deeper), 1)
    assert_equal(deeper[0], "a/b/two.txt")


def test_glob_with_no_pattern_is_a_lookup() raises:
    """A pattern with nothing special in it matches itself if it is there."""
    var fsys = _tree()
    assert_equal(len(glob(fsys, "a/one.txt")), 1)
    assert_equal(len(glob(fsys, "a/nothing.txt")), 0)


def test_glob_bad_pattern() raises:
    """A malformed pattern is the one failure `glob` has."""
    var fsys = _tree()
    with assert_raises():
        _ = glob(fsys, "a/[")


def test_walk_dir_visits_everything_in_order() raises:
    """Every name under the root, parents before children, sorted."""
    var fsys = _tree()
    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]):
        seen.append(path)

    walk_dir[visit](fsys, ".")
    assert_equal(len(seen), 7)
    assert_equal(seen[0], ".")
    assert_equal(seen[1], "a")
    assert_equal(seen[2], "a/b")
    assert_equal(seen[3], "a/b/three.md")
    assert_equal(seen[4], "a/b/two.txt")
    assert_equal(seen[5], "a/one.txt")
    assert_equal(seen[6], "hello.txt")


def test_walk_dir_from_a_subdirectory() raises:
    """The paths start with the root the walk was given."""
    var fsys = _tree()
    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]):
        seen.append(path)

    walk_dir[visit](fsys, "a/b")
    assert_equal(len(seen), 3)
    assert_equal(seen[0], "a/b")
    assert_equal(seen[1], "a/b/three.md")
    assert_equal(seen[2], "a/b/two.txt")


def test_walk_dir_skip_dir() raises:
    """`skip_dir` leaves a directory alone and the walk carries on."""
    var fsys = _tree()
    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]) raises:
        if entry.name() == "b" and entry.is_dir():
            raise skip_dir()
        seen.append(path)

    walk_dir[visit](fsys, ".")
    assert_equal(len(seen), 4)
    assert_equal(seen[1], "a")
    assert_equal(seen[2], "a/one.txt")
    assert_equal(seen[3], "hello.txt")


def test_walk_dir_skip_all() raises:
    """`skip_all` stops the walk and does not come out of it."""
    var fsys = _tree()
    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]) raises:
        seen.append(path)
        if path == "a/b":
            raise skip_all()

    walk_dir[visit](fsys, ".")
    assert_equal(len(seen), 3)
    assert_equal(seen[2], "a/b")


def test_walk_dir_of_a_missing_root() raises:
    """The callback is handed the failure, and the entry is still a name."""
    var fsys = _tree()
    var told = List[String]()
    var failures = 0

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]):
        told.append(entry.name())
        if err:
            failures += 1

    walk_dir[visit](fsys, "nothing")
    assert_equal(len(told), 1)
    assert_equal(told[0], "nothing")
    assert_equal(failures, 1)


def test_sub_sees_only_its_own_tree() raises:
    """Names are relative to the root and the root is not in them."""
    var under = sub(_tree(), "a")
    assert_equal(String(from_utf8_lossy=read_file(under, "one.txt")), "one")
    assert_equal(String(from_utf8_lossy=read_file(under, "b/two.txt")), "two")

    var entries = read_dir(under, ".")
    assert_equal(len(entries), 2)
    assert_equal(entries[0].name(), "b")
    assert_equal(entries[1].name(), "one.txt")


def test_sub_refuses_to_be_left() raises:
    """There is no name that reaches the parent tree."""
    var under = sub(_tree(), "a")
    with assert_raises():
        _ = read_file(under, "../hello.txt")
    with assert_raises():
        _ = read_file(under, "/hello.txt")
    with assert_raises():
        _ = read_file(under, "hello.txt")


def test_sub_shortens_the_path_it_reports() raises:
    """A failure names what the caller asked for, not where the root is."""
    var under = sub(_tree(), "a")
    try:
        _ = under.open("nothing.txt")
        assert_true(False, "open of a missing name should raise")
    except e:
        assert_true(matches(e, ErrNotExist))
        assert_equal(String(e).find("a/nothing.txt"), -1)


def test_sub_glob_is_relative_too() raises:
    """The matches come back without the root on them."""
    var under = sub(_tree(), "a")
    var found = glob(under, "b/*.txt")
    assert_equal(len(found), 1)
    assert_equal(found[0], "b/two.txt")


def test_sub_of_the_root() raises:
    """`.` is a root like any other and gives back the same tree."""
    var whole = sub(_tree(), ".")
    assert_equal(String(from_utf8_lossy=read_file(whole, "hello.txt")), "hello")


def test_sub_of_an_invalid_name() raises:
    """A root that is not a valid name is refused before anything is opened."""
    with assert_raises():
        _ = sub(_tree(), "../a")
    with assert_raises():
        _ = sub(_tree(), "/a")


def test_sub_of_a_sub() raises:
    """A subtree of a subtree is rooted at the two joined together."""
    var under = sub(sub(_tree(), "a"), "b")
    assert_equal(String(from_utf8_lossy=read_file(under, "two.txt")), "two")

    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]):
        seen.append(path)

    walk_dir[visit](under, ".")
    assert_equal(len(seen), 3)
    assert_equal(seen[0], ".")
    assert_equal(seen[1], "three.md")
    assert_equal(seen[2], "two.txt")


def test_format_file_info() raises:
    """One line of a long listing, in Go's order."""
    from core.io.fs import format_file_info
    from core.time import unix

    var info = FileInfo(
        name="notes.txt", size=12, mode=FileMode(0o644), mod_time=unix(0, 0)
    )
    assert_equal(
        format_file_info(info), "-rw-r--r-- 12 1970-01-01T00:00:00Z notes.txt"
    )

    var listing = FileInfo(
        name="src",
        size=0,
        mode=MODE_DIR | FileMode(0o755),
        mod_time=unix(0, 0),
    )
    assert_equal(
        format_file_info(listing), "drwxr-xr-x 0 1970-01-01T00:00:00Z src/"
    )
