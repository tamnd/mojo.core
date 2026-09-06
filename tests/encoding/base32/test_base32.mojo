"""Encoding and decoding, over Go's own table of pairs.

Every row is the RFC 4648 example or a Wikipedia one, read in both directions
and through the standard encoding, the same one with the padding changed, and
the same one with the padding taken off. `tests/generated/base32.mojo` has the
rows.
"""

from std.testing import assert_equal, assert_true

from core.encoding.base32 import (
    NO_PADDING,
    STD_PADDING,
    hex_encoding,
    new_encoding,
    std_encoding,
)
from tests.generated.base32 import pairs_rows

from ._fixtures import as_text, at_ref, raw_ref

comptime _BIG_DECODED = "Twas brillig, and the slithy toves"
"""Go's `bigtest`, which is a single value rather than a table and so is here."""

comptime _BIG_ENCODED = (
    "KR3WC4ZAMJZGS3DMNFTSYIDBNZSCA5DIMUQHG3DJORUHSIDUN53GK4Y="
)
"""What it encodes to."""


def test_encode_pairs() raises:
    """Go's `TestEncode`, including the appending form."""
    var enc = std_encoding()
    var rows = pairs_rows()
    for i in range(len(rows)):
        assert_equal(
            enc.encode_to_string(rows[i].decoded.as_bytes()), rows[i].encoded
        )
        var out = List[UInt8]()
        for b in "lead".as_bytes():
            out.append(b)
        _ = enc.append_encode(out, rows[i].decoded.as_bytes())
        assert_equal(as_text(out), "lead" + rows[i].encoded)


def test_decode_pairs() raises:
    """Go's `TestDecode`, including `decode_string` and the appending form."""
    var enc = std_encoding()
    var rows = pairs_rows()
    for i in range(len(rows)):
        assert_equal(
            as_text(enc.decode_string(rows[i].encoded)), rows[i].decoded
        )
        var out = List[UInt8]()
        for b in "lead".as_bytes():
            out.append(b)
        var got = enc.append_decode(out, rows[i].encoded.as_bytes())
        assert_equal(got, rows[i].decoded.byte_length())
        assert_equal(as_text(out), "lead" + rows[i].decoded)


def test_encode_into_a_span() raises:
    """`encode` writes what `encoded_len` said it would."""
    var enc = std_encoding()
    var rows = pairs_rows()
    for i in range(len(rows)):
        var room = enc.encoded_len(rows[i].decoded.byte_length())
        var out = List[UInt8](length=room, fill=0)
        var wrote = enc.encode(Span(out), rows[i].decoded.as_bytes())
        assert_equal(wrote, room)
        assert_equal(as_text(out), rows[i].encoded)


def test_decode_into_a_span() raises:
    """`decode` writes no more than `decoded_len` said it might."""
    var enc = std_encoding()
    var rows = pairs_rows()
    for i in range(len(rows)):
        var room = enc.decoded_len(rows[i].encoded.byte_length())
        var out = List[UInt8](length=room, fill=0)
        var got = enc.decode(Span(out), rows[i].encoded.as_bytes())
        assert_equal(got, rows[i].decoded.byte_length())
        out.resize(got, 0)
        assert_equal(as_text(out), rows[i].decoded)


def test_append_decode_keeps_the_good_prefix() raises:
    """What Go returns beside the error, and the reason this call exists."""
    var enc = std_encoding()
    var out = List[UInt8]()
    var refused = False
    try:
        _ = enc.append_decode(out, "MZXW6YTB!!!!!!!!".as_bytes())
    except:
        refused = True
    assert_true(refused)
    assert_equal(as_text(out), "fooba")


def test_encoded_len() raises:
    """Go's `TestEncodedLen`, including the two rows about overflow."""
    var std = std_encoding()
    var raw = std_encoding().with_padding(NO_PADDING)
    assert_equal(std.encoded_len(0), 0)
    assert_equal(std.encoded_len(1), 8)
    assert_equal(std.encoded_len(2), 8)
    assert_equal(std.encoded_len(3), 8)
    assert_equal(std.encoded_len(4), 8)
    assert_equal(std.encoded_len(5), 8)
    assert_equal(std.encoded_len(6), 16)
    assert_equal(std.encoded_len(10), 16)
    assert_equal(std.encoded_len(11), 24)
    assert_equal(raw.encoded_len(0), 0)
    assert_equal(raw.encoded_len(1), 2)
    assert_equal(raw.encoded_len(2), 4)
    assert_equal(raw.encoded_len(3), 5)
    assert_equal(raw.encoded_len(4), 7)
    assert_equal(raw.encoded_len(5), 8)
    assert_equal(raw.encoded_len(6), 10)
    assert_equal(raw.encoded_len(7), 12)
    assert_equal(raw.encoded_len(10), 16)
    assert_equal(raw.encoded_len(11), 18)
    var most = 9223372036854775807
    assert_equal(raw.encoded_len((most - 4) // 8 + 1), 1844674407370955162)
    assert_equal(raw.encoded_len(most // 8 * 5 + 4), most)


def test_decoded_len() raises:
    """Go's `TestDecodedLen`, the same way."""
    var std = std_encoding()
    var raw = std_encoding().with_padding(NO_PADDING)
    assert_equal(std.decoded_len(0), 0)
    assert_equal(std.decoded_len(8), 5)
    assert_equal(std.decoded_len(16), 10)
    assert_equal(std.decoded_len(24), 15)
    assert_equal(raw.decoded_len(0), 0)
    assert_equal(raw.decoded_len(2), 1)
    assert_equal(raw.decoded_len(4), 2)
    assert_equal(raw.decoded_len(5), 3)
    assert_equal(raw.decoded_len(7), 4)
    assert_equal(raw.decoded_len(8), 5)
    assert_equal(raw.decoded_len(10), 6)
    assert_equal(raw.decoded_len(12), 7)
    assert_equal(raw.decoded_len(16), 10)
    assert_equal(raw.decoded_len(18), 11)
    var most = 9223372036854775807
    assert_equal(raw.decoded_len(most // 5 + 1), 1152921504606846976)
    assert_equal(raw.decoded_len(most), 5764607523034234879)


def test_newline_characters() raises:
    """Go's `TestNewLineCharacters`. Every one of these decodes to `sure`."""
    var sure = [
        String("ON2XEZI="),
        String("ON2XEZI=\r"),
        String("ON2XEZI=\n"),
        String("ON2XEZI=\r\n"),
        String("ON2XEZ\r\nI="),
        String("ON2X\rEZ\nI="),
        String("ON2X\nEZ\rI="),
        String("ON2XEZ\nI="),
        String("ON2XEZI\n="),
    ]
    for i in range(len(sure)):
        assert_equal(as_text(std_encoding().decode_string(sure[i])), "sure")

    var foobar = [
        String("MZXW6YTBOI======"),
        String("MZXW6YTBOI=\r\n====="),
    ]
    for i in range(len(foobar)):
        assert_equal(as_text(std_encoding().decode_string(foobar[i])), "foobar")


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


def test_with_custom_padding() raises:
    """Go's `TestWithCustomPadding`, over every row."""
    var at = std_encoding().with_padding(Int32(ord("@")))
    var rows = pairs_rows()
    for i in range(len(rows)):
        assert_equal(
            at.encode_to_string(rows[i].decoded.as_bytes()),
            at_ref(rows[i].encoded),
        )


def test_without_padding() raises:
    """Go's `TestWithoutPadding`, over every row."""
    var raw = std_encoding().with_padding(NO_PADDING)
    var rows = pairs_rows()
    for i in range(len(rows)):
        assert_equal(
            raw.encode_to_string(rows[i].decoded.as_bytes()),
            raw_ref(rows[i].encoded),
        )


def test_decode_with_padding() raises:
    """Go's `TestDecodeWithPadding`: three paddings, all round tripping."""
    var rows = pairs_rows()
    for which in range(3):
        var enc = std_encoding()
        if which == 1:
            enc = std_encoding().with_padding(Int32(ord("-")))
        elif which == 2:
            enc = std_encoding().with_padding(NO_PADDING)
        for i in range(len(rows)):
            var text = enc.encode_to_string(rows[i].decoded.as_bytes())
            assert_equal(as_text(enc.decode_string(text)), rows[i].decoded)


def test_decode_with_wrong_padding() raises:
    """Go's `TestDecodeWithWrongPadding`. The `=` is not a symbol either way."""
    var encoded = std_encoding().encode_to_string("foobar".as_bytes())

    var refused = False
    try:
        _ = std_encoding().with_padding(Int32(ord("-"))).decode_string(encoded)
    except:
        refused = True
    assert_true(refused)

    var also = False
    try:
        _ = std_encoding().with_padding(NO_PADDING).decode_string(encoded)
    except:
        also = True
    assert_true(also)


def test_padding_can_be_removed_and_put_back() raises:
    """`NO_PADDING` and `STD_PADDING` are the two ends of the same switch."""
    var raw = std_encoding().with_padding(NO_PADDING)
    assert_equal(raw.encode_to_string("f".as_bytes()), "MY")
    assert_equal(
        raw.with_padding(STD_PADDING).encode_to_string("f".as_bytes()),
        "MY======",
    )


def test_the_hex_alphabet() raises:
    """`hex_encoding`, and the ordering that is the whole reason for it."""
    var hex = hex_encoding()
    assert_equal(hex.encode_to_string("foobar".as_bytes()), "CPNMUOJ1E8======")
    assert_equal(as_text(hex.decode_string("CPNMUOJ1E8======")), "foobar")

    # Symbol order is byte order, which is what DNSSEC wants from it. Ten and
    # twenty six spell `A` and `Q` here and sort the way the values do; the
    # standard alphabet spells them `K` and `2`, which sort the other way
    # round.
    var ten = List[UInt8](length=5, fill=0)
    ten[0] = 10 << 3
    var twenty_six = List[UInt8](length=5, fill=0)
    twenty_six[0] = 26 << 3
    assert_equal(hex.encode_to_string(Span(ten)), "A0000000")
    assert_equal(hex.encode_to_string(Span(twenty_six)), "Q0000000")
    assert_equal(std_encoding().encode_to_string(Span(ten)), "KAAAAAAA")
    assert_equal(std_encoding().encode_to_string(Span(twenty_six)), "2AAAAAAA")


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
        _ = new_encoding("ABCDEFGHIJKLMNOPQRSTUVWXYZ2345\n7")
    except:
        newline = True
    assert_true(newline)

    var duplicate = False
    try:
        _ = new_encoding("AACDEFGHIJKLMNOPQRSTUVWXYZ234567")
    except:
        duplicate = True
    assert_true(duplicate)


def test_a_bad_padding_character_is_refused() raises:
    """The other two places Go panics. Go's `WithPadding` says all five."""
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
