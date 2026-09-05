"""A whole file in one call, in each direction.

The two calls most programs reach for, and the tests are about the edges rather
than the middle: an empty file, a file bigger than one read, a file whose size
the host reports as zero, and what happens to the permissions of a file that
was already there.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import matches
from core.errors.codes import ErrNotExist
from core.io.fs import FileMode, PathError
from core.os import (
    chmod,
    mkdir,
    read_file,
    remove_all,
    stat,
    symlink,
    write_file,
)
from core.syscall import getpid


def _scratch(name: String) raises -> String:
    var place = String("/tmp/mojo-core-osread-", getpid(), "-", name)
    remove_all(place)
    mkdir(place, FileMode(0o700))
    return place


def _text(data: List[Byte]) -> String:
    return String(from_utf8_lossy=Span(data))


def test_a_file_written_and_read_back() raises:
    var place = _scratch("roundtrip")
    var path = String(place, "/note.txt")
    write_file(path, "hello, world".as_bytes(), FileMode(0o644))
    assert_equal(_text(read_file(path)), "hello, world")
    assert_equal(stat(path).mode().perm(), FileMode(0o644))
    remove_all(place)


def test_an_empty_file_is_not_the_end_of_anything() raises:
    # The difference from `File.read`, which raises at the end. Reaching the
    # end is the successful outcome here, so nothing is raised and an empty
    # list comes back.
    var place = _scratch("empty")
    var path = String(place, "/empty.txt")
    write_file(path, "".as_bytes(), FileMode(0o644))
    assert_equal(len(read_file(path)), 0)
    remove_all(place)


def test_a_file_bigger_than_one_read() raises:
    # Big enough that the kernel is entitled to hand back less than was asked
    # for, which is the case a single read would get wrong.
    var place = _scratch("big")
    var path = String(place, "/big.txt")
    var text = String()
    for i in range(4000):
        text += String(i % 10)
    write_file(path, text.as_bytes(), FileMode(0o644))

    var back = read_file(path)
    assert_equal(len(back), 4000)
    assert_equal(_text(back), text)
    remove_all(place)


def test_write_file_truncates_what_was_there() raises:
    var place = _scratch("truncating")
    var path = String(place, "/note.txt")
    write_file(path, "a long first line".as_bytes(), FileMode(0o644))
    write_file(path, "short".as_bytes(), FileMode(0o644))
    assert_equal(_text(read_file(path)), "short")
    assert_equal(stat(path).size(), 5)
    remove_all(place)


def test_write_file_leaves_the_mode_of_a_file_that_was_there() raises:
    # `perm` is for a file this creates and for no other, which is Go's rule
    # and the part worth knowing: this is not a way to fix a mode.
    var place = _scratch("keptmode")
    var path = String(place, "/note.txt")
    write_file(path, "first".as_bytes(), FileMode(0o644))
    chmod(path, FileMode(0o600))
    write_file(path, "second".as_bytes(), FileMode(0o666))
    assert_equal(stat(path).mode().perm(), FileMode(0o600))
    remove_all(place)


def test_read_file_of_a_name_that_is_not_there() raises:
    var place = _scratch("missing")
    try:
        _ = read_file(String(place, "/nowhere"))
        raise Error("reading a file that is not there should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))
        assert_equal(PathError.of(e).value().op, "open")
    remove_all(place)


def test_write_file_into_a_directory_that_is_not_there() raises:
    var place = _scratch("nodir")
    try:
        write_file(
            String(place, "/nowhere/note.txt"),
            "x".as_bytes(),
            FileMode(0o644),
        )
        raise Error("writing into a directory that is gone should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))
        assert_equal(PathError.of(e).value().op, "open")
    remove_all(place)


def test_read_file_of_a_directory() raises:
    var place = _scratch("isdir")
    try:
        _ = read_file(place)
        raise Error("reading a directory as a file should have failed")
    except e:
        assert_true(PathError.of(e))
    remove_all(place)


def test_read_file_follows_a_link() raises:
    var place = _scratch("link")
    var target = String(place, "/target.txt")
    write_file(target, "pointed at".as_bytes(), FileMode(0o644))
    symlink("target.txt", String(place, "/pointer"))
    assert_equal(_text(read_file(String(place, "/pointer"))), "pointed at")
    remove_all(place)


def test_a_file_whose_size_is_not_the_answer() raises:
    # Linux reports zero for everything under `/proc` and hands over contents
    # anyway, which is why the size is a hint for the buffer and not the
    # answer. macOS has no `/proc`, so there the assertion is the one that can
    # be made everywhere: a file the size call knows nothing about still reads.
    var path = String("/proc/self/status")
    var found = False
    try:
        _ = stat(path)
        found = True
    except:
        pass
    if not found:
        return
    assert_true(len(read_file(path)) > 0)
