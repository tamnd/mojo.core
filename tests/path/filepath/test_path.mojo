"""Go's `TestClean`, `TestSlash`, `TestSplit`, `TestJoin`, `TestExt`,
`TestBase`, `TestDir`, `TestIsAbs`, `TestIsLocal`, `TestLocalize`,
`TestSplitList`, `TestVolumeName` and `TestRel`, against Go's own tables.

Every table but one comes from `tests/generated/filepath.mojo`, which
`tools/testgen` copies out of the Go tree. Go keeps the rows for a host that
separates with a slash in a `nonwin` table beside the shared one, so the tests
below read both where there are both, which is what Go's own `init` does by
appending one to the other.

`localizetests` is the one hand port, and the comment on it says why.

Go's `TestWalk`, `TestGlob`, `TestAbs` and `TestEvalSymlinks` are not here.
Every one of them builds a tree on a disk first, so none of them is a table,
and they are in `test_walk.mojo`, `test_glob.mojo` and `test_disk.mojo`
written against a tree of their own.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.errors import matches
from core.errors.codes import ErrInvalidPath, ErrRelPath
from core.io import Byte
from core.path.filepath import (
    LIST_SEPARATOR,
    SEPARATOR,
    base,
    clean,
    dir,
    ext,
    from_slash,
    is_abs,
    is_local,
    is_match,
    join,
    localize,
    rel,
    split,
    split_list,
    to_slash,
    volume_name,
)

from tests.generated.filepath import (
    basetests_rows,
    cleantests_rows,
    dirtests_rows,
    exttests_rows,
    isabstests_rows,
    islocaltests_rows,
    jointests_rows,
    nonwincleantests_rows,
    nonwindirtests_rows,
    nonwinjointests_rows,
    reltests_rows,
    slashtests_rows,
    splitlisttests_rows,
    unixsplittests_rows,
)


def test_clean() raises:
    """Go's `TestClean`, both tables.

    Every path is cleaned, and then its expected result is cleaned again. The
    second half is what says `clean` is idempotent: an answer that changes when
    it is passed back in is not the shortest form of anything.
    """
    var rows = cleantests_rows()
    rows.extend(nonwincleantests_rows())
    for row in rows:
        assert_equal(clean(row.path), row.result, "clean(" + row.path + ")")
        assert_equal(clean(row.result), row.result, "clean(" + row.result + ")")


def test_slash() raises:
    """Go's `TestFromAndToSlash`.

    On a host that separates with a slash both functions are the path they were
    given, which is what every row of Go's `slashtests` says here.
    """
    for row in slashtests_rows():
        assert_equal(from_slash(row.path), row.result)
        assert_equal(to_slash(row.result), row.path)


def test_split() raises:
    """Go's `TestSplit`."""
    for row in unixsplittests_rows():
        var d, f = split(row.path)
        assert_equal(String(d), row.dir, "split(" + row.path + ") dir")
        assert_equal(String(f), row.file, "split(" + row.path + ") file")

        # The halves are the path, which is the property the separator on the
        # end of the directory exists for.
        assert_equal(String(d) + String(f), row.path)


def test_join() raises:
    """Go's `TestJoin`, both tables."""
    var rows = jointests_rows()
    rows.extend(nonwinjointests_rows())
    for row in rows:
        assert_equal(join(row.elem), row.path)


def test_ext() raises:
    """Go's `TestExt`."""
    for row in exttests_rows():
        assert_equal(String(ext(row.path)), row.ext, "ext(" + row.path + ")")


def test_base() raises:
    """Go's `TestBase`."""
    for row in basetests_rows():
        assert_equal(base(row.path), row.result, "base(" + row.path + ")")


def test_dir() raises:
    """Go's `TestDir`, both tables."""
    var rows = dirtests_rows()
    rows.extend(nonwindirtests_rows())
    for row in rows:
        assert_equal(dir(row.path), row.result, "dir(" + row.path + ")")


def test_is_abs() raises:
    """Go's `TestIsAbs`."""
    for row in isabstests_rows():
        assert_equal(is_abs(row.path), row.is_abs, "is_abs(" + row.path + ")")


def test_is_local() raises:
    """Go's `TestIsLocal`."""
    for row in islocaltests_rows():
        assert_equal(
            is_local(row.path), row.is_local, "is_local(" + row.path + ")"
        )


def test_is_local_is_not_the_opposite_of_is_abs() raises:
    """The two questions are different and a path can answer no to both.

    `a/../..` is relative, so `is_abs` is false, and it climbs out of the
    directory it is relative to, so `is_local` is false as well. Worth a test of
    its own because the names invite reading one as the negation of the other.
    """
    assert_false(is_abs("a/../.."))
    assert_false(is_local("a/../.."))


def test_localize() raises:
    """Go's `TestLocalize`, over a hand ported table.

    Go's `localizetests` is not harvested because one of its rows is the string
    `a\\xffb`, which is bytes and not text, and a Mojo string literal is text.
    So the rows are here, in Go's order, with that one built out of bytes below.
    Go marks a name it refuses with an empty want; here a raise is the refusal
    and the empty string is what says a row expects one.

    The `unixlocalizetests` rows are folded in at the end, because this is one
    of the hosts they are for.
    """
    var rows: List[Tuple[String, String]] = [
        ("", ""),
        (".", "."),
        ("..", ""),
        ("a/..", ""),
        ("/", ""),
        ("/a", ""),
        ("a/", ""),
        ("a/./b", ""),
        ("\0", ""),
        ("a", "a"),
        ("a/b/c", "a/b/c"),
        # unixlocalizetests.
        ("#a", "#a"),
        ("a\\b:c", "a\\b:c"),
    ]
    for row in rows:
        var path = row[0]
        var want = row[1]
        if want == "":
            with assert_raises():
                _ = localize(path)
        else:
            assert_equal(localize(path), want, "localize(" + path + ")")


def test_localize_invalid_utf8() raises:
    """The `a\\xffb` row of Go's `localizetests`.

    Its own test because the name has to be built as bytes: it is the row that
    says `localize` refuses a name that is not text, which it does through
    `core.io.fs.valid_path`.
    """
    var raw: List[Byte] = [Byte(ord("a")), Byte(0xFF), Byte(ord("b"))]
    with assert_raises():
        _ = localize(StringSlice(unsafe_from_utf8=Span(raw)))


def test_localize_reports_the_sentinel() raises:
    """A refused name raises with `ErrInvalidPath` on it."""
    try:
        _ = localize("../a")
        raise Error("localize('../a') did not raise")
    except e:
        assert_true(matches(e, ErrInvalidPath))


def test_localize_result_is_local() raises:
    """Every name `localize` accepts comes back as a local path.

    That is the property the function exists for. A name from an archive or a
    request either becomes a path that cannot name anything outside the
    directory it is joined onto, or it does not become a path at all.
    """
    var names: List[String] = ["a", "a/b/c", ".", "#a"]
    for name in names:
        assert_true(
            is_local(localize(name)), "is_local(localize(" + name + "))"
        )


def test_split_list() raises:
    """Go's `TestSplitList`."""
    for row in splitlisttests_rows():
        var got = split_list(row.list)
        assert_equal(len(got), len(row.result), "split_list(" + row.list + ")")
        for i in range(len(got)):
            assert_equal(got[i], row.result[i])


def test_volume_name() raises:
    """There is no volume name on this host, so it is always empty.

    Go's `TestVolumeName` is a Windows only test for that reason. The rows here
    are the shapes that carry one there, checked to be empty here, because an
    answer that was not empty would take a prefix off the front of every other
    function's idea of the path.
    """
    var paths: List[String] = ["", "/", "/a/b", "c:/a", "a/b"]
    for path in paths:
        assert_equal(String(volume_name(path)), "", "volume_name(" + path + ")")


def test_rel() raises:
    """Go's `TestRel`.

    A want of `err` marks a pair Go expects a failure from, which is how the
    harvested table spells the empty want Go's own test reads.
    """
    for row in reltests_rows():
        if row.want == "err":
            with assert_raises():
                _ = rel(row.root, row.path)
        else:
            assert_equal(
                rel(row.root, row.path),
                row.want,
                "rel(" + row.root + ", " + row.path + ")",
            )


def test_rel_reports_the_sentinel() raises:
    """A pair with no lexical answer raises with `ErrRelPath` on it."""
    try:
        _ = rel("/a", "a")
        raise Error("rel('/a', 'a') did not raise")
    except e:
        assert_true(matches(e, ErrRelPath))


def test_rel_round_trips() raises:
    """`join(base, rel(base, targ))` names what `targ` named.

    The property `rel` exists for, checked over every row of Go's table that
    has an answer. Both sides are cleaned, because `rel` is defined in terms of
    what the two paths mean rather than how they were spelled.
    """
    for row in reltests_rows():
        if row.want == "err":
            continue
        var back = join([row.root, rel(row.root, row.path)])
        assert_equal(
            back,
            clean(row.path),
            "join(" + row.root + ", rel(...)) for " + row.path,
        )


def test_is_match() raises:
    """Go's `TestMatch`, in the small.

    The pattern language and its whole table belong to `core.path.is_match`,
    which is where they are tested. What is checked here is that the name is
    exported from this package and answers the same way, since on this host it
    is the same function.
    """
    assert_true(is_match("*.mojo", "main.mojo"))
    assert_false(is_match("*.mojo", "main.go"))
    assert_false(is_match("*", "a/b"))
    with assert_raises():
        _ = is_match("[", "a")


def test_separators() raises:
    """The two constants, which are what this host spells them."""
    assert_equal(SEPARATOR, Int32(ord("/")))
    assert_equal(LIST_SEPARATOR, Int32(ord(":")))
