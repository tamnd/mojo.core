"""The streaming pair, in the awkward sizes. Go's `TestEncoderDecoder`.

Go copies through both with a seven byte buffer, which is odd on purpose: seven
bytes is three and a half pairs, so every chunk boundary falls in the middle of
one and the decoder has to hold a character back. The loops here do the same by
hand, since there is no `io.CopyBuffer` shape that would make the buffer size
visible otherwise.
"""

from std.testing import assert_equal, assert_true

from core.encoding.hex import (
    InvalidByteError,
    new_decoder,
    new_encoder,
)
from core.errors import matches
from core.errors.codes import EOF, ErrUnexpectedEOF
from core.io import read_all
from tests.generated.hex import enc_dec_tests_rows

from ._fixtures import Fixed, OneByte, Sink, as_bytes, hex_of


def test_encoder_over_the_rows() raises:
    """Every row, written in one go and in sevens."""
    var rows = enc_dec_tests_rows()
    for i in range(len(rows)):
        var dec = as_bytes(rows[i].dec)

        var whole = new_encoder(Sink())
        _ = whole.write(Span(dec))
        assert_equal(whole.w.text(), rows[i].enc)

        var pieces = new_encoder(Sink())
        var at = 0
        while at < len(dec):
            var end = at + 7
            if end > len(dec):
                end = len(dec)
            var took = pieces.write(Span(dec)[at:end])
            assert_equal(took, end - at)
            at = end
        assert_equal(pieces.w.text(), rows[i].enc)


def test_an_encoder_holds_nothing_back() raises:
    """The difference from every other stream encoder in this directory.

    One byte is two characters, so there is no group to complete and no `close`
    to forget. This is the assertion that says so.
    """
    var enc = new_encoder(Sink())
    _ = enc.write("f".as_bytes())
    assert_equal(enc.w.text(), "66")
    _ = enc.write("oo".as_bytes())
    assert_equal(enc.w.text(), "666f6f")


def test_encoder_over_a_long_input() raises:
    """More than the 1024 character buffer, so the chunking is exercised."""
    var data = List[UInt8]()
    for i in range(3000):
        data.append(UInt8(i % 256))
    var enc = new_encoder(Sink())
    var took = enc.write(Span(data))
    assert_equal(took, len(data))
    assert_equal(enc.w.text(), hex_of(data))


def test_decoder_over_the_rows() raises:
    """Go's decoder half of `TestEncoderDecoder`, read to the end."""
    var rows = enc_dec_tests_rows()
    for i in range(len(rows)):
        var dec = new_decoder(Fixed(rows[i].enc))
        assert_equal(hex_of(read_all(dec)), hex_of(as_bytes(rows[i].dec)))


def test_decoder_into_a_small_buffer() raises:
    """Every buffer size from one to nine, which straddles a pair either way."""
    var rows = enc_dec_tests_rows()
    for size in range(1, 10):
        for i in range(len(rows)):
            var dec = new_decoder(Fixed(rows[i].enc))
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
            assert_equal(hex_of(all), hex_of(as_bytes(rows[i].dec)))


def test_decoder_one_byte_at_a_time() raises:
    """Every pair split across two reads, which is the case the buffer is for.

    A decoder that assumed a read filled the span would try to decode a single
    character and refuse a document that is perfectly good.
    """
    var dec = new_decoder(OneByte("f8f9fafbfcfdfeff"))
    assert_equal(hex_of(read_all(dec)), "f8f9fafbfcfdfeff")


def test_decoder_of_nothing_is_nothing() raises:
    var dec = new_decoder(Fixed(""))
    assert_equal(len(read_all(dec)), 0)


def test_decoder_over_a_long_input() raises:
    """More than the 1024 character buffer, so the refill is exercised."""
    var data = List[UInt8]()
    for i in range(3000):
        data.append(UInt8(i % 256))
    var dec = new_decoder(Fixed(hex_of(data)))
    assert_equal(hex_of(read_all(dec)), hex_of(data))


def test_a_stream_that_ends_mid_pair() raises:
    """`ErrUnexpectedEOF` here where `decode` raises `ErrLength`.

    Go draws the same line and documents it on `ErrLength`: a string was
    written down wrong, and a stream may simply not have finished arriving.
    """
    var dec = new_decoder(Fixed("0"))
    var refused = False
    try:
        _ = read_all(dec)
    except e:
        refused = True
        assert_true(matches(e, ErrUnexpectedEOF))
    assert_true(refused)


def test_the_bytes_before_a_short_ending_still_arrive() raises:
    """Go's `errTests` row `ffeed`, read through the decoder."""
    var dec = new_decoder(Fixed("ffeed"))
    var buf = List[UInt8](length=16, fill=0)
    var got = dec.read(Span(buf))
    assert_equal(got, 2)
    buf.resize(2, 0)
    assert_equal(hex_of(buf), "ffee")

    var refused = False
    var again = List[UInt8](length=16, fill=0)
    try:
        _ = dec.read(Span(again))
    except e:
        refused = True
        assert_true(matches(e, ErrUnexpectedEOF))
    assert_true(refused)


def test_a_bad_last_character_beats_the_short_ending() raises:
    """Go's `errTests` row `d4aaz`, which is odd and ends in a bad character.

    Two things are wrong and Go reports the character, because that is the one
    the caller can do something about.
    """
    var dec = new_decoder(Fixed("d4aaz"))
    var buf = List[UInt8](length=16, fill=0)
    var got = dec.read(Span(buf))
    assert_equal(got, 2)
    buf.resize(2, 0)
    assert_equal(hex_of(buf), "d4aa")

    var refused = False
    var again = List[UInt8](length=16, fill=0)
    try:
        _ = dec.read(Span(again))
    except e:
        refused = True
        var bad = InvalidByteError.of(e)
        assert_true(Bool(bad))
        assert_equal(bad.value().byte, UInt8(ord("z")))
    assert_true(refused)


def test_a_bad_character_in_the_middle() raises:
    """Go's `errTests` row `00gg`: one byte out, then the refusal."""
    var dec = new_decoder(Fixed("00gg"))
    var buf = List[UInt8](length=16, fill=0)
    var got = dec.read(Span(buf))
    assert_equal(got, 1)
    assert_equal(buf[0], UInt8(0))

    var refused = False
    var again = List[UInt8](length=16, fill=0)
    try:
        _ = dec.read(Span(again))
    except e:
        refused = True
        var bad = InvalidByteError.of(e)
        assert_true(Bool(bad))
        assert_equal(bad.value().byte, UInt8(ord("g")))
    assert_true(refused)


def test_a_stuck_decoder_stays_stuck() raises:
    """The failure is sticky, so a caller that ignores one is not rewarded."""
    var dec = new_decoder(Fixed("zz"))
    var buf = List[UInt8](length=16, fill=0)
    for _ in range(3):
        var refused = False
        try:
            _ = dec.read(Span(buf))
        except e:
            refused = True
            assert_true(Bool(InvalidByteError.of(e)))
        assert_true(refused)


def test_a_finished_decoder_keeps_saying_so() raises:
    """`EOF` again on every read after the input ran out."""
    var dec = new_decoder(Fixed("6667"))
    assert_equal(hex_of(read_all(dec)), "6667")
    var buf = List[UInt8](length=4, fill=0)
    for _ in range(2):
        var ended = False
        try:
            _ = dec.read(Span(buf))
        except e:
            ended = True
            assert_true(matches(e, EOF))
        assert_true(ended)
