"""Making and removing a whole tree.

The two calls in `core.os` that are walks rather than system calls, and the
tests are mostly about what each of them is allowed to ignore. `mkdir_all`
ignores a directory that is already there and `remove_all` ignores a path that
is not, and getting either of those rules slightly wrong is a bug that only
shows up the second time a program runs.

Every test builds its own tree under the system temporary directory and takes
it away with the call it is testing, which is a small amount of eating the
cooking: a test that cleaned up some other way would not notice `remove_all`
leaving something behind.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import matches
from core.errors.codes import ErrExist, ErrNotExist
from core.io.fs import FileMode, PathError
from core.os import (
    lstat,
    mkdir,
    mkdir_all,
    read_dir,
    remove_all,
    stat,
    symlink,
    write_file,
)
from core.syscall import EINVAL, getpid


def _scratch(name: String) raises -> String:
    """An empty directory of this suite's own."""
    var place = String("/tmp/mojo-core-ostree-", getpid(), "-", name)
    remove_all(place)
    mkdir(place, FileMode(0o700))
    return place


def _write(path: String, text: String) raises:
    write_file(path, text.as_bytes(), FileMode(0o644))


def _is_gone(path: String) raises -> Bool:
    try:
        _ = lstat(path)
        return False
    except e:
        return matches(e, ErrNotExist)


def test_mkdir_all_makes_every_level() raises:
    var place = _scratch("levels")
    var deep = String(place, "/one/two/three")
    mkdir_all(deep, FileMode(0o755))

    assert_true(stat(String(place, "/one")).is_dir())
    assert_true(stat(String(place, "/one/two")).is_dir())
    assert_true(stat(deep).is_dir())
    remove_all(place)


def test_mkdir_all_of_a_tree_that_is_already_there() raises:
    # The reason the function exists. A second call changes nothing and does
    # not complain, which is what lets a program call it on every start.
    var place = _scratch("already")
    var deep = String(place, "/one/two")
    mkdir_all(deep, FileMode(0o755))
    mkdir_all(deep, FileMode(0o755))
    assert_true(stat(deep).is_dir())
    remove_all(place)


def test_mkdir_all_leaves_the_mode_of_a_directory_that_was_there() raises:
    # This is not a way to fix permissions on a tree, and Go says the same. The
    # level that already existed keeps what it had.
    var place = _scratch("keptmode")
    var first = String(place, "/one")
    mkdir(first, FileMode(0o700))
    mkdir_all(String(first, "/two"), FileMode(0o755))
    assert_equal(stat(first).mode().perm(), FileMode(0o700))
    remove_all(place)


def test_mkdir_all_refuses_a_plain_file_in_the_way() raises:
    var place = _scratch("blocked")
    var file = String(place, "/one")
    _write(file, "in the way")
    try:
        mkdir_all(String(file, "/two"), FileMode(0o755))
        raise Error("a file in the way should have stopped mkdir_all")
    except e:
        assert_true(PathError.of(e))
        assert_equal(PathError.of(e).value().op, "mkdir")
    remove_all(place)


def test_mkdir_all_on_a_file_that_is_the_whole_path() raises:
    # The first `stat` finds something that is not a directory, which is the
    # branch that never reaches a call at all.
    var place = _scratch("isfile")
    var file = String(place, "/plain.txt")
    _write(file, "plain")
    try:
        mkdir_all(file, FileMode(0o755))
        raise Error("mkdir_all of a plain file should have failed")
    except e:
        assert_equal(PathError.of(e).value().op, "mkdir")
        assert_equal(PathError.of(e).value().path, file)
    remove_all(place)


def test_mkdir_all_with_a_trailing_separator_and_a_dot() raises:
    # Two spellings of the same directory that the platform's own `mkdir`
    # refuses, and that Go's second look accepts.
    var place = _scratch("spellings")
    mkdir_all(String(place, "/one/"), FileMode(0o755))
    assert_true(stat(String(place, "/one")).is_dir())
    mkdir_all(String(place, "/two/."), FileMode(0o755))
    assert_true(stat(String(place, "/two")).is_dir())
    remove_all(place)


def test_remove_all_takes_a_tree_away() raises:
    var place = _scratch("tree")
    mkdir_all(String(place, "/one/two/three"), FileMode(0o755))
    _write(String(place, "/top.txt"), "top")
    _write(String(place, "/one/middle.txt"), "middle")
    _write(String(place, "/one/two/three/deep.txt"), "deep")

    remove_all(place)
    assert_true(_is_gone(place))


def test_remove_all_of_a_path_that_is_not_there() raises:
    # Success, and the half that makes this the call to reach for when
    # cleaning up: the caller does not have to know what state anything is in.
    var place = _scratch("absent")
    remove_all(place)
    remove_all(place)
    assert_true(_is_gone(place))


def test_remove_all_of_one_plain_file() raises:
    var place = _scratch("onefile")
    var file = String(place, "/only.txt")
    _write(file, "only")
    remove_all(file)
    assert_true(_is_gone(file))
    assert_true(stat(place).is_dir())
    remove_all(place)


def test_remove_all_removes_a_link_and_not_what_it_points_at() raises:
    # The assertion that matters most here. A walk that followed links would
    # take away a directory the caller never named, and there is no way to get
    # that back.
    var keep = _scratch("keep")
    _write(String(keep, "/precious.txt"), "precious")

    var place = _scratch("withlink")
    mkdir(String(place, "/inner"), FileMode(0o755))
    symlink(keep, String(place, "/inner/pointer"))
    _write(String(place, "/inner/ordinary.txt"), "ordinary")

    remove_all(place)
    assert_true(_is_gone(place))
    assert_true(stat(keep).is_dir())
    assert_equal(stat(String(keep, "/precious.txt")).size(), 8)
    remove_all(keep)


def test_remove_all_refuses_a_path_ending_in_a_dot() raises:
    # `foo/.` names a directory that cannot be removed by that name, and a
    # caller who wrote it almost certainly meant `foo`.
    var place = _scratch("dotend")
    try:
        remove_all(String(place, "/."))
        raise Error("remove_all of a path ending in a dot should have failed")
    except e:
        assert_equal(PathError.of(e).value().op, "removeall")
        assert_equal(PathError.of(e).value().err.value, EINVAL)
    assert_true(stat(place).is_dir())
    remove_all(place)


def test_remove_all_of_an_empty_string_does_nothing() raises:
    remove_all("")


def test_remove_all_leaves_the_rest_of_the_directory_alone() raises:
    # The names are removed relative to the descriptor of the directory they
    # were read from, so a sibling of the target is not touched.
    var place = _scratch("siblings")
    mkdir_all(String(place, "/going/deeper"), FileMode(0o755))
    _write(String(place, "/going/deeper/gone.txt"), "gone")
    mkdir(String(place, "/staying"), FileMode(0o755))
    _write(String(place, "/staying/kept.txt"), "kept")

    remove_all(String(place, "/going"))
    assert_true(_is_gone(String(place, "/going")))

    var left = read_dir(place)
    assert_equal(len(left), 1)
    assert_equal(left[0].name(), "staying")
    assert_equal(stat(String(place, "/staying/kept.txt")).size(), 4)
    remove_all(place)


def test_remove_all_of_a_wide_directory() raises:
    # Enough entries that the directory is read in more than one go on every
    # file system in the matrix, which is the case a read that resumed at the
    # wrong place would get wrong.
    var place = _scratch("wide")
    var inner = String(place, "/many")
    mkdir(inner, FileMode(0o755))
    for i in range(200):
        _write(String(inner, "/file-", i, ".txt"), "x")
    assert_equal(len(read_dir(inner)), 200)

    remove_all(inner)
    assert_true(_is_gone(inner))
    remove_all(place)


def test_remove_all_of_a_deep_tree() raises:
    # The recursion, given something to recurse through. Twenty levels is well
    # inside what a path can spell and well past anything an accident makes.
    var place = _scratch("deep")
    var path = String(place)
    for i in range(20):
        path = String(path, "/level-", i)
    mkdir_all(path, FileMode(0o755))
    _write(String(path, "/bottom.txt"), "bottom")

    remove_all(String(place, "/level-0"))
    assert_true(_is_gone(String(place, "/level-0")))
    assert_true(stat(place).is_dir())
    remove_all(place)
