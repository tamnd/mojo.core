"""A span read as a stream. Go's `reader_test.go`.

A `Reader` borrows and never copies, so the only state is a cursor and the
position of the last rune. Almost every test here is about one of those two:
where the cursor ends up after a seek, and whether `unread_rune` knows what it
is putting back.

The two places this answers differently from Go both come from the type system
rather than from a choice. `reset` takes a span with the same origin, because
the origin is part of the type; and the whole `Reader[o]` cannot outlive what
it borrows, which is why there is no test here for reading from a reader whose
bytes are gone — it does not compile, and `probes/` is where that is pinned.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.bytes import Buffer, new_reader
from core.errors import matches, partial
from core.errors.codes import EOF, ErrShortWrite
from core.io import Byte, SEEK_CURRENT, SEEK_END, SEEK_START, read_all
from core.unicode.utf8 import RUNE_ERROR

from tests.bytes._fixtures import Short, Sink, enc, expect, quote

comptime DIGITS = "0123456789"
"""Go's input for `TestReader`. Ten bytes, each its own index."""


def test_read_takes_what_is_there() raises:
    """A read asks for a size and gets what is left when that is less.

    The first row of Go's `TestReader` asks for twenty bytes of ten, which is
    the case a reader written as `copy` of a fixed size gets wrong.
    """
    var s = enc(DIGITS)
    var r = new_reader(Span(s))
    var window = List[Byte](length=20, fill=0)
    var n = r.read(Span(window))
    assert_equal(n, 10)
    assert_equal(quote(Span(window)[0:n]), expect(DIGITS))
    assert_equal(r.len(), 0)
    with assert_raises():
        _ = r.read(Span(window))


def test_seek() raises:
    """Go's `TestReader`, as a sequence rather than a table.

    Go's rows carry a seek error and a read error in two columns; here either
    of those is a raise, so the steps are written out. The interesting ones are
    the seek to 1<<33, which is legal and leaves a reader at the end, and the
    seek from there by one more, which is still legal.
    """
    var s = enc(DIGITS)
    var r = new_reader(Span(s))
    var window = List[Byte](length=20, fill=0)

    assert_equal(Int(r.seek(0, SEEK_START)), 0)
    assert_equal(
        quote(Span(window)[0 : r.read(Span(window)[0:20])]), expect(DIGITS)
    )

    assert_equal(Int(r.seek(1, SEEK_START)), 1)
    assert_equal(
        quote(Span(window)[0 : r.read(Span(window)[0:1])]), expect("1")
    )

    assert_equal(Int(r.seek(1, SEEK_CURRENT)), 3)
    assert_equal(
        quote(Span(window)[0 : r.read(Span(window)[0:2])]), expect("34")
    )

    with assert_raises(contains="before the start"):
        _ = r.seek(-1, SEEK_START)

    assert_equal(Int(r.seek(1 << 33, SEEK_START)), 1 << 33)
    with assert_raises():
        _ = r.read(Span(window))

    assert_equal(Int(r.seek(1, SEEK_CURRENT)), (1 << 33) + 1)
    with assert_raises():
        _ = r.read(Span(window))

    assert_equal(Int(r.seek(0, SEEK_START)), 0)
    assert_equal(
        quote(Span(window)[0 : r.read(Span(window)[0:5])]), expect("01234")
    )
    assert_equal(
        quote(Span(window)[0 : r.read(Span(window)[0:5])]), expect("56789")
    )

    assert_equal(Int(r.seek(-1, SEEK_END)), 9)
    assert_equal(
        quote(Span(window)[0 : r.read(Span(window)[0:1])]), expect("9")
    )


def test_seek_with_an_unknown_whence_raises() raises:
    """Three constants and nothing else, so a fourth value is a caller bug and
    not a position."""
    var s = enc(DIGITS)
    var r = new_reader(Span(s))
    with assert_raises(contains="unknown whence"):
        _ = r.seek(0, 99)


def test_read_after_a_big_seek() raises:
    """Go's `TestReadAfterBigSeek`.

    Seeking a long way past the end is not a failure — a file behaves the same
    — and the end arrives on the read. What this catches is an implementation
    that computes a remaining length as a subtraction and hands back a huge
    one.
    """
    var s = enc(DIGITS)
    var r = new_reader(Span(s))
    assert_equal(Int(r.seek((1 << 31) + 5, SEEK_START)), (1 << 31) + 5)
    assert_equal(r.len(), 0)
    var window = List[Byte](length=10, fill=0)
    with assert_raises():
        _ = r.read(Span(window))


def test_read_at() raises:
    """Go's `TestReaderAt`.

    `read_at` fills what it was given or reaches the end, and it never moves
    the cursor, which is the difference from `read` and the whole reason
    `io.ReaderAt` is a separate interface. The cursor is checked after each
    call for exactly that.
    """
    var s = enc(DIGITS)
    var r = new_reader(Span(s))
    var window = List[Byte](length=4, fill=0)

    assert_equal(r.read_at(Span(window), 0), 4)
    assert_equal(quote(Span(window)), expect("0123"))
    assert_equal(r.len(), 10)

    assert_equal(r.read_at(Span(window), 6), 4)
    assert_equal(quote(Span(window)), expect("6789"))
    assert_equal(r.len(), 10)


def test_read_at_the_end_and_past_it() raises:
    """A short answer means the end, and there is nowhere else it can mean.

    Filling part of the span raises `EOF` with the count on it, because a
    caller reading a fixed size record needs to know both that the record is
    incomplete and how much of it arrived. An offset at or past the end raises
    with nothing.
    """
    var s = enc(DIGITS)
    var r = new_reader(Span(s))
    var window = List[Byte](length=4, fill=0)

    var got = -1
    try:
        _ = r.read_at(Span(window), 8)
    except e:
        assert_true(matches(e, EOF))
        got = partial(e)
    assert_equal(got, 2)
    assert_equal(quote(Span(window)[0:2]), expect("89"))

    with assert_raises():
        _ = r.read_at(Span(window), 10)
    with assert_raises(contains="negative offset"):
        _ = r.read_at(Span(window), -1)


def test_len_and_size() raises:
    """Go's `TestReaderLen` and `TestReaderLenSize`.

    `len()` counts what is unread and shrinks as the reader is read; `size()`
    counts the bytes there are and never changes. `ReaderAt` needs the second
    and a caller sizing a buffer needs the first, which is why both exist.
    """
    var s = enc("hello world")
    var r = new_reader(Span(s))
    assert_equal(r.len(), 11)
    assert_equal(Int(r.size()), 11)

    var window = List[Byte](length=10, fill=0)
    assert_equal(r.read(Span(window)), 10)
    assert_equal(r.len(), 1)
    assert_equal(Int(r.size()), 11)

    assert_equal(r.read(Span(window)[0:1]), 1)
    assert_equal(r.len(), 0)
    assert_equal(Int(r.size()), 11)


def test_read_byte_and_unread_byte() raises:
    """Stepping back is always meaningful over a fixed span, so unlike
    `Buffer.unread_byte` this does not ask what the last call was. At the
    beginning there is nowhere to step back to and it raises, which is where Go
    draws the line too.
    """
    var s = enc(DIGITS)
    var r = new_reader(Span(s))
    with assert_raises(contains="beginning"):
        r.unread_byte()

    assert_equal(Int(r.read_byte()), ord("0"))
    r.unread_byte()
    assert_equal(Int(r.read_byte()), ord("0"))
    assert_equal(Int(r.read_byte()), ord("1"))

    _ = r.seek(0, SEEK_END)
    with assert_raises():
        _ = r.read_byte()


def test_read_rune_and_unread_rune() raises:
    """A rune of three bytes read and put back leaves the cursor where it was.

    `héllo` is the input because the second rune is two bytes: after unreading
    it, the next `read_byte` has to give back the first of the two and not the
    second.
    """
    var s = enc("h\\xc3\\xa9llo")
    var r = new_reader(Span(s))
    var first, width = r.read_rune()
    assert_equal(Int(first), ord("h"))
    assert_equal(width, 1)

    var second, second_width = r.read_rune()
    assert_equal(Int(second), 0xE9)
    assert_equal(second_width, 2)

    r.unread_rune()
    assert_equal(Int(r.read_byte()), 0xC3)


def test_read_rune_over_bytes_that_do_not_decode() raises:
    """Invalid encodings come back as U+FFFD one byte at a time, which is the
    rule everywhere in this library and is what keeps a decoding loop from
    either failing or losing its place."""
    var s = enc("\\xff\\xfea")
    var r = new_reader(Span(s))
    var first, first_width = r.read_rune()
    assert_equal(Int(first), Int(RUNE_ERROR))
    assert_equal(first_width, 1)
    var second, second_width = r.read_rune()
    assert_equal(Int(second), Int(RUNE_ERROR))
    assert_equal(second_width, 1)
    var third, third_width = r.read_rune()
    assert_equal(Int(third), ord("a"))
    assert_equal(third_width, 1)


def test_unread_rune_after_anything_else_raises() raises:
    """Go's `UnreadRuneErrorTests`: five things that invalidate it.

    The width to give back is only known straight after a `read_rune`, so
    anything in between — a read, a byte read, another unread, a seek, a
    `write_to` — has to make the call refuse rather than guess a width.
    """
    var s = enc(DIGITS)
    var window = List[Byte](length=1, fill=0)

    var after_read = new_reader(Span(s))
    _ = after_read.read_rune()
    _ = after_read.read(Span(window))
    with assert_raises():
        after_read.unread_rune()

    var after_read_byte = new_reader(Span(s))
    _ = after_read_byte.read_rune()
    _ = after_read_byte.read_byte()
    with assert_raises():
        after_read_byte.unread_rune()

    var after_unread = new_reader(Span(s))
    _ = after_unread.read_rune()
    after_unread.unread_rune()
    with assert_raises():
        after_unread.unread_rune()

    var after_seek = new_reader(Span(s))
    _ = after_seek.read_rune()
    _ = after_seek.seek(0, SEEK_CURRENT)
    with assert_raises():
        after_seek.unread_rune()

    var after_write_to = new_reader(Span(s))
    _ = after_write_to.read_rune()
    var sink = Sink()
    _ = after_write_to.write_to(sink)
    with assert_raises():
        after_write_to.unread_rune()


def test_write_to() raises:
    """Go's `TestReaderWriteTo`.

    One call with everything left, because the bytes are contiguous and there
    is nothing to gain by cutting them up, and the reader is at the end
    afterwards.
    """
    var s = enc(DIGITS)
    var r = new_reader(Span(s))
    var dst = Sink()
    assert_equal(Int(r.write_to(dst)), 10)
    assert_equal(dst.writes, 1)
    assert_equal(quote(Span(dst.data)), expect(DIGITS))
    assert_equal(r.len(), 0)


def test_write_to_from_the_middle() raises:
    """Only the unread part goes, so a reader half read writes half."""
    var s = enc(DIGITS)
    var r = new_reader(Span(s))
    var window = List[Byte](length=6, fill=0)
    _ = r.read(Span(window))
    var dst = Sink()
    assert_equal(Int(r.write_to(dst)), 4)
    assert_equal(quote(Span(dst.data)), expect("6789"))


def test_write_to_an_exhausted_reader_writes_nothing() raises:
    """Go's `TestReaderCopyNothing`: copying from an empty reader is zero and
    not a failure, whether the reader is empty because it was drained or
    because it never had anything."""
    var s = enc(DIGITS)
    var drained = new_reader(Span(s))
    var window = List[Byte](length=10, fill=0)
    _ = drained.read(Span(window))
    var first = Sink()
    assert_equal(Int(drained.write_to(first)), 0)
    assert_equal(first.writes, 0)

    var nothing = List[Byte]()
    var empty = new_reader(Span(nothing))
    var second = Sink()
    assert_equal(Int(empty.write_to(second)), 0)
    assert_equal(second.writes, 0)


def test_write_to_a_writer_that_takes_only_part() raises:
    """The cursor is left after the bytes the writer took, and the count comes
    out on the failure, so the caller can pick up where it stopped."""
    var s = enc(DIGITS)
    var r = new_reader(Span(s))
    var dst = Short(4)
    var took = -1
    try:
        _ = r.write_to(dst)
    except e:
        assert_true(matches(e, ErrShortWrite))
        took = partial(e)
    assert_equal(took, 4)
    assert_equal(quote(Span(dst.data)), expect("0123"))
    assert_equal(r.len(), 6)


def test_reset() raises:
    """Go's `TestReaderReset`, with both spans from the same bytes.

    Go's `Reset` takes any `[]byte` because a slice header carries no lifetime.
    Here the span has to have the origin the reader was built with, so this
    points the reader at a different part of the same list — which is the case
    `reset` is actually for, and for a different source there is `new_reader`,
    which is two words and no allocation. `deviations.md` has the row.

    The rune position is cleared along with the cursor, so an `unread_rune`
    straight after a `reset` is refused.
    """
    var s = enc("世界abcdef")
    # An immutable view, because the reader keeps the origin and `reset` is
    # handed a second span over the same bytes: two mutable ones cannot both be
    # live in the same call.
    var view = Span(s).as_imm()
    var r = new_reader(view)
    var _rune, _width = r.read_rune()

    r.reset(view[6 : len(view)])
    with assert_raises():
        r.unread_rune()
    assert_equal(r.len(), 6)
    var rest = read_all(r)
    assert_equal(quote(Span(rest)), expect("abcdef"))


def test_a_reader_over_nothing() raises:
    """Go's `TestReaderZero`: every read on an empty reader reports the end and
    `len()` is zero rather than negative."""
    var nothing = List[Byte]()
    var r = new_reader(Span(nothing))
    assert_equal(r.len(), 0)
    assert_equal(Int(r.size()), 0)

    var window = List[Byte](length=4, fill=0)
    with assert_raises():
        _ = r.read(Span(window))
    with assert_raises():
        _ = r.read_at(Span(window), 11)
    with assert_raises():
        _ = r.read_byte()
    with assert_raises():
        _ = r.read_rune()
    with assert_raises():
        r.unread_byte()
    with assert_raises():
        r.unread_rune()
    assert_equal(Int(r.seek(0, SEEK_END)), 0)


def test_a_reader_feeds_a_buffer() raises:
    """The two types in this package meeting, which is how most callers use
    them: bytes in memory read as a stream into something that collects them.

    `Buffer.read_from` and `Reader.write_to` are both fast paths and only one
    of them can run, which is what `capabilities` is for elsewhere in
    `core.io`; either way the bytes arrive once and in order.
    """
    var s = enc(DIGITS)
    var r = new_reader(Span(s))
    var b = Buffer()
    assert_equal(Int(b.read_from(r)), 10)
    assert_equal(b.string(), DIGITS)
