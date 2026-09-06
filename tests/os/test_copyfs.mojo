"""`copy_fs`, from a real directory onto real files.

The source is a `dir_fs` over a scratch tree rather than a file system built in
memory, because the two halves of this function are a walk and a create and the
walk is the half that has to see real directory entries. A source made up here
would let a symbolic link through as whatever this file said it was.

Every assertion about a mode is about a bit being set rather than about the
whole number, since the umask belongs to whoever started the run and takes bits
out of every creation this makes.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import matches
from core.io import Byte
from core.io.fs import ErrInvalid, FileMode
from core.os import (
    chmod,
    copy_fs,
    dir_fs,
    getpid,
    is_exist,
    mkdir_all,
    read_file,
    remove_all,
    stat,
    symlink,
    write_file,
)


def _scratch(name: String) raises -> String:
    """A directory holding `src`, with two files and one subdirectory in it."""
    var place = String("/tmp/mojo-core-copyfs-", getpid(), "-", name)
    remove_all(place)
    mkdir_all(String(place, "/src/sub"), FileMode(0o755))
    write_file(String(place, "/src/a.txt"), "a\n".as_bytes(), FileMode(0o644))
    write_file(
        String(place, "/src/sub/b.txt"), "b\n".as_bytes(), FileMode(0o644)
    )
    return place


def _text(data: List[Byte]) -> String:
    return String(from_utf8_lossy=Span(data))


def test_copy_fs_copies_a_whole_tree() raises:
    var place = _scratch("tree")
    copy_fs(String(place, "/dst"), dir_fs(String(place, "/src")))

    assert_true(stat(String(place, "/dst")).mode().is_dir())
    assert_true(stat(String(place, "/dst/sub")).mode().is_dir())
    assert_equal(_text(read_file(String(place, "/dst/a.txt"))), "a\n")
    assert_equal(_text(read_file(String(place, "/dst/sub/b.txt"))), "b\n")


def test_copy_fs_makes_the_destination_and_every_parent_it_needs() raises:
    var place = _scratch("parents")
    copy_fs(String(place, "/one/two/three"), dir_fs(String(place, "/src")))

    assert_equal(_text(read_file(String(place, "/one/two/three/a.txt"))), "a\n")


def test_copy_fs_keeps_the_executable_bit() raises:
    var place = _scratch("mode")
    chmod(String(place, "/src/a.txt"), FileMode(0o755))
    copy_fs(String(place, "/dst"), dir_fs(String(place, "/src")))

    var copied = stat(String(place, "/dst/a.txt")).mode().perm()
    assert_true(copied.value & 0o100 != 0)
    assert_true(copied.value & 0o400 != 0)


def test_copy_fs_refuses_a_file_that_is_already_there() raises:
    var place = _scratch("exists")
    copy_fs(String(place, "/dst"), dir_fs(String(place, "/src")))

    var refused = False
    try:
        copy_fs(String(place, "/dst"), dir_fs(String(place, "/src")))
    except e:
        refused = is_exist(e)
    assert_true(refused)


def test_copy_fs_refuses_anything_that_is_not_a_regular_file() raises:
    """A symbolic link is the case, and there is no way to copy one.

    An `FS` has no `read_link` that every implementation answers, so the target
    cannot be asked for, and writing the link out as an ordinary file holding
    the target's contents would put a second copy of the data somewhere the
    caller did not ask for one. Go refuses it for the same reason.
    """
    var place = _scratch("link")
    symlink("a.txt", String(place, "/src/link"))

    var refused = False
    try:
        copy_fs(String(place, "/dst"), dir_fs(String(place, "/src")))
    except e:
        refused = matches(e, ErrInvalid)
    assert_true(refused)


def test_copy_fs_over_an_empty_source_makes_just_the_directory() raises:
    var place = String("/tmp/mojo-core-copyfs-", getpid(), "-empty")
    remove_all(place)
    mkdir_all(String(place, "/src"), FileMode(0o755))

    copy_fs(String(place, "/dst"), dir_fs(String(place, "/src")))
    assert_true(stat(String(place, "/dst")).mode().is_dir())
    assert_false(stat(String(place, "/dst")).mode().is_regular())
