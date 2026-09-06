"""The streaming pair, in every awkward size. Go's six streaming tests.

Go writes the big row in every block size from one to twelve and reads it back
in every block size from one to twelve, which is the point of the whole file: a
group is four bytes going in and five characters coming out, so no block size
under twelve divides both, and every one of them leaves the encoder or the
decoder holding a fragment between calls.
"""

from std.testing import assert_equal, assert_true

from core.encoding.ascii85 import (
    CorruptInputError,
    new_decoder,
    new_encoder,
)
from core.errors import matches
from core.errors.codes import EOF
from core.io import read_all
from tests.generated.ascii85 import pairs_rows

from ._fixtures import Fixed, OneByte, Sink, as_text, bytes_of, strip85


def test_encoder() raises:
    """Go's `TestEncoder`: every row written whole and closed."""
    var rows = pairs_rows()
    for i in range(len(rows)):
        var enc = new_encoder(Sink())
        _ = enc.write(Span(rows[i].decoded))
        enc.close()
        assert_equal(strip85(Span(enc.w.got)), strip85(Span(rows[i].encoded)))


def test_encoder_buffering() raises:
    """Go's `TestEncoderBuffering`: the big row in blocks of one to twelve."""
    var rows = pairs_rows()
    var data = rows[1].decoded.copy()
    var want = strip85(Span(rows[1].encoded))
    for size in range(1, 13):
        var enc = new_encoder(Sink())
        var at = 0
        while at < len(data):
            var end = at + size
            if end > len(data):
                end = len(data)
            var took = enc.write(Span(data)[at:end])
            assert_equal(took, end - at)
            at = end
        enc.close()
        assert_equal(strip85(Span(enc.w.got)), want)


def test_an_encoder_has_to_be_closed() raises:
    """The last group is inside the encoder until `close` gets it out.

    This is the one mistake this package invites, so it is the one assertion
    worth making twice: nothing at all before the close, the whole thing after.
    """
    var enc = new_encoder(Sink())
    _ = enc.write(bytes_of("Man"))
    assert_equal(enc.w.text(), "")
    enc.close()
    assert_equal(enc.w.text(), "9jqo")


def test_closing_twice_writes_nothing_more() raises:
    """The held bytes are gone after the first close, so the second is quiet."""
    var enc = new_encoder(Sink())
    _ = enc.write(bytes_of("Man"))
    enc.close()
    var writes = enc.w.writes
    enc.close()
    assert_equal(enc.w.writes, writes)
    assert_equal(enc.w.text(), "9jqo")


def test_an_encoder_writes_whole_groups_as_they_arrive() raises:
    """Four bytes in is five characters out, before any close."""
    var enc = new_encoder(Sink())
    _ = enc.write(bytes_of("Man "))
    assert_equal(enc.w.text(), "9jqo^")
    enc.close()
    assert_equal(enc.w.text(), "9jqo^")


def test_decoder() raises:
    """Go's `TestDecoder`: every row read to the end."""
    var rows = pairs_rows()
    for i in range(len(rows)):
        var dec = new_decoder(Fixed(rows[i].encoded.copy()))
        assert_equal(as_text(read_all(dec)), as_text(rows[i].decoded))


def test_decoder_buffering() raises:
    """Go's `TestDecoderBuffering`: the big row read one to twelve at a time."""
    var rows = pairs_rows()
    var want = as_text(rows[1].decoded)
    for size in range(1, 13):
        var dec = new_decoder(Fixed(rows[1].encoded.copy()))
        var all = List[UInt8]()
        var buf = List[UInt8](length=size, fill=0)
        while True:
            var got = 0
            try:
                got = dec.read(Span(buf))
            except:
                break
            for j in range(got):
                all.append(buf[j])
        assert_equal(as_text(all), want)


def test_decoder_one_character_at_a_time() raises:
    """A group split across five reads, which is what the buffer is for."""
    var dec = new_decoder(OneByte("9jqo^BlbD-"))
    assert_equal(as_text(read_all(dec)), "Man is d")


def test_decoder_of_nothing_is_nothing() raises:
    var dec = new_decoder(Fixed(""))
    assert_equal(len(read_all(dec)), 0)


def test_big() raises:
    """Go's `TestBig`: three thousand and one bytes, out and back.

    The odd byte on the end is deliberate. Three thousand divides by four and
    the extra one does not, so the last group is short and the round trip only
    closes if `close` and `flush` agree about what a short group means.
    """
    comptime alpha = (
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    )
    var table = alpha.as_bytes()
    var raw = List[UInt8](capacity=3001)
    for i in range(3001):
        raw.append(table[i % len(table)])

    var enc = new_encoder(Sink())
    var took = enc.write(Span(raw))
    assert_equal(took, len(raw))
    enc.close()

    var dec = new_decoder(Fixed(enc.w.got.copy()))
    assert_equal(as_text(read_all(dec)), as_text(raw))


def test_decoder_internal_whitespace() raises:
    """Go's `TestDecoderInternalWhitespace`: two buffers of spaces, then a `z`.

    Two thousand and forty eight spaces is twice the decoder's buffer, so the
    buffer fills with nothing that decodes and has to be squeezed out to make
    room for the one character that does. A decoder that only skipped
    whitespace inside a group would stop dead here.
    """
    var data = List[UInt8]()
    for _ in range(2048):
        data.append(UInt8(ord(" ")))
    data.append(UInt8(ord("z")))
    var dec = new_decoder(Fixed(data^))
    var got = read_all(dec)
    assert_equal(len(got), 4)
    for b in got:
        assert_equal(b, UInt8(0))


def test_decoder_refuses_a_corrupt_stream() raises:
    """A bad character loses the good bytes that shared its buffer.

    The odd one out in this directory. Everywhere else a decoder hands over
    what decoded before the failure and raises on the next call, and here the
    four bytes of `Man ` never arrive at all, because `decode` reports nothing
    decoded when it refuses and the whole buffer went in at once. Go does the
    same, for the same reason, and it is on the deviations page.

    The offset is into what the decoder was holding rather than into the whole
    stream, which is Go's limit too: `decode` counts from the front of what it
    was given.
    """
    var dec = new_decoder(Fixed("9jqo^v"))
    var buf = List[UInt8](length=16, fill=0)
    var refused = False
    try:
        _ = dec.read(Span(buf))
    except e:
        refused = True
        var bad = CorruptInputError.of(e)
        assert_true(Bool(bad))
        assert_equal(bad.value().offset, Int64(5))
    assert_true(refused)


def test_a_stuck_decoder_stays_stuck() raises:
    """The failure is sticky, so a caller that ignores one is not rewarded."""
    var dec = new_decoder(Fixed("v"))
    var buf = List[UInt8](length=16, fill=0)
    for _ in range(3):
        var refused = False
        try:
            _ = dec.read(Span(buf))
        except e:
            refused = True
            assert_true(Bool(CorruptInputError.of(e)))
        assert_true(refused)


def test_a_finished_decoder_keeps_saying_so() raises:
    """`EOF` again on every read after the input ran out."""
    var dec = new_decoder(Fixed("9jqo^"))
    assert_equal(as_text(read_all(dec)), "Man ")
    var buf = List[UInt8](length=4, fill=0)
    for _ in range(2):
        var ended = False
        try:
            _ = dec.read(Span(buf))
        except e:
            ended = True
            assert_true(matches(e, EOF))
        assert_true(ended)


def test_a_stream_that_ends_mid_group() raises:
    """A short last group is completed, the same as `flush` completes one.

    Which is the difference from base32 and base64, where a truncated document
    is refused. Ascii85 has no padding to be missing: a group of two, three or
    four characters is a legal ending and spells one, two or three bytes.
    """
    var dec = new_decoder(Fixed("9jqo^Blb"))
    assert_equal(as_text(read_all(dec)), "Man is")


def test_a_stream_ending_in_one_character_is_refused() raises:
    """The one ending that is not legal, through the decoder this time."""
    var dec = new_decoder(Fixed("9jqo^B"))
    var buf = List[UInt8](length=16, fill=0)
    var got = dec.read(Span(buf))
    assert_equal(got, 4)
    buf.resize(4, 0)
    assert_equal(as_text(buf), "Man ")

    var refused = False
    var again = List[UInt8](length=16, fill=0)
    try:
        _ = dec.read(Span(again))
    except e:
        refused = True
        var bad = CorruptInputError.of(e)
        assert_true(Bool(bad))
        assert_equal(bad.value().offset, Int64(1))
    assert_true(refused)
