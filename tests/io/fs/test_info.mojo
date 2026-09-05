"""`FileInfo` built by hand.

The interesting half of `FileInfo` is what `os.stat` puts in it and that is
tested in `tests/os/test_stat.mojo`, against files this process wrote and whose
size and mode it therefore knows. What is here is the half that does not need a
host: the constructor a file system with no host underneath it uses.

The base name rule is `core.path.base` now and is tested in
`tests/path/test_path.mojo` against Go's own table. This package used to carry
a second copy of it, because `core.path` sat above `core.io.fs` and could not
be named from here; the tier changed with the `FS` trait and the copy went.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.io.fs import MODE_DIR, FileInfo, FileMode
from core.time import unix


def test_an_info_with_no_host_under_it() raises:
    """What a zip archive or a map in a test would build.

    `sys` is empty, which is where Go's `Sys` returns nil, and every other
    method answers from the values it was handed.
    """
    var info = FileInfo(
        name="notes.txt", size=12, mode=FileMode(0o644), mod_time=unix(1700, 5)
    )
    assert_equal(info.name(), "notes.txt")
    assert_equal(info.size(), 12)
    assert_equal(info.mode(), FileMode(0o644))
    assert_equal(info.mod_time().unix(), 1700)
    assert_equal(info.mod_time().nanosecond(), 5)
    assert_false(info.is_dir())
    assert_false(Bool(info.sys()))


def test_is_dir_asks_the_mode_and_nothing_else() raises:
    var info = FileInfo(
        name="things",
        size=4096,
        mode=MODE_DIR | FileMode(0o755),
        mod_time=unix(0, 0),
    )
    assert_true(info.is_dir())
    assert_equal(info.mode().string(), "drwxr-xr-x")


def test_an_info_is_a_snapshot() raises:
    """Copying one and asking both gives the same answers twice.

    Go's contract as well: a `FileInfo` is what was true when it was made, and
    a caller holding one is not holding a view of a file that moves under them.
    """
    var info = FileInfo(
        name="a", size=1, mode=FileMode(0o600), mod_time=unix(42, 0)
    )
    var copied = info.copy()
    assert_equal(copied.name(), info.name())
    assert_equal(copied.size(), info.size())
    assert_equal(copied.mode(), info.mode())
    assert_equal(copied.mod_time().unix(), info.mod_time().unix())
