"""Go's `TestClean`, `TestSplit`, `TestJoin`, `TestExt`, `TestBase`, `TestDir`
and `TestIsAbs`, against Go's own tables.

Every table comes from `tests/generated/path.mojo`, which `tools/testgen`
copies out of the Go tree, so a row here is a row there and a row Go adds
arrives as a diff rather than as something somebody has to notice.

Go's `TestCleanMallocs` is not ported. It asserts that cleaning an already
clean path allocates nothing, which is true of Go's lazily built buffer and is
not true here: `clean` returns an owned `String` and so allocates on every
call. `core/path/path.mojo` says why at the point where the buffer is made.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.path import base, clean, dir, ext, is_abs, join, split

from tests.generated.path import (
    basetests_rows,
    cleantests_rows,
    dirtests_rows,
    exttests_rows,
    is_abs_tests_rows,
    jointests_rows,
    splittests_rows,
)


def test_clean() raises:
    """Go's `TestClean`.

    Every path is cleaned, and then its expected result is cleaned again. The
    second half is what says `clean` is idempotent: an answer that changes when
    it is passed back in is not the shortest form of anything.
    """
    for row in cleantests_rows():
        assert_equal(clean(row.path), row.result, "clean(" + row.path + ")")
        assert_equal(clean(row.result), row.result, "clean(" + row.result + ")")


def test_split() raises:
    """Go's `TestSplit`."""
    for row in splittests_rows():
        var d, f = split(row.path)
        assert_equal(String(d), row.dir, "split(" + row.path + ") dir")
        assert_equal(String(f), row.file, "split(" + row.path + ") file")

        # The halves are the path, which is the property the slash on the end
        # of the directory exists for.
        assert_equal(String(d) + String(f), row.path)


def test_join() raises:
    """Go's `TestJoin`."""
    for row in jointests_rows():
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
    """Go's `TestDir`."""
    for row in dirtests_rows():
        assert_equal(dir(row.path), row.result, "dir(" + row.path + ")")


def test_is_abs() raises:
    """Go's `TestIsAbs`."""
    for row in is_abs_tests_rows():
        if row.is_abs:
            assert_true(is_abs(row.path), "is_abs(" + row.path + ")")
        else:
            assert_false(is_abs(row.path), "is_abs(" + row.path + ")")


def test_ext_and_base_are_views() raises:
    """The two functions that promise not to copy.

    Not a Go test. `ext` and `split` return a slice of the argument and `base`
    does not, and the package docstring gives a reason for each; this is that
    reason written as something that fails if the return types are changed
    without the documentation being changed with them.
    """
    var path = String("a/b/c.go")
    var start = path.unsafe_ptr()

    var suffix = ext(path)
    assert_equal(String(suffix), ".go")
    assert_true(suffix.unsafe_ptr() == start.unsafe_offset(5))

    var d, f = split(path)
    assert_true(d.unsafe_ptr() == start)
    assert_true(f.unsafe_ptr() == start.unsafe_offset(4))
