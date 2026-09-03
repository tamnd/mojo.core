"""Go's `TestIntGobEncoding`, `TestIntJSONEncoding` and `TestIntAppendText`,
from `intmarsh_test.go`.

Go's table is seven numbers and each is run with no sign, a plus and a minus,
which is nine of the interesting cases in twenty one rows. The `Int` half of gob
is `GobEncode` and `GobDecode`, and Go's test drives them through a real encoder
and decoder. There is no `encoding/gob` here, so the two methods are called
directly, which is the part of the round trip this package is responsible for.

The gob form is one byte of version and sign followed by the magnitude big
endian, and it is Go's format rather than an invention, so the exact bytes are
checked and not only that they survive a round trip. A number written by a
program using this package has to be readable by a Go program.
"""

from std.testing import assert_equal, assert_true

import core.math.big as big
from core.errors import matches
from core.errors.codes import ErrInvalidArgument, ErrSyntax

from tests.math.big._fixtures import pb


def _encoding() -> List[String]:
    """Go's `encodingTests`."""
    return [
        "0",
        "1",
        "2",
        "10",
        "1000",
        "1234567890",
        "298472983472983471903246121093472394872319615612417471234712061",
    ]


def _signs() -> List[String]:
    """The three prefixes Go puts in front of every row."""
    return ["", "+", "-"]


def test_gob_round_trip() raises:
    # Go's `TestIntGobEncoding`.
    for base in _encoding():
        for sign in _signs():
            var x = pb(sign + base, 10)
            var encoded = x.gob_encode()

            # The receiver starts holding something else, so a decode that
            # forgets to clear a field shows up rather than being masked.
            var back = big.Int(Int64(-1234567890))
            back.gob_decode(Span(encoded))
            assert_equal(back.cmp(x), 0, sign + base)
            assert_equal(back.string(), x.string(), sign + base)


def test_gob_bytes() raises:
    # Not from Go, which drives the format through its own encoder rather than
    # writing it down. The bytes are Go's, so they are worth pinning: version
    # one in the top seven bits of the first byte, the sign in the bottom bit,
    # then the magnitude big endian with no leading zero byte.
    var rows: List[List[String]] = [
        ["0", "02"],
        ["-0", "02"],
        ["1", "0201"],
        ["-1", "0301"],
        ["255", "02ff"],
        ["256", "020100"],
        ["-256", "030100"],
        ["1234567890", "02499602d2"],
        ["18446744073709551615", "02ffffffffffffffff"],
        ["18446744073709551616", "02010000000000000000"],
    ]
    for row in rows:
        var x = pb(row[0], 10)
        assert_equal(_hex(x.gob_encode()), row[1], row[0])


def test_gob_decode_empty_is_zero() raises:
    # Go's encoder sends nothing at all for a zero value, and its decoder has
    # to read that back as zero rather than as an error.
    var z = big.Int(Int64(999))
    var empty = List[UInt8]()
    z.gob_decode(Span(empty))
    assert_equal(z.string(), "0")
    assert_equal(z.sign(), 0)


def test_gob_decode_rejects_another_version() raises:
    # Go returns an error naming the version rather than guessing at the bytes.
    var z = big.Int()
    var versions: List[UInt8] = [0, 1, 4, 5, 0xFE, 0xFF]
    for v in versions:
        var buf: List[UInt8] = [v, 1, 2, 3]
        var raised = False
        var err = Error()
        try:
            z.gob_decode(Span(buf))
        except e:
            raised = True
            err = e
        assert_true(raised, "version byte " + String(v))
        assert_true(matches(err, ErrInvalidArgument))


def test_json_round_trip() raises:
    # Go's `TestIntJSONEncoding`. A big number is a JSON number here and not a
    # string, which is why Go's own documentation warns that a decoder reading
    # into a float will lose it.
    for base in _encoding():
        for sign in _signs():
            var x = pb(sign + base, 10)
            var encoded = x.marshal_json()
            var back = big.Int(Int64(-1))
            back.unmarshal_json(Span(encoded))
            assert_equal(back.cmp(x), 0, sign + base)

            # The JSON form is the decimal text, with no quotes around it.
            assert_equal(
                String(from_utf8_lossy=Span(encoded)), x.string(), sign + base
            )


def test_json_null_leaves_the_value_alone() raises:
    # Go's `Int.UnmarshalJSON` treats null as nothing to do, which is what the
    # rest of its JSON decoding does with one.
    var z = big.Int(Int64(42))
    var null = "null".as_bytes()
    z.unmarshal_json(null)
    assert_equal(z.string(), "42")


def test_text_round_trip() raises:
    # Go's `TestIntAppendText`. Go appends to a buffer that already has four
    # bytes in it and reads back from past them, which is the whole point of
    # having an append form, so the same is done here.
    var prefix: List[UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
    for base in _encoding():
        for sign in _signs():
            var x = pb(sign + base, 10)
            var buf = prefix.copy()
            x.append_text(buf)
            for i in range(4):
                assert_equal(buf[i], prefix[i], "the prefix was kept")

            var back = big.Int(Int64(-1))
            back.unmarshal_text(Span(buf)[4:])
            assert_equal(back.cmp(x), 0, sign + base)

            # `marshal_text` is the same bytes with nothing in front.
            var marshalled = x.marshal_text()
            assert_equal(len(marshalled), len(buf) - 4, "same length")
            for i in range(len(marshalled)):
                assert_equal(marshalled[i], buf[i + 4], "byte " + String(i))


def test_unmarshal_text_reads_prefixes() raises:
    # Go's `UnmarshalText` uses base zero, so it takes anything `SetString`
    # with base zero takes and not only decimal.
    var rows: List[List[String]] = [
        ["0x10", "16"],
        ["0b1010", "10"],
        ["0o17", "15"],
        ["017", "15"],
        ["-0xff", "-255"],
        ["+1_000", "1000"],
    ]
    for row in rows:
        var z = big.Int()
        z.unmarshal_text(row[0].as_bytes())
        assert_equal(z.string(), row[1], row[0])


def test_unmarshal_text_rejects_rubbish() raises:
    # Go returns an error rather than a zero, so that a caller reading a
    # malformed document finds out.
    var bad: List[String] = ["", "abc", "0x", "-", "12 34", "1.5", "1e10"]
    for s in bad:
        var z = big.Int(Int64(7))
        var raised = False
        var err = Error()
        try:
            z.unmarshal_text(s.as_bytes())
        except e:
            raised = True
            err = e
        assert_true(raised, "'" + s + "' is not a number")
        assert_true(matches(err, ErrSyntax))
        assert_equal(z.string(), "7", "the receiver was not touched")


def _hex(buf: List[UInt8]) -> String:
    """`buf` as lowercase hexadecimal, so a format can be written down in a
    table rather than as a list of numbers."""
    var digits = "0123456789abcdef".as_bytes()
    var out = List[UInt8]()
    for b in buf:
        out.append(digits[Int(b >> 4)])
        out.append(digits[Int(b & 15)])
    return String(from_utf8_lossy=Span(out))
