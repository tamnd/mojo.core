"""A directory names cannot climb out of.

Half of these tests are about ordinary work done through a `Root`, which has to
keep behaving the way the same call behaves outside one, and half are about the
escapes. The second half is the reason the type exists, so each of the ways out
gets its own test: an absolute name, a name with `..` in it, a link holding an
absolute path, a link holding `..`, a link in the middle of a path rather than
at the end, and a chain of links long enough to be a loop.

Every test builds its own tree under the system temporary directory and takes
it away with `remove_all` afterwards, and the tree always holds a file outside
the root as the thing an escape would reach, so a test that fails to refuse
does not merely fail to raise: it reads a file it should never have seen.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import ErrorValue, capture, matches
from core.errors.codes import ErrClosed, ErrExist, ErrInvalid, ErrNotExist
from core.io import Byte
from core.io.fs import (
    MODE_SYMLINK,
    DirEntry,
    FileMode,
    PathError,
    walk_dir,
)
from core.os import (
    O_CREATE,
    O_EXCL,
    O_WRONLY,
    lstat,
    mkdir,
    mkdir_all,
    open_in_root,
    open_root,
    read_file,
    remove_all,
    stat,
    symlink,
    write_file,
)
from core.syscall import ELOOP, getpid
from core.time import Time, now


def _scratch(name: String) raises -> String:
    """An empty directory of this suite's own, with a secret beside it.

    The layout is the same everywhere: `place` is the sandbox, `place/root` is
    what gets opened as a root, and `place/outside` is a file with contents no
    test is allowed to read through the root.
    """
    var place = String("/tmp/mojo-core-osroot-", getpid(), "-", name)
    remove_all(place)
    mkdir_all(place + "/root", FileMode(0o700))
    write_file(place + "/outside", "secret\n".as_bytes(), FileMode(0o600))
    return place


def _text(data: List[Byte]) -> String:
    return String(from_utf8_lossy=Span(data))


def _escaped(e: Error) -> Bool:
    """Whether this is the refusal a root makes rather than a real failure."""
    if not matches(e, ErrInvalid):
        return False
    return capture(e).field("errno") is None


def test_open_root_and_name() raises:
    var place = _scratch("name")
    var root = open_root(place + "/root")
    assert_equal(root.name(), place + "/root")
    root.close()
    remove_all(place)


def test_open_root_refuses_a_plain_file() raises:
    var place = _scratch("notdir")
    var failed = False
    try:
        var root = open_root(place + "/outside")
        root.close()
    except e:
        failed = True
        assert_equal(PathError.of(e).value().op, "open")
    assert_true(failed)
    remove_all(place)


def test_create_and_read_back() raises:
    var place = _scratch("create")
    var root = open_root(place + "/root")
    var f = root.create("note")
    _ = f.write_string("hello\n")
    f.close()
    assert_equal(_text(root.read_file("note")), "hello\n")
    assert_equal(_text(read_file(place + "/root/note")), "hello\n")
    root.close()
    remove_all(place)


def test_write_file_and_read_file() raises:
    var place = _scratch("writefile")
    var root = open_root(place + "/root")
    root.write_file("a", "one".as_bytes(), FileMode(0o600))
    assert_equal(_text(root.read_file("a")), "one")
    root.close()
    remove_all(place)


def test_open_file_carries_the_flags() raises:
    var place = _scratch("openfile")
    var root = open_root(place + "/root")
    var f = root.open_file(
        "only-once", O_WRONLY | O_CREATE | O_EXCL, FileMode(0o600)
    )
    f.close()
    var refused = False
    try:
        var again = root.open_file(
            "only-once", O_WRONLY | O_CREATE | O_EXCL, FileMode(0o600)
        )
        again.close()
    except e:
        refused = matches(e, ErrExist)
    assert_true(refused)
    root.close()
    remove_all(place)


def test_a_file_names_the_root_it_came_through() raises:
    var place = _scratch("filename")
    var root = open_root(place + "/root")
    var f = root.create("note")
    assert_equal(f.name(), place + "/root/note")
    f.close()
    root.close()
    remove_all(place)


def test_mkdir_and_stat() raises:
    var place = _scratch("mkdir")
    var root = open_root(place + "/root")
    root.mkdir("one", FileMode(0o755))
    assert_true(root.stat("one").is_dir())
    root.close()
    remove_all(place)


def test_mkdir_all_makes_every_level() raises:
    var place = _scratch("mkdirall")
    var root = open_root(place + "/root")
    root.mkdir_all("a/b/c", FileMode(0o755))
    assert_true(root.stat("a/b/c").is_dir())
    assert_true(stat(place + "/root/a/b/c").is_dir())
    root.close()
    remove_all(place)


def test_mkdir_all_of_a_tree_that_is_already_there() raises:
    var place = _scratch("mkdallagain")
    var root = open_root(place + "/root")
    root.mkdir_all("a/b", FileMode(0o755))
    root.mkdir_all("a/b", FileMode(0o755))
    assert_true(root.stat("a/b").is_dir())
    root.close()
    remove_all(place)


def test_remove_takes_a_file_and_an_empty_directory() raises:
    var place = _scratch("remove")
    var root = open_root(place + "/root")
    root.write_file("a", "x".as_bytes(), FileMode(0o600))
    root.mkdir("d", FileMode(0o755))
    root.remove("a")
    root.remove("d")
    var gone = False
    try:
        _ = root.stat("a")
    except e:
        gone = matches(e, ErrNotExist)
    assert_true(gone)
    root.close()
    remove_all(place)


def test_remove_all_takes_a_whole_tree() raises:
    var place = _scratch("removeall")
    var root = open_root(place + "/root")
    root.mkdir_all("a/b/c", FileMode(0o755))
    root.write_file("a/b/c/deep", "x".as_bytes(), FileMode(0o600))
    root.remove_all("a")
    var gone = False
    try:
        _ = root.stat("a")
    except e:
        gone = matches(e, ErrNotExist)
    assert_true(gone)
    root.close()
    remove_all(place)


def test_remove_all_refuses_the_root_itself() raises:
    var place = _scratch("removeallroot")
    var root = open_root(place + "/root")
    root.write_file("keep", "x".as_bytes(), FileMode(0o600))
    var refused = False
    try:
        root.remove_all(".")
    except e:
        refused = True
    assert_true(refused)
    assert_equal(_text(root.read_file("keep")), "x")
    root.close()
    remove_all(place)


def test_chmod_and_chown_and_chtimes() raises:
    var place = _scratch("attrs")
    var root = open_root(place + "/root")
    root.write_file("a", "x".as_bytes(), FileMode(0o600))
    root.chmod("a", FileMode(0o640))
    assert_equal(Int(root.stat("a").mode().perm().value), 0o640)
    # `-1` for both is the call that changes nothing, which is the only
    # ownership change an ordinary user is allowed to make.
    root.chown("a", -1, -1)
    var when = now()
    root.chtimes("a", Time(), when)
    assert_equal(root.stat("a").mod_time().unix(), when.unix())
    root.close()
    remove_all(place)


def test_link_and_rename() raises:
    var place = _scratch("link")
    var root = open_root(place + "/root")
    root.write_file("a", "one".as_bytes(), FileMode(0o600))
    root.link("a", "b")
    assert_equal(_text(root.read_file("b")), "one")
    root.rename("b", "c")
    assert_equal(_text(root.read_file("c")), "one")
    root.close()
    remove_all(place)


def test_symlink_and_readlink_and_lstat() raises:
    var place = _scratch("symlink")
    var root = open_root(place + "/root")
    root.write_file("a", "one".as_bytes(), FileMode(0o600))
    root.symlink("a", "l")
    assert_equal(root.readlink("l"), "a")
    assert_equal(root.lstat("l").mode().type(), MODE_SYMLINK)
    assert_false(root.stat("l").mode().type() == MODE_SYMLINK)
    assert_equal(_text(root.read_file("l")), "one")
    root.close()
    remove_all(place)


def test_a_link_in_the_middle_of_a_path_is_followed() raises:
    var place = _scratch("midlink")
    var root = open_root(place + "/root")
    root.mkdir_all("real/inner", FileMode(0o755))
    root.write_file("real/inner/note", "deep".as_bytes(), FileMode(0o600))
    root.symlink("real", "alias")
    assert_equal(_text(root.read_file("alias/inner/note")), "deep")
    root.close()
    remove_all(place)


def test_dot_dot_inside_the_root_is_allowed() raises:
    var place = _scratch("dotdotin")
    var root = open_root(place + "/root")
    root.mkdir_all("a/b", FileMode(0o755))
    root.write_file("a/note", "up".as_bytes(), FileMode(0o600))
    assert_equal(_text(root.read_file("a/b/../note")), "up")
    root.close()
    remove_all(place)


def test_an_absolute_name_is_refused() raises:
    var place = _scratch("absolute")
    var root = open_root(place + "/root")
    var refused = False
    try:
        _ = root.read_file(place + "/outside")
    except e:
        refused = _escaped(e)
    assert_true(refused)
    root.close()
    remove_all(place)


def test_dot_dot_out_of_the_root_is_refused() raises:
    var place = _scratch("dotdotout")
    var root = open_root(place + "/root")
    var refused = False
    try:
        _ = root.read_file("../outside")
    except e:
        refused = _escaped(e)
    assert_true(refused)
    root.close()
    remove_all(place)


def test_dot_dot_that_goes_down_and_further_up_is_refused() raises:
    var place = _scratch("dotdotdeep")
    var root = open_root(place + "/root")
    root.mkdir("a", FileMode(0o755))
    var refused = False
    try:
        _ = root.read_file("a/../../outside")
    except e:
        refused = _escaped(e)
    assert_true(refused)
    root.close()
    remove_all(place)


def test_a_link_holding_an_absolute_path_is_refused() raises:
    var place = _scratch("abslink")
    var root = open_root(place + "/root")
    symlink(place + "/outside", place + "/root/escape")
    var refused = False
    try:
        _ = root.read_file("escape")
    except e:
        refused = _escaped(e)
    assert_true(refused)
    # The link itself is still readable, which is the point: saying what a
    # link holds is not the same as following it.
    assert_equal(root.readlink("escape"), place + "/outside")
    root.close()
    remove_all(place)


def test_a_link_holding_dot_dot_is_refused() raises:
    var place = _scratch("uplink")
    var root = open_root(place + "/root")
    symlink("../outside", place + "/root/escape")
    var refused = False
    try:
        _ = root.read_file("escape")
    except e:
        refused = _escaped(e)
    assert_true(refused)
    root.close()
    remove_all(place)


def test_a_link_in_the_middle_that_escapes_is_refused() raises:
    var place = _scratch("midescape")
    var root = open_root(place + "/root")
    mkdir(place + "/beyond", FileMode(0o755))
    write_file(place + "/beyond/note", "no".as_bytes(), FileMode(0o600))
    symlink("../beyond", place + "/root/alias")
    var refused = False
    try:
        _ = root.read_file("alias/note")
    except e:
        refused = _escaped(e)
    assert_true(refused)
    root.close()
    remove_all(place)


def test_a_loop_of_links_gives_up() raises:
    var place = _scratch("loop")
    var root = open_root(place + "/root")
    root.symlink("b", "a")
    root.symlink("a", "b")
    var gave_up = False
    try:
        _ = root.read_file("a")
    except e:
        var found = PathError.of(e)
        gave_up = found and found.value().err.value == ELOOP
    assert_true(gave_up)
    root.close()
    remove_all(place)


def test_open_root_of_a_subdirectory() raises:
    var place = _scratch("subroot")
    var root = open_root(place + "/root")
    root.mkdir("inner", FileMode(0o755))
    root.write_file("inner/note", "in".as_bytes(), FileMode(0o600))
    root.write_file("above", "out".as_bytes(), FileMode(0o600))
    var inner = root.open_root("inner")
    assert_equal(_text(inner.read_file("note")), "in")
    var refused = False
    try:
        _ = inner.read_file("../above")
    except e:
        refused = _escaped(e)
    assert_true(refused)
    inner.close()
    root.close()
    remove_all(place)


def test_a_closed_root_refuses_everything() raises:
    var place = _scratch("closed")
    var root = open_root(place + "/root")
    root.close()
    # Twice is not an error, which is what makes a value that also closes
    # itself safe to close by hand.
    root.close()
    var refused = False
    try:
        _ = root.stat("anything")
    except e:
        refused = matches(e, ErrClosed)
    assert_true(refused)
    remove_all(place)


def test_a_file_opened_through_a_root_outlives_it() raises:
    var place = _scratch("outlives")
    var root = open_root(place + "/root")
    root.write_file("a", "kept".as_bytes(), FileMode(0o600))
    var f = root.open("a")
    root.close()
    var room = List[Byte](length=4, fill=0)
    _ = f.read(Span(room))
    assert_equal(_text(room), "kept")
    f.close()
    remove_all(place)


def test_open_in_root() raises:
    var place = _scratch("openin")
    var root = open_root(place + "/root")
    root.write_file("a", "one".as_bytes(), FileMode(0o600))
    root.close()
    var f = open_in_root(place + "/root", "a")
    var room = List[Byte](length=3, fill=0)
    _ = f.read(Span(room))
    assert_equal(_text(room), "one")
    f.close()
    remove_all(place)


def test_open_in_root_refuses_an_escape() raises:
    var place = _scratch("openinescape")
    var refused = False
    try:
        var f = open_in_root(place + "/root", "../outside")
        f.close()
    except e:
        refused = _escaped(e)
    assert_true(refused)
    remove_all(place)


def test_fs_reads_the_tree() raises:
    var place = _scratch("fs")
    var root = open_root(place + "/root")
    root.mkdir("d", FileMode(0o755))
    root.write_file("d/one", "1".as_bytes(), FileMode(0o600))
    root.write_file("two", "2".as_bytes(), FileMode(0o600))
    var fsys = root.fs()
    root.close()

    var seen = List[String]()

    @parameter
    def visit(path: String, entry: DirEntry, err: Optional[ErrorValue]) raises:
        if err:
            raise err.value().error()
        seen.append(path)

    walk_dir[visit](fsys, ".")
    assert_equal(len(seen), 4)
    assert_equal(seen[0], ".")
    assert_equal(seen[1], "d")
    assert_equal(seen[2], "d/one")
    assert_equal(seen[3], "two")
    assert_equal(_text(fsys.read_file("d/one")), "1")
    remove_all(place)


def test_fs_refuses_a_name_no_file_system_accepts() raises:
    var place = _scratch("fsname")
    var root = open_root(place + "/root")
    var fsys = root.fs()
    root.close()
    var refused = False
    try:
        _ = fsys.stat("../outside")
    except e:
        refused = matches(e, ErrInvalid)
    assert_true(refused)
    remove_all(place)
