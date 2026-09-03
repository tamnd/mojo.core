"""A string read as a stream. Go's `reader_test.go`.

The type forwards every method to a `core.bytes.Reader`, so what is under test
is the forwarding and not the seeking arithmetic, which `tests/bytes` covers on
the same code. Each of the eleven methods gets at least one call, because a
wrong name in a one line forwarder is the failure this file exists to catch.

The difference from Go worth asserting is at the bottom: `new_reader` copies
nothing, where Go's `bytes.NewReader([]byte(s))` copies the whole string, and
that is the reason `strings.Reader` exists in Go at all.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.io import Byte, SEEK_CURRENT, SEEK_END, SEEK_START, read_all
from core.strings import Builder, new_reader


def test_read() raises:
    """Everything out through `read`, which is `io.Reader`."""
    var r = new_reader("hello world")
    assert_equal(r.len(), 11)
    assert_equal(Int(r.size()), 11)
    var got = read_all(r)
    assert_equal(String(from_utf8=Span(got)), "hello world")
    assert_equal(r.len(), 0)


def test_read_into_a_short_buffer() raises:
    """A read takes what fits and leaves the rest, and says how much it took."""
    var r = new_reader("abcdef")
    var buf = List[Byte](length=4, fill=0)
    assert_equal(r.read(Span(buf)), 4)
    assert_equal(String(from_utf8=Span(buf)), "abcd")
    assert_equal(r.len(), 2)
    assert_equal(r.read(Span(buf)), 2)
    assert_equal(String(from_utf8=Span(buf)[0:2]), "ef")
    # And the read after the last one has nothing to hand over, so it ends.
    with assert_raises():
        _ = r.read(Span(buf))


def test_read_byte_and_unread_byte() raises:
    """One byte at a time, and one step back. Go's `TestReadByte`."""
    var r = new_reader("abc")
    assert_equal(Int(r.read_byte()), ord("a"))
    r.unread_byte()
    assert_equal(Int(r.read_byte()), ord("a"))
    assert_equal(Int(r.read_byte()), ord("b"))
    assert_equal(Int(r.read_byte()), ord("c"))
    with assert_raises():
        _ = r.read_byte()


def test_read_rune_and_unread_rune() raises:
    """Whole characters, with the width, which is what `read` cannot give.

    A `read` can stop in the middle of a character because it counts bytes.
    `read_rune` cannot, and it says how many bytes the character was so the
    caller can keep their own offset.
    """
    var r = new_reader("a☺b")
    var r1, w1 = r.read_rune()
    assert_equal(Int(r1), ord("a"))
    assert_equal(w1, 1)
    var r2, w2 = r.read_rune()
    assert_equal(Int(r2), 0x263A)
    assert_equal(w2, 3)
    r.unread_rune()
    var r3, w3 = r.read_rune()
    assert_equal(Int(r3), 0x263A)
    assert_equal(w3, 3)
    var r4, w4 = r.read_rune()
    assert_equal(Int(r4), ord("b"))
    assert_equal(w4, 1)
    with assert_raises():
        _ = r.read_rune()


def test_unread_rune_needs_a_read_rune_first() raises:
    """Go's rule, and the reason `unread_rune` can fail where `unread_byte`
    cannot say much."""
    var r = new_reader("abc")
    with assert_raises():
        r.unread_rune()
    _ = r.read_byte()
    with assert_raises():
        r.unread_rune()


def test_seek() raises:
    """Go's `TestReaderAtSeek`, in all three whences."""
    var r = new_reader("0123456789")
    assert_equal(Int(r.seek(5, SEEK_START)), 5)
    assert_equal(Int(r.read_byte()), ord("5"))
    assert_equal(Int(r.seek(2, SEEK_CURRENT)), 8)
    assert_equal(Int(r.read_byte()), ord("8"))
    assert_equal(Int(r.seek(-3, SEEK_END)), 7)
    assert_equal(Int(r.read_byte()), ord("7"))
    # Seeking before the start is an error; seeking past the end is not, and
    # the read that follows it ends straight away.
    with assert_raises():
        _ = r.seek(-1, SEEK_START)
    assert_equal(Int(r.seek(100, SEEK_START)), 100)
    assert_equal(r.len(), 0)


def test_seek_lands_in_the_middle_of_a_character() raises:
    """A byte offset, so it can, and Go behaves the same way.

    Neither library can do better here: the `io.Seeker` interface is in bytes,
    so a caller who seeks into the middle of a rune gets the replacement
    character out of the decoder rather than an error.
    """
    var r = new_reader("a☺b")
    _ = r.seek(2, SEEK_START)
    var got, width = r.read_rune()
    assert_equal(Int(got), 0xFFFD)
    assert_equal(width, 1)


def test_read_at() raises:
    """Reading without moving the cursor. Go's `TestReaderAt`."""
    var r = new_reader("0123456789")
    var buf = List[Byte](length=3, fill=0)
    assert_equal(r.read_at(Span(buf), 4), 3)
    assert_equal(String(from_utf8=Span(buf)), "456")
    # The cursor has not moved, so a plain read still starts at the beginning.
    assert_equal(Int(r.read_byte()), ord("0"))
    with assert_raises():
        _ = r.read_at(Span(buf), -1)


def test_write_to() raises:
    """The fast path a `Reader` advertises, since the text is already in memory.
    """
    var r = new_reader("hello")
    var b = Builder()
    assert_equal(Int(r.write_to(b)), 5)
    assert_equal(b.string(), "hello")
    assert_equal(r.len(), 0)


def test_reset() raises:
    """Starting again over other text from the same place. Go's `Reset`.

    The slice has to have the origin the reader was built with, because the
    origin is part of the type. That is the deviation, and it costs a caller
    with different text two words to make a new reader.
    """
    var s = String("hello world")
    var view = s.as_string_slice().as_imm()
    var r = new_reader(view)
    _ = r.read_byte()
    assert_equal(r.len(), 10)
    r.reset(view[byte = 6 : view.byte_length()])
    assert_equal(r.len(), 5)
    var rest = read_all(r)
    assert_equal(String(from_utf8=Span(rest)), "world")


def test_reader_over_an_empty_string() raises:
    """Nothing to read, and every accessor still answers."""
    var r = new_reader("")
    assert_equal(r.len(), 0)
    assert_equal(Int(r.size()), 0)
    with assert_raises():
        _ = r.read_byte()
    assert_equal(len(read_all(r)), 0)


def test_the_reader_borrows_rather_than_copies() raises:
    """Why this type exists in Go, and why it is nearly free here.

    Go writes `strings.NewReader(s)` instead of `bytes.NewReader([]byte(s))`
    because the second copies the whole string. Here neither copies, so the
    reader is two words over text somebody else owns, and the compiler is what
    stops it outliving them.
    """
    var s = String("0123456789")
    var view = s.as_string_slice().as_imm()
    var r1 = new_reader(view)
    var r2 = new_reader(view)
    # Two readers over the same text, each with its own position, which is the
    # `ImmOrigin` bound doing its job.
    _ = r1.seek(5, SEEK_START)
    assert_equal(Int(r1.read_byte()), ord("5"))
    assert_equal(Int(r2.read_byte()), ord("0"))
    assert_true(r1.len() != r2.len())
