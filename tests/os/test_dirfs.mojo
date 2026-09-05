"""Go's `TestDirFS`, over a tree this file builds.

`dir_fs` is the only place in the library where the `fs.FS` trait meets a real
disk, so these tests are about the join and the name rule rather than about the
system calls underneath, which `tests/os/test_stat.mojo` and its neighbours
already cover. What matters here is that a name is checked before it is used,
that the failure a caller sees names what the caller wrote, and that the
generic functions in `core.io.fs` work over the result.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.errors import ErrorValue, matches
from core.errors.codes import ErrInvalid, ErrNotExist
from core.io.fs import (
    DirEntry,
    FileMode,
    glob,
    read_dir,
    read_file,
    read_link,
    stat,
    sub,
    walk_dir,
)
from core.os import (
    dir_fs,
    mkdir_all,
    remove_all,
    symlink,
    write_file,
)
from core.path.filepath import join
from core.syscall import getpid


def _scratch(name: String) raises -> String:
    """The tree every test in this file opens.

    ```text
    a.txt
    z.md
    sub/b.txt
    sub/deeper/c.txt
    ```
    """
    var place = String("/tmp/mojo-core-dirfs-", getpid(), "-", name)
    remove_all(place)
    mkdir_all(join([place, "sub", "deeper"]), FileMode(0o700))
    write_file(join([place, "a.txt"]), "a".as_bytes(), FileMode(0o600))
    write_file(join([place, "z.md"]), "z".as_bytes(), FileMode(0o600))
    write_file(join([place, "sub", "b.txt"]), "b".as_bytes(), FileMode(0o600))
    write_file(
        join([place, "sub", "deeper", "c.txt"]), "c".as_bytes(), FileMode(0o600)
    )
    return place^


def test_open_and_read_file() raises:
    """A name under the root is the root and the name, joined."""
    var place = _scratch("read")
    var fsys = dir_fs(place)

    assert_equal(String(from_utf8_lossy=read_file(fsys, "a.txt")), "a")
    assert_equal(
        String(from_utf8_lossy=read_file(fsys, "sub/deeper/c.txt")), "c"
    )

    var file = fsys.open("z.md")
    file.close()

    remove_all(place)


def test_read_dir_is_sorted() raises:
    """The listing is the host's, in name order."""
    var place = _scratch("listing")
    var fsys = dir_fs(place)

    var entries = read_dir(fsys, ".")
    assert_equal(len(entries), 3)
    assert_equal(entries[0].name(), "a.txt")
    assert_equal(entries[1].name(), "sub")
    assert_true(entries[1].is_dir())
    assert_equal(entries[2].name(), "z.md")

    remove_all(place)


def test_stat_answers_about_the_joined_path() raises:
    """The info is about the file under the root, with its own base name."""
    var place = _scratch("stat")
    var fsys = dir_fs(place)

    var info = stat(fsys, "sub/b.txt")
    assert_equal(info.name(), "b.txt")
    assert_equal(info.size(), 1)
    assert_true(stat(fsys, "sub").is_dir())

    remove_all(place)


def test_a_missing_name_says_what_the_caller_asked_for() raises:
    """The root is not in the message, which is Go's rule for `dirFS`."""
    var place = _scratch("missing")
    var fsys = dir_fs(place)

    try:
        _ = stat(fsys, "nothing.txt")
        assert_true(False, "stat of a missing name should raise")
    except e:
        assert_true(matches(e, ErrNotExist))
        assert_equal(String(e).find(place), -1)
        assert_true(String(e).find("nothing.txt") >= 0)

    remove_all(place)


def test_names_that_are_refused() raises:
    """The name rule, checked before anything reaches the host."""
    var place = _scratch("names")
    var fsys = dir_fs(place)

    for name in ["../etc/passwd", "/etc/passwd", "a//b", String(""), "./a.txt"]:
        try:
            _ = fsys.open(name)
            assert_true(False, "opened " + name)
        except e:
            assert_true(matches(e, ErrInvalid), name)

    remove_all(place)


def test_an_empty_root_is_refused() raises:
    """A file system with no root would be every name relative to nothing."""
    with assert_raises():
        _ = dir_fs("")


def test_walk_dir_over_a_real_tree() raises:
    """The generic walk, over a directory on this host."""
    var place = _scratch("walk")
    var fsys = dir_fs(place)
    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]) raises:
        assert_false(Bool(err))
        seen.append(path)

    walk_dir[visit](fsys, ".")
    assert_equal(
        seen,
        [
            String("."),
            "a.txt",
            "sub",
            "sub/b.txt",
            "sub/deeper",
            "sub/deeper/c.txt",
            "z.md",
        ],
    )

    remove_all(place)


def test_glob_over_a_real_tree() raises:
    """The generic glob, which reads the directories the pattern names."""
    var place = _scratch("glob")
    var fsys = dir_fs(place)

    assert_equal(glob(fsys, "*.txt"), [String("a.txt")])
    assert_equal(glob(fsys, "sub/*.txt"), [String("sub/b.txt")])
    assert_equal(glob(fsys, "*/*/c.txt"), [String("sub/deeper/c.txt")])
    assert_equal(len(glob(fsys, "*.nothing")), 0)

    remove_all(place)


def test_sub_of_a_real_directory() raises:
    """A subtree of a host file system is a file system like any other."""
    var place = _scratch("sub")
    var under = sub(dir_fs(place), "sub")

    assert_equal(String(from_utf8_lossy=read_file(under, "b.txt")), "b")
    assert_equal(String(from_utf8_lossy=read_file(under, "deeper/c.txt")), "c")
    with assert_raises():
        _ = read_file(under, "../a.txt")
    with assert_raises():
        _ = read_file(under, "a.txt")

    remove_all(place)


def test_read_link_through_the_file_system() raises:
    """`read_link` says what the link holds, whatever it points at.

    The target is not rewritten and not checked, which is the honest answer:
    the link says `../a.txt` and that is what it says. Following it is the
    caller's decision, and `dir_fs` refuses the name if they try it here.
    """
    var place = _scratch("link")
    symlink("../a.txt", join([place, "sub", "up.txt"]))
    var fsys = dir_fs(place)

    assert_equal(read_link(fsys, "sub/up.txt"), "../a.txt")

    # The link is followed by an ordinary open, which is what the package
    # docstring warns about: this reads a file above the link's own directory.
    assert_equal(String(from_utf8_lossy=read_file(fsys, "sub/up.txt")), "a")

    remove_all(place)
