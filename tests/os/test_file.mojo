"""`File`, against real files this process opens, writes and reads back.

Everything here goes through the kernel. A file that reports the right size
after a write it did not perform is the kind of failure a mocked file system
hides, and the calls being tested are thin enough that mocking them would leave
nothing under test.

The scratch directory is named after the process, so two runs of this suite at
once do not fight over one path, and every test that asserts a mode sets it
after the file exists, because the umask takes bits out of a creation mode and
the umask belongs to whoever started the run.

Errors are read before the next one is raised. The record lives in a slot that
the next raise on this thread overwrites, so a test that holds two raised
errors and then asks about both is testing the second one twice.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.errors import matches
from core.errors.codes import EOF, ErrClosed, ErrInvalid
from core.io import (
    Byte,
    Reader,
    SEEK_CURRENT,
    SEEK_END,
    SEEK_START,
    read_all,
    read_full,
)
from core.io.fs import FileMode, PathError
from core.os import (
    DEV_NULL,
    O_APPEND,
    O_CREATE,
    O_EXCL,
    O_RDONLY,
    O_RDWR,
    O_WRONLY,
    PATH_LIST_SEPARATOR,
    PATH_SEPARATOR,
    create,
    is_exist,
    is_not_exist,
    is_path_separator,
    is_permission,
    new_file,
    open,
    open_file,
    stderr,
    stdin,
    stdout,
)
from core.os import stat as stat_path
from core.syscall import chmod, fstat, getpid, mkdir, rmdir, unlink
from core.syscall import create as sys_create


def _scratch(name: String) raises -> String:
    var place = String("/tmp/mojo-core-file-", getpid(), "-", name)
    try:
        rmdir(place)
    except:
        pass
    mkdir(place, 0o700)
    chmod(place, 0o700)
    return place


def _bytes(n: Int) -> List[Byte]:
    """A buffer of `n` bytes to read into."""
    var out = List[Byte]()
    for _ in range(n):
        out.append(0)
    return out^


def test_a_file_written_and_read_back() raises:
    var path = String(_scratch("roundtrip"), "/notes.txt")

    var out = create(path)
    assert_equal(out.write_string("hello, file\n"), 12)
    out.close()

    var back = open(path)
    var text = read_all(back)
    back.close()

    assert_equal(String(from_utf8_lossy=Span(text)), "hello, file\n")


def test_the_name_is_what_was_passed() raises:
    var path = String(_scratch("name"), "/named.txt")
    var f = create(path)
    assert_equal(f.name(), path)
    assert_true(f.fd() >= 0)
    f.close()


def test_reading_past_the_end_raises_eof() raises:
    var path = String(_scratch("eof"), "/short.txt")
    var out = create(path)
    _ = out.write_string("ab")
    out.close()

    var f = open(path)
    var room = _bytes(8)
    assert_equal(f.read(Span(room)), 2)
    with assert_raises():
        _ = f.read(Span(room))

    # And the raise says which end it was, rather than being a bare failure.
    var seen = False
    try:
        _ = f.read(Span(room))
    except e:
        seen = matches(e, EOF)
    f.close()
    assert_true(seen)


def test_an_empty_span_reads_nothing_and_does_not_raise() raises:
    var path = String(_scratch("emptyspan"), "/empty.txt")
    var made = create(path)
    made.close()

    var f = open(path)
    var nothing = List[Byte]()
    # At the end of a file of no bytes, which is where a reader that used this
    # to test for the end would be wrong.
    assert_equal(f.read(Span(nothing)), 0)
    f.close()


def test_exclusive_create_refuses_the_second_time() raises:
    var path = String(_scratch("excl"), "/once.txt")

    var first = open_file(path, O_WRONLY | O_CREATE | O_EXCL, FileMode(0o600))
    first.close()

    var refused = False
    var says_exist = False
    try:
        _ = open_file(path, O_WRONLY | O_CREATE | O_EXCL, FileMode(0o600))
    except e:
        refused = True
        says_exist = is_exist(e)
    assert_true(refused)
    assert_true(says_exist)


def test_append_writes_at_the_end() raises:
    var path = String(_scratch("append"), "/log.txt")

    var first = create(path)
    _ = first.write_string("one\n")
    first.close()

    var more = open_file(path, O_WRONLY | O_APPEND, FileMode(0))
    # Seeking to the start changes nothing: an appending descriptor writes at
    # the end whatever the offset says, which is the whole point of the flag
    # and the reason `write_at` refuses to run on one.
    _ = more.seek(0, SEEK_START)
    _ = more.write_string("two\n")
    more.close()

    var f = open(path)
    var text = read_all(f)
    f.close()
    assert_equal(String(from_utf8_lossy=Span(text)), "one\ntwo\n")


def test_write_at_is_refused_on_an_appending_file() raises:
    var path = String(_scratch("appendat"), "/log.txt")
    var made = create(path)
    made.close()

    var f = open_file(path, O_WRONLY | O_APPEND, FileMode(0))
    var refused = False
    var says_invalid = False
    try:
        _ = f.write_at("x".as_bytes(), 0)
    except e:
        refused = True
        says_invalid = matches(e, ErrInvalid)
    f.close()
    assert_true(refused)
    assert_true(says_invalid)


def test_seek_from_all_three_places() raises:
    var path = String(_scratch("seek"), "/twelve.txt")
    var out = create(path)
    _ = out.write_string("0123456789ab")
    out.close()

    var f = open(path)
    assert_equal(f.seek(4, SEEK_START), 4)
    var room = _bytes(2)
    assert_equal(f.read(Span(room)), 2)
    assert_equal(String(from_utf8_lossy=Span(room)), "45")

    assert_equal(f.seek(2, SEEK_CURRENT), 8)
    assert_equal(f.read(Span(room)), 2)
    assert_equal(String(from_utf8_lossy=Span(room)), "89")

    assert_equal(f.seek(-2, SEEK_END), 10)
    assert_equal(f.read(Span(room)), 2)
    assert_equal(String(from_utf8_lossy=Span(room)), "ab")
    f.close()


def test_read_at_and_write_at_leave_the_offset_alone() raises:
    var path = String(_scratch("at"), "/twelve.txt")
    var out = create(path)
    _ = out.write_string("0123456789ab")
    out.close()

    var f = open_file(path, O_RDWR, FileMode(0))
    assert_equal(f.seek(3, SEEK_START), 3)

    var room = _bytes(4)
    assert_equal(f.read_at(Span(room), 8), 4)
    assert_equal(String(from_utf8_lossy=Span(room)), "89ab")

    assert_equal(f.write_at("XY".as_bytes(), 0), 2)

    # Neither call moved the cursor, so a plain read carries on from three.
    var next = _bytes(2)
    assert_equal(f.read(Span(next)), 2)
    assert_equal(String(from_utf8_lossy=Span(next)), "34")
    f.close()

    var back = open(path)
    var text = read_all(back)
    back.close()
    assert_equal(String(from_utf8_lossy=Span(text)), "XY23456789ab")


def test_read_at_fills_the_span_or_says_it_reached_the_end() raises:
    var path = String(_scratch("atend"), "/four.txt")
    var out = create(path)
    _ = out.write_string("abcd")
    out.close()

    var f = open(path)
    var room = _bytes(8)
    var short = False
    var says_eof = False
    try:
        _ = f.read_at(Span(room), 0)
    except e:
        short = True
        says_eof = matches(e, EOF)
    f.close()
    assert_true(short)
    assert_true(says_eof)


def test_read_at_refuses_a_negative_offset() raises:
    var path = String(_scratch("negative"), "/four.txt")
    var made = create(path)
    made.close()

    var f = open(path)
    var room = _bytes(4)
    var refused = False
    var says_invalid = False
    try:
        _ = f.read_at(Span(room), -1)
    except e:
        refused = True
        says_invalid = matches(e, ErrInvalid)
    f.close()
    assert_true(refused)
    assert_true(says_invalid)


def test_truncate_and_stat_on_the_open_file() raises:
    var path = String(_scratch("truncate"), "/grow.txt")
    var f = open_file(path, O_RDWR | O_CREATE, FileMode(0o600))
    _ = f.write_string("0123456789")
    assert_equal(f.stat().size(), 10)

    f.truncate(4)
    assert_equal(f.stat().size(), 4)

    # Growing leaves a hole, which reads back as zeros rather than as nothing.
    f.truncate(6)
    assert_equal(f.stat().size(), 6)
    f.sync()

    var room = _bytes(6)
    assert_equal(f.read_at(Span(room), 0), 6)
    assert_equal(room[4], 0)
    assert_equal(room[5], 0)
    f.close()


def test_stat_answers_for_a_file_with_no_name_left() raises:
    var path = String(_scratch("unlinked"), "/gone.txt")
    var f = create(path)
    _ = f.write_string("still here")
    unlink(path)

    # The name is gone and the file is not. This is the case `fstat` on the
    # descriptor answers and a second `stat` on the name cannot.
    assert_equal(f.stat().size(), 10)
    var missing = False
    try:
        _ = stat_path(path)
    except e:
        missing = is_not_exist(e)
    f.close()
    assert_true(missing)


def test_chmod_on_the_open_file() raises:
    var path = String(_scratch("chmod"), "/mode.txt")
    var f = create(path)
    f.chmod(FileMode(0o640))
    assert_equal(String(f.stat().mode()), "-rw-r-----")
    f.close()


def test_a_closed_file_raises_and_says_so() raises:
    var path = String(_scratch("closed"), "/done.txt")
    var f = create(path)
    f.close()

    var room = _bytes(4)
    var read_refused = False
    try:
        _ = f.read(Span(room))
    except e:
        read_refused = matches(e, ErrClosed)
    assert_true(read_refused)

    var write_refused = False
    try:
        _ = f.write_string("no")
    except e:
        write_refused = matches(e, ErrClosed)
    assert_true(write_refused)

    var second_close_refused = False
    try:
        f.close()
    except e:
        second_close_refused = matches(e, ErrClosed)
    assert_true(second_close_refused)


def test_a_refused_call_has_no_errno_because_nothing_was_called() raises:
    var path = String(_scratch("noerrno"), "/done.txt")
    var f = create(path)
    f.close()

    # `PathError` holds the number the platform left behind and there is no
    # number, because the descriptor was already gone and no call was made.
    # The operation and the path are still on the record, which is what a
    # caller actually reads.
    var held = Optional[PathError]()
    var op = String()
    try:
        f.close()
    except e:
        held = PathError.of(e)
        op = String(e)
    assert_false(Bool(held))
    assert_equal(op, String("close ", path, ": file already closed"))


def test_a_path_with_a_zero_byte_is_refused() raises:
    var path = String(_scratch("nul"), "/a\0b.txt")

    var refused = False
    var says_invalid = False
    try:
        _ = create(path)
    except e:
        refused = True
        says_invalid = matches(e, ErrInvalid)
    assert_true(refused)
    assert_true(says_invalid)

    # And nothing was created under the name the kernel would have seen, which
    # is what passing the path down would have produced.
    var truncated = String(_scratch("nul"), "/a")
    var missing = False
    try:
        _ = stat_path(truncated)
    except e:
        missing = is_not_exist(e)
    assert_true(missing)


def test_a_missing_file_says_which_one() raises:
    var path = String(_scratch("missing"), "/nowhere.txt")

    var failed = Optional[PathError]()
    try:
        _ = open(path)
    except e:
        failed = PathError.of(e)
    assert_true(Bool(failed))
    var report = failed.value().copy()
    assert_equal(report.op, "open")
    assert_equal(report.path, path)
    assert_equal(
        report.error(), String("open ", path, ": No such file or directory")
    )


def test_a_file_that_cannot_be_opened() raises:
    var place = _scratch("denied")
    var path = String(place, "/locked.txt")
    var made = create(path)
    made.close()
    chmod(path, 0o000)

    try:
        _ = open(path)
    except e:
        # Only asserted inside the catch, so a run as root, where the mode is
        # advisory, skips it rather than failing.
        assert_true(is_permission(e))
    chmod(path, 0o600)


def test_a_file_gives_its_descriptor_back_when_it_dies() raises:
    var path = String(_scratch("dropped"), "/dropped.txt")

    var f = create(path)
    # `f` is not named below this line, so this is its last use and the
    # destructor runs here rather than at the end of the function. The probe
    # `last_use_destroys` pins that behaviour.
    var number = f.fd()

    var closed = False
    try:
        _ = fstat(number)
    except:
        closed = True
    assert_true(closed)


def test_the_standard_streams_keep_their_descriptors() raises:
    assert_equal(stdin().fd(), 0)
    assert_equal(stdout().fd(), 1)
    assert_equal(stderr().fd(), 2)

    # Three temporaries have just been created and destroyed. If any of them
    # had owned its descriptor, this process would now have no output.
    _ = fstat(1)
    _ = fstat(2)


def test_new_file_takes_a_descriptor_this_package_did_not_open() raises:
    var path = String(_scratch("adopted"), "/adopted.txt")
    var number = sys_create(path, 0o600)

    # The descriptor came from `core.syscall`, which is the case `new_file` is
    # for: a number from a library, from a lower layer, or inherited from a
    # parent process. The file owns it from here and closing it is this test's
    # job only through the file.
    var f = new_file(number, path)
    assert_equal(f.fd(), number)
    assert_equal(f.write_string("adopted"), 7)
    f.close()

    var back = open(path)
    var text = read_all(back)
    back.close()
    assert_equal(String(from_utf8_lossy=Span(text)), "adopted")


def test_new_file_refuses_a_descriptor_that_is_not_open() raises:
    # Go returns nil here and a caller who does not check it gets a nil pointer
    # dereference two lines later. There is no nil to return, so this raises,
    # which is the same information arriving somewhere it cannot be ignored.
    var refused = False
    try:
        _ = new_file(-1, String("nothing"))
    except:
        refused = True
    assert_true(refused)


def test_the_null_device_takes_everything() raises:
    var f = open_file(String(DEV_NULL), O_WRONLY, FileMode(0))
    assert_equal(f.write_string("into the void"), 13)
    f.close()

    var empty = open_file(String(DEV_NULL), O_RDONLY, FileMode(0))
    var text = read_all(empty)
    empty.close()
    assert_equal(len(text), 0)


def test_the_path_characters() raises:
    assert_equal(PATH_SEPARATOR, Int32(ord("/")))
    assert_equal(PATH_LIST_SEPARATOR, Int32(ord(":")))
    assert_true(is_path_separator(Byte(ord("/"))))
    assert_false(is_path_separator(Byte(ord("\\"))))


def _first_line[R: Reader](mut src: R) raises -> String:
    """A function that knows nothing about files, only about `core.io.Reader`.
    """
    var room = _bytes(5)
    _ = read_full(src, Span(room))
    return String(from_utf8_lossy=Span(room))


def test_a_file_is_a_reader_to_anything_that_wants_one() raises:
    var path = String(_scratch("trait"), "/reader.txt")
    var out = create(path)
    _ = out.write_string("hello, generic reader")
    out.close()

    var f = open(path)
    var head = _first_line(f)
    f.close()
    assert_equal(head, "hello")
