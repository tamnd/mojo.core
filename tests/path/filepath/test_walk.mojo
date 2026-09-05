"""Go's `TestWalk`, `TestWalkSkipDirOnFile`, `TestWalkFileError` and
`TestWalkSymlinkRoot`, over a tree built for the occasion.

Go's walk tests build a tree, walk it and compare the visits against a list, so
that is what these do. Every assertion is about names relative to the root, and
the root is a scratch directory whose real name has a process id in it, so that
two runs on one machine cannot collide.

The four things worth pinning are the four people get wrong. The order is
lexical and the root comes first. `SkipDir` from a callback given a file skips
the rest of that file's directory rather than nothing. A failure reaching a
name goes to the callback rather than out of the walk. And a symbolic link is
reported and not followed.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import ErrorValue, matches
from core.errors.codes import ErrNotExist
from core.io.fs import DirEntry, FileInfo, FileMode, skip_all, skip_dir
from core.os import chmod, mkdir, mkdir_all, remove_all, symlink, write_file
from core.path.filepath import join, walk, walk_dir
from core.syscall import getpid


def _file(dir: String, name: String) raises:
    write_file(join([dir, name]), "x".as_bytes(), FileMode(0o600))


def _scratch(name: String) raises -> String:
    """The tree every test in this file walks.

    ```text
    a.txt
    sub/b.txt
    sub/deeper/c.txt
    z.txt
    ```
    """
    var place = String("/tmp/mojo-core-fpwalk-", getpid(), "-", name)
    remove_all(place)
    mkdir_all(join([place, "sub", "deeper"]), FileMode(0o700))
    _file(place, "a.txt")
    _file(place, "z.txt")
    _file(join([place, "sub"]), "b.txt")
    _file(join([place, "sub", "deeper"]), "c.txt")
    return place^


def _under(place: String, path: String) -> String:
    """A visited path as it reads relative to the root, with the root as `.`."""
    if path == place:
        return String(".")
    return String(path[byte = place.byte_length() + 1 :])


def test_walk_dir_visits_the_root_and_everything_under_it_in_order() raises:
    var place = _scratch("order")
    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]) raises:
        assert_false(Bool(err))
        seen.append(_under(place, path))

    walk_dir[visit](place)

    assert_equal(
        seen,
        [
            String("."),
            "a.txt",
            "sub",
            "sub/b.txt",
            "sub/deeper",
            "sub/deeper/c.txt",
            "z.txt",
        ],
    )

    remove_all(place)


def test_walk_visits_the_same_names_with_an_info() raises:
    var place = _scratch("info")
    var seen = List[String]()
    var files = 0

    @parameter
    def visit(path: String, info: FileInfo, err: Optional[ErrorValue]) raises:
        assert_false(Bool(err))
        seen.append(_under(place, path))
        if not info.is_dir():
            files += 1
            assert_equal(info.size(), 1)

    walk[visit](place)

    assert_equal(len(seen), 7)
    assert_equal(files, 4)
    assert_equal(seen[0], ".")
    assert_equal(seen[6], "z.txt")

    remove_all(place)


def test_walk_dir_on_a_file_visits_only_that_file() raises:
    var place = _scratch("onefile")
    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]):
        seen.append(_under(place, path))

    walk_dir[visit](join([place, "a.txt"]))

    assert_equal(seen, [String("a.txt")])

    remove_all(place)


def test_walk_dir_skip_dir_on_a_directory_leaves_its_contents_alone() raises:
    var place = _scratch("skipdir")
    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]) raises:
        seen.append(_under(place, path))
        if entry.name() == "sub":
            raise skip_dir()

    walk_dir[visit](place)

    # `sub` itself is visited and reported, and nothing below it is.
    assert_equal(seen, [String("."), "a.txt", "sub", "z.txt"])

    remove_all(place)


def test_walk_dir_skip_dir_on_a_file_skips_the_rest_of_its_directory() raises:
    # The rule that surprises people. `b.txt` says skip and what gets skipped
    # is everything left in `sub`, which is `deeper` and its contents.
    var place = _scratch("skipfile")
    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]) raises:
        seen.append(_under(place, path))
        if entry.name() == "b.txt":
            raise skip_dir()

    walk_dir[visit](place)

    assert_equal(seen, [String("."), "a.txt", "sub", "sub/b.txt", "z.txt"])

    remove_all(place)


def test_walk_dir_skip_all_stops_the_whole_walk() raises:
    var place = _scratch("skipall")
    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]) raises:
        seen.append(_under(place, path))
        if entry.name() == "b.txt":
            raise skip_all()

    walk_dir[visit](place)

    assert_equal(seen, [String("."), "a.txt", "sub", "sub/b.txt"])

    remove_all(place)


def test_walk_skip_all_stops_the_whole_walk() raises:
    var place = _scratch("skipallinfo")
    var seen = List[String]()

    @parameter
    def visit(path: String, info: FileInfo, err: Optional[ErrorValue]) raises:
        seen.append(_under(place, path))
        if info.name() == "b.txt":
            raise skip_all()

    walk[visit](place)

    assert_equal(seen, [String("."), "a.txt", "sub", "sub/b.txt"])

    remove_all(place)


def test_walk_dir_lets_anything_else_the_callback_raises_out() raises:
    var place = _scratch("raise")
    var seen = 0

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]) raises:
        seen += 1
        if entry.name() == "a.txt":
            raise Error("the callback said no")

    try:
        walk_dir[visit](place)
        raise Error("the callback's failure should have come out")
    except e:
        assert_true("the callback said no" in String(e))

    assert_equal(seen, 2)

    remove_all(place)


def test_walk_dir_on_a_missing_root_hands_the_failure_to_the_callback() raises:
    var place = _scratch("missing")
    var seen = List[String]()
    var reported = 0

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]) raises:
        seen.append(path)
        if err:
            reported += 1
            assert_true(err.value().matches(ErrNotExist))
            # Nothing was learned about the name, so the entry carries the one
            # thing that is true about it. Go passes nil here.
            assert_equal(entry.name(), "not-here")
            assert_false(entry.is_dir())

    walk_dir[visit](join([place, "not-here"]))

    assert_equal(len(seen), 1)
    assert_equal(reported, 1)

    remove_all(place)


def test_walk_on_a_missing_root_hands_the_failure_to_the_callback() raises:
    var place = _scratch("missinginfo")
    var reported = 0

    @parameter
    def visit(path: String, info: FileInfo, err: Optional[ErrorValue]) raises:
        if err:
            reported += 1
            assert_true(err.value().matches(ErrNotExist))
            assert_equal(info.name(), "not-here")
            assert_equal(info.size(), 0)

    walk[visit](join([place, "not-here"]))

    assert_equal(reported, 1)

    remove_all(place)


def test_walk_dir_reports_a_directory_it_cannot_read_twice() raises:
    # Once with the entry and no failure, once with the failure. A callback
    # that swallows the second one lets the walk carry on past it.
    var place = _scratch("shut")
    chmod(join([place, "sub"]), FileMode(0o000))

    var seen = List[String]()
    var failures = 0

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]):
        seen.append(_under(place, path))
        if err:
            failures += 1

    walk_dir[visit](place)

    chmod(join([place, "sub"]), FileMode(0o700))
    remove_all(place)

    # Root runs the suite as root on some machines and reads it anyway, so the
    # assertion is that the walk finished and reached `z.txt` either way.
    assert_true("z.txt" in seen)
    assert_true("sub" in seen)
    if failures > 0:
        assert_equal(failures, 1)


def test_walk_dir_reports_a_symbolic_link_without_following_it() raises:
    var place = _scratch("link")
    symlink(join([place, "sub"]), join([place, "alias"]))

    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]):
        seen.append(_under(place, path))

    walk_dir[visit](place)

    assert_true("alias" in seen)
    assert_false("alias/b.txt" in seen)

    remove_all(place)


def test_walk_dir_joins_the_root_the_way_join_does() raises:
    # Go says this out loud: a walk rooted at `x/../dir` reports `dir/a` and
    # not `x/../dir/a`, because every path is built with `join`, which cleans.
    var place = _scratch("joined")
    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]):
        seen.append(path)

    walk_dir[visit](join([place, "sub", "..", "sub"]))

    assert_equal(seen[0], join([place, "sub"]))
    assert_equal(seen[1], join([place, "sub", "b.txt"]))

    remove_all(place)
