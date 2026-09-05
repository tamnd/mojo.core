"""Go's `TestValidPath`, against Go's own table.

The table comes from `tests/generated/fs.mojo`, which `tools/testgen` copies
out of the Go tree, so a row here is a row there.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.io import Byte
from core.io.fs import valid_path

from tests.generated.fs import is_valid_path_tests_rows


def test_valid_path() raises:
    """Go's `TestValidPath`."""
    for row in is_valid_path_tests_rows():
        assert_equal(
            valid_path(row.name), row.ok, "valid_path(" + row.name + ")"
        )


def test_backslash_is_an_ordinary_byte() raises:
    """A backslash is a character in a name and not a separator.

    Four rows of Go's table say so and they are the ones that would go the
    other way on a host whose paths are spelled with backslashes. They pass
    here for the reason the package docstring gives: a name in this package is
    slash separated whatever the host underneath does, so `x\\y` is one element
    with a backslash in the middle of it.
    """
    assert_true(valid_path("x\\y"))
    assert_true(valid_path("\\x"))
    assert_true(valid_path("x:y"))


def test_invalid_utf8() raises:
    """A name that is not valid UTF-8 is refused.

    Not in Go's table, and Go's `ValidPath` refuses it too, through the
    `utf8.ValidString` at the top. It is here as bytes because a Mojo string
    literal holds text, so the only way to write a name that is not text is to
    build it.
    """
    var raw: List[Byte] = [Byte(ord("a")), Byte(0xFF), Byte(ord("b"))]
    assert_false(valid_path(StringSlice(unsafe_from_utf8=Span(raw))))


def test_root() raises:
    """`"."` is the tree itself and is the only dot name that passes."""
    assert_true(valid_path("."))
    assert_false(valid_path(".."))
    assert_false(valid_path("./"))
    assert_false(valid_path("a/."))
