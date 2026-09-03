"""Go's `ratmarsh_test.go`.

Go drives gob through a real encoder and decoder and text through
`encoding/json` and `encoding/xml`. None of those exist here, so the methods
are called directly, which is the part of the round trip this package is
responsible for. Its `TestRatJSONEncoding` and `TestRatXMLEncoding` are the
same values through the same `MarshalText` and `UnmarshalText` that
`TestRatAppendText` uses, so the three come down to one test here.

`TestGobEncodingNilRatInSlice` is about a nil pointer inside a slice, which is
a question about `encoding/gob` rather than about this package, and a `Rat`
here is a value that cannot be nil.
"""

from std.testing import assert_equal, assert_true

import core.math.big as big
from core.errors import matches
from core.errors.codes import ErrInvalidArgument, ErrSyntax

from tests.math.big._fixtures import q


def _encoding() -> List[String]:
    """Go's `encodingTests`, which `intmarsh_test.go` declares and this file
    borrows the way Go's does."""
    return [
        "0",
        "1",
        "2",
        "10",
        "1000",
        "1234567890",
        "298472983472983471903246121093472394872319615612417471234712061",
    ]


def _rat_nums() -> List[String]:
    """Go's `ratNums`."""
    return [
        (
            "-14159265358979323846264338327950288419716939937510582097494459"
            "2307816406286"
        ),
        "-1415926535897932384626433832795028841971",
        "-141592653589793",
        "-1",
        "0",
        "1",
        "141592653589793",
        "1415926535897932384626433832795028841971",
        (
            "1415926535897932384626433832795028841971693993751058209749445923"
            "07816406286"
        ),
    ]


def _rat_denoms() -> List[String]:
    """Go's `ratDenoms`."""
    return [
        "1",
        "718281828459045",
        "7182818284590452353602874713526624977572",
        (
            "71828182845904523536028747135266249775724709369995957496696762772"
            "4076630353"
        ),
    ]


def test_gob_round_trip() raises:
    # Go's `TestRatGobEncoding`. Every row is turned into a fraction by putting
    # a decimal tail on it, so that the denominator is not one and both halves
    # of the encoding are carrying something.
    for base in _encoding():
        var x = q(base + ".14159265")
        var encoded = x.gob_encode()

        # The receiver starts holding something else, so a decode that forgets
        # to clear a field shows up rather than being masked.
        var back = big.new_rat(-987654321, 7)
        back.gob_decode(Span(encoded))
        assert_equal(back.cmp(x), 0, base)
        assert_equal(back.rat_string(), x.rat_string(), base)

    # And the same for the negatives, which Go does not cover here because
    # every row in its table is positive.
    for base in _encoding():
        var x = q("-" + base + ".14159265")
        var encoded = x.gob_encode()
        var back = big.Rat()
        back.gob_decode(Span(encoded))
        assert_equal(back.cmp(x), 0, "-" + base)


def test_gob_bytes() raises:
    # Not from Go, which drives the format through its own encoder rather than
    # writing it down. The bytes are Go's: version one in the top seven bits of
    # the first byte and the sign in the bottom bit, then the length of the
    # numerator in four bytes big endian, then the numerator and the
    # denominator, both big endian magnitudes with no leading zero byte.
    var rows: List[List[String]] = [
        ["0", "020000000001"],
        ["-0", "020000000001"],
        ["1", "02000000010101"],
        ["-1", "03000000010101"],
        ["1/2", "02000000010102"],
        ["-3/4", "03000000010304"],
        ["255/256", "0200000001ff0100"],
        ["1234567890", "0200000004499602d201"],
        ["18446744073709551616/3", "020000000901000000000000000003"],
    ]
    for row in rows:
        var x = q(row[0])
        assert_equal(_hex(x.gob_encode()), row[1], row[0])


def test_gob_decode_empty_is_zero() raises:
    # Go's encoder sends nothing at all for a zero value, and its decoder has
    # to read that back as zero rather than as an error.
    var z = big.new_rat(22, 7)
    var empty = List[UInt8]()
    z.gob_decode(Span(empty))
    assert_equal(z.rat_string(), "0")
    assert_equal(z.sign(), 0)
    assert_equal(z.denom().string(), "1", "the denominator is a one")


def test_gob_decode_repairs_an_empty_denominator() raises:
    # Go's own zero value carries an empty denominator rather than a one, so
    # that is what a Go program writes for it, and reading it here has to give
    # a number rather than a fraction with nothing underneath it. A `Rat` here
    # never writes that form, because its denominator is a one from the start,
    # which is the one place the bytes differ from Go's for the same value.
    var z = big.new_rat(22, 7)
    var buf: List[UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00]
    z.gob_decode(Span(buf))
    assert_equal(z.rat_string(), "0")
    assert_equal(z.denom().string(), "1")

    # The same with a numerator, which is how a Go program writes a whole
    # number it built as a zero value and then set.
    var seven: List[UInt8] = [0x02, 0x00, 0x00, 0x00, 0x01, 0x07]
    z.gob_decode(Span(seven))
    assert_equal(z.rat_string(), "7")


def test_gob_decode_rejects_a_short_buffer() raises:
    # Go's `TestRatGobDecodeShortBuffer`, its three rows exactly: a header with
    # no length, a length longer than what follows, and a length of four
    # thousand million.
    var rows: List[List[UInt8]] = [
        [0x02],
        [0x02, 0x00, 0x00, 0x00, 0xFF],
        [0x02, 0xFF, 0xFF, 0xFF, 0xFF],
    ]
    for buf in rows:
        var z = big.new_rat(1, 2)
        var raised = False
        var err = Error()
        try:
            z.gob_decode(Span(buf))
        except e:
            raised = True
            err = e
        assert_true(raised, "a buffer of " + String(len(buf)) + " bytes")
        assert_true(matches(err, ErrInvalidArgument))


def test_gob_decode_rejects_another_version() raises:
    # Go returns an error naming the version rather than guessing at the bytes.
    var versions: List[UInt8] = [0, 1, 4, 5, 0xFE, 0xFF]
    for v in versions:
        var z = big.Rat()
        var buf: List[UInt8] = [v, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03]
        var raised = False
        var err = Error()
        try:
            z.gob_decode(Span(buf))
        except e:
            raised = True
            err = e
        assert_true(raised, "version byte " + String(v))
        assert_true(matches(err, ErrInvalidArgument))


def test_text_round_trip() raises:
    # Go's `TestRatAppendText`, and its `TestRatJSONEncoding` and
    # `TestRatXMLEncoding`, which are the same values through the same two
    # methods. Go appends to a buffer that already has four bytes in it and
    # reads back from past them, which is the whole point of having an append
    # form, so the same is done here.
    var prefix: List[UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
    for num in _rat_nums():
        for denom in _rat_denoms():
            var written = num + "/" + denom
            var x = q(written)

            var buf = prefix.copy()
            x.append_text(buf)
            for i in range(4):
                assert_equal(buf[i], prefix[i], "the prefix was kept")

            var back = big.new_rat(-1, 3)
            back.unmarshal_text(Span(buf)[4:])
            assert_equal(back.cmp(x), 0, written)

            # `marshal_text` is the same bytes with nothing in front.
            var marshalled = x.marshal_text()
            assert_equal(len(marshalled), len(buf) - 4, "same length")
            for i in range(len(marshalled)):
                assert_equal(marshalled[i], buf[i + 4], "byte " + String(i))


def test_text_is_the_short_form() raises:
    # `append_text` writes `rat_string` rather than `string`, so a whole number
    # has no denominator on it and a fraction does. Go's is the same and it
    # matters, because this is what lands in a JSON document.
    var rows: List[List[String]] = [
        ["0", "0"],
        ["-0", "0"],
        ["7", "7"],
        ["-7", "-7"],
        ["4/2", "2"],
        ["1/2", "1/2"],
        ["-1/2", "-1/2"],
        ["6/4", "3/2"],
    ]
    for row in rows:
        var x = q(row[0])
        var got = String(from_utf8_lossy=Span(x.marshal_text()))
        assert_equal(got, row[1], row[0])
        # `string` always writes both halves, which is the other spelling.
        assert_true("/" in x.string(), row[0] + " has both halves")


def test_unmarshal_text_takes_everything_set_string_does() raises:
    # Go's `UnmarshalText` is `SetString`, so a document may hold a fraction, a
    # decimal or a number with a prefix.
    var rows: List[List[String]] = [
        ["2/4", "1/2"],
        ["-0.125", "-1/8"],
        ["1.5e3", "1500"],
        ["0x10/0x20", "1/2"],
        ["1_000", "1000"],
    ]
    for row in rows:
        var z = big.Rat()
        z.unmarshal_text(row[0].as_bytes())
        assert_equal(z.rat_string(), row[1], row[0])


def test_unmarshal_text_rejects_rubbish() raises:
    # Go returns an error rather than a zero, so that a caller reading a
    # malformed document finds out.
    var bad: List[String] = ["", "abc", "0x", "-", "12 34", "1/", "1e"]
    for s in bad:
        var z = big.new_rat(22, 7)
        var raised = False
        var err = Error()
        try:
            z.unmarshal_text(s.as_bytes())
        except e:
            raised = True
            err = e
        assert_true(raised, "'" + s + "' is not a number")
        assert_true(matches(err, ErrSyntax))
        assert_equal(z.rat_string(), "22/7", "the receiver was not touched")


def _hex(buf: List[UInt8]) -> String:
    """`buf` as lowercase hexadecimal, so a format can be written down in a
    table rather than as a list of numbers."""
    var digits = "0123456789abcdef".as_bytes()
    var out = List[UInt8]()
    for b in buf:
        out.append(digits[Int(b >> 4)])
        out.append(digits[Int(b & 15)])
    return String(from_utf8_lossy=Span(out))
