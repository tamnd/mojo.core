"""The calls, against a real file system.

There is nothing to fake at this layer. A mock of `open` would be a test of the
mock, and the whole reason this package exists is that the platform underneath
it disagrees with itself between macOS and Linux, which is exactly what a mock
hides. So every test here makes a real directory under the system temporary
directory, does its work in it and takes it away again.

The name of that directory carries the process id, so two suites running at
once do not land on each other, and every test removes what it made whether it
passed or not. A test that leaves a file behind makes the next run of the same
test pass or fail for a reason that has nothing to do with the code.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import field
from core.syscall import (
    EEXIST,
    ENOENT,
    ENOTDIR,
    ENOTEMPTY,
    Errno,
    O_CREAT,
    O_RDONLY,
    O_RDWR,
    O_WRONLY,
    SEEK_CUR,
    SEEK_END,
    SEEK_SET,
    chdir,
    chmod,
    close,
    create,
    dup,
    fchmod,
    fstat,
    fsync,
    ftruncate,
    getcwd,
    getpid,
    link,
    lseek,
    lstat,
    mkdir,
    open,
    read,
    readlink,
    rename,
    rmdir,
    stat,
    symlink,
    unlink,
    write,
)

comptime Byte = UInt8


def _scratch(name: String) raises -> String:
    """A directory of our own, made fresh and empty.

    The process id is in the name so that the three platforms of the test
    matrix, or two suites on one machine, do not collide. The test name is in
    it too, so a directory left behind by a crash says which test crashed.
    """
    var place = String("/tmp/mojo-core-syscall-", getpid(), "-", name)
    try:
        _remove(place)
    except:
        pass
    mkdir(place, 0o700)
    return place


def _remove(place: String) raises:
    """Take a scratch directory away, files and all.

    One level deep, because nothing here makes a nested tree. Directory
    reading is not bound yet, so the names have to be known, which they are:
    every test passes the ones it made.
    """
    rmdir(place)


def _clear(place: String, names: List[String]) raises:
    """Remove the named files, then the directory."""
    for name in names:
        try:
            unlink(String(place, "/", name))
        except:
            pass
    rmdir(place)


def _read_all(path: String) raises -> String:
    """The whole of a small file, as text."""
    var fd = open(path, O_RDONLY)
    var room = List[Byte](length=4096, fill=0)
    var n = read(fd, Span(room))
    close(fd)
    var out = String()
    for i in range(n):
        out += chr(Int(room[i]))
    return out


def test_create_write_read_back() raises:
    var place = _scratch("roundtrip")
    var path = String(place, "/hello.txt")

    var fd = create(path, 0o644)
    assert_equal(write(fd, "hello, world".as_bytes()), 12)
    fsync(fd)
    close(fd)

    assert_equal(_read_all(path), "hello, world")
    _clear(place, ["hello.txt"])


def test_open_refuses_o_creat() raises:
    # The three argument form takes the mode as a variadic argument and there
    # is no way to pass one correctly on Apple silicon, so this refuses rather
    # than creating a file with whatever was in the register. Design section 11
    # and issue #139. The refusal is the tested behaviour, not an accident.
    var place = _scratch("nocreat")
    try:
        _ = open(String(place, "/made.txt"), O_CREAT | O_WRONLY)
        raise Error("open should have refused O_CREAT")
    except e:
        assert_true("O_CREAT" in String(e))
        assert_true("create" in String(e))

    # And nothing was made.
    try:
        _ = stat(String(place, "/made.txt"))
        raise Error("the refused open should not have made a file")
    except e:
        assert_equal(field(e, "errno").value(), String(ENOENT))
    _remove(place)


def test_create_gives_the_mode_that_was_asked_for() raises:
    # This is the assertion the variadic hole was found by. Before `create`
    # replaced the three argument `open`, this file came out with mode zero on
    # this laptop and 0644 on both Linux machines.
    var place = _scratch("mode")
    var path = String(place, "/mode.txt")
    var fd = create(path, 0o640)
    close(fd)
    assert_equal(stat(path).permissions(), 0o640)
    _clear(place, ["mode.txt"])


def test_a_short_read_is_not_a_failure() raises:
    var place = _scratch("short")
    var path = String(place, "/four.txt")
    var fd = create(path, 0o644)
    _ = write(fd, "abcd".as_bytes())
    close(fd)

    fd = open(path, O_RDONLY)
    var room = List[Byte](length=64, fill=0)
    assert_equal(read(fd, Span(room)), 4)
    # And the end of the file is zero rather than an error.
    assert_equal(read(fd, Span(room)), 0)
    close(fd)
    _clear(place, ["four.txt"])


def test_lseek_can_return_minus_one_and_mean_it() raises:
    # Minus one is a legal offset and also the failure value, which is why
    # `lseek` is the one call in the package that clears errno first. Seeking
    # one before the start of the file is the case: the offset is minus one,
    # the call worked, and reading errno without clearing it would find
    # whatever the last failure anywhere in the process was.
    var place = _scratch("seek")
    var path = String(place, "/seek.txt")
    var fd = create(path, 0o644)
    _ = write(fd, "0123456789".as_bytes())

    assert_equal(lseek(fd, 0, SEEK_SET), 0)
    assert_equal(lseek(fd, 4, SEEK_SET), 4)
    assert_equal(lseek(fd, 2, SEEK_CUR), 6)
    assert_equal(lseek(fd, 0, SEEK_END), 10)
    close(fd)
    _clear(place, ["seek.txt"])


def test_seeking_before_the_start_is_a_failure() raises:
    var place = _scratch("seekbad")
    var path = String(place, "/seek.txt")
    var fd = create(path, 0o644)
    try:
        _ = lseek(fd, -1, SEEK_SET)
        raise Error("seeking before the start should have failed")
    except e:
        assert_equal(field(e, "op").value(), "lseek")
    close(fd)
    _clear(place, ["seek.txt"])


def test_ftruncate_both_ways() raises:
    var place = _scratch("truncate")
    var path = String(place, "/grow.txt")
    var fd = create(path, 0o644)
    _ = write(fd, "0123456789".as_bytes())

    ftruncate(fd, 4)
    assert_equal(fstat(fd).size(), 4)
    ftruncate(fd, 32)
    assert_equal(fstat(fd).size(), 32)
    close(fd)
    _clear(place, ["grow.txt"])


def test_dup_shares_the_file_offset() raises:
    # Two descriptors from `dup` are one open file, which is the thing that
    # makes it different from opening the path twice.
    var place = _scratch("dup")
    var path = String(place, "/dup.txt")
    var fd = create(path, 0o644)
    _ = write(fd, "0123456789".as_bytes())
    close(fd)

    fd = open(path, O_RDONLY)
    var second = dup(fd)
    assert_equal(lseek(fd, 4, SEEK_SET), 4)
    assert_equal(lseek(second, 0, SEEK_CUR), 4)
    close(second)
    close(fd)
    _clear(place, ["dup.txt"])


def test_rename_replaces_the_destination() raises:
    var place = _scratch("rename")
    var one = String(place, "/one.txt")
    var two = String(place, "/two.txt")

    var fd = create(one, 0o644)
    _ = write(fd, "first".as_bytes())
    close(fd)
    fd = create(two, 0o644)
    _ = write(fd, "second".as_bytes())
    close(fd)

    rename(one, two)
    assert_equal(_read_all(two), "first")
    try:
        _ = stat(one)
        raise Error("the old name should be gone")
    except e:
        assert_equal(field(e, "errno").value(), String(ENOENT))
    _clear(place, ["one.txt", "two.txt"])


def test_link_makes_a_second_name_for_one_file() raises:
    var place = _scratch("link")
    var one = String(place, "/one.txt")
    var two = String(place, "/two.txt")

    var fd = create(one, 0o644)
    _ = write(fd, "shared".as_bytes())
    close(fd)

    link(one, two)
    assert_equal(stat(one).ino(), stat(two).ino())
    assert_equal(stat(one).nlink(), 2)

    unlink(one)
    # The file is still there under its other name, which is the whole point.
    assert_equal(_read_all(two), "shared")
    assert_equal(stat(two).nlink(), 1)
    _clear(place, ["two.txt"])


def test_symlink_and_readlink() raises:
    var place = _scratch("symlink")
    var target = String(place, "/target.txt")
    var made = String(place, "/link.txt")

    var fd = create(target, 0o644)
    _ = write(fd, "pointed at".as_bytes())
    close(fd)

    symlink(target, made)
    assert_equal(readlink(made), target)
    # `stat` follows the link and `lstat` does not, which is the only reason
    # both are bound.
    assert_true(stat(made).is_regular())
    assert_true(lstat(made).is_symlink())
    assert_equal(_read_all(made), "pointed at")
    _clear(place, ["link.txt", "target.txt"])


def test_a_symlink_to_nowhere_still_reads_back() raises:
    # The target is never resolved and does not have to exist. `readlink`
    # answers, `lstat` answers, and `stat` is the one that fails.
    var place = _scratch("dangling")
    var made = String(place, "/dangling.txt")
    symlink("/nonexistent/nothing/here", made)

    assert_equal(readlink(made), "/nonexistent/nothing/here")
    assert_true(lstat(made).is_symlink())
    try:
        _ = stat(made)
        raise Error("stat should follow the link and find nothing")
    except e:
        assert_equal(field(e, "errno").value(), String(ENOENT))
    _clear(place, ["dangling.txt"])


def test_mkdir_and_rmdir() raises:
    var place = _scratch("dirs")
    var inner = String(place, "/inner")

    mkdir(inner, 0o755)
    assert_true(stat(inner).is_dir())
    assert_equal(stat(inner).permissions(), 0o755)

    try:
        mkdir(inner, 0o755)
        raise Error("making a directory twice should have failed")
    except e:
        assert_equal(field(e, "errno").value(), String(EEXIST))

    rmdir(inner)
    try:
        _ = stat(inner)
        raise Error("the directory should be gone")
    except e:
        assert_equal(field(e, "errno").value(), String(ENOENT))
    _remove(place)


def test_rmdir_refuses_a_directory_with_something_in_it() raises:
    var place = _scratch("notempty")
    var fd = create(String(place, "/inside.txt"), 0o644)
    close(fd)
    try:
        rmdir(place)
        raise Error("removing a directory with a file in it should have failed")
    except e:
        assert_equal(field(e, "errno").value(), String(ENOTEMPTY))
    _clear(place, ["inside.txt"])


def test_chmod_and_fchmod() raises:
    var place = _scratch("chmod")
    var path = String(place, "/perm.txt")
    var fd = create(path, 0o600)
    assert_equal(stat(path).permissions(), 0o600)

    chmod(path, 0o644)
    assert_equal(stat(path).permissions(), 0o644)

    fchmod(fd, 0o600)
    assert_equal(fstat(fd).permissions(), 0o600)
    close(fd)
    _clear(place, ["perm.txt"])


def test_getcwd_and_chdir() raises:
    # The working directory is process wide, so this puts it back before it
    # returns, including when an assertion fails on the way.
    var was = getcwd()
    assert_true(was.byte_length() > 0)
    var place = _scratch("cwd")
    try:
        chdir(place)
        # macOS puts the temporary directory under /private, and getcwd reports
        # the resolved path, so what is asserted is the last component.
        assert_true(
            getcwd().endswith(String("mojo-core-syscall-", getpid(), "-cwd"))
        )
    finally:
        chdir(was)
    assert_equal(getcwd(), was)
    _remove(place)


def test_a_path_that_is_not_a_directory() raises:
    var place = _scratch("notdir")
    var path = String(place, "/file.txt")
    var fd = create(path, 0o644)
    close(fd)
    try:
        _ = stat(String(path, "/under"))
        raise Error("walking through a file should have failed")
    except e:
        assert_equal(field(e, "errno").value(), String(ENOTDIR))
    _clear(place, ["file.txt"])


def test_close_twice_is_a_failure() raises:
    var place = _scratch("closetwice")
    var path = String(place, "/close.txt")
    var fd = create(path, 0o644)
    close(fd)
    try:
        close(fd)
        raise Error("closing twice should have failed")
    except e:
        assert_equal(field(e, "op").value(), "close")
    _clear(place, ["close.txt"])


def test_getpid_is_the_same_every_time() raises:
    assert_true(getpid() > 0)
    assert_equal(getpid(), getpid())


def test_the_error_carries_the_call_that_failed() raises:
    # Every failure names its call under `op` and its number under `errno`, so
    # a caller deciding what to do next never has to read the sentence.
    var place = _scratch("fields")
    try:
        _ = open(String(place, "/absent.txt"), O_RDWR)
        raise Error("opening a path that is not there should have failed")
    except e:
        assert_equal(field(e, "op").value(), "open")
        assert_equal(field(e, "errno").value(), String(ENOENT))
        assert_false(field(e, "nothing"))
    _remove(place)
