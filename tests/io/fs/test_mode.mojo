"""`FileMode`: the letters, the masks, and the translation out of `st_mode`.

Go has no table for `FileMode.String`, so the table here is written from the
constants and their documented letters. Every one of the thirteen type bits
appears on its own, so a letter in the wrong position or a bit shifted by one
fails on the row for that bit rather than showing up as one odd character in a
string somebody has to read carefully.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.io.fs import (
    MODE_APPEND,
    MODE_CHAR_DEVICE,
    MODE_DEVICE,
    MODE_DIR,
    MODE_EXCLUSIVE,
    MODE_IRREGULAR,
    MODE_NAMED_PIPE,
    MODE_PERM,
    MODE_SETGID,
    MODE_SETUID,
    MODE_SOCKET,
    MODE_STICKY,
    MODE_SYMLINK,
    MODE_TEMPORARY,
    MODE_TYPE,
    FileMode,
)
from core.io.fs.mode import _of_platform_mode
from core.syscall import S_ISGID, S_ISUID, S_ISVTX


def _rows() -> List[Tuple[FileMode, String]]:
    """Every type bit on its own, then the shapes `ls` prints every day."""
    return [
        (FileMode(0), "----------"),
        (FileMode(0o777), "-rwxrwxrwx"),
        (FileMode(0o644), "-rw-r--r--"),
        (FileMode(0o755), "-rwxr-xr-x"),
        (FileMode(0o600), "-rw-------"),
        (MODE_DIR | FileMode(0o755), "drwxr-xr-x"),
        (MODE_APPEND | FileMode(0o644), "arw-r--r--"),
        (MODE_EXCLUSIVE | FileMode(0o644), "lrw-r--r--"),
        (MODE_TEMPORARY | FileMode(0o644), "Trw-r--r--"),
        (MODE_SYMLINK | FileMode(0o777), "Lrwxrwxrwx"),
        (MODE_DEVICE | FileMode(0o660), "Drw-rw----"),
        (MODE_NAMED_PIPE | FileMode(0o644), "prw-r--r--"),
        (MODE_SOCKET | FileMode(0o755), "Srwxr-xr-x"),
        (MODE_SETUID | FileMode(0o755), "urwxr-xr-x"),
        (MODE_SETGID | FileMode(0o755), "grwxr-xr-x"),
        (MODE_DEVICE | MODE_CHAR_DEVICE | FileMode(0o620), "Dcrw--w----"),
        (MODE_STICKY | FileMode(0o777), "trwxrwxrwx"),
        (MODE_IRREGULAR | FileMode(0o644), "?rw-r--r--"),
        (MODE_DIR | MODE_STICKY | FileMode(0o777), "dtrwxrwxrwx"),
    ]


def test_the_mode_string() raises:
    """Go's `String`, letter for letter."""
    for row in _rows():
        assert_equal(row[0].string(), row[1])


def test_write_to_says_the_same_thing() raises:
    """A failing assertion prints what `string` returns and not an address."""
    for row in _rows():
        assert_equal(String(row[0]), row[1])


def test_a_mode_with_no_type_bit_leads_with_a_dash() raises:
    """So the permission letters always start at the same column.

    Ten characters for an ordinary file and eleven once a type letter is there.
    Go writes the dash for the same reason and `ls` lines up because of it.
    """
    assert_equal(FileMode(0o644).string().byte_length(), 10)
    assert_equal((MODE_DIR | FileMode(0o755)).string().byte_length(), 10)
    assert_equal(
        (MODE_DIR | MODE_STICKY | FileMode(0o755)).string().byte_length(), 11
    )


def test_is_dir() raises:
    assert_true((MODE_DIR | FileMode(0o755)).is_dir())
    assert_false(FileMode(0o755).is_dir())
    assert_false((MODE_SYMLINK | FileMode(0o777)).is_dir())


def test_is_regular() raises:
    """An ordinary file is one with no type bit, not one with a bit of its own.
    """
    assert_true(FileMode(0o644).is_regular())
    assert_true(FileMode(0).is_regular())
    assert_false((MODE_DIR | FileMode(0o755)).is_regular())
    assert_false((MODE_IRREGULAR | FileMode(0o644)).is_regular())

    # Setuid, setgid, sticky and the three Plan 9 bits say how a file behaves
    # rather than what it is, so a file carrying them is still ordinary.
    assert_true((MODE_SETUID | FileMode(0o755)).is_regular())
    assert_true((MODE_SETGID | FileMode(0o755)).is_regular())
    assert_true((MODE_STICKY | FileMode(0o755)).is_regular())
    assert_true((MODE_APPEND | FileMode(0o644)).is_regular())


def test_perm_and_type_are_complementary() raises:
    var mode = MODE_DIR | MODE_SETUID | FileMode(0o750)
    assert_equal(mode.perm(), FileMode(0o750))
    assert_equal(mode.type(), MODE_DIR)

    # `perm` keeps only the nine, so the setuid bit is in neither answer: it is
    # not a permission bit here even though the platform keeps it beside them.
    assert_equal(mode.perm() | mode.type(), MODE_DIR | FileMode(0o750))


def test_mode_type_holds_exactly_the_seven_kinds() raises:
    """And not the six that describe behaviour rather than kind."""
    assert_equal(
        MODE_TYPE,
        MODE_DIR
        | MODE_SYMLINK
        | MODE_NAMED_PIPE
        | MODE_SOCKET
        | MODE_DEVICE
        | MODE_CHAR_DEVICE
        | MODE_IRREGULAR,
    )
    assert_equal(MODE_TYPE & MODE_SETUID, FileMode(0))
    assert_equal(MODE_TYPE & MODE_SETGID, FileMode(0))
    assert_equal(MODE_TYPE & MODE_STICKY, FileMode(0))
    assert_equal(MODE_TYPE & MODE_APPEND, FileMode(0))
    assert_equal(MODE_TYPE & MODE_EXCLUSIVE, FileMode(0))
    assert_equal(MODE_TYPE & MODE_TEMPORARY, FileMode(0))


def test_mode_perm_is_nine_bits_and_not_twelve() raises:
    """The platform keeps setuid, setgid and sticky just above the nine and a
    `FileMode` keeps them at the top, so `MODE_PERM` is 0o777 and not 0o7777."""
    assert_equal(MODE_PERM, FileMode(0o777))
    assert_equal(MODE_PERM.string(), "-rwxrwxrwx")


def test_the_constants_are_thirteen_distinct_bits() raises:
    """One bit each, all different, none overlapping the permissions."""
    var singles: List[FileMode] = [
        MODE_DIR,
        MODE_APPEND,
        MODE_EXCLUSIVE,
        MODE_TEMPORARY,
        MODE_SYMLINK,
        MODE_DEVICE,
        MODE_NAMED_PIPE,
        MODE_SOCKET,
        MODE_SETUID,
        MODE_SETGID,
        MODE_CHAR_DEVICE,
        MODE_STICKY,
        MODE_IRREGULAR,
    ]
    var seen = FileMode(0)
    for bit in singles:
        assert_equal(bit & MODE_PERM, FileMode(0))
        assert_equal(bit & seen, FileMode(0))
        seen = seen | bit
    assert_equal(seen.value, UInt32(0xFFF8_0000))


def test_platform_mode_translation() raises:
    """Go's `fillFileStatFromSys`, over every kind `S_IFMT` can report.

    The numbers on the left are `st_mode` values, not `FileMode` values, which
    is the whole point: they are the platform's layout and the strings on the
    right are this library's.
    """
    var rows: List[Tuple[UInt32, String]] = [
        (UInt32(0o100644), "-rw-r--r--"),
        (UInt32(0o100755), "-rwxr-xr-x"),
        (UInt32(0o040755), "drwxr-xr-x"),
        (UInt32(0o120777), "Lrwxrwxrwx"),
        (UInt32(0o010644), "prw-r--r--"),
        (UInt32(0o140755), "Srwxr-xr-x"),
        (UInt32(0o020620), "Dcrw--w----"),
        (UInt32(0o060660), "Drw-rw----"),
    ]
    for row in rows:
        assert_equal(_of_platform_mode(row[0]).string(), row[1])


def test_the_three_odd_bits_move_to_the_top() raises:
    """Setuid, setgid and sticky are low in an `st_mode` and high in a mode.

    A translation that let them through unchanged would leave them inside the
    permission bits, where `perm` would report them and `string` would not.
    """
    assert_equal(
        _of_platform_mode(0o100755 | UInt32(S_ISUID)).string(), "urwxr-xr-x"
    )
    assert_equal(
        _of_platform_mode(0o100755 | UInt32(S_ISGID)).string(), "grwxr-xr-x"
    )
    assert_equal(
        _of_platform_mode(0o040777 | UInt32(S_ISVTX)).string(), "dtrwxrwxrwx"
    )
    assert_equal(
        _of_platform_mode(0o100755 | UInt32(S_ISUID)).perm(), FileMode(0o755)
    )


def test_an_unknown_type_reads_as_an_ordinary_file() raises:
    """Which is Go's answer and the conservative one.

    `MODE_IRREGULAR` is for a file system that can say a file is odd, not for a
    type this switch has not heard of.
    """
    assert_true(_of_platform_mode(0o030644).is_regular())
