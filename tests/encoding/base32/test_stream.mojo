"""The streaming encoder and decoder, in the awkward sizes.

The whole reason both types exist is the remainder between calls, so most of
these write or read in pieces that are not multiples of five or eight. Go's
`TestEncoderBuffering` and `TestDecoderBuffering` do the same thing by walking
the buffer size from one upwards, and that is what the loops here are.

The end of a document is the other half of it. A padded quantum closes a base32
stream, so the decoder has to refuse what turns up afterwards, and Go's
`TestBufferedDecodingPadding` is a table of exactly which offsets it says when
it does.
"""

from std.testing import assert_equal, assert_true

from core.encoding.base32 import (
    CorruptInputError,
    NO_PADDING,
    new_decoder,
    new_encoder,
    std_encoding,
)
from core.errors import matches
from core.errors.codes import ErrUnexpectedEOF
from core.io import read_all
from tests.generated.base32 import pairs_rows

from ._fixtures import Chunks, Fixed, OneByte, Sink, as_text, raw_ref

comptime _BIG_DECODED = "Twas brillig, and the slithy toves"
"""Go's `bigtest` again, which is what its buffering tests are run over."""

comptime _BIG_ENCODED = (
    "KR3WC4ZAMJZGS3DMNFTSYIDBNZSCA5DIMUQHG3DJORUHSIDUN53GK4Y="
)
"""What it encodes to."""


struct _Late(Copyable, Movable):
    """One row of Go's `TestBufferedDecodingPadding`: the chunks and the word.
    """

    var chunks: List[String]
    """What the reader hands over, one per call."""

    var want: String
    """The message the whole read ends with."""

    def __init__(out self, var chunks: List[String], want: String):
        self.chunks = chunks^
        self.want = want


def test_encoder_over_the_pairs() raises:
    """Go's `TestEncoder`. One write and a close, per row."""
    var rows = pairs_rows()
    for i in range(len(rows)):
        var enc = new_encoder(std_encoding(), Sink())
        _ = enc.write(rows[i].decoded.as_bytes())
        enc.close()
        assert_equal(enc.w.text(), rows[i].encoded)


def test_encoder_without_padding() raises:
    """Go's `TestWithoutPaddingClose`, which is the same rows unpadded."""
    var rows = pairs_rows()
    for i in range(len(rows)):
        var enc = new_encoder(std_encoding().with_padding(NO_PADDING), Sink())
        _ = enc.write(rows[i].decoded.as_bytes())
        enc.close()
        assert_equal(enc.w.text(), raw_ref(rows[i].encoded))


def test_encoder_buffering() raises:
    """Go's `TestEncoderBuffering`: the same bytes in every size of piece."""
    var input = _BIG_DECODED.as_bytes()
    for size in range(1, 13):
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
    _ = enc.write("fooba".as_bytes())
    _ = enc.write("r".as_bytes())
    assert_equal(enc.w.text(), "MZXW6YTB")
    enc.close()
    assert_equal(enc.w.text(), "MZXW6YTBOI======")


def test_closing_twice_writes_nothing_the_second_time() raises:
    var enc = new_encoder(std_encoding(), Sink())
    _ = enc.write("f".as_bytes())
    enc.close()
    var after = enc.w.writes
    enc.close()
    assert_equal(enc.w.writes, after)
    assert_equal(enc.w.text(), "MY======")


def test_decoder_over_the_pairs() raises:
    """Go's `TestDecoder` and `TestDecodeReadAll`, both paddings."""
    var rows = pairs_rows()
    for i in range(len(rows)):
        var dec = new_decoder(std_encoding(), Fixed(rows[i].encoded))
        assert_equal(as_text(read_all(dec)), rows[i].decoded)

        var raw = new_decoder(
            std_encoding().with_padding(NO_PADDING),
            Fixed(raw_ref(rows[i].encoded)),
        )
        assert_equal(as_text(read_all(raw)), rows[i].decoded)


def test_decoder_into_a_small_buffer() raises:
    """Go's `TestDecodeSmallBuffer`, over the sizes that are worth the time.

    Go walks the buffer size to two hundred, which is a hundred and ninety of
    the same case; this walks to sixteen, which covers everything below a group
    and everything between one group and two.
    """
    var rows = pairs_rows()
    for size in range(1, 17):
        for i in range(len(rows)):
            var dec = new_decoder(std_encoding(), Fixed(rows[i].encoded))
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
            assert_equal(as_text(all), rows[i].decoded)


def test_decoder_one_byte_at_a_time() raises:
    """Go's `TestDecoderBuffering`, in its harshest form.

    A decoder that assumed a read filled the span would decode the first
    character on its own and get nothing out of it.
    """
    var dec = new_decoder(std_encoding(), OneByte(_BIG_ENCODED))
    assert_equal(as_text(read_all(dec)), _BIG_DECODED)


def test_decoder_skips_newlines() raises:
    """Go's `TestDecoderIssue4779` in miniature: a wrapped document decodes."""
    var wrapped = (
        "KR3WC4ZAMJZGS3DMNFTSYIDBNZSC\r\nA5DIMUQHG3DJORUHSIDUN53GK4Y=\r\n"
    )
    var dec = new_decoder(std_encoding(), Fixed(wrapped))
    assert_equal(as_text(read_all(dec)), _BIG_DECODED)


def test_decoder_of_nothing_is_nothing() raises:
    var dec = new_decoder(std_encoding(), Fixed(""))
    assert_equal(len(read_all(dec)), 0)


def test_a_truncated_group_is_unexpected_eof() raises:
    """A padded encoding cannot end in the middle of a group."""
    var dec = new_decoder(std_encoding(), Fixed("MY====="))
    var refused = False
    try:
        _ = read_all(dec)
    except e:
        refused = True
        assert_true(matches(e, ErrUnexpectedEOF))
    assert_true(refused)


def test_a_corrupt_group_arrives_after_the_bytes_before_it() raises:
    """`io.Reader` here never hands over bytes and a failure at once."""
    var dec = new_decoder(std_encoding(), Fixed("MZXW6YTB!!!!!!!!"))
    var into = List[UInt8](length=32, fill=0)
    var got = dec.read(Span(into))
    assert_equal(got, 5)
    into.resize(5, 0)
    assert_equal(as_text(into), "fooba")

    var refused = False
    var again = List[UInt8](length=32, fill=0)
    try:
        _ = dec.read(Span(again))
    except:
        refused = True
    assert_true(refused)


def test_what_arrives_after_the_padding() raises:
    """Go's `TestBufferedDecodingPadding`, message for message.

    A padded quantum ends the document, so a second one is not a second
    document. Where the offset is zero it means the start of what arrived after
    the padding rather than the start of the input, which is why the same two
    quanta in one chunk and in two give different numbers.
    """
    var rows = List[_Late]()
    # The first row ends short rather than late, so it is the sentinel that is
    # worth pinning and not the message: `read_all` puts its own prefix on the
    # front of whatever it is handed.
    rows.append(_Late(["I4======", "=="], ""))
    rows.append(
        _Late(["I4======N4======"], "illegal base32 data at input byte 2")
    )
    rows.append(
        _Late(["I4======", "N4======"], "illegal base32 data at input byte 0")
    )
    rows.append(
        _Late(["I4======", "========"], "illegal base32 data at input byte 0")
    )
    rows.append(
        _Late(
            ["I4I4I4I4", "I4======", "I4======"],
            "illegal base32 data at input byte 0",
        )
    )

    # Read straight from the decoder rather than through `read_all`. Both fail
    # in the same place, but `read_all` wraps what it is handed and the offset
    # then sits a link down the chain, where `errors.field` does not look for
    # it and `CorruptInputError.of` therefore cannot find it.
    for i in range(len(rows)):
        var dec = new_decoder(std_encoding(), Chunks(rows[i].chunks.copy()))
        var buf = List[UInt8](length=64, fill=0)
        var refused = False
        while not refused:
            try:
                _ = dec.read(Span(buf))
            except e:
                refused = True
                if rows[i].want.byte_length() > 0:
                    var bad = CorruptInputError.of(e)
                    assert_true(Bool(bad))
                    assert_equal(bad.value().error(), rows[i].want)
                else:
                    assert_true(matches(e, ErrUnexpectedEOF))
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
