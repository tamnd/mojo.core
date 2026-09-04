"""Reading a `struct stat` at the offsets the platform reported.

The bug this file is written against does not look like a bug. A structure
typed by hand from one platform's headers compiles everywhere and reads a
neighbouring field on the other two, so the test that catches it has to assert
a number it knows independently rather than assert that the accessor returns
something. Every test here writes a file of a known length with a known mode
and then asks for those two back.

The type predicates are the other half. `S_IFMT` is 0o170000 on all three
platforms and the type bits inside it are the same, but `st_mode` sits at
offset 4 on macOS, 24 on Linux x86-64 and 16 on Linux arm64, so a wrong offset
makes every one of them answer false and the file look like nothing at all.
"""

from std.testing import (
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from core.syscall import (
    Errno,
    S_IFDIR,
    S_IFMT,
    S_IFREG,
    Stat,
    Timespec,
    close,
    create,
    fstat,
    getpid,
    lstat,
    mkdir,
    rmdir,
    stat,
    symlink,
    unlink,
    write,
)

comptime Byte = UInt8


def _scratch(name: String) raises -> String:
    var place = String("/tmp/mojo-core-stat-", getpid(), "-", name)
    try:
        rmdir(place)
    except:
        pass
    mkdir(place, 0o700)
    return place


def test_a_file_of_a_known_length() raises:
    var place = _scratch("size")
    var path = String(place, "/known.txt")
    var fd = create(path, 0o644)
    # Longer than any field near st_size, so a neighbouring read cannot
    # coincidentally give the right answer.
    _ = write(fd, "0123456789abcdefghijklmnopqrstuvwxyz".as_bytes())
    close(fd)

    assert_equal(stat(path).size(), 36)
    assert_equal(lstat(path).size(), 36)

    fd = create(path, 0o644)
    assert_equal(fstat(fd).size(), 0)
    close(fd)

    unlink(path)
    rmdir(place)


def test_the_three_calls_agree_about_a_plain_file() raises:
    var place = _scratch("agree")
    var path = String(place, "/same.txt")
    var fd = create(path, 0o644)
    _ = write(fd, "same file".as_bytes())

    var by_fd = fstat(fd)
    var by_path = stat(path)
    var by_link = lstat(path)
    assert_equal(by_fd.ino(), by_path.ino())
    assert_equal(by_fd.ino(), by_link.ino())
    assert_equal(by_fd.dev(), by_path.dev())
    assert_equal(by_fd.mode(), by_path.mode())
    assert_equal(by_fd.size(), by_path.size())

    close(fd)
    unlink(path)
    rmdir(place)


def test_the_mode_is_the_type_and_the_permissions() raises:
    var place = _scratch("mode")
    var path = String(place, "/mode.txt")
    var fd = create(path, 0o640)
    close(fd)

    var got = stat(path)
    assert_equal(got.permissions(), 0o640)
    assert_equal(got.mode() & UInt32(S_IFMT), UInt32(S_IFREG))
    assert_equal(got.mode(), UInt32(S_IFREG) | 0o640)

    unlink(path)
    rmdir(place)


def test_a_directory_is_a_directory_and_nothing_else() raises:
    var place = _scratch("dir")
    var got = stat(place)
    assert_true(got.is_dir())
    assert_false(got.is_regular())
    assert_false(got.is_symlink())
    assert_false(got.is_fifo())
    assert_false(got.is_socket())
    assert_false(got.is_block_device())
    assert_false(got.is_char_device())
    assert_equal(got.mode() & UInt32(S_IFMT), UInt32(S_IFDIR))
    assert_equal(got.permissions(), 0o700)
    rmdir(place)


def test_a_file_is_a_file_and_nothing_else() raises:
    var place = _scratch("regular")
    var path = String(place, "/plain.txt")
    var fd = create(path, 0o644)
    close(fd)

    var got = stat(path)
    assert_true(got.is_regular())
    assert_false(got.is_dir())
    assert_false(got.is_symlink())
    assert_false(got.is_char_device())

    unlink(path)
    rmdir(place)


def test_a_symlink_is_only_a_symlink_to_lstat() raises:
    var place = _scratch("link")
    var target = String(place, "/target.txt")
    var made = String(place, "/link.txt")
    var fd = create(target, 0o644)
    _ = write(fd, "twelve bytes".as_bytes())
    close(fd)
    symlink(target, made)

    assert_true(lstat(made).is_symlink())
    assert_false(lstat(made).is_regular())
    assert_true(stat(made).is_regular())
    # A symlink's size is the length of the text it holds, which is how you can
    # tell the two calls apart without looking at the mode.
    assert_equal(lstat(made).size(), target.byte_length())
    assert_equal(stat(made).size(), 12)

    unlink(made)
    unlink(target)
    rmdir(place)


def test_a_character_device() raises:
    # /dev/null is a character device on both platforms and is the only thing
    # that is not a regular file or a directory that a test can count on being
    # there. Its rdev is not zero, which is the field only a device has.
    var got = stat("/dev/null")
    assert_true(got.is_char_device())
    assert_false(got.is_regular())
    assert_false(got.is_dir())
    assert_not_equal(got.rdev(), 0)


def test_the_root_directory() raises:
    var got = stat("/")
    assert_true(got.is_dir())
    assert_equal(got.uid(), 0)
    assert_true(got.nlink() > 0)


def test_the_link_count_is_the_number_of_names() raises:
    var place = _scratch("nlink")
    var path = String(place, "/one.txt")
    var fd = create(path, 0o644)
    close(fd)
    assert_equal(stat(path).nlink(), 1)
    # A directory has at least two: its own name and its own dot.
    assert_true(stat(place).nlink() >= 2)
    unlink(path)
    rmdir(place)


def test_the_owner_is_this_process() raises:
    # Whatever the test is running as, a file it just made belongs to it. What
    # is asserted is that uid and gid are read from the right place, not what
    # they are, because CI runs as root and this laptop does not.
    var place = _scratch("owner")
    var path = String(place, "/mine.txt")
    var fd = create(path, 0o644)
    close(fd)
    assert_equal(stat(path).uid(), stat(place).uid())
    assert_equal(stat(path).gid(), stat(place).gid())
    unlink(path)
    rmdir(place)


def test_the_block_fields_are_sane() raises:
    var place = _scratch("blocks")
    var path = String(place, "/blocks.txt")
    var fd = create(path, 0o644)
    var line = "0123456789abcdef".as_bytes()
    for _ in range(256):
        _ = write(fd, line)
    close(fd)

    var got = stat(path)
    assert_equal(got.size(), 4096)
    assert_true(got.blksize() > 0)
    # Blocks are 512 bytes regardless of what blksize says, on both platforms,
    # so four kilobytes is eight of them at least.
    assert_true(got.blocks() >= 8)

    unlink(path)
    rmdir(place)


def test_the_timestamps_are_this_century() raises:
    # A wrong offset for a timespec gives a number from a neighbouring field,
    # which is either enormous or zero. 1600000000 is September 2020 and
    # 4000000000 is 2096, so anything between them is a plausible file time and
    # nothing read from the wrong place lands there by accident.
    var place = _scratch("times")
    var path = String(place, "/times.txt")
    var fd = create(path, 0o644)
    _ = write(fd, "now".as_bytes())
    close(fd)

    var got = stat(path)
    for when in [got.atime(), got.mtime(), got.ctime()]:
        assert_true(when.sec > 1600000000)
        assert_true(when.sec < 4000000000)
        assert_true(when.nsec >= 0)
        assert_true(when.nsec < 1000000000)

    unlink(path)
    rmdir(place)


def test_a_timespec_prints_and_compares() raises:
    assert_equal(Timespec(3, 4), Timespec(3, 4))
    assert_not_equal(Timespec(3, 4), Timespec(3, 5))
    assert_equal(String(Timespec(3, 4)), "3.4")


def test_an_untouched_stat_reads_as_zeros() raises:
    # Zeroed rather than left alone, so a buffer that was never filled reads as
    # an obviously empty answer rather than as a believable one off the stack.
    var empty = Stat()
    assert_equal(empty.size(), 0)
    assert_equal(empty.mode(), 0)
    assert_equal(empty.ino(), 0)
    assert_false(empty.is_regular())
    assert_false(empty.is_dir())
    assert_equal(empty.mtime(), Timespec(0, 0))
