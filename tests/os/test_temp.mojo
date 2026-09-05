"""Temporary files and directories, and the times on a path.

`create_temp` and `mkdir_temp` make something with a name nobody chose, so
there is nothing here that can assert what the name is. What can be asserted is
everything around it: that the prefix and the suffix are the ones asked for,
that the random part is somewhere between them, that two calls do not collide,
that the permissions are the tight ones, and that a pattern with a separator in
it is refused before anything is made.

`chtimes` is in this file rather than beside the other path calls because it is
the one call in `core.os` that needs `core.time`, and keeping it here keeps that
dependency in one suite.

Everything made here is taken away again, whether the test passed or not.
"""

from std.testing import assert_equal, assert_false, assert_not_equal
from std.testing import assert_raises, assert_true

from core.errors import field, matches
from core.errors.codes import ErrInvalid, ErrNotExist
from core.io import SEEK_START, read_all
from core.io.fs import FileMode, MODE_DIR
from core.os import (
    chtimes,
    create_temp,
    mkdir,
    mkdir_temp,
    open as os_open,
    remove,
    remove_all,
    stat,
    temp_dir,
    write_file,
)
from core.syscall import getpid
from core.syscall import stat as sys_stat
from core.time import Time, unix


def _scratch(name: String) raises -> String:
    """An empty directory of this suite's own."""
    var place = String("/tmp/mojo-core-ostemp-", getpid(), "-", name)
    remove_all(place)
    mkdir(place, FileMode(0o700))
    return place


def _has_prefix(text: String, want: String) -> Bool:
    """Whether `text` starts with `want`."""
    return (
        text.byte_length() >= want.byte_length()
        and String(text[byte = : want.byte_length()]) == want
    )


def _has_suffix(text: String, want: String) -> Bool:
    """Whether `text` ends with `want`."""
    if text.byte_length() < want.byte_length():
        return False
    return (
        String(text[byte = text.byte_length() - want.byte_length() :]) == want
    )


def test_create_temp_puts_the_random_part_at_the_star() raises:
    var place = _scratch("star")

    var f = create_temp(place, "note-*.txt")
    var name = f.name()
    _ = f.write_string("written\n")
    f.close()

    assert_true(_has_prefix(name, String(place, "/note-")))
    assert_true(_has_suffix(name, ".txt"))
    # Something was put where the star was, rather than the star being dropped.
    assert_true(name.byte_length() > String(place, "/note-.txt").byte_length())

    var back = os_open(name)
    var text = read_all(back)
    back.close()
    assert_equal(String(from_utf8_lossy=Span(text)), "written\n")

    remove_all(place)


def test_create_temp_with_no_star_appends() raises:
    var place = _scratch("nostar")

    var f = create_temp(place, "note-")
    var name = f.name()
    f.close()

    assert_true(_has_prefix(name, String(place, "/note-")))
    assert_true(name.byte_length() > String(place, "/note-").byte_length())

    remove_all(place)


def test_create_temp_uses_the_last_star() raises:
    # Go replaces the last star and leaves any earlier one in the name, so a
    # pattern is not a glob and a literal star is reachable.
    var place = _scratch("laststar")

    var f = create_temp(place, "a*b*c")
    var name = f.name()
    f.close()

    assert_true(_has_prefix(name, String(place, "/a*b")))
    assert_true(_has_suffix(name, "c"))

    remove_all(place)


def test_create_temp_opens_the_file_readable_and_writable() raises:
    var place = _scratch("rw")

    var f = create_temp(place, "rw-*")
    var name = f.name()
    _ = f.write_string("both ways")
    _ = f.seek(0, SEEK_START)
    var text = read_all(f)
    f.close()
    assert_equal(String(from_utf8_lossy=Span(text)), "both ways")

    remove_all(place)


def test_create_temp_makes_a_file_only_its_owner_can_read() raises:
    # The unguessable name is half the argument and this is the other half.
    var place = _scratch("perm")

    var f = create_temp(place, "secret-*")
    var name = f.name()
    f.close()

    assert_equal(stat(name).mode().perm(), FileMode(0o600))

    remove_all(place)


def test_create_temp_with_an_empty_directory_uses_temp_dir() raises:
    var f = create_temp("", "mojo-core-empty-dir-*")
    var name = f.name()
    f.close()

    # Not built with a separator of this test's own, because TMPDIR is allowed
    # to end in one and on macOS it usually does. The rule is Go's joinPath:
    # one separator between the two, never two.
    assert_true(_has_prefix(name, temp_dir()))
    assert_true("/mojo-core-empty-dir-" in name)
    assert_false("//" in name)

    remove(name)


def test_create_temp_does_not_double_a_trailing_separator() raises:
    var place = _scratch("trailing")

    var f = create_temp(String(place, "/"), "note-*")
    var name = f.name()
    f.close()

    assert_true(_has_prefix(name, String(place, "/note-")))
    assert_false("//" in name)

    remove_all(place)


def test_create_temp_refuses_a_pattern_holding_a_separator() raises:
    var place = _scratch("sep")

    try:
        var f = create_temp(place, "sub/note-*")
        f.close()
        raise Error("a pattern with a separator should have been refused")
    except e:
        assert_true(matches(e, ErrInvalid))
        assert_equal(field(e, "op").value(), "createtemp")
        assert_equal(field(e, "path").value(), "sub/note-*")

    remove_all(place)


def test_create_temp_raises_a_failure_that_is_not_a_collision() raises:
    # Only a name that was taken is retried. Anything else comes straight back
    # out, because ten thousand attempts at a directory that is not there is a
    # slow way to report that a directory is not there.
    var place = _scratch("nodir")

    try:
        var f = create_temp(String(place, "/absent"), "note-*")
        f.close()
        raise Error("creating under a missing directory should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))

    remove_all(place)


def test_mkdir_temp_makes_a_directory_of_its_own() raises:
    var place = _scratch("dir")

    var one = mkdir_temp(place, "work-*")
    var two = mkdir_temp(place, "work-*")

    assert_not_equal(one, two)
    assert_true(_has_prefix(one, String(place, "/work-")))
    assert_true(stat(one).is_dir())
    assert_equal(stat(one).mode().type(), MODE_DIR)
    assert_equal(stat(one).mode().perm(), FileMode(0o700))

    remove_all(place)


def test_mkdir_temp_refuses_a_pattern_holding_a_separator() raises:
    var place = _scratch("dirsep")

    try:
        _ = mkdir_temp(place, "a/b-*")
        raise Error("a pattern with a separator should have been refused")
    except e:
        assert_true(matches(e, ErrInvalid))
        assert_equal(field(e, "op").value(), "mkdirtemp")

    remove_all(place)


def test_chtimes_sets_both_times() raises:
    var place = _scratch("times")
    var name = String(place, "/dated")
    write_file(name, "content".as_bytes(), FileMode(0o600))

    var when = unix(1_600_000_000, 0)
    var later = unix(1_700_000_000, 0)
    chtimes(name, when, later)

    var raw = sys_stat(name)
    assert_equal(raw.atime().sec, 1_600_000_000)
    assert_equal(raw.mtime().sec, 1_700_000_000)
    assert_equal(stat(name).mod_time().unix(), 1_700_000_000)

    remove_all(place)


def test_chtimes_leaves_a_zero_time_alone() raises:
    var place = _scratch("omit")
    var name = String(place, "/half")
    write_file(name, "content".as_bytes(), FileMode(0o600))

    chtimes(name, unix(1_500_000_000, 0), unix(1_500_000_001, 0))
    chtimes(name, Time(), unix(1_600_000_000, 0))

    var raw = sys_stat(name)
    assert_equal(raw.atime().sec, 1_500_000_000)
    assert_equal(raw.mtime().sec, 1_600_000_000)

    remove_all(place)


def test_chtimes_with_two_zero_times_changes_nothing() raises:
    var place = _scratch("nothing")
    var name = String(place, "/still")
    write_file(name, "content".as_bytes(), FileMode(0o600))

    chtimes(name, unix(1_400_000_000, 0), unix(1_400_000_001, 0))
    chtimes(name, Time(), Time())

    var raw = sys_stat(name)
    assert_equal(raw.atime().sec, 1_400_000_000)
    assert_equal(raw.mtime().sec, 1_400_000_001)

    remove_all(place)


def test_chtimes_on_a_missing_path_says_which_path() raises:
    var place = _scratch("missing")

    try:
        chtimes(String(place, "/not-here"), Time(), unix(1, 0))
        raise Error("setting the times on a missing file should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))
        assert_equal(field(e, "op").value(), "chtimes")
        assert_equal(field(e, "path").value(), String(place, "/not-here"))

    remove_all(place)
