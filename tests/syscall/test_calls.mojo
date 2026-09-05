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
    EBADF,
    EEXIST,
    ENOENT,
    ENOTDIR,
    ENOTEMPTY,
    EPERM,
    Errno,
    FD_CLOEXEC,
    F_GETFD,
    F_GETFL,
    F_SETFD,
    AT_FDCWD,
    AT_REMOVEDIR,
    O_ACCMODE,
    O_CREAT,
    O_EXCL,
    O_RDONLY,
    O_DIRECTORY,
    O_RDWR,
    O_WRONLY,
    SEEK_CUR,
    SEEK_END,
    SEEK_SET,
    Timespec,
    UTIME_OMIT,
    chdir,
    chmod,
    chown,
    close,
    create,
    dup,
    fchdir,
    fchmod,
    fchown,
    fcntl,
    fstat,
    fsync,
    ftruncate,
    getcwd,
    getpid,
    lchown,
    link,
    lseek,
    lstat,
    mkdir,
    open,
    openat,
    pread,
    pwrite,
    read,
    readlink,
    rename,
    rmdir,
    stat,
    symlink,
    truncate,
    unlinkat,
    unlink,
    utimensat,
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
    var fd = open(path, O_RDONLY, 0)
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


def test_open_creates_with_the_mode_that_was_asked_for() raises:
    # The assertion the whole shim exists for. The mode is an anonymous
    # argument to C's `open`, and a fixed arity call leaves it in a register
    # that Apple silicon does not read, so this file came out with mode zero
    # here and 0640 on both Linux machines until `core_syscall_open3` was
    # written. Design section 11 and core/syscall/shim/README.md.
    var place = _scratch("openmode")
    var path = String(place, "/made.txt")

    var fd = open(path, O_CREAT | O_WRONLY, 0o640)
    assert_equal(write(fd, "made".as_bytes()), 4)
    close(fd)

    var found = stat(path)
    assert_equal(found.permissions(), 0o640)
    assert_equal(_read_all(path), "made")
    _clear(place, ["made.txt"])


def test_open_creating_can_also_read() raises:
    # `creat` is `O_CREAT | O_WRONLY | O_TRUNC` and cannot be anything else, so
    # a file that is created and then read back through the same descriptor is
    # the case that only the three argument form covers.
    var place = _scratch("openrdwr")
    var path = String(place, "/both.txt")

    var fd = open(path, O_CREAT | O_RDWR, 0o644)
    assert_equal(write(fd, "both".as_bytes()), 4)
    assert_equal(lseek(fd, 0, SEEK_SET), 0)
    var room = List[Byte](length=16, fill=0)
    assert_equal(read(fd, Span(room)), 4)
    close(fd)
    _clear(place, ["both.txt"])


def test_o_excl_refuses_a_file_that_is_there() raises:
    # The other flag only the three argument form can reach, and the one whose
    # entire purpose is that the check and the creation are one operation.
    var place = _scratch("excl")
    var path = String(place, "/once.txt")

    close(open(path, O_CREAT | O_WRONLY | O_EXCL, 0o644))
    try:
        _ = open(path, O_CREAT | O_WRONLY | O_EXCL, 0o644)
        raise Error("O_EXCL should have refused a file that is already there")
    except e:
        assert_equal(field(e, "errno").value(), String(EEXIST))
        assert_equal(field(e, "op").value(), "open")
    _clear(place, ["once.txt"])


def test_open_without_o_creat_ignores_the_mode() raises:
    # The mode is read only when something is created, so a nonsense one on an
    # ordinary open changes nothing. Worth pinning because the argument is now
    # required and a caller writing a zero should be able to write anything.
    var place = _scratch("modeignored")
    var path = String(place, "/kept.txt")

    close(create(path, 0o600))
    close(open(path, O_RDONLY, 0o777))
    assert_equal(stat(path).permissions(), 0o600)
    _clear(place, ["kept.txt"])


def test_fcntl_reads_and_sets_the_descriptor_flags() raises:
    var place = _scratch("fcntl")
    var path = String(place, "/flags.txt")
    var fd = create(path, 0o644)

    # A fresh descriptor is not close on exec, and setting the bit takes.
    assert_equal(fcntl(fd, F_GETFD, 0) & FD_CLOEXEC, 0)
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    assert_equal(fcntl(fd, F_GETFD, 0) & FD_CLOEXEC, FD_CLOEXEC)

    close(fd)
    _clear(place, ["flags.txt"])


def test_fcntl_reads_the_access_mode_back() raises:
    # F_GETFL gives back the flags the file was opened with, which is the one
    # way to check from the outside that `open` passed them through.
    var place = _scratch("getfl")
    var path = String(place, "/mode.txt")

    var fd = open(path, O_CREAT | O_RDWR, 0o644)
    assert_equal(fcntl(fd, F_GETFL, 0) & O_ACCMODE, O_RDWR)
    close(fd)

    fd = open(path, O_RDONLY, 0)
    assert_equal(fcntl(fd, F_GETFL, 0) & O_ACCMODE, O_RDONLY)
    close(fd)
    _clear(place, ["mode.txt"])


def test_fcntl_on_a_closed_descriptor_fails() raises:
    try:
        _ = fcntl(-1, F_GETFD, 0)
        raise Error("fcntl on a descriptor that is not open should have failed")
    except e:
        assert_equal(field(e, "op").value(), "fcntl")
        assert_equal(field(e, "errno").value(), String(EBADF))


def test_create_gives_the_mode_that_was_asked_for() raises:
    # This is the assertion the variadic hole was found by, and `creat` is the
    # call that answered it first because its prototype is fixed. It stays
    # because Go has `syscall.Creat` and because the two calls now agree, which
    # is the cheapest evidence that the shim passes the mode through unharmed.
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

    fd = open(path, O_RDONLY, 0)
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

    fd = open(path, O_RDONLY, 0)
    var second = dup(fd)
    assert_equal(lseek(fd, 4, SEEK_SET), 4)
    assert_equal(lseek(second, 0, SEEK_CUR), 4)
    close(second)
    close(fd)
    _clear(place, ["dup.txt"])


def test_pread_reads_at_an_offset_and_leaves_the_offset_alone() raises:
    # The whole point of the call: the descriptor's own offset is where the
    # last ordinary read left it, whatever pread was asked for.
    var place = _scratch("pread")
    var path = String(place, "/pread.txt")
    var fd = create(path, 0o644)
    _ = write(fd, "0123456789".as_bytes())
    close(fd)

    fd = open(path, O_RDONLY, 0)
    var room = List[Byte](length=3, fill=0)
    assert_equal(read(fd, Span(room)), 3)
    assert_equal(String(from_utf8_lossy=Span(room)), "012")

    assert_equal(pread(fd, Span(room), 6), 3)
    assert_equal(String(from_utf8_lossy=Span(room)), "678")
    assert_equal(lseek(fd, 0, SEEK_CUR), 3)
    close(fd)
    _clear(place, ["pread.txt"])


def test_pread_at_the_end_reads_nothing() raises:
    # End of file is a read of zero bytes rather than a failure, the same as
    # an ordinary read. Turning it into an error is the layer above's job.
    var place = _scratch("preadend")
    var path = String(place, "/short.txt")
    var fd = create(path, 0o644)
    _ = write(fd, "abc".as_bytes())
    close(fd)

    fd = open(path, O_RDONLY, 0)
    var room = List[Byte](length=4, fill=0)
    assert_equal(pread(fd, Span(room), 3), 0)
    assert_equal(pread(fd, Span(room), 99), 0)
    close(fd)
    _clear(place, ["short.txt"])


def test_pread_on_a_closed_descriptor_fails() raises:
    var place = _scratch("preadbad")
    var path = String(place, "/gone.txt")
    var fd = create(path, 0o644)
    close(fd)
    var room = List[Byte](length=1, fill=0)
    try:
        _ = pread(fd, Span(room), 0)
        raise Error("reading a closed descriptor should have failed")
    except e:
        assert_equal(field(e, "op").value(), "pread")
        assert_equal(field(e, "errno").value(), String(EBADF))
    _clear(place, ["gone.txt"])


def test_pwrite_writes_at_an_offset_and_leaves_the_offset_alone() raises:
    var place = _scratch("pwrite")
    var path = String(place, "/pwrite.txt")
    var fd = create(path, 0o644)
    _ = write(fd, "0123456789".as_bytes())
    close(fd)

    fd = open(path, O_RDWR, 0)
    assert_equal(lseek(fd, 2, SEEK_SET), 2)
    assert_equal(pwrite(fd, "xyz".as_bytes(), 5), 3)
    assert_equal(lseek(fd, 0, SEEK_CUR), 2)
    close(fd)

    assert_equal(_read_all(path), "01234xyz89")
    _clear(place, ["pwrite.txt"])


def test_pwrite_past_the_end_leaves_a_hole() raises:
    # Writing beyond the end grows the file, and what was skipped reads back
    # as zeroes rather than as whatever the disk had there.
    var place = _scratch("pwritehole")
    var path = String(place, "/hole.txt")
    var fd = open(path, O_RDWR | O_CREAT, 0o644)
    assert_equal(pwrite(fd, "end".as_bytes(), 5), 3)
    assert_equal(fstat(fd).size(), 8)

    var room = List[Byte](length=8, fill=1)
    assert_equal(pread(fd, Span(room), 0), 8)
    for i in range(5):
        assert_equal(Int(room[i]), 0)
    close(fd)
    _clear(place, ["hole.txt"])


def test_fchdir_moves_the_working_directory() raises:
    # Same effect as chdir, from a descriptor rather than a name, which is how
    # a caller holding an open directory moves into it without a race.
    var was = getcwd()
    var place = _scratch("fchdir")
    var fd = open(place, O_RDONLY, 0)
    try:
        fchdir(fd)
        assert_true(
            getcwd().endswith(String("mojo-core-syscall-", getpid(), "-fchdir"))
        )
    finally:
        chdir(was)
        close(fd)
    assert_equal(getcwd(), was)
    _remove(place)


def test_fchdir_refuses_a_descriptor_that_is_not_a_directory() raises:
    var was = getcwd()
    var place = _scratch("fchdirfile")
    var path = String(place, "/file.txt")
    var fd = create(path, 0o644)
    try:
        fchdir(fd)
        raise Error("moving into a file should have failed")
    except e:
        assert_equal(field(e, "op").value(), "fchdir")
        assert_equal(field(e, "errno").value(), String(ENOTDIR))
    close(fd)
    assert_equal(getcwd(), was)
    _clear(place, ["file.txt"])


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


def test_openat_resolves_inside_the_directory_it_was_given() raises:
    # The point of the call. The same name is opened twice, once relative to
    # the scratch directory and once relative to the working directory, and
    # only the first one finds anything.
    var place = _scratch("openat")
    var path = String(place, "/inside.txt")
    var fd = create(path, 0o644)
    _ = write(fd, "inside".as_bytes())
    close(fd)

    var dir = open(place, O_RDONLY | O_DIRECTORY, 0)
    var found = openat(dir, "inside.txt", O_RDONLY, 0)
    var room = List[Byte](length=16, fill=0)
    assert_equal(read(found, Span(room)), 6)
    close(found)

    try:
        _ = openat(AT_FDCWD, "inside.txt", O_RDONLY, 0)
        raise Error(
            "openat from the working directory should have found nothing"
        )
    except e:
        assert_equal(field(e, "op").value(), "openat")
        assert_equal(field(e, "errno").value(), String(ENOENT))

    close(dir)
    _clear(place, ["inside.txt"])


def test_openat_creates_with_the_mode_that_was_asked_for() raises:
    # The same assertion `open` carries, for the same reason: the mode is the
    # anonymous argument, and it is what the shim exists to get right.
    var place = _scratch("openatmode")
    var dir = open(place, O_RDONLY | O_DIRECTORY, 0)
    var made = openat(dir, "made.txt", O_CREAT | O_WRONLY, 0o640)
    close(made)
    close(dir)
    assert_equal(stat(String(place, "/made.txt")).permissions(), 0o640)
    _clear(place, ["made.txt"])


def test_unlinkat_removes_a_name_relative_to_a_directory() raises:
    # Both halves: a file with no flags, and a directory with AT_REMOVEDIR,
    # which is the flag that makes this an rmdir instead.
    var place = _scratch("unlinkat")
    close(create(String(place, "/gone.txt"), 0o644))
    mkdir(String(place, "/gonedir"), 0o700)

    var dir = open(place, O_RDONLY | O_DIRECTORY, 0)
    unlinkat(dir, "gone.txt", 0)
    unlinkat(dir, "gonedir", AT_REMOVEDIR)
    close(dir)

    try:
        _ = stat(String(place, "/gone.txt"))
        raise Error("the file should have gone")
    except e:
        assert_equal(field(e, "errno").value(), String(ENOENT))

    _remove(place)


def test_truncate_shortens_and_lengthens_a_file() raises:
    var place = _scratch("truncate")
    var path = String(place, "/sized.txt")
    var fd = create(path, 0o644)
    var text = String("twelve bytes").as_bytes()
    _ = write(fd, text)
    close(fd)
    assert_equal(stat(path).size(), 12)

    truncate(path, 4)
    assert_equal(stat(path).size(), 4)

    # Growing leaves a hole, which reads back as zeros rather than as whatever
    # was there before the file was shortened.
    truncate(path, 8)
    assert_equal(stat(path).size(), 8)
    var back = open(path, O_RDONLY, 0)
    var into = List[Byte](length=8, fill=0)
    assert_equal(read(back, into), 8)
    close(back)
    assert_equal(Int(into[3]), ord("l"))
    assert_equal(Int(into[4]), 0)
    assert_equal(Int(into[7]), 0)

    _clear(place, ["sized.txt"])


def test_truncate_of_a_path_that_is_not_there_fails() raises:
    var place = _scratch("truncmiss")
    try:
        truncate(String(place, "/nowhere"), 0)
        raise Error("truncating a file that is not there should have failed")
    except e:
        assert_equal(field(e, "op").value(), "truncate")
        assert_equal(field(e, "errno").value(), String(ENOENT))
    _remove(place)


def test_chown_to_the_owner_a_file_already_has() raises:
    # The only change an ordinary user is allowed to make, and it is worth
    # making because it is the case that proves the arguments are in the right
    # order and are the right width. A uid passed as the wrong type would be a
    # different number and this would fail with EPERM.
    var place = _scratch("chown")
    var path = String(place, "/owned.txt")
    close(create(path, 0o644))
    var before = stat(path)
    chown(path, Int(before.uid()), Int(before.gid()))
    assert_equal(stat(path).uid(), before.uid())
    assert_equal(stat(path).gid(), before.gid())

    # And -1 for both, which is the platform's way of saying change neither.
    chown(path, -1, -1)
    assert_equal(stat(path).uid(), before.uid())

    var fd = open(path, O_RDONLY, 0)
    fchown(fd, Int(before.uid()), Int(before.gid()))
    assert_equal(fstat(fd).uid(), before.uid())
    close(fd)

    _clear(place, ["owned.txt"])


def test_chown_to_somebody_else_is_refused() raises:
    # Root is allowed to do this and CI runs some jobs as root, so the test
    # asserts the refusal only when the process is not root. What it always
    # asserts is that the call either worked or failed for the one reason it
    # is allowed to fail for here.
    var place = _scratch("chownother")
    var path = String(place, "/owned.txt")
    close(create(path, 0o644))
    var mine = stat(path).uid()
    var other = 0 if mine != 0 else 65534
    try:
        chown(path, other, -1)
        assert_equal(stat(path).uid(), UInt32(other))
    except e:
        assert_equal(field(e, "op").value(), "chown")
        assert_equal(field(e, "errno").value(), String(EPERM))
    _clear(place, ["owned.txt"])


def test_lchown_names_the_link_rather_than_the_target() raises:
    # A link has an owner of its own. Asserting that is hard without root, so
    # what this asserts is that the call reaches the link at all: lchown of a
    # link to nothing succeeds, where chown of the same link fails, because
    # chown follows it and there is nothing at the other end.
    var place = _scratch("lchown")
    var link = String(place, "/pointer")
    symlink("nowhere", link)
    var mine = lstat(link)
    lchown(link, Int(mine.uid()), Int(mine.gid()))

    try:
        chown(link, Int(mine.uid()), Int(mine.gid()))
        raise Error("chown through a link to nothing should have failed")
    except e:
        assert_equal(field(e, "op").value(), "chown")
        assert_equal(field(e, "errno").value(), String(ENOENT))

    _clear(place, ["pointer"])


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
        _ = open(String(place, "/absent.txt"), O_RDWR, 0)
        raise Error("opening a path that is not there should have failed")
    except e:
        assert_equal(field(e, "op").value(), "open")
        assert_equal(field(e, "errno").value(), String(ENOENT))
        assert_false(field(e, "nothing"))
    _remove(place)


def test_utimensat_sets_both_times() raises:
    # The two times go in the order the C array is in, access first, and
    # swapping them is a mistake nothing would report, so the two numbers here
    # are far enough apart to tell which is which.
    var place = _scratch("times")
    var path = String(place, "/dated.txt")
    close(create(path, 0o600))

    utimensat(
        AT_FDCWD,
        path,
        Timespec(1_600_000_000, 0),
        Timespec(1_700_000_000, 0),
        0,
    )

    var got = stat(path)
    assert_equal(got.atime().sec, 1_600_000_000)
    assert_equal(got.mtime().sec, 1_700_000_000)
    _clear(place, ["dated.txt"])


def test_utimensat_omits_the_time_it_is_told_to() raises:
    var place = _scratch("omit")
    var path = String(place, "/half.txt")
    close(create(path, 0o600))

    utimensat(
        AT_FDCWD,
        path,
        Timespec(1_500_000_000, 0),
        Timespec(1_500_000_001, 0),
        0,
    )
    utimensat(
        AT_FDCWD, path, Timespec(0, UTIME_OMIT), Timespec(1_600_000_000, 0), 0
    )

    var got = stat(path)
    assert_equal(got.atime().sec, 1_500_000_000)
    assert_equal(got.mtime().sec, 1_600_000_000)
    _clear(place, ["half.txt"])


def test_utimensat_keeps_the_nanoseconds_the_file_system_keeps() raises:
    # Both platforms of this matrix keep nanoseconds on their temporary file
    # system, so this asserts the field arrived rather than that every file
    # system in the world would keep it.
    var place = _scratch("nsec")
    var path = String(place, "/fine.txt")
    close(create(path, 0o600))

    utimensat(
        AT_FDCWD, path, Timespec(1, 0), Timespec(1_700_000_000, 123_456_789), 0
    )

    assert_equal(stat(path).mtime(), Timespec(1_700_000_000, 123_456_789))
    _clear(place, ["fine.txt"])


def test_utimensat_on_a_path_that_is_not_there() raises:
    var place = _scratch("notimes")
    try:
        utimensat(
            AT_FDCWD,
            String(place, "/absent.txt"),
            Timespec(1, 0),
            Timespec(1, 0),
            0,
        )
        raise Error("setting the times on a missing file should have failed")
    except e:
        assert_equal(field(e, "op").value(), "utimensat")
        assert_equal(field(e, "errno").value(), String(ENOENT))
    _remove(place)
