"""The streaming encoder and decoder, in the awkward sizes.

The whole reason both types exist is the remainder between calls, so most of
these write or read in pieces that are not multiples of three or four. Go's
`TestEncoderBuffering` and `TestDecoderBuffering` do the same thing by walking
the buffer size from one upwards, and that is what the two loops here are.
"""

from std.testing import assert_equal, assert_true

from core.encoding.base64 import (
    new_decoder,
    new_encoder,
    raw_std_encoding,
    std_encoding,
)
from core.errors import matches
from core.errors.codes import EOF, ErrUnexpectedEOF
from core.io import read_all
from tests.generated.base64 import pairs_rows

from ._fixtures import Fixed, OneByte, Sink, as_hex, as_text

comptime _BIG_DECODED = "Twas brillig, and the slithy toves"
"""Go's `bigtest` again, which is what its buffering tests are run over."""

comptime _BIG_ENCODED = "VHdhcyBicmlsbGlnLCBhbmQgdGhlIHNsaXRoeSB0b3Zlcw=="
"""What it encodes to."""


def test_encoder_over_the_pairs() raises:
    """Go's `TestEncoder`. One write and a close, per row."""
    var rows = pairs_rows()
    for i in range(len(rows)):
        var enc = new_encoder(std_encoding(), Sink())
        _ = enc.write(Span(rows[i].decoded))
        enc.close()
        assert_equal(as_text(enc.w.got), as_text(rows[i].encoded))


def test_encoder_buffering() raises:
    """Go's `TestEncoderBuffering`: the same bytes in every size of piece."""
    var input = _BIG_DECODED.as_bytes()
    for size in range(1, 12):
        var enc = new_encoder(std_encoding(), Sink())
        var at = 0
        while at < len(input):
            var end = at + size
            if end > len(input):
                end = len(input)
            var took = enc.write(input[at:end])
            assert_equal(took, end - at)
            at = end
        enc.close()
        assert_equal(enc.w.text(), _BIG_ENCODED)


def test_an_unclosed_encoder_holds_the_last_group_back() raises:
    """The mistake everybody makes once, pinned so it stays a known one."""
    var enc = new_encoder(std_encoding(), Sink())
    _ = enc.write("foobar".as_bytes())
    _ = enc.write("!".as_bytes())
    assert_equal(enc.w.text(), "Zm9vYmFy")
    enc.close()
    assert_equal(enc.w.text(), "Zm9vYmFyIQ==")


def test_closing_twice_writes_nothing_the_second_time() raises:
    var enc = new_encoder(std_encoding(), Sink())
    _ = enc.write("f".as_bytes())
    enc.close()
    var after = enc.w.writes
    enc.close()
    assert_equal(enc.w.writes, after)
    assert_equal(enc.w.text(), "Zg==")


def test_decoder_over_the_pairs() raises:
    """Go's `TestDecoder`, through a reader that fills what it is given."""
    var rows = pairs_rows()
    for i in range(len(rows)):
        var text = as_text(rows[i].encoded)
        var dec = new_decoder(std_encoding(), Fixed(text))
        assert_equal(as_hex(read_all(dec)), as_hex(rows[i].decoded))


def test_decoder_one_byte_at_a_time() raises:
    """Go's `TestDecoderBuffering`, in its harshest form.

    A decoder that assumed a read filled the span would decode the first
    character on its own and get nothing out of it.
    """
    var dec = new_decoder(std_encoding(), OneByte(_BIG_ENCODED))
    assert_equal(as_text(read_all(dec)), _BIG_DECODED)


def test_decoder_skips_newlines() raises:
    """What lets this read the base64 out of a PEM file or a MIME body."""
    var wrapped = "VHdhcyBicmlsbGlnLCBhbmQg\r\ndGhlIHNsaXRoeSB0b3Zlcw==\r\n"
    var dec = new_decoder(std_encoding(), Fixed(wrapped))
    assert_equal(as_text(read_all(dec)), _BIG_DECODED)


def test_decoder_of_nothing_is_nothing() raises:
    var dec = new_decoder(std_encoding(), Fixed(""))
    assert_equal(len(read_all(dec)), 0)


def test_decoder_raw() raises:
    """Go's `TestDecoderRaw`: an unpadded stream ends on a partial group."""
    var dec = new_decoder(raw_std_encoding(), Fixed("aGVsbG8"))
    assert_equal(as_text(read_all(dec)), "hello")


def test_a_truncated_group_is_unexpected_eof() raises:
    """A padded encoding cannot end in the middle of a group."""
    var dec = new_decoder(std_encoding(), Fixed("aGVsbG8"))
    var refused = False
    try:
        _ = read_all(dec)
    except e:
        refused = True
        assert_true(matches(e, ErrUnexpectedEOF))
    assert_true(refused)


def test_a_corrupt_group_arrives_after_the_bytes_before_it() raises:
    """`io.Reader` here never hands over bytes and a failure at once."""
    var dec = new_decoder(std_encoding(), Fixed("Zm9vYmFy!!!!"))
    var into = List[UInt8](length=32, fill=0)
    var got = dec.read(Span(into))
    assert_equal(got, 6)
    into.resize(6, 0)
    assert_equal(as_text(into), "foobar")

    var refused = False
    var again = List[UInt8](length=32, fill=0)
    try:
        _ = dec.read(Span(again))
    except:
        refused = True
    assert_true(refused)


def test_a_stream_round_trips_at_every_size() raises:
    """Go's `TestBig`, through both streams rather than through the tables."""
    comptime alpha = (
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    )
    var letters = alpha.as_bytes()
    var raw = List[UInt8]()
    for i in range(3 * 1000 + 1):
        raw.append(letters[i % len(letters)])

    var enc = new_encoder(std_encoding(), Sink())
    var wrote = enc.write(Span(raw))
    assert_equal(wrote, len(raw))
    enc.close()

    var dec = new_decoder(std_encoding(), Fixed(enc.w.got.copy()))
    var back = read_all(dec)
    assert_equal(len(back), len(raw))
    for i in range(len(raw)):
        assert_equal(back[i], raw[i])
