"""`ReadWriter`. Go's `bufio.ReadWriter`, which has no upstream tests at all.

Go's `bufio_test.go` tests `NewReadWriter` and nothing else, because everything
else is method promotion through two embedded pointers and there is nothing
there to be wrong. Here the forwarding is written out by hand, so there is: a
method wired to the wrong half, or wired to the right half and dropping its
return value, would compile and pass no test that did not exist.

So every forwarded method is called at least once, and the two halves are given
different content so that a call that reached the wrong one shows up as wrong
bytes rather than as a coincidence.
"""

from std.testing import assert_equal, assert_true

from core.bufio import (
    ReadWriter,
    new_read_writer,
    new_reader_size,
    new_writer_size,
)
from core.errors import matches
from core.io import EOF, Byte, READER_FROM, WRITER_TO

from tests.bufio._fixtures import (
    Fixed,
    Half,
    NEWLINE,
    Sink,
    as_bytes,
    as_text,
)


def joined(src: String) raises -> ReadWriter[Fixed, Sink]:
    """A read writer over a fixed source and a collecting sink."""
    return new_read_writer(
        new_reader_size(Fixed(src), 16), new_writer_size(Sink(), 16)
    )


def test_the_two_halves_are_independent() raises:
    """The one thing Go's own test checks, and the reason it is worth checking:
    reading does not touch the sink and writing does not touch the source."""
    var rw = joined("from the source\n")
    _ = rw.write_string("to the sink")
    assert_equal(rw.read_string(NEWLINE), "from the source\n")
    assert_equal(len(rw.writer.w.got), 0)
    rw.flush()
    assert_equal(rw.writer.w.text(), "to the sink")


def test_the_halves_are_reachable_by_name() raises:
    """`buffered`, `size` and `reset` are not forwarded, because each of them
    means two different things here. Go has the same ambiguity and resolves it
    the same way, one mistake later."""
    var rw = joined("abcdef")
    assert_equal(rw.reader.size(), 16)
    assert_equal(rw.writer.size(), 16)
    _ = rw.read_byte()
    _ = rw.write_string("xy")
    assert_equal(rw.reader.buffered(), 5)
    assert_equal(rw.writer.buffered(), 2)


def test_peek_and_discard_forward() raises:
    var rw = joined("abcdef")
    assert_equal(as_text(rw.peek(3)), "abc")
    assert_equal(rw.discard(2), 2)
    assert_equal(rw.read_byte(), Byte(ord("c")))


def test_read_forwards() raises:
    var rw = joined("abcdef")
    var buf = List[Byte](length=3, fill=0)
    assert_equal(rw.read(Span(buf)), 3)
    assert_equal(as_text(buf), "abc")


def test_unread_byte_forwards() raises:
    var rw = joined("abc")
    _ = rw.read_byte()
    rw.unread_byte()
    assert_equal(rw.read_byte(), Byte(ord("a")))


def test_read_rune_and_unread_rune_forward() raises:
    var rw = joined("€x")
    var value: Int32
    var width: Int
    value, width = rw.read_rune()
    assert_equal(Int(value), 0x20AC)
    assert_equal(width, 3)
    rw.unread_rune()
    value, width = rw.read_rune()
    assert_equal(Int(value), 0x20AC)


def test_read_slice_and_read_bytes_forward() raises:
    var rw = joined("one\ntwo\n")
    assert_equal(as_text(rw.read_slice(NEWLINE)), "one\n")
    assert_equal(as_text(rw.read_bytes(NEWLINE)), "two\n")


def test_read_line_forwards() raises:
    var rw = joined("one\r\ntwo")
    var line = rw.read_line()
    assert_equal(as_text(line[0]), "one")
    assert_true(not line[1])


def test_read_string_forwards() raises:
    var rw = joined("hello\n")
    assert_equal(rw.read_string(NEWLINE), "hello\n")


def test_write_byte_and_write_string_forward() raises:
    var rw = joined("")
    rw.write_byte(Byte(ord("a")))
    assert_equal(rw.write_string("bc"), 2)
    rw.flush()
    assert_equal(rw.writer.w.text(), "abc")


def test_write_forwards_and_returns_the_length() raises:
    var rw = joined("")
    var data = as_bytes("hello")
    assert_equal(rw.write(Span(data)), 5)
    rw.flush()
    assert_equal(rw.writer.w.text(), "hello")


def test_write_rune_forwards() raises:
    var rw = joined("")
    assert_equal(rw.write_rune(Int32(0x20AC)), 3)
    rw.flush()
    assert_equal(rw.writer.w.text(), "€")


def test_available_forwards_to_the_writer() raises:
    var rw = joined("abcdef")
    assert_equal(rw.available(), 16)
    _ = rw.write_string("xy")
    assert_equal(rw.available(), 14)


def test_write_to_pushes_the_source_somewhere_else() raises:
    """Not into this value's own sink, which is the thing the name invites and
    the docstring warns about."""
    var rw = joined("hello world")
    var elsewhere = Sink()
    assert_equal(Int(rw.write_to(elsewhere)), 11)
    assert_equal(elsewhere.text(), "hello world")
    assert_equal(len(rw.writer.w.got), 0)


def test_read_from_drains_something_else_into_the_sink() raises:
    var rw = joined("")
    var src = Half("hello world")
    assert_equal(Int(rw.read_from(src)), 11)
    rw.flush()
    assert_equal(rw.writer.w.text(), "hello world")


def test_capabilities_claims_both_fast_paths() raises:
    var rw = joined("")
    assert_equal(rw.capabilities() & WRITER_TO, WRITER_TO)
    assert_equal(rw.capabilities() & READER_FROM, READER_FROM)


def test_the_end_of_the_source_still_ends() raises:
    var rw = joined("a")
    assert_equal(rw.read_byte(), Byte(ord("a")))
    var raised = False
    try:
        _ = rw.read_byte()
    except e:
        raised = True
        assert_true(matches(e, EOF))
    assert_true(raised)


def test_a_conversation_reads_and_writes_in_turn() raises:
    """What the type is for: a line in, a line out, over one buffered pair."""
    var rw = joined("one\ntwo\nthree\n")
    while True:
        var line: String
        try:
            line = rw.read_string(NEWLINE)
        except e:
            break
        _ = rw.write_string(line)
    rw.flush()
    assert_equal(rw.writer.w.text(), "one\ntwo\nthree\n")
