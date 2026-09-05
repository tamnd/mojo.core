"""Go's `TestAbs` and `TestEvalSymlinks`, over a tree built for the occasion.

Go's own tables for these two are not usable as tables. `TestAbs` compares
against the working directory, which is different on every machine, and
`TestEvalSymlinks` is a list of links to make followed by a list of paths to
resolve, which is a program rather than data. So the shape is Go's and the rows
are written here.

Nothing in this file compares an absolute path against a literal. macOS puts
`/tmp` behind a symbolic link to `/private/tmp` and Linux does not, so a test
that spelled the answer out would be a test that only passes on one of them.
The scratch directory is resolved once and everything is compared against that.
"""

from std.testing import assert_equal, assert_not_equal, assert_true

from core.errors import field, matches
from core.errors.codes import ErrNotExist
from core.io.fs import FileMode
from core.os import getwd, mkdir, remove_all, symlink, write_file
from core.path.filepath import abs, clean, eval_symlinks, join
from core.syscall import ELOOP, ENOTDIR, getpid


def _scratch(name: String) raises -> String:
    """An empty directory of this suite's own, and its resolved name."""
    var place = String("/tmp/mojo-core-fpdisk-", getpid(), "-", name)
    remove_all(place)
    mkdir(place, FileMode(0o700))
    return eval_symlinks(place)


def _file(place: String, name: String) raises -> String:
    var full = join([place, name])
    write_file(full, "content".as_bytes(), FileMode(0o600))
    return full^


def test_abs_only_cleans_a_path_that_is_already_absolute() raises:
    assert_equal(abs("/usr/../bin"), "/bin")
    assert_equal(abs("/a/b/./c/"), "/a/b/c")


def test_abs_puts_the_working_directory_in_front_of_a_relative_path() raises:
    var here = getwd()
    assert_equal(abs("x"), join([here, "x"]))
    assert_equal(abs("."), clean(here))
    assert_equal(abs("a/../b"), join([here, "b"]))


def test_eval_symlinks_leaves_a_path_with_no_links_alone() raises:
    var place = _scratch("plain")
    var name = _file(place, "note")

    assert_equal(eval_symlinks(name), join([place, "note"]))
    assert_equal(eval_symlinks(join([place, "./note"])), join([place, "note"]))

    remove_all(place)


def test_eval_symlinks_follows_a_link_to_a_file() raises:
    var place = _scratch("tofile")
    _ = _file(place, "real")
    symlink("real", join([place, "link"]))

    assert_equal(eval_symlinks(join([place, "link"])), join([place, "real"]))

    remove_all(place)


def test_eval_symlinks_follows_a_link_in_the_middle_of_a_path() raises:
    # The whole reason this is not just one readlink on the last element.
    var place = _scratch("middle")
    mkdir(join([place, "sub"]), FileMode(0o700))
    _ = _file(join([place, "sub"]), "deep")
    symlink("sub", join([place, "toward"]))

    assert_equal(
        eval_symlinks(join([place, "toward", "deep"])),
        join([place, "sub", "deep"]),
    )

    remove_all(place)


def test_eval_symlinks_follows_an_absolute_link() raises:
    var place = _scratch("absolute")
    mkdir(join([place, "sub"]), FileMode(0o700))
    var target = _file(join([place, "sub"]), "deep")
    symlink(target, join([place, "shortcut"]))

    assert_equal(eval_symlinks(join([place, "shortcut"])), target)

    remove_all(place)


def test_eval_symlinks_takes_dot_dot_off_the_answer() raises:
    var place = _scratch("dotdot")
    mkdir(join([place, "sub"]), FileMode(0o700))
    _ = _file(place, "note")

    assert_equal(
        eval_symlinks(join([place, "sub", "..", "note"])),
        join([place, "note"]),
    )

    remove_all(place)


def test_eval_symlinks_on_a_missing_path_says_so() raises:
    var place = _scratch("missing")

    try:
        _ = eval_symlinks(join([place, "not-here"]))
        raise Error("resolving a missing path should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))

    remove_all(place)


def test_eval_symlinks_refuses_a_file_used_as_a_directory() raises:
    var place = _scratch("notdir")
    _ = _file(place, "note")

    try:
        _ = eval_symlinks(join([place, "note", "deeper"]))
        raise Error("a file used as a directory should have failed")
    except e:
        assert_equal(field(e, "op").value(), "evalsymlinks")
        assert_equal(field(e, "errno").value(), String(ENOTDIR))
        # Go raises a bare errno here with no path on it at all.
        assert_equal(field(e, "path").value(), join([place, "note"]))

    remove_all(place)


def test_eval_symlinks_gives_up_on_a_loop() raises:
    var place = _scratch("loop")
    symlink("second", join([place, "first"]))
    symlink("first", join([place, "second"]))

    try:
        _ = eval_symlinks(join([place, "first"]))
        raise Error("a loop of links should have failed")
    except e:
        assert_equal(field(e, "op").value(), "evalsymlinks")
        assert_equal(field(e, "errno").value(), String(ELOOP))
        assert_equal(field(e, "path").value(), join([place, "first"]))

    remove_all(place)


def test_eval_symlinks_and_abs_together_name_one_file_once() raises:
    # The pair Go recommends for a path that has to be compared with another.
    var place = _scratch("pair")
    _ = _file(place, "real")
    symlink("real", join([place, "link"]))

    var one = eval_symlinks(abs(join([place, "link"])))
    var two = eval_symlinks(abs(join([place, ".", "real"])))
    assert_equal(one, two)
    assert_not_equal(one, join([place, "link"]))

    remove_all(place)
