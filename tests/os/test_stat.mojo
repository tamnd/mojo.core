"""`stat`, `lstat` and `same_file`, against files this process wrote.

The point of asserting a size and a mode the test set itself is that a wrong
answer here does not look wrong. A `FileInfo` built out of the wrong offset in
a `struct stat` comes back with a plausible number rather than with nothing, so
the test has to know the number independently.

The failure paths are asked of real failures rather than of errors built by
hand. `is_not_exist` is only worth anything when it is true for what the kernel
actually says when a file is not there, and that is a different question from
whether it is true for an error this file constructed.

Every mode a test asserts is set with `chmod` after the file exists rather than
passed to `create`, because the umask takes bits out of a creation mode and the
umask belongs to whoever started the test run.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.io.fs import MODE_SYMLINK, FileInfo, FileMode, PathError
from core.os import is_not_exist, is_permission, lstat, same_file, stat
from core.syscall import (
    chmod,
    close,
    create,
    getpid,
    link,
    mkdir,
    rmdir,
    symlink,
    unlink,
    write,
)
from core.time import unix


def _scratch(name: String) raises -> String:
    var place = String("/tmp/mojo-core-os-", getpid(), "-", name)
    try:
        rmdir(place)
    except:
        pass
    mkdir(place, 0o700)
    chmod(place, 0o700)
    return place


def test_a_file_of_a_known_size_and_mode() raises:
    var place = _scratch("known")
    var path = String(place, "/known.txt")
    var fd = create(path, 0o644)
    # Longer than any field near st_size, so a read at a neighbouring offset
    # cannot coincidentally give the right answer.
    _ = write(fd, "0123456789abcdefghijklmnopqrstuvwxyz".as_bytes())
    close(fd)
    chmod(path, 0o640)

    var info = stat(path)
    assert_equal(info.name(), "known.txt")
    assert_equal(info.size(), 36)
    assert_equal(info.mode().perm(), FileMode(0o640))
    assert_equal(info.mode().string(), "-rw-r-----")
    assert_true(info.mode().is_regular())
    assert_false(info.is_dir())
    assert_true(Bool(info.sys()))

    unlink(path)
    rmdir(place)


def test_the_name_is_the_last_element() raises:
    """Go bases it, so a listing reads as a listing rather than as paths."""
    var place = _scratch("naming")
    var path = String(place, "/deep.txt")
    close(create(path, 0o644))

    assert_equal(stat(path).name(), "deep.txt")
    assert_equal(
        stat(place).name(), String("mojo-core-os-", getpid(), "-naming")
    )
    assert_equal(stat("/").name(), "/")

    unlink(path)
    rmdir(place)


def test_a_directory() raises:
    var place = _scratch("dir")
    var info = stat(place)
    assert_true(info.is_dir())
    assert_true(info.mode().is_dir())
    assert_false(info.mode().is_regular())
    assert_equal(info.mode().string(), "drwx------")
    rmdir(place)


def test_the_modification_time_keeps_its_nanoseconds() raises:
    """A file system that records them and a library that rounds them away
    would say two files were written at the same instant when they were not.

    The assertion is that the two ways of reading the same instant agree, since
    the value itself is whatever the clock said. A `mod_time` built out of the
    seconds alone would still pass `unix()` and would fail this.
    """
    var place = _scratch("nanos")
    var path = String(place, "/when.txt")
    close(create(path, 0o644))

    var info = stat(path)
    var seconds = info.mod_time().unix()
    var nanos = info.mod_time().nanosecond()
    assert_equal(info.mod_time().unix_nano(), seconds * 1_000_000_000 + nanos)
    assert_true(nanos >= 0 and nanos < 1_000_000_000)

    unlink(path)
    rmdir(place)


def test_lstat_sees_the_link_and_stat_sees_through_it() raises:
    var place = _scratch("link")
    var target = String(place, "/target.txt")
    var made = String(place, "/link.txt")
    var fd = create(target, 0o644)
    _ = write(fd, "twelve bytes".as_bytes())
    close(fd)
    symlink(target, made)

    assert_equal(lstat(made).mode().type(), MODE_SYMLINK)
    assert_equal(stat(made).mode().type(), FileMode(0))
    assert_equal(stat(made).size(), 12)
    assert_true(stat(made).mode().is_regular())

    # The name is the link's own either way, because it is the path that was
    # asked about and not the one the link happens to point at.
    assert_equal(lstat(made).name(), "link.txt")
    assert_equal(stat(made).name(), "link.txt")

    unlink(made)
    unlink(target)
    rmdir(place)


def test_same_file() raises:
    """Two names for one file are the same file and two files are not.

    The hard link is the case worth having: the two paths differ, the two names
    differ, and everything except the device and the inode is a coincidence, so
    an implementation comparing anything else gets this one wrong.
    """
    var place = _scratch("same")
    var one = String(place, "/one.txt")
    var two = String(place, "/two.txt")
    var other = String(place, "/other.txt")
    close(create(one, 0o644))
    link(one, two)
    close(create(other, 0o644))

    assert_true(same_file(stat(one), stat(two)))
    assert_true(same_file(stat(one), stat(one)))
    assert_false(same_file(stat(one), stat(other)))
    assert_false(same_file(stat(one), stat(place)))

    unlink(one)
    unlink(two)
    unlink(other)
    rmdir(place)


def test_same_file_is_false_without_a_host_underneath() raises:
    """There is nothing to compare, and Go answers the same way for the same
    reason: its `Sys` assertion fails and it stops looking."""
    var made = FileInfo(
        name="a", size=0, mode=FileMode(0o644), mod_time=unix(0, 0)
    )
    var place = _scratch("nosys")
    assert_false(same_file(made, stat(place)))
    assert_false(same_file(stat(place), made))
    assert_false(same_file(made, made))
    rmdir(place)


def test_a_missing_file_raises_a_path_error() raises:
    var place = _scratch("missing")
    var path = String(place, "/not-here.txt")
    var raised = False
    try:
        _ = stat(path)
    except e:
        raised = True
        assert_true(is_not_exist(e))
        assert_false(is_permission(e))

        var failed = PathError.of(e)
        assert_true(Bool(failed))
        assert_equal(failed.value().op, "stat")
        assert_equal(failed.value().path, path)
        assert_false(failed.value().timeout())

        # The message and the fields say the same thing, which is what lets a
        # caller print either one and get Go's sentence.
        assert_equal(String(e), failed.value().error())
        assert_equal(
            String(e),
            String("stat ", path, ": ", failed.value().err.message()),
        )
    assert_true(raised, "stat of a missing file did not raise")
    rmdir(place)


def test_lstat_names_itself_in_the_error() raises:
    """So a message says which of the two calls was the one that failed."""
    var place = _scratch("lmissing")
    var path = String(place, "/not-here.txt")
    var raised = False
    try:
        _ = lstat(path)
    except e:
        raised = True
        assert_true(is_not_exist(e))
        assert_equal(PathError.of(e).value().op, "lstat")
    assert_true(raised, "lstat of a missing file did not raise")
    rmdir(place)


def test_a_directory_that_cannot_be_searched() raises:
    """The other half of the mapping, and the half that needs a real kernel.

    A directory with no execute bit refuses a stat of anything inside it with
    `EACCES`, which is a different number from `ENOENT` and has to come out as
    a different sentinel. Root ignores the bits, so a run as root gets no
    failure to look at and the assertions inside the catch simply do not run.
    """
    var place = _scratch("locked")
    var inner = String(place, "/inner.txt")
    close(create(inner, 0o644))
    chmod(place, 0o600)

    try:
        _ = stat(inner)
    except e:
        assert_true(is_permission(e))
        assert_false(is_not_exist(e))
        assert_equal(PathError.of(e).value().op, "stat")
        assert_equal(PathError.of(e).value().path, inner)

    chmod(place, 0o700)
    unlink(inner)
    rmdir(place)
