"""Encoding and decoding, over Go's own table.

`encDecTests` is seven rows covering every nibble value and both odd sizes, and
Go reads it through five of its functions. So does this.
`tests/generated/hex.mojo` has the rows.
"""

from std.testing import assert_equal, assert_true

from core.encoding.hex import (
    InvalidByteError,
    append_decode,
    append_encode,
    decode,
    decode_string,
    decoded_len,
    encode,
    encode_to_string,
    encoded_len,
)
from core.errors import matches, partial
from core.errors.codes import ErrInvalidHexByte, ErrLength
from tests.generated.hex import enc_dec_tests_rows

from ._fixtures import as_bytes, hex_of


def test_encode_rows() raises:
    """Go's `TestEncode`, including the appending form."""
    var rows = enc_dec_tests_rows()
    for i in range(len(rows)):
        var dec = as_bytes(rows[i].dec)
        var room = encoded_len(len(dec))
        var out = List[UInt8](length=room, fill=0)
        var wrote = encode(Span(out), Span(dec))
        assert_equal(wrote, room)
        assert_equal(String(from_utf8=Span(out)), rows[i].enc)

        var onto = List[UInt8]()
        for b in "lead".as_bytes():
            onto.append(b)
        _ = append_encode(onto, Span(dec))
        assert_equal(String(from_utf8=Span(onto)), "lead" + rows[i].enc)


def test_encode_to_string_rows() raises:
    """Go's `TestEncodeToString`."""
    var rows = enc_dec_tests_rows()
    for i in range(len(rows)):
        assert_equal(encode_to_string(Span(as_bytes(rows[i].dec))), rows[i].enc)


def test_decode_rows() raises:
    """Go's `TestDecode`, including the appending form and uppercase input."""
    var rows = enc_dec_tests_rows()
    var texts = List[String]()
    var wants = List[String]()
    for i in range(len(rows)):
        texts.append(rows[i].enc)
        wants.append(hex_of(as_bytes(rows[i].dec)))
    # Go appends one more row here, the same bytes written in capitals, since
    # `encode` only ever writes lowercase and the uppercase path would
    # otherwise never be read.
    texts.append(String("F8F9FAFBFCFDFEFF"))
    wants.append(String("f8f9fafbfcfdfeff"))

    for i in range(len(texts)):
        var room = decoded_len(texts[i].byte_length())
        var out = List[UInt8](length=room, fill=0)
        var got = decode(Span(out), texts[i].as_bytes())
        assert_equal(got, room)
        assert_equal(hex_of(out), wants[i])

        var onto = List[UInt8]()
        for b in "lead".as_bytes():
            onto.append(b)
        _ = append_decode(onto, texts[i].as_bytes())
        # `6c656164` is `lead`, which is what Go puts on the front of the
        # destination to prove the decode appended rather than overwrote.
        assert_equal(hex_of(onto), "6c656164" + wants[i])


def test_decode_string_rows() raises:
    """Go's `TestDecodeString`."""
    var rows = enc_dec_tests_rows()
    for i in range(len(rows)):
        assert_equal(
            hex_of(decode_string(rows[i].enc)), hex_of(as_bytes(rows[i].dec))
        )


def test_the_lengths() raises:
    """`encoded_len` doubles and `decoded_len` halves, rounding down."""
    assert_equal(encoded_len(0), 0)
    assert_equal(encoded_len(1), 2)
    assert_equal(encoded_len(7), 14)
    assert_equal(decoded_len(0), 0)
    assert_equal(decoded_len(1), 0)
    assert_equal(decoded_len(2), 1)
    assert_equal(decoded_len(15), 7)


def test_either_case_decodes() raises:
    """Go's rule, and the reason this is not a wrapper over `b16decode`.

    Mojo's standard library reads uppercase only and writes uppercase only.
    Every hash a program is handed is lowercase.
    """
    assert_equal(hex_of(decode_string("ff")), "ff")
    assert_equal(hex_of(decode_string("FF")), "ff")
    assert_equal(hex_of(decode_string("fF")), "ff")
    var high: List[UInt8] = [0xFF, 0xAB]
    assert_equal(encode_to_string(Span(high)), "ffab")


def test_an_odd_length_is_refused() raises:
    """`ErrLength`, which is Go's exported sentinel for exactly this."""
    var out = List[UInt8](length=8, fill=0)
    var refused = False
    try:
        _ = decode(Span(out), "0".as_bytes())
    except e:
        refused = True
        assert_true(matches(e, ErrLength))
        assert_equal(String(e), "encoding/hex: odd length hex string")
    assert_true(refused)


def test_a_character_that_is_not_a_digit_is_refused() raises:
    """`InvalidByteError`, with Go's message including its `%#U` spelling."""
    var out = List[UInt8](length=8, fill=0)
    var refused = False
    try:
        _ = decode(Span(out), "0g".as_bytes())
    except e:
        refused = True
        assert_true(matches(e, ErrInvalidHexByte))
        var bad = InvalidByteError.of(e)
        assert_true(Bool(bad))
        assert_equal(bad.value().byte, UInt8(ord("g")))
        assert_equal(
            bad.value().error(), "encoding/hex: invalid byte: U+0067 'g'"
        )
    assert_true(refused)


def test_the_message_of_an_unprintable_byte() raises:
    """Go's `%#U` leaves the quoted character off when it is not printable."""
    assert_equal(
        InvalidByteError(UInt8(0x01)).error(),
        "encoding/hex: invalid byte: U+0001",
    )
    assert_equal(
        InvalidByteError(UInt8(0x7F)).error(),
        "encoding/hex: invalid byte: U+007F",
    )
    # The quote and the backslash go in raw, because Go's verb does not escape
    # what it puts between the quotes.
    assert_equal(
        InvalidByteError(UInt8(ord("'"))).error(),
        "encoding/hex: invalid byte: U+0027 '''",
    )
    assert_equal(
        InvalidByteError(UInt8(ord("\\"))).error(),
        "encoding/hex: invalid byte: U+005C '\\'",
    )
    # A space is printable and a non breaking space is not, which is the line
    # `unicode.IsPrint` draws and the reason this asks it rather than checking
    # a range.
    assert_equal(
        InvalidByteError(UInt8(ord(" "))).error(),
        "encoding/hex: invalid byte: U+0020 ' '",
    )
    assert_equal(
        InvalidByteError(UInt8(0xA0)).error(),
        "encoding/hex: invalid byte: U+00A0",
    )
    assert_equal(
        InvalidByteError(UInt8(0xE9)).error(),
        "encoding/hex: invalid byte: U+00E9 'é'",
    )


def test_an_error_from_elsewhere_is_not_one_of_these() raises:
    """What a type assertion covers by failing."""
    var out = List[UInt8](length=8, fill=0)
    try:
        _ = decode(Span(out), "0".as_bytes())
    except e:
        assert_true(not InvalidByteError.of(e))


def test_the_rows_go_returns_beside_an_error() raises:
    """Go's `errTests`, which is declared inside the test file by hand.

    Nine inputs, each with what decodes before the refusal and which of the two
    failures it is. Go compares against `ErrLength` and `InvalidByteError`
    values; here the code is the thing to compare and the character comes off
    the record.
    """
    var inputs = [
        String(""),
        String("0"),
        String("zd4aa"),
        String("d4aaz"),
        String("30313"),
        String("0g"),
        String("00gg"),
        String("0\x01"),
        String("ffeed"),
    ]
    var prefixes = [
        String(""),
        String(""),
        String(""),
        String("d4aa"),
        String("3031"),
        String(""),
        String("00"),
        String(""),
        String("ffee"),
    ]
    # Only the empty input decodes cleanly. Of the eight that do not, four are
    # a length and four are a character.
    var wanted = [False, True, True, True, True, True, True, True, True]
    var by_length = [False, True, False, False, True, False, False, False, True]

    for i in range(len(inputs)):
        var onto = List[UInt8]()
        var refused = False
        try:
            _ = append_decode(onto, inputs[i].as_bytes())
        except e:
            refused = True
            if by_length[i]:
                assert_true(matches(e, ErrLength))
            else:
                assert_true(matches(e, ErrInvalidHexByte))
            assert_equal(partial(e), prefixes[i].byte_length() // 2)
        assert_equal(refused, wanted[i])
        assert_equal(hex_of(onto), prefixes[i])


def test_a_newline_is_not_skipped() raises:
    """The one rule that separates this decoder from the base32 one.

    Base32 and base64 skip carriage returns and line feeds because both are
    written down in places that wrap. Hex has no wrapping convention, so a
    newline is a character that is not a hex digit.
    """
    var refused = False
    try:
        _ = decode_string("ff\nee")
    except e:
        refused = True
        var bad = InvalidByteError.of(e)
        assert_true(Bool(bad))
        assert_equal(bad.value().byte, UInt8(ord("\n")))
    assert_true(refused)
