"""Encoding and decoding, over Go's own table of pairs.

Every row is read through all five encodings and each of those twice, once
plain and once strict, which is Go's `encodingTests` written as two loops
because the table itself cannot come across. `tests/generated/base64.mojo` has
the rows.
"""

from std.testing import assert_equal, assert_true

from core.encoding.base64 import (
    Encoding,
    NO_PADDING,
    STD_PADDING,
    new_encoding,
    raw_std_encoding,
    raw_url_encoding,
    std_encoding,
    url_encoding,
)
from tests.generated.base64 import pairs_rows

from ._fixtures import (
    FUNNY,
    RAW_STD,
    RAW_URL,
    STD,
    URL,
    as_hex,
    as_text,
    ref_for,
)

comptime _ENCODINGS = 5
"""How many spellings the table is read through. Go's `encodingTests`."""

comptime _BIG_DECODED = "Twas brillig, and the slithy toves"
"""Go's `bigtest`, which is a single value rather than a table and so is here."""

comptime _BIG_ENCODED = "VHdhcyBicmlsbGlnLCBhbmQgdGhlIHNsaXRoeSB0b3Zlcw=="
"""What it encodes to."""


def _encoding_for(which: Int, strict: Bool) raises -> Encoding:
    """The encoding the index `which` names, strict or not."""
    var enc = std_encoding()
    if which == URL:
        enc = url_encoding()
    elif which == RAW_STD:
        enc = raw_std_encoding()
    elif which == RAW_URL:
        enc = raw_url_encoding()
    elif which == FUNNY:
        enc = new_encoding(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        ).with_padding(Int32(ord("@")))
    if strict:
        return enc.strict()
    return enc^


def test_encode_pairs() raises:
    """Go's `TestEncode`, over every encoding."""
    var rows = pairs_rows()
    for which in range(_ENCODINGS):
        for strict in range(2):
            var enc = _encoding_for(which, strict == 1)
            for i in range(len(rows)):
                var want = ref_for(which, as_text(rows[i].encoded))
                assert_equal(enc.encode_to_string(Span(rows[i].decoded)), want)


def test_decode_pairs() raises:
    """Go's `TestDecode`, over every encoding."""
    var rows = pairs_rows()
    for which in range(_ENCODINGS):
        for strict in range(2):
            var enc = _encoding_for(which, strict == 1)
            for i in range(len(rows)):
                var text = ref_for(which, as_text(rows[i].encoded))
                assert_equal(
                    as_hex(enc.decode_string(text)),
                    as_hex(rows[i].decoded),
                )


def test_encode_into_a_span() raises:
    """`encode` writes what `encoded_len` said it would."""
    var enc = std_encoding()
    var rows = pairs_rows()
    for i in range(len(rows)):
        var room = enc.encoded_len(len(rows[i].decoded))
        var out = List[UInt8](length=room, fill=0)
        var wrote = enc.encode(Span(out), Span(rows[i].decoded))
        assert_equal(wrote, room)
        assert_equal(as_text(out), as_text(rows[i].encoded))


def test_decode_into_a_span() raises:
    """`decode` writes no more than `decoded_len` said it might."""
    var enc = std_encoding()
    var rows = pairs_rows()
    for i in range(len(rows)):
        var room = enc.decoded_len(len(rows[i].encoded))
        var out = List[UInt8](length=room, fill=0)
        var got = enc.decode(Span(out), Span(rows[i].encoded))
        assert_equal(got, len(rows[i].decoded))
        out.resize(got, 0)
        assert_equal(as_hex(out), as_hex(rows[i].decoded))


def test_append_encode() raises:
    """The appending form leaves what was already in the list alone."""
    var enc = std_encoding()
    var out = List[UInt8]()
    for b in "start ".as_bytes():
        out.append(b)
    var wrote = enc.append_encode(out, "foobar".as_bytes())
    assert_equal(wrote, 8)
    assert_equal(as_text(out), "start Zm9vYmFy")


def test_append_decode() raises:
    """The same the other way, and the count is bytes rather than characters."""
    var enc = std_encoding()
    var out = List[UInt8]()
    for b in "start ".as_bytes():
        out.append(b)
    var got = enc.append_decode(out, "Zm9vYmFy".as_bytes())
    assert_equal(got, 6)
    assert_equal(as_text(out), "start foobar")


def test_append_decode_keeps_the_good_prefix() raises:
    """What Go returns beside the error, and the reason this call exists."""
    var enc = std_encoding()
    var out = List[UInt8]()
    var refused = False
    try:
        _ = enc.append_decode(out, "Zm9vYmFy!!!!".as_bytes())
    except:
        refused = True
    assert_true(refused)
    assert_equal(as_text(out), "foobar")


def test_encoded_len() raises:
    """Go's `TestEncodedLen`, including the two rows about overflow."""
    var raw = raw_std_encoding()
    var std = std_encoding()
    assert_equal(raw.encoded_len(0), 0)
    assert_equal(raw.encoded_len(1), 2)
    assert_equal(raw.encoded_len(2), 3)
    assert_equal(raw.encoded_len(3), 4)
    assert_equal(raw.encoded_len(7), 10)
    assert_equal(std.encoded_len(0), 0)
    assert_equal(std.encoded_len(1), 4)
    assert_equal(std.encoded_len(2), 4)
    assert_equal(std.encoded_len(3), 4)
    assert_equal(std.encoded_len(4), 8)
    assert_equal(std.encoded_len(7), 12)
    var most = 9223372036854775807
    assert_equal(raw.encoded_len((most - 5) // 8 + 1), 1537228672809129302)
    assert_equal(raw.encoded_len(most // 4 * 3 + 2), most)


def test_decoded_len() raises:
    """Go's `TestDecodedLen`, the same way."""
    var raw = raw_std_encoding()
    var std = std_encoding()
    assert_equal(raw.decoded_len(0), 0)
    assert_equal(raw.decoded_len(2), 1)
    assert_equal(raw.decoded_len(3), 2)
    assert_equal(raw.decoded_len(4), 3)
    assert_equal(raw.decoded_len(10), 7)
    assert_equal(std.decoded_len(0), 0)
    assert_equal(std.decoded_len(4), 3)
    assert_equal(std.decoded_len(8), 6)
    var most = 9223372036854775807
    assert_equal(raw.decoded_len(most // 6 + 1), 1152921504606846976)
    assert_equal(raw.decoded_len(most), 6917529027641081855)


def test_decode_bounds() raises:
    """Go's `TestDecodeBounds`: decoding 32 bytes back over their own buffer."""
    var buf = List[UInt8](length=32, fill=0)
    var text = std_encoding().encode_to_string(Span(buf))
    var got = std_encoding().decode(Span(buf), text.as_bytes())
    assert_equal(got, 32)


def test_newline_characters() raises:
    """Go's `TestNewLineCharacters`. Every one of these decodes to `sure`."""
    var examples = [
        String("c3VyZQ=="),
        String("c3VyZQ==\r"),
        String("c3VyZQ==\n"),
        String("c3VyZQ==\r\n"),
        String("c3VyZ\r\nQ=="),
        String("c3V\ryZ\nQ=="),
        String("c3V\nyZ\rQ=="),
        String("c3VyZ\nQ=="),
        String("c3VyZQ\n=="),
        String("c3VyZQ=\n="),
        String("c3VyZQ=\r\n\r\n="),
    ]
    for i in range(len(examples)):
        assert_equal(as_text(std_encoding().decode_string(examples[i])), "sure")


def test_big() raises:
    """Go's `TestBig`, without the stream: 3001 bytes there and back."""
    comptime alpha = (
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    )
    var raw = List[UInt8]()
    var letters = alpha.as_bytes()
    for i in range(3 * 1000 + 1):
        raw.append(letters[i % len(letters)])
    var enc = std_encoding()
    var text = enc.encode_to_string(Span(raw))
    var back = enc.decode_string(text)
    assert_equal(len(back), len(raw))
    for i in range(len(raw)):
        assert_equal(back[i], raw[i])


def test_bigtest_pair() raises:
    """Go's `bigtest`, which is one row and not a table."""
    var enc = std_encoding()
    assert_equal(enc.encode_to_string(_BIG_DECODED.as_bytes()), _BIG_ENCODED)
    assert_equal(as_text(enc.decode_string(_BIG_ENCODED)), _BIG_DECODED)


def test_padding_can_be_changed() raises:
    """Go's `funnyEncoding`, and the four refusals `with_padding` makes."""
    var funny = new_encoding(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    ).with_padding(Int32(ord("@")))
    assert_equal(funny.encode_to_string("f".as_bytes()), "Zg@@")
    assert_equal(as_text(funny.decode_string("Zg@@")), "f")

    var std = std_encoding()
    for bad in [Int32(-2), Int32(ord("\r")), Int32(ord("\n")), Int32(0x100)]:
        var refused = False
        try:
            _ = std.with_padding(bad)
        except:
            refused = True
        assert_true(refused)

    var in_alphabet = False
    try:
        _ = std.with_padding(Int32(ord("A")))
    except:
        in_alphabet = True
    assert_true(in_alphabet)


def test_padding_can_be_removed_and_put_back() raises:
    """`NO_PADDING` and `STD_PADDING` are the two ends of the same switch."""
    var raw = std_encoding().with_padding(NO_PADDING)
    assert_equal(raw.encode_to_string("f".as_bytes()), "Zg")
    assert_equal(
        raw.with_padding(STD_PADDING).encode_to_string("f".as_bytes()), "Zg=="
    )


def test_a_bad_alphabet_is_refused() raises:
    """Go panics on each of these three and this raises."""
    var short = False
    try:
        _ = new_encoding("too short")
    except:
        short = True
    assert_true(short)

    var newline = False
    try:
        _ = new_encoding(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz012345678\n+/"
        )
    except:
        newline = True
    assert_true(newline)

    var duplicate = False
    try:
        _ = new_encoding(
            "AACDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        )
    except:
        duplicate = True
    assert_true(duplicate)
