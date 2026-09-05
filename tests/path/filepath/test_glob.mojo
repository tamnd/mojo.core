"""Go's `TestGlob`, `TestGlobError` and `TestGlobSymlink`, over a tree built for
the occasion.

Go's rows are paths in its own source tree, which is not here, so the tree is
built and the rows are written against it. The three things worth pinning are
Go's and are the ones people get wrong: no match is not a failure, a directory
that cannot be read is not a failure either, and a malformed pattern is the
only thing that is.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.errors import matches
from core.errors.codes import ErrBadPattern
from core.io.fs import FileMode
from core.os import chmod, mkdir, remove_all, symlink, write_file
from core.path.filepath import glob, join
from core.syscall import getpid


def _scratch(name: String) raises -> String:
    var place = String("/tmp/mojo-core-fpglob-", getpid(), "-", name)
    remove_all(place)
    mkdir(place, FileMode(0o700))
    return place^


def _file(place: String, name: String) raises:
    write_file(join([place, name]), "x".as_bytes(), FileMode(0o600))


def _names(found: List[String], place: String) raises -> List[String]:
    """A glob result with the scratch directory taken off the front of each."""
    var out = List[String]()
    var cut = place.byte_length() + 1
    for ref name in found:
        out.append(String(name[byte=cut:]))
    return out^


def test_glob_with_nothing_special_in_it_is_one_lstat() raises:
    var place = _scratch("plain")
    _file(place, "note")

    assert_equal(glob(join([place, "note"])), [join([place, "note"])])
    assert_equal(len(glob(join([place, "absent"]))), 0)

    remove_all(place)


def test_glob_matches_within_one_directory_in_order() raises:
    var place = _scratch("order")
    _file(place, "c.txt")
    _file(place, "a.txt")
    _file(place, "b.log")

    assert_equal(
        _names(glob(join([place, "*.txt"])), place), ["a.txt", "c.txt"]
    )
    assert_equal(
        _names(glob(join([place, "*"])), place), ["a.txt", "b.log", "c.txt"]
    )

    remove_all(place)


def test_glob_star_does_not_cross_a_separator() raises:
    var place = _scratch("cross")
    mkdir(join([place, "sub"]), FileMode(0o700))
    _file(join([place, "sub"]), "deep.txt")

    assert_equal(len(glob(join([place, "*.txt"]))), 0)
    assert_equal(
        _names(glob(join([place, "*", "*.txt"])), place), ["sub/deep.txt"]
    )

    remove_all(place)


def test_glob_matches_a_leading_dot_where_a_shell_would_not() raises:
    # Go's `Match` has no special case for a name beginning with a dot, so a
    # glob here finds the names a shell hides. Worth knowing before using this
    # to build a list somebody is going to delete.
    var place = _scratch("hidden")
    _file(place, ".secret")
    _file(place, "plain")

    assert_equal(_names(glob(join([place, "*"])), place), [".secret", "plain"])

    remove_all(place)


def test_glob_of_a_missing_directory_is_empty_and_not_a_failure() raises:
    var place = _scratch("nodir")

    assert_equal(len(glob(join([place, "absent", "*"]))), 0)
    assert_equal(len(glob(join([place, "*", "*"]))), 0)

    remove_all(place)


def test_glob_skips_a_directory_it_cannot_read() raises:
    # Go ignores the read failure and reports what it could find. A caller who
    # needs to know a directory was unreadable walks it instead.
    var place = _scratch("shut")
    mkdir(join([place, "open"]), FileMode(0o700))
    _file(join([place, "open"]), "seen.txt")
    mkdir(join([place, "shut"]), FileMode(0o700))
    _file(join([place, "shut"]), "hidden.txt")
    chmod(join([place, "shut"]), FileMode(0o000))

    var found = _names(glob(join([place, "*", "*.txt"])), place)

    chmod(join([place, "shut"]), FileMode(0o700))
    remove_all(place)

    # Running as root reads it anyway, so the assertion is about the open one.
    assert_true("open/seen.txt" in found)


def test_glob_refuses_a_pattern_that_is_not_one() raises:
    var place = _scratch("bad")

    with assert_raises():
        _ = glob(join([place, "[", "x"]))
    try:
        _ = glob(join([place, "[a-"]))
        raise Error("a malformed pattern should have been refused")
    except e:
        assert_true(matches(e, ErrBadPattern))

    remove_all(place)


def test_glob_reports_a_symbolic_link_without_following_it() raises:
    var place = _scratch("link")
    _file(place, "real.txt")
    symlink("real.txt", join([place, "alias.txt"]))

    assert_equal(
        _names(glob(join([place, "*.txt"])), place), ["alias.txt", "real.txt"]
    )

    remove_all(place)
