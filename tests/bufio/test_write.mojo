"""The buffered writer. Go's `bufio/bufio_test.go`, writer half.

Two things get most of the attention. The first is that nothing is written
until `flush`, which is the mistake everybody makes once and is worth a test
that fails loudly if it ever stops being true. The second is that a writer
whose sink has broken stays broken: Go keeps the error in `b.err` and every
method returns it without touching the sink again, and a version that forgot to
would look like it was working while discarding bytes.

`Partial` is the sink that breaks `io.Writer`'s contract by taking half of what
it is given without saying anything, and it is here because `ErrShortWrite`
exists for exactly it.
"""

from std.testing import assert_equal, assert_true

from core.bufio import Writer, new_writer, new_writer_size
from core.errors import matches, partial
from core.io import Byte, ErrShortWrite

from tests.bufio._fixtures import (
    Cracked,
    Fixed,
    Half,
    Partial,
    Sink,
    as_bytes,
    as_text,
)


def test_a_size_below_the_floor_is_raised_to_it() raises:
    var w = new_writer_size(Sink(), 1)
    assert_equal(w.size(), 16)


def test_the_default_size_is_gos() raises:
    var w = new_writer(Sink())
    assert_equal(w.size(), 4096)


def test_nothing_is_written_before_flush() raises:
    var w = new_writer_size(Sink(), 64)
    _ = w.write_string("hello")
    assert_equal(len(w.w.got), 0)
    assert_equal(w.buffered(), 5)
    w.flush()
    assert_equal(w.w.text(), "hello")
    assert_equal(w.buffered(), 0)


def test_many_small_writes_become_one() raises:
    """The reason the package exists, the other way round from the reader."""
    var w = new_writer_size(Sink(), 64)
    for _ in range(10):
        w.write_byte(Byte(ord("x")))
    w.flush()
    assert_equal(w.w.writes, 1)
    assert_equal(w.w.text(), "xxxxxxxxxx")


def test_available_and_buffered_add_up_to_the_size() raises:
    var w = new_writer_size(Sink(), 32)
    _ = w.write_string("abc")
    assert_equal(w.buffered(), 3)
    assert_equal(w.available(), 29)
    assert_equal(w.buffered() + w.available(), w.size())


def test_a_write_that_overflows_the_buffer_flushes_it_first() raises:
    var w = new_writer_size(Sink(), 16)
    _ = w.write_string("0123456789")
    _ = w.write_string("abcdefghij")
    w.flush()
    assert_equal(w.w.text(), "0123456789abcdefghij")


def test_a_write_larger_than_the_buffer_goes_straight_through() raises:
    """Go's optimisation and it is observable: the sink sees one write of the
    caller's length rather than two of the buffer's."""
    var w = new_writer_size(Sink(), 16)
    _ = w.write_string("0123456789012345678901234567890123456789")
    assert_equal(w.w.writes, 1)
    assert_equal(len(w.w.got), 40)


def test_write_returns_the_whole_length() raises:
    var w = new_writer_size(Sink(), 16)
    var data = as_bytes("hello")
    assert_equal(w.write(Span(data)), 5)


def test_write_rune_encodes_utf8() raises:
    var w = new_writer_size(Sink(), 32)
    assert_equal(w.write_rune(Int32(ord("a"))), 1)
    assert_equal(w.write_rune(Int32(0xA2)), 2)
    assert_equal(w.write_rune(Int32(0x20AC)), 3)
    assert_equal(w.write_rune(Int32(0x10348)), 4)
    w.flush()
    assert_equal(w.w.text(), "a¢€𐍈")


def test_write_rune_across_a_flush_boundary() raises:
    """A rune that does not fit in what is left forces a flush rather than
    being split, which is the case the minimum buffer size is for."""
    var w = new_writer_size(Sink(), 16)
    for _ in range(15):
        w.write_byte(Byte(ord("x")))
    assert_equal(w.write_rune(Int32(0x10348)), 4)
    w.flush()
    assert_equal(w.w.text(), "xxxxxxxxxxxxxxx𐍈")


def test_write_rune_substitutes_for_a_value_that_is_not_a_code_point() raises:
    var w = new_writer_size(Sink(), 32)
    assert_equal(w.write_rune(Int32(0x110000)), 3)
    w.flush()
    assert_equal(w.w.text(), "�")


def test_reset_throws_the_buffered_bytes_away() raises:
    var w = new_writer_size(Sink(), 32)
    _ = w.write_string("lost")
    w.reset(Sink())
    assert_equal(w.buffered(), 0)
    _ = w.write_string("kept")
    w.flush()
    assert_equal(w.w.text(), "kept")


def test_a_sink_that_fails_makes_the_writer_stick() raises:
    """The failure is sticky, so a program cannot carry on filling a buffer
    that will never be emptied."""
    var w = new_writer_size(Cracked(4), 16)
    _ = w.write_string("abcdefgh")
    var first = False
    try:
        w.flush()
    except e:
        first = True
    assert_true(first)

    var second = False
    try:
        _ = w.write_string("more")
    except e:
        second = True
    assert_true(second)

    var third = False
    try:
        w.flush()
    except e:
        third = True
    assert_true(third)


def test_reset_clears_a_stuck_writer() raises:
    var w = new_writer_size(Cracked(0), 16)
    _ = w.write_string("abc")
    try:
        w.flush()
    except e:
        pass
    w.reset(Cracked(64))
    _ = w.write_string("fine")
    w.flush()
    assert_equal(len(w.w.got), 4)


def test_a_sink_that_takes_only_part_says_short_write() raises:
    """`Partial` breaks `io.Writer`'s contract by returning a short count with
    no error, and this is what stands between that and bytes vanishing."""
    var w = new_writer_size(Partial(), 16)
    _ = w.write_string("abcdefgh")
    var raised = False
    try:
        w.flush()
    except e:
        raised = True
        assert_true(matches(e, ErrShortWrite))
        assert_equal(partial(e), 4)
    assert_true(raised)


def test_the_unwritten_remainder_stays_at_the_front_of_the_buffer() raises:
    var w = new_writer_size(Partial(), 16)
    _ = w.write_string("abcdefgh")
    try:
        w.flush()
    except e:
        pass
    # Four went, four are left, and they are the last four rather than any
    # four: a slide written the wrong way round loses which is which.
    assert_equal(w.buffered(), 4)
    assert_equal(w.w.text(), "abcd")


def test_read_from_drains_a_reader() raises:
    var w = new_writer_size(Sink(), 16)
    var src = Fixed("hello world")
    assert_equal(Int(w.read_from(src)), 11)
    w.flush()
    assert_equal(w.w.text(), "hello world")


def test_read_from_over_a_half_reader() raises:
    var w = new_writer_size(Sink(), 16)
    var src = Half("hello world")
    assert_equal(Int(w.read_from(src)), 11)
    w.flush()
    assert_equal(w.w.text(), "hello world")


def test_read_from_of_an_empty_reader_is_zero() raises:
    var w = new_writer_size(Sink(), 16)
    var src = Fixed("")
    assert_equal(Int(w.read_from(src)), 0)


def test_read_from_does_not_flush() raises:
    """Nothing here flushes, and this is the call most likely to be assumed to.
    """
    var w = new_writer_size(Sink(), 4096)
    var src = Fixed("hello")
    _ = w.read_from(src)
    assert_equal(len(w.w.got), 0)
    assert_equal(w.buffered(), 5)
