"""The buffered reader. Go's `bufio/bufio_test.go`, reader half.

Almost every case here is run through `Half` or `OneByte` as well as through
`Fixed`, because a buffered reader is exactly the thing whose bugs only show
when a read comes back short: the version that assumes one read fills the
buffer passes over `Fixed` and loses bytes over the other two. Issue #14 names
that as the point of the package.

The rest is the three-outcome contract on `read_slice`, which is this package's
one real deviation from Go and therefore the part with no upstream test to copy.
"""

from std.testing import assert_equal, assert_true

from core.bufio import (
    ErrBufferFull,
    ErrInvalidUnreadByte,
    ErrInvalidUnreadRune,
    ErrNegativeCount,
    Reader,
    new_reader,
    new_reader_size,
)
from core.errors import matches, partial
from core.io import EOF, Byte

from tests.bufio._fixtures import (
    Broken,
    Fixed,
    Half,
    NEWLINE,
    OneByte,
    Sink,
    as_bytes,
    as_text,
)


def test_a_size_below_the_floor_is_raised_to_it() raises:
    var r = new_reader_size(Fixed("x"), 1)
    assert_equal(r.size(), 16)


def test_the_default_size_is_gos() raises:
    var r = new_reader(Fixed("x"))
    assert_equal(r.size(), 4096)


def test_one_read_covers_many_read_bytes() raises:
    """The reason the package exists: ten bytes out, one call in."""
    var r = new_reader_size(Fixed("abcdefghij"), 64)
    var out = String("")
    for _ in range(10):
        out += chr(Int(r.read_byte()))
    assert_equal(out, "abcdefghij")
    assert_equal(r.r.reads, 1)


def test_read_byte_over_a_one_byte_reader() raises:
    var r = new_reader_size(OneByte("abcdefghij"), 64)
    var out = String("")
    for _ in range(10):
        out += chr(Int(r.read_byte()))
    assert_equal(out, "abcdefghij")


def test_read_byte_past_the_end_is_eof() raises:
    var r = new_reader_size(Fixed("ab"), 16)
    _ = r.read_byte()
    _ = r.read_byte()
    var raised = False
    try:
        _ = r.read_byte()
    except e:
        raised = True
        assert_true(matches(e, EOF))
    assert_true(raised)


def test_buffered_counts_what_is_in_hand() raises:
    var r = new_reader_size(Fixed("abcdef"), 16)
    assert_equal(r.buffered(), 0)
    _ = r.read_byte()
    assert_equal(r.buffered(), 5)


def test_peek_does_not_consume() raises:
    var r = new_reader_size(Fixed("abcdef"), 16)
    var first = r.peek(3)
    assert_equal(as_text(first), "abc")
    var again = r.peek(3)
    assert_equal(as_text(again), "abc")
    assert_equal(as_text(r.peek(6)), "abcdef")
    assert_equal(r.read_byte(), Byte(ord("a")))


def test_peek_over_a_half_reader_still_fills() raises:
    """One read cannot satisfy this, so a `peek` without a loop fails here."""
    var r = new_reader_size(Half("abcdefghij"), 16)
    assert_equal(as_text(r.peek(10)), "abcdefghij")


def test_peek_past_the_end_raises_and_keeps_the_bytes() raises:
    """Go returns what it has with the error. Peeking consumes nothing, so
    there is nothing to hand back: the bytes are still there to peek at."""
    var r = new_reader_size(Fixed("abc"), 16)
    var raised = False
    try:
        _ = r.peek(5)
    except e:
        raised = True
        assert_true(matches(e, EOF))
    assert_true(raised)
    assert_equal(r.buffered(), 3)
    assert_equal(as_text(r.peek(3)), "abc")


def test_peek_of_more_than_the_buffer_is_buffer_full() raises:
    """And it is refused before the source is touched, because no amount of
    reading would make it succeed. A version that only noticed after filling
    the buffer would raise the same thing and have moved bytes to do it."""
    var r = new_reader_size(Fixed("abcdefghijklmnopqrst"), 16)
    var raised = False
    try:
        _ = r.peek(17)
    except e:
        raised = True
        assert_true(matches(e, ErrBufferFull))
    assert_true(raised)
    assert_equal(r.r.reads, 0)


def test_peek_of_a_negative_count_is_refused() raises:
    var r = new_reader_size(Fixed("abc"), 16)
    var raised = False
    try:
        _ = r.peek(-1)
    except e:
        raised = True
        assert_true(matches(e, ErrNegativeCount))
    assert_true(raised)


def test_read_into_a_span_shorter_than_the_buffer() raises:
    var r = new_reader_size(Fixed("abcdefghij"), 16)
    var buf = List[Byte](length=4, fill=0)
    assert_equal(r.read(Span(buf)), 4)
    assert_equal(as_text(buf), "abcd")


def test_read_of_an_empty_span_is_zero_and_does_not_end() raises:
    """`io.Reader`'s rule: an empty span cannot be used to test for the end."""
    var r = new_reader_size(Fixed(""), 16)
    var empty = List[Byte]()
    assert_equal(r.read(Span(empty)), 0)


def test_a_read_larger_than_the_buffer_goes_straight_through() raises:
    """Go's optimisation, and it is observable: the source sees the caller's
    length rather than the buffer's, so one read is enough for forty bytes."""
    var r = new_reader_size(
        Fixed("0123456789012345678901234567890123456789"), 16
    )
    var buf = List[Byte](length=40, fill=0)
    assert_equal(r.read(Span(buf)), 40)
    assert_equal(r.r.reads, 1)


def test_the_source_sees_the_callers_length_not_the_buffers() raises:
    """Which is the observable half of the straight-through path, and the half
    a read count cannot see. Over a half reader with a sixteen byte buffer, a
    twenty byte span comes back with ten bytes; a version that filled the
    buffer instead would return eight, in the same one read."""
    var r = new_reader_size(Half("0123456789abcdefghij"), 16)
    var buf = List[Byte](length=20, fill=0)
    assert_equal(r.read(Span(buf)), 10)
    assert_equal(r.r.inner.reads, 1)


def test_read_comes_back_short_like_gos() raises:
    """One read of the source per call, so this is allowed to be short even
    though the source has more. `io.read_full` is the loop."""
    var r = new_reader_size(Half("abcdefghij"), 16)
    var buf = List[Byte](length=10, fill=0)
    var got = r.read(Span(buf))
    assert_true(got > 0)
    assert_true(got < 10)


def test_unread_byte_puts_it_back() raises:
    var r = new_reader_size(Fixed("abc"), 16)
    assert_equal(r.read_byte(), Byte(ord("a")))
    r.unread_byte()
    assert_equal(r.read_byte(), Byte(ord("a")))
    assert_equal(r.read_byte(), Byte(ord("b")))


def test_unread_byte_before_any_read_is_refused() raises:
    var r = new_reader_size(Fixed("abc"), 16)
    var raised = False
    try:
        r.unread_byte()
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidUnreadByte))
    assert_true(raised)


def test_unread_byte_twice_is_refused() raises:
    var r = new_reader_size(Fixed("abc"), 16)
    _ = r.read_byte()
    r.unread_byte()
    var raised = False
    try:
        r.unread_byte()
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidUnreadByte))
    assert_true(raised)


def test_unread_byte_after_a_peek_is_refused() raises:
    """Go clears the mark in `Peek` for a reason: the buffer may have slid."""
    var r = new_reader_size(Fixed("abc"), 16)
    _ = r.read_byte()
    _ = r.peek(1)
    var raised = False
    try:
        r.unread_byte()
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidUnreadByte))
    assert_true(raised)


def test_read_rune_decodes_multibyte() raises:
    var r = new_reader_size(Fixed("a¢€𐍈"), 32)
    var value: Int32
    var width: Int
    value, width = r.read_rune()
    assert_equal(Int(value), ord("a"))
    assert_equal(width, 1)
    value, width = r.read_rune()
    assert_equal(Int(value), 0xA2)
    assert_equal(width, 2)
    value, width = r.read_rune()
    assert_equal(Int(value), 0x20AC)
    assert_equal(width, 3)
    value, width = r.read_rune()
    assert_equal(Int(value), 0x10348)
    assert_equal(width, 4)


def test_read_rune_over_a_one_byte_reader_still_joins_it_up() raises:
    """The rune arrives one byte at a time, so a reader that decoded whatever
    happened to be in the buffer would report four replacement characters."""
    var r = new_reader_size(OneByte("𐍈"), 16)
    var value: Int32
    var width: Int
    value, width = r.read_rune()
    assert_equal(Int(value), 0x10348)
    assert_equal(width, 4)


def test_read_rune_on_invalid_input_advances_one_byte() raises:
    """Go's rule, and the reason a decode loop terminates rather than sticking.
    """
    var raw = List[Byte]()
    raw.append(Byte(0xFF))
    raw.append(Byte(ord("z")))
    var r = new_reader_size(Fixed(raw^), 16)
    var value: Int32
    var width: Int
    value, width = r.read_rune()
    assert_equal(Int(value), 0xFFFD)
    assert_equal(width, 1)
    value, width = r.read_rune()
    assert_equal(Int(value), ord("z"))


def test_unread_rune_puts_the_whole_rune_back() raises:
    var r = new_reader_size(Fixed("€x"), 32)
    var value: Int32
    var width: Int
    value, width = r.read_rune()
    assert_equal(width, 3)
    r.unread_rune()
    value, width = r.read_rune()
    assert_equal(Int(value), 0x20AC)
    assert_equal(width, 3)


def test_unread_rune_after_a_byte_read_is_refused() raises:
    var r = new_reader_size(Fixed("abc"), 16)
    _ = r.read_byte()
    var raised = False
    try:
        r.unread_rune()
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidUnreadRune))
    assert_true(raised)


def test_read_slice_stops_at_the_delimiter() raises:
    var r = new_reader_size(Fixed("hello\nworld\n"), 32)
    assert_equal(as_text(r.read_slice(NEWLINE)), "hello\n")
    assert_equal(as_text(r.read_slice(NEWLINE)), "world\n")


def test_read_slice_over_a_one_byte_reader() raises:
    var r = new_reader_size(OneByte("hello\nworld\n"), 32)
    assert_equal(as_text(r.read_slice(NEWLINE)), "hello\n")
    assert_equal(as_text(r.read_slice(NEWLINE)), "world\n")


def test_read_slice_hands_over_an_unterminated_tail_then_the_reason() raises:
    """The deviation, and the reason for it. Go returns the tail together with
    the error; here the bytes come back on their own and the end arrives on the
    next call, which is `io.Reader`'s rule about bytes now."""
    var r = new_reader_size(Fixed("hello\ntail"), 32)
    assert_equal(as_text(r.read_slice(NEWLINE)), "hello\n")
    var tail = r.read_slice(NEWLINE)
    assert_equal(as_text(tail), "tail")
    var raised = False
    try:
        _ = r.read_slice(NEWLINE)
    except e:
        raised = True
        assert_true(matches(e, EOF))
    assert_true(raised)


def test_read_slice_that_fills_the_buffer_keeps_the_bytes() raises:
    """The other half of the deviation: Go hands the bytes over with
    `ErrBufferFull` and this leaves them buffered, so nothing is lost and
    `buffered()` says how much is waiting."""
    var r = new_reader_size(Fixed("0123456789abcdefghij\n"), 16)
    var raised = False
    try:
        _ = r.read_slice(NEWLINE)
    except e:
        raised = True
        assert_true(matches(e, ErrBufferFull))
        assert_equal(partial(e), 16)
    assert_true(raised)
    assert_equal(r.buffered(), 16)
    assert_equal(as_text(r.peek(4)), "0123")


def test_read_bytes_grows_past_the_buffer() raises:
    var r = new_reader_size(Fixed("0123456789abcdefghij\nrest"), 16)
    assert_equal(as_text(r.read_bytes(NEWLINE)), "0123456789abcdefghij\n")


def test_read_bytes_over_a_half_reader() raises:
    var r = new_reader_size(Half("0123456789abcdefghij\nrest"), 16)
    assert_equal(as_text(r.read_bytes(NEWLINE)), "0123456789abcdefghij\n")


def test_read_bytes_returns_the_final_unterminated_line() raises:
    var r = new_reader_size(Fixed("a\nb"), 16)
    assert_equal(as_text(r.read_bytes(NEWLINE)), "a\n")
    assert_equal(as_text(r.read_bytes(NEWLINE)), "b")


def test_read_bytes_with_nothing_left_is_eof() raises:
    var r = new_reader_size(Fixed(""), 16)
    var raised = False
    try:
        _ = r.read_bytes(NEWLINE)
    except e:
        raised = True
        assert_true(matches(e, EOF))
    assert_true(raised)


def test_read_string_reads_text() raises:
    var r = new_reader_size(Fixed("héllo\nx"), 32)
    assert_equal(r.read_string(NEWLINE), "héllo\n")


def test_read_string_refuses_bytes_that_are_not_utf8() raises:
    """Stricter than Go on purpose: a Mojo `String` claims to be UTF-8 and
    there is no honest way to make one out of this. `read_bytes` is the way."""
    var raw = List[Byte]()
    raw.append(Byte(0xFF))
    raw.append(NEWLINE)
    var r = new_reader_size(Fixed(raw^), 16)
    var raised = False
    try:
        _ = r.read_string(NEWLINE)
    except e:
        raised = True
    assert_true(raised)


def test_read_line_strips_both_endings() raises:
    var r = new_reader_size(Fixed("one\r\ntwo\nthree"), 32)
    # One `var` per call rather than reassigning a pair, because a `List` is
    # not implicitly copyable and unpacking into an existing name would copy.
    var first = r.read_line()
    assert_equal(as_text(first[0]), "one")
    assert_true(not first[1])
    var second = r.read_line()
    assert_equal(as_text(second[0]), "two")
    assert_true(not second[1])
    var third = r.read_line()
    assert_equal(as_text(third[0]), "three")
    assert_true(not third[1])


def test_read_line_says_when_a_line_was_cut() raises:
    var r = new_reader_size(Fixed("0123456789abcdefghij\n"), 16)
    var front = r.read_line()
    assert_equal(len(front[0]), 16)
    assert_true(front[1])
    var rest = r.read_line()
    assert_equal(as_text(rest[0]), "ghij")
    assert_true(not rest[1])


def test_read_line_does_not_split_a_carriage_return_from_its_newline() raises:
    """A cut line ending in `\\r` puts the `\\r` back, because it might be the
    first half of an ending whose second half has not arrived."""
    var r = new_reader_size(Fixed("0123456789abcde\r\nx"), 16)
    var front = r.read_line()
    assert_equal(as_text(front[0]), "0123456789abcde")
    assert_true(front[1])
    var rest = r.read_line()
    assert_equal(as_text(rest[0]), "")
    assert_true(not rest[1])


def test_a_cut_line_that_ends_in_a_carriage_return_keeps_it() raises:
    """The other half of the rule above. The `\\r` goes back because it might
    be the first byte of an ending; when the next byte turns out not to be a
    newline it is an ordinary byte and has to still be in the stream. A version
    that dropped it passes the test above, where the newline does arrive."""
    var r = new_reader_size(Fixed("0123456789abcde\rx"), 16)
    var front = r.read_line()
    assert_equal(as_text(front[0]), "0123456789abcde")
    assert_true(front[1])
    var rest = r.read_line()
    assert_equal(as_text(rest[0]), "\rx")
    assert_true(not rest[1])


def test_discard_skips_and_says_how_many() raises:
    var r = new_reader_size(Fixed("abcdefghij"), 16)
    assert_equal(r.discard(4), 4)
    assert_equal(r.read_byte(), Byte(ord("e")))


def test_discard_past_the_end_says_how_far_it_got() raises:
    var r = new_reader_size(Fixed("abc"), 16)
    var raised = False
    try:
        _ = r.discard(10)
    except e:
        raised = True
        assert_true(matches(e, EOF))
        assert_equal(partial(e), 3)
    assert_true(raised)


def test_discard_of_zero_is_nothing() raises:
    var r = new_reader_size(Fixed("abc"), 16)
    assert_equal(r.discard(0), 0)
    assert_equal(r.r.reads, 0)


def test_discard_more_than_the_buffer_holds() raises:
    var r = new_reader_size(Half("0123456789abcdefghij"), 16)
    assert_equal(r.discard(18), 18)
    assert_equal(r.read_byte(), Byte(ord("i")))


def test_reset_starts_again() raises:
    var r = new_reader_size(Fixed("abcdef"), 16)
    _ = r.read_byte()
    r.reset(Fixed("xyz"))
    assert_equal(r.buffered(), 0)
    assert_equal(r.read_byte(), Byte(ord("x")))


def test_a_failure_arrives_after_the_buffered_bytes() raises:
    """`io.Reader`'s contract, and this is the type it was written for."""
    var r = new_reader_size(Broken("abc"), 16)
    assert_equal(r.read_byte(), Byte(ord("a")))
    assert_equal(r.read_byte(), Byte(ord("b")))
    assert_equal(r.read_byte(), Byte(ord("c")))
    var raised = False
    try:
        _ = r.read_byte()
    except e:
        raised = True
        assert_true(not matches(e, EOF))
    assert_true(raised)


def test_write_to_moves_everything() raises:
    var r = new_reader_size(Fixed("hello world"), 16)
    var dst = Sink()
    assert_equal(Int(r.write_to(dst)), 11)
    assert_equal(dst.text(), "hello world")


def test_write_to_after_some_reading_moves_the_rest() raises:
    var r = new_reader_size(Fixed("hello world"), 16)
    _ = r.read_byte()
    var dst = Sink()
    assert_equal(Int(r.write_to(dst)), 10)
    assert_equal(dst.text(), "ello world")


def test_write_to_over_a_half_reader() raises:
    var r = new_reader_size(Half("hello world"), 16)
    var dst = Sink()
    assert_equal(Int(r.write_to(dst)), 11)
    assert_equal(dst.text(), "hello world")
