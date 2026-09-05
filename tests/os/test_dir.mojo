"""Reading real directories, and the entries that come back.

Every directory here is one this suite makes, fills and takes away again, for
the reason the rest of these suites give: a listing of a directory somebody
else owns is a test that passes until somebody else changes their mind.

The scratch directory carries the process id so two runs do not read each
other's files, and every test removes what it made whether it passed or not.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.errors import matches
from core.errors.codes import EOF, ErrClosed, ErrNotExist
from core.io.fs import (
    MODE_DIR,
    MODE_SYMLINK,
    FileInfo,
    FileMode,
    PathError,
    file_info_to_dir_entry,
    format_dir_entry,
)
from core.os import create, open, read_dir
from core.syscall import getpid, mkdir, rmdir, symlink, unlink
from core.time import unix


def _scratch(name: String) raises -> String:
    """An empty directory of this suite's own."""
    var place = String("/tmp/mojo-core-osdir-", getpid(), "-", name)
    try:
        rmdir(place)
    except:
        pass
    mkdir(place, 0o700)
    return place


def _clear(place: String, names: List[String]) raises:
    """Remove the named entries, then the directory itself."""
    for name in names:
        try:
            unlink(String(place, "/", name))
        except:
            pass
        try:
            rmdir(String(place, "/", name))
        except:
            pass
    rmdir(place)


def _touch(path: String) raises:
    """An empty file at this path."""
    var made = create(path)
    made.close()


def test_a_directory_with_one_of_each_kind() raises:
    # The kind comes out of the directory read itself on both platforms in the
    # matrix, so none of these three assertions costs a stat.
    var place = _scratch("kinds")
    _touch(String(place, "/file.txt"))
    mkdir(String(place, "/sub"), 0o700)
    symlink("file.txt", String(place, "/link"))

    var entries = read_dir(place)
    assert_equal(len(entries), 3)

    assert_equal(entries[0].name(), "file.txt")
    assert_true(entries[0].type().is_regular())
    assert_false(entries[0].is_dir())

    assert_equal(entries[1].name(), "link")
    assert_equal(entries[1].type(), MODE_SYMLINK)
    assert_false(entries[1].is_dir())

    assert_equal(entries[2].name(), "sub")
    assert_true(entries[2].is_dir())
    assert_equal(entries[2].type(), MODE_DIR)

    _clear(place, ["file.txt", "link", "sub"])


def test_the_listing_is_sorted_and_drops_dot_and_dot_dot() raises:
    # Created out of order on purpose. The order a file system hands entries
    # back in is its own business, which is why this sorts and why Go does.
    var place = _scratch("sorted")
    for name in ["zebra", "apple", "Mango", "banana"]:
        _touch(String(place, "/", name))

    var entries = read_dir(place)
    var names = List[String]()
    for ref entry in entries:
        names.append(entry.name())

    assert_equal(len(names), 4)
    assert_equal(names[0], "Mango")
    assert_equal(names[1], "apple")
    assert_equal(names[2], "banana")
    assert_equal(names[3], "zebra")

    _clear(place, ["zebra", "apple", "Mango", "banana"])


def test_an_empty_directory_reads_as_an_empty_list() raises:
    # Not an error and not the end of anything: a directory with nothing in it
    # still has `.` and `..`, and both are dropped.
    var place = _scratch("empty")
    assert_equal(len(read_dir(place)), 0)
    rmdir(place)


def test_a_directory_that_is_not_there() raises:
    var place = _scratch("absent")
    rmdir(place)
    try:
        _ = read_dir(place)
        raise Error("reading a directory that is gone should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))
        var reported = PathError.of(e)
        assert_true(reported)
        assert_equal(reported.value().op, "open")


def test_info_asks_the_host_again() raises:
    # The size is not carried by a directory entry, so this is the call that
    # goes and gets it, and it reports what is there now rather than what was
    # there when the directory was read.
    var place = _scratch("info")
    var path = String(place, "/notes.txt")
    var out = create(path)
    _ = out.write_string("twelve bytes")
    out.close()

    var entries = read_dir(place)
    assert_equal(len(entries), 1)
    var info = entries[0].info()
    assert_equal(info.name(), "notes.txt")
    assert_equal(info.size(), 12)
    assert_false(info.is_dir())

    _clear(place, ["notes.txt"])


def test_info_on_an_entry_that_has_gone() raises:
    # The race every directory listing has. The entry was read, the file was
    # removed, and the question is answered honestly rather than from a copy
    # taken earlier.
    var place = _scratch("vanished")
    _touch(String(place, "/here.txt"))
    var entries = read_dir(place)
    unlink(String(place, "/here.txt"))

    try:
        _ = entries[0].info()
        raise Error("info on a removed entry should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))
    rmdir(place)


def test_info_on_a_link_describes_the_link() raises:
    # `lstat` rather than `stat`, which is what makes the type bits and the
    # info agree with each other for a symbolic link.
    var place = _scratch("linkinfo")
    _touch(String(place, "/target.txt"))
    symlink("target.txt", String(place, "/pointer"))

    var entries = read_dir(place)
    assert_equal(entries[0].name(), "pointer")
    assert_equal(entries[0].info().mode().type(), MODE_SYMLINK)

    _clear(place, ["pointer", "target.txt"])


def test_reading_a_directory_a_piece_at_a_time() raises:
    # A positive count reads at most that many and resumes where the last call
    # stopped, which is the whole reason a File holds a directory position.
    var place = _scratch("pieces")
    for name in ["a", "b", "c", "d", "e"]:
        _touch(String(place, "/", name))

    var dir = open(place)
    var first = dir.read_dir(2)
    var second = dir.read_dir(2)
    var third = dir.read_dir(2)
    assert_equal(len(first), 2)
    assert_equal(len(second), 2)
    assert_equal(len(third), 1)

    var seen = List[String]()
    for ref entry in first:
        seen.append(entry.name())
    for ref entry in second:
        seen.append(entry.name())
    for ref entry in third:
        seen.append(entry.name())
    assert_equal(len(seen), 5)

    with assert_raises():
        _ = dir.read_dir(2)
    dir.close()

    _clear(place, ["a", "b", "c", "d", "e"])


def test_the_end_of_a_partial_read_is_the_end_of_input() raises:
    var place = _scratch("pieceend")
    var dir = open(place)
    try:
        _ = dir.read_dir(1)
        raise Error("reading an empty directory by pieces should have ended")
    except e:
        assert_true(matches(e, EOF))
    dir.close()
    rmdir(place)


def test_reading_everything_at_the_end_is_an_empty_list() raises:
    # A count of zero or less never raises at the end, which is the difference
    # between the two shapes of the call and is Go's rule as well.
    var place = _scratch("allend")
    _touch(String(place, "/one"))

    var dir = open(place)
    assert_equal(len(dir.read_dir(0)), 1)
    assert_equal(len(dir.read_dir(0)), 0)
    dir.close()

    _clear(place, ["one"])


def _holds(got: List[String], want: List[String]) raises:
    """Assert a listing holds exactly these names, in whatever order.

    The three methods on `File` hand entries back in the order the file system
    keeps them, which is Go's rule for the same three, so a test that expects
    them sorted is testing the file system rather than this library. Sorting is
    what the package level `read_dir` is for, and it has its own test.
    """
    assert_equal(len(got), len(want))
    for ref name in want:
        var found = False
        for ref entry in got:
            if entry == name:
                found = True
        assert_true(found, String("expected ", name, " in the listing"))


def test_readdir_and_readdirnames() raises:
    var place = _scratch("names")
    _touch(String(place, "/second"))
    _touch(String(place, "/first"))

    var dir = open(place)
    var names = dir.readdirnames(0)
    dir.close()
    _holds(names, ["first", "second"])

    var again = open(place)
    var infos = again.readdir(0)
    again.close()
    var from_infos = List[String]()
    for ref info in infos:
        from_infos.append(info.name())
    _holds(from_infos, ["first", "second"])

    _clear(place, ["first", "second"])


def test_a_closed_file_refuses_to_read_a_directory() raises:
    var place = _scratch("closeddir")
    var dir = open(place)
    dir.close()
    try:
        _ = dir.read_dir(0)
        raise Error("reading a closed directory should have failed")
    except e:
        assert_true(matches(e, ErrClosed))
    rmdir(place)


def test_reading_a_file_as_a_directory() raises:
    var place = _scratch("notadir")
    var path = String(place, "/plain.txt")
    _touch(path)

    var plain = open(path)
    with assert_raises():
        _ = plain.read_dir(0)
    plain.close()

    _clear(place, ["plain.txt"])


def test_the_directory_handle_goes_back_with_the_file() raises:
    # The handle holds a second descriptor, so a file read and then closed
    # many times over would run the process out of them if it leaked.
    var place = _scratch("handles")
    _touch(String(place, "/one"))
    for _ in range(64):
        var dir = open(place)
        _ = dir.read_dir(0)
        dir.close()
    _clear(place, ["one"])


def test_an_entry_built_from_an_info() raises:
    # The case a file system with no host underneath it produces: everything
    # is known already and nothing is asked of a platform that is not there.
    var info = FileInfo(
        name="notes.txt", size=12, mode=FileMode(0o644), mod_time=unix(0, 0)
    )
    var entry = file_info_to_dir_entry(info^)
    assert_equal(entry.name(), "notes.txt")
    assert_false(entry.is_dir())
    assert_equal(entry.info().size(), 12)


def test_an_entry_written_out() raises:
    var info = FileInfo(
        name="src", size=0, mode=FileMode(0o755) | MODE_DIR, mod_time=unix(0, 0)
    )
    assert_equal(format_dir_entry(file_info_to_dir_entry(info^)), "d src/")

    var plain = FileInfo(
        name="notes.txt", size=1, mode=FileMode(0o644), mod_time=unix(0, 0)
    )
    assert_equal(
        format_dir_entry(file_info_to_dir_entry(plain^)), "- notes.txt"
    )
