"""Reading a directory, against a real one.

The same reasoning as the rest of this package's tests. `struct dirent` is 1048
bytes on macOS and 280 on Linux with `d_type` at 20 and 18, so a layout typed
from one platform reads a neighbouring byte on the other and hands back a name
that starts one character early or a type that is a fragment of the length.
Every test here makes a directory whose contents it chose and asks for them
back by name.

Nothing asserts that a type is what it should be without allowing
`DT_UNKNOWN`. Several file systems do not carry the type in the directory at
all, XFS and some network ones among them, and CI runs on file systems this
laptop does not have. `DT_UNKNOWN` is a real answer from a working call and a
test that refused it would fail on a platform where nothing is wrong. What is
worth asserting, and is asserted, is that the answer is never some third thing.
"""

from std.testing import (
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from core.errors import field
from core.syscall import (
    DT_DIR,
    DT_LNK,
    DT_REG,
    DT_UNKNOWN,
    ENOENT,
    ENOTDIR,
    close,
    closedir,
    create,
    getpid,
    mkdir,
    opendir,
    readdir,
    rmdir,
    symlink,
    unlink,
)


def _scratch(name: String) raises -> String:
    var place = String("/tmp/mojo-core-dir-", getpid(), "-", name)
    try:
        rmdir(place)
    except:
        pass
    mkdir(place, 0o700)
    return place


def _names(place: String) raises -> List[String]:
    """Every name in a directory, in whatever order the platform gives them.

    The order is not asserted anywhere. A directory is a set with an
    implementation defined order, it differs between the file systems this runs
    on, and a test that pinned it would be testing the file system.
    """
    var out = List[String]()
    var dir = opendir(place)
    while True:
        var entry = readdir(dir)
        if not entry:
            break
        out.append(entry.value().name)
    closedir(dir)
    return out^


def _holds(names: List[String], wanted: String) -> Bool:
    var found = False
    for name in names:
        if name == wanted:
            found = True
    return found


def _kind_of(place: String, wanted: String) raises -> Int:
    """The type one named entry reports."""
    var dir = opendir(place)
    var kind = -1
    while True:
        var entry = readdir(dir)
        if not entry:
            break
        if entry.value().name == wanted:
            kind = entry.value().kind
    closedir(dir)
    return kind


def test_a_directory_gives_back_what_was_put_in_it() raises:
    var place = _scratch("names")
    close(create(String(place, "/one.txt"), 0o644))
    close(create(String(place, "/two.txt"), 0o644))
    mkdir(String(place, "/inner"), 0o700)

    var names = _names(place)
    assert_true(_holds(names, "one.txt"))
    assert_true(_holds(names, "two.txt"))
    assert_true(_holds(names, "inner"))

    # Three entries and the two the platform puts in every directory, and
    # nothing else. The count is the assertion that catches a name read one
    # byte early, because a truncated name is still a name and still passes the
    # lookups above if the whole entry is found twice.
    assert_equal(len(names), 5)

    rmdir(String(place, "/inner"))
    unlink(String(place, "/one.txt"))
    unlink(String(place, "/two.txt"))
    rmdir(place)


def test_dot_and_dot_dot_are_entries_like_any_other() raises:
    # Go filters these in `os` rather than in `syscall`, and so do we. A caller
    # that gets a directory listing without them cannot tell whether the layer
    # underneath filtered them or the directory was strange.
    var place = _scratch("dots")
    var names = _names(place)
    assert_equal(len(names), 2)
    assert_true(_holds(names, "."))
    assert_true(_holds(names, ".."))
    rmdir(place)


def test_a_name_comes_back_whole() raises:
    # A long name and a one character name in the same directory. The long one
    # catches a `d_name` offset that is too small, which prefixes the name with
    # a byte of the type or the length, and the short one catches a scan that
    # runs past the terminator.
    var place = _scratch("wholename")
    var long = String("a-name-long-enough-to-cross-the-end-of-any-short-field")
    close(create(String(place, "/", long), 0o644))
    close(create(String(place, "/z"), 0o644))

    var names = _names(place)
    assert_true(_holds(names, long))
    assert_true(_holds(names, "z"))
    assert_equal(len(names), 4)

    unlink(String(place, "/", long))
    unlink(String(place, "/z"))
    rmdir(place)


def test_the_type_is_the_type_or_it_is_unknown() raises:
    var place = _scratch("kinds")
    close(create(String(place, "/plain.txt"), 0o644))
    mkdir(String(place, "/inner"), 0o700)
    symlink("plain.txt", String(place, "/pointer"))

    var plain = _kind_of(place, "plain.txt")
    assert_true(plain == DT_REG or plain == DT_UNKNOWN)
    var inner = _kind_of(place, "inner")
    assert_true(inner == DT_DIR or inner == DT_UNKNOWN)
    var pointer = _kind_of(place, "pointer")
    assert_true(pointer == DT_LNK or pointer == DT_UNKNOWN)

    # And a symbolic link is reported as itself rather than as what it points
    # at, which is the `lstat` rule rather than the `stat` one.
    assert_not_equal(pointer, DT_REG)

    unlink(String(place, "/pointer"))
    rmdir(String(place, "/inner"))
    unlink(String(place, "/plain.txt"))
    rmdir(place)


def test_every_entry_carries_an_inode_number() raises:
    # Not compared against what `stat` says, deliberately. The two agree on
    # every file system this is expected to run on and disagree on a union
    # mount, which is a difference between file systems rather than a bug here.
    # That an entry the platform just listed has a number at all is what the
    # offset being right looks like.
    var place = _scratch("inode")
    close(create(String(place, "/numbered.txt"), 0o644))

    var dir = opendir(place)
    var seen = 0
    while True:
        var entry = readdir(dir)
        if not entry:
            break
        assert_not_equal(entry.value().ino, UInt64(0))
        seen += 1
    closedir(dir)
    assert_equal(seen, 3)

    unlink(String(place, "/numbered.txt"))
    rmdir(place)


def test_the_end_of_a_directory_stays_the_end() raises:
    # Nothing and a failure are the same return value in C and are told apart
    # by errno, so a second read past the end is the case where a stale errno
    # would turn the end of a directory into a raised error.
    var place = _scratch("end")
    var dir = opendir(place)
    while readdir(dir):
        pass
    assert_false(readdir(dir))
    assert_false(readdir(dir))
    closedir(dir)
    rmdir(place)


def test_opening_a_directory_that_is_not_there_fails() raises:
    var place = _scratch("absent")
    try:
        _ = opendir(String(place, "/nowhere"))
        raise Error("opendir of a path that is not there should have failed")
    except e:
        assert_equal(field(e, "op").value(), "opendir")
        assert_equal(field(e, "errno").value(), String(ENOENT))
    rmdir(place)


def test_opening_a_file_as_a_directory_fails() raises:
    var place = _scratch("notdir")
    var path = String(place, "/plain.txt")
    close(create(path, 0o644))
    try:
        _ = opendir(path)
        raise Error("opendir of a regular file should have failed")
    except e:
        assert_equal(field(e, "op").value(), "opendir")
        assert_equal(field(e, "errno").value(), String(ENOTDIR))
    unlink(path)
    rmdir(place)


def test_an_entry_prints_its_name_and_its_type() raises:
    var place = _scratch("printed")
    close(create(String(place, "/shown.txt"), 0o644))

    var dir = opendir(place)
    var shown = String()
    while True:
        var entry = readdir(dir)
        if not entry:
            break
        if entry.value().name == "shown.txt":
            shown = String(entry.value())
    closedir(dir)

    # The type is spelled rather than numbered, because DT_UNKNOWN in a failing
    # assertion says what happened and 0 says nothing.
    assert_true(
        shown == "shown.txt (DT_REG)" or shown == "shown.txt (DT_UNKNOWN)"
    )

    unlink(String(place, "/shown.txt"))
    rmdir(place)
