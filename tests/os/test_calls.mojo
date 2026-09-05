"""The calls that take a path, against a real file system.

Same reasoning as the rest of these suites: there is nothing worth faking at
this level, so every test makes a directory of its own under the system
temporary directory, does its work in it and takes it away again. The process
id is in the name so that two runs do not read each other's files.

What is asserted here is the part `core.os` adds over `core.syscall`, which is
the shape of the failure rather than the success. A `mkdir` that works is one
line; a `mkdir` that fails has to carry the operation, the path and a sentinel
a caller can ask about, and that is what most of these check.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import matches
from core.errors.codes import ErrExist, ErrInvalid, ErrNotExist, ErrPermission
from core.io.fs import MODE_DIR, MODE_SYMLINK, FileMode, PathError
from core.os import (
    LinkError,
    chdir,
    chmod,
    chown,
    getwd,
    lchown,
    link,
    lstat,
    mkdir,
    readlink,
    remove,
    remove_all,
    rename,
    same_file,
    stat,
    symlink,
    truncate,
    write_file,
)
from core.syscall import getpid


def _scratch(name: String) raises -> String:
    """An empty directory of this suite's own."""
    var place = String("/tmp/mojo-core-oscalls-", getpid(), "-", name)
    remove_all(place)
    mkdir(place, FileMode(0o700))
    return place


def _write(path: String, text: String) raises:
    write_file(path, text.as_bytes(), FileMode(0o644))


def test_mkdir_makes_one_level() raises:
    var place = _scratch("mkdir")
    var made = String(place, "/inner")
    mkdir(made, FileMode(0o755))
    assert_true(stat(made).is_dir())
    remove_all(place)


def test_mkdir_refuses_a_name_that_is_taken() raises:
    var place = _scratch("mkdirtwice")
    var made = String(place, "/inner")
    mkdir(made, FileMode(0o755))
    try:
        mkdir(made, FileMode(0o755))
        raise Error("a second mkdir of the same name should have failed")
    except e:
        assert_true(matches(e, ErrExist))
        assert_equal(PathError.of(e).value().op, "mkdir")
        assert_equal(PathError.of(e).value().path, made)
    remove_all(place)


def test_mkdir_needs_its_parent() raises:
    var place = _scratch("mkdirparent")
    try:
        mkdir(String(place, "/one/two"), FileMode(0o755))
        raise Error("mkdir with no parent should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))
    remove_all(place)


def test_a_name_with_a_zero_byte_in_it_is_refused() raises:
    # The refusal never reaches the kernel, so it carries no errno and
    # `PathError.of` is empty for it, which is the arrangement `File` already
    # uses for a call on a closed file.
    var place = _scratch("nulname")
    var name = String(place, "/one\0two")
    try:
        mkdir(name, FileMode(0o755))
        raise Error("a name with a zero byte in it should have been refused")
    except e:
        assert_true(matches(e, ErrInvalid))
        assert_false(PathError.of(e))
    remove_all(place)


def test_remove_takes_away_a_file_and_an_empty_directory() raises:
    var place = _scratch("remove")
    var file = String(place, "/gone.txt")
    var dir = String(place, "/gonedir")
    _write(file, "here")
    mkdir(dir, FileMode(0o700))

    remove(file)
    remove(dir)
    try:
        _ = lstat(file)
        raise Error("the file should have gone")
    except e:
        assert_true(matches(e, ErrNotExist))
    remove_all(place)


def test_remove_refuses_a_directory_with_something_in_it() raises:
    var place = _scratch("removefull")
    var dir = String(place, "/full")
    mkdir(dir, FileMode(0o700))
    _write(String(dir, "/inside.txt"), "here")
    try:
        remove(dir)
        raise Error("removing a directory with a file in it should have failed")
    except e:
        # `ENOTEMPTY` means the same thing to a caller as `EEXIST`, which is
        # the mapping `is_exist` is written around.
        assert_true(matches(e, ErrExist))
        assert_equal(PathError.of(e).value().op, "remove")
    remove_all(place)


def test_remove_of_a_name_that_is_not_there() raises:
    # The interesting half of Go's two call arrangement. `unlink` fails with
    # ENOENT and `rmdir` fails with ENOENT too, so neither is ENOTDIR and the
    # second one is reported, which still says the file is missing.
    var place = _scratch("removemiss")
    try:
        remove(String(place, "/nowhere"))
        raise Error("removing a name that is not there should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))
        assert_equal(PathError.of(e).value().op, "remove")
    remove_all(place)


def test_rename_moves_a_name() raises:
    var place = _scratch("rename")
    var from_path = String(place, "/before.txt")
    var to_path = String(place, "/after.txt")
    _write(from_path, "moved")

    rename(from_path, to_path)
    assert_equal(stat(to_path).size(), 5)
    try:
        _ = lstat(from_path)
        raise Error("the old name should have gone")
    except e:
        assert_true(matches(e, ErrNotExist))
    remove_all(place)


def test_rename_failure_names_both_paths() raises:
    var place = _scratch("renamefail")
    try:
        rename(String(place, "/nowhere"), String(place, "/anywhere"))
        raise Error("renaming a name that is not there should have failed")
    except e:
        var reported = LinkError.of(e)
        assert_true(reported)
        assert_equal(reported.value().op, "rename")
        assert_equal(reported.value().old, String(place, "/nowhere"))
        assert_equal(reported.value().new, String(place, "/anywhere"))
        # A two path failure is not a one path failure, and the two readers do
        # not answer for each other.
        assert_false(PathError.of(e))
    remove_all(place)


def test_link_makes_a_second_name_for_one_file() raises:
    var place = _scratch("link")
    var first = String(place, "/first.txt")
    var second = String(place, "/second.txt")
    _write(first, "shared")
    link(first, second)

    assert_true(same_file(stat(first), stat(second)))
    remove(first)
    assert_equal(stat(second).size(), 6)
    remove_all(place)


def test_symlink_and_readlink() raises:
    var place = _scratch("symlink")
    var target = String(place, "/target.txt")
    var pointer = String(place, "/pointer")
    _write(target, "pointed at")
    symlink("target.txt", pointer)

    assert_equal(readlink(pointer), "target.txt")
    assert_equal(lstat(pointer).mode().type(), MODE_SYMLINK)
    assert_equal(stat(pointer).size(), 10)
    remove_all(place)


def test_a_link_to_nothing_is_still_a_link() raises:
    # `symlink` does not look at what it is given, which is the whole
    # difference between a symbolic link and a hard one.
    var place = _scratch("danglink")
    var pointer = String(place, "/pointer")
    symlink("nowhere-at-all", pointer)
    assert_equal(readlink(pointer), "nowhere-at-all")
    try:
        _ = stat(pointer)
        raise Error("following a link to nothing should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))
    remove_all(place)


def test_readlink_of_something_that_is_not_a_link() raises:
    var place = _scratch("readlinkplain")
    var path = String(place, "/plain.txt")
    _write(path, "plain")
    try:
        _ = readlink(path)
        raise Error("readlink of an ordinary file should have failed")
    except e:
        assert_equal(PathError.of(e).value().op, "readlink")
    remove_all(place)


def test_chmod_sets_the_permission_bits() raises:
    var place = _scratch("chmod")
    var path = String(place, "/perm.txt")
    _write(path, "x")

    chmod(path, FileMode(0o600))
    assert_equal(stat(path).mode().perm(), FileMode(0o600))
    chmod(path, FileMode(0o644))
    assert_equal(stat(path).mode().perm(), FileMode(0o644))

    # The type bits are not a caller's to set and are dropped rather than
    # refused, so a mode with MODE_DIR in it still sets the nine permissions.
    chmod(path, FileMode(0o640) | MODE_DIR)
    assert_equal(stat(path).mode().perm(), FileMode(0o640))
    assert_false(stat(path).is_dir())
    remove_all(place)


def test_chmod_of_a_name_that_is_not_there() raises:
    var place = _scratch("chmodmiss")
    try:
        chmod(String(place, "/nowhere"), FileMode(0o644))
        raise Error("chmod of a name that is not there should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))
        assert_equal(PathError.of(e).value().op, "chmod")
    remove_all(place)


def test_chown_to_the_owner_a_file_already_has() raises:
    # The only change an ordinary user is allowed to make. It is worth making
    # because it proves the arguments arrive in the right order and the right
    # width: a uid that lost its top bits would be another user and this would
    # be refused.
    var place = _scratch("chown")
    var path = String(place, "/owned.txt")
    _write(path, "owned")
    var held = stat(path).sys()
    var before = held.take()
    chown(path, Int(before.uid()), Int(before.gid()))
    chown(path, -1, -1)
    var after = stat(path).sys()
    assert_equal(after.value().uid(), before.uid())
    remove_all(place)


def test_chown_to_somebody_else_is_refused() raises:
    # Root is allowed to do this and some CI jobs run as root, so the refusal
    # is only asserted when the process is not root. What is always asserted is
    # that the call either worked or failed for the one reason it may.
    var place = _scratch("chownother")
    var path = String(place, "/owned.txt")
    _write(path, "owned")
    var held = stat(path).sys()
    var mine = held.value().uid()
    var other = 0 if mine != 0 else 65534
    try:
        chown(path, other, -1)
        var now = stat(path).sys()
        assert_equal(Int(now.value().uid()), other)
    except e:
        assert_true(matches(e, ErrPermission))
        assert_equal(PathError.of(e).value().op, "chown")
    remove_all(place)


def test_lchown_reaches_the_link_itself() raises:
    # Asserting that a link has its own owner needs root. What can be asserted
    # without it is that `lchown` stops at the link and `chown` does not: a
    # link to nothing can be lchowned and cannot be chowned.
    var place = _scratch("lchown")
    var pointer = String(place, "/pointer")
    symlink("nowhere", pointer)
    var held = lstat(pointer).sys()
    var mine = held.take()
    lchown(pointer, Int(mine.uid()), Int(mine.gid()))

    try:
        chown(pointer, Int(mine.uid()), Int(mine.gid()))
        raise Error("chown through a link to nothing should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))
        assert_equal(PathError.of(e).value().op, "chown")
    remove_all(place)


def test_truncate_shortens_and_lengthens() raises:
    var place = _scratch("truncate")
    var path = String(place, "/sized.txt")
    _write(path, "twelve bytes")
    assert_equal(stat(path).size(), 12)

    truncate(path, 4)
    assert_equal(stat(path).size(), 4)
    truncate(path, 9)
    assert_equal(stat(path).size(), 9)
    remove_all(place)


def test_truncate_of_a_name_that_is_not_there() raises:
    var place = _scratch("truncmiss")
    try:
        truncate(String(place, "/nowhere"), 0)
        raise Error("truncating a name that is not there should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))
        assert_equal(PathError.of(e).value().op, "truncate")
    remove_all(place)


def test_getwd_and_chdir() raises:
    # The working directory is process wide, so this puts it back before it
    # returns, whether the assertions passed or not.
    var was = getwd()
    assert_true(was.startswith("/"))
    var place = _scratch("cwd")
    try:
        chdir(place)
        # macOS resolves /tmp to /private/tmp and getwd reports what the kernel
        # says, so the last element is what can be asserted.
        assert_true(
            getwd().endswith(String("mojo-core-oscalls-", getpid(), "-cwd"))
        )
    finally:
        chdir(was)
    assert_equal(getwd(), was)
    remove_all(place)


def test_chdir_into_a_name_that_is_not_there() raises:
    var place = _scratch("chdirmiss")
    try:
        chdir(String(place, "/nowhere"))
        raise Error("chdir into nothing should have failed")
    except e:
        assert_true(matches(e, ErrNotExist))
        assert_equal(PathError.of(e).value().op, "chdir")
    remove_all(place)
