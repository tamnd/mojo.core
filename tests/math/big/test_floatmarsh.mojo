"""Go's `TestFloatGobEncoding` through `TestFloatAppendTextNil`, from
`floatmarsh_test.go`.

Go drives its gob tests through a real `encoding/gob` encoder and decoder.
There is no `encoding/gob` here, so `gob_encode` and `gob_decode` are called
directly, which is the part of the round trip this package is responsible for.
The bytes between them are Go's own layout, so a number written here can be
read by a Go program.

Go's `TestFloatJSONEncoding` is the same round trip again. A `Float` has no
`MarshalJSON` of its own in Go either; `encoding/json` finds `MarshalText` and
uses that, so the JSON form is the text form and `test_text_round_trip` below
covers it. Go's `TestFloatAppendTextNil` is about a nil pointer, which cannot
exist here, so there is nothing to port.

A gob encoding carries the precision, the rounding mode and the accuracy as
well as the number, and all four are checked, because a decoder that reads the
number and drops the precision leaves a value that rounds differently from the
one that was sent.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.errors import matches
from core.errors.codes import ErrInvalidArgument
import core.math.big as big
from core.math.big.rounding import RoundingMode
from core.strconv import format_int


def _float_vals() -> List[String]:
    """Go's `floatVals`. Zero, small whole numbers, a fraction, exponents at
    both ends of what a `Float64` can reach, two long mantissas and the
    infinities in both spellings."""
    return [
        "0",
        "1",
        "0.1",
        "2.71828",
        "1234567890",
        "3.14e1234",
        "3.14e-1234",
        "0.738957395793475734757349579759957975985497e100",
        (
            "0.73895739579347546656564656573475734957975995797598589749859834"
            "759476745986795497e100"
        ),
        "inf",
        "Inf",
    ]


def _signs() -> List[String]:
    """The three prefixes Go puts in front of every row."""
    return ["", "+", "-"]


def _precs() -> List[Int]:
    """The precisions Go runs the codecs at, with zero standing for a value
    that has not been given one."""
    return [0, 1, 2, 10, 53, 64, 100, 1000]


def _modes() -> List[RoundingMode]:
    """Every rounding mode there is, since the mode travels with the value."""
    var out: List[RoundingMode] = [
        big.ToNearestEven,
        big.ToNearestAway,
        big.ToZero,
        big.AwayFromZero,
        big.ToNegativeInf,
        big.ToPositiveInf,
    ]
    return out^


def _parsed(x: String, prec: Int) raises -> big.Float:
    """`x` read at `prec` bits, with a precision of zero left as zero.

    Parsing at a precision of zero works at sixty four bits, since it has to
    work at something, and Go puts the zero back afterwards so that the rest of
    the test sees a value with no precision of its own. This does the same.
    """
    var z = big.Float()
    z.set_prec(prec)
    _ = z.parse(x, 0)
    if prec == 0:
        z.set_prec(0)
    return z^


def test_gob_round_trip() raises:
    # Go's `TestFloatGobEncoding`. The value, the precision, the mode and the
    # accuracy all have to come back, at every precision and under every mode.
    var vals = _float_vals()
    var signs = _signs()
    var precs = _precs()
    var modes = _modes()
    for val in vals:
        for sign in signs:
            for prec in precs:
                for mode in modes:
                    var x = sign + val
                    var tx = _parsed(x, prec)
                    tx.set_mode(mode)

                    var label = (
                        x
                        + " at "
                        + format_int(Int64(prec), 10)
                        + " "
                        + mode.string()
                    )
                    var encoded = tx.gob_encode()

                    # The receiver has no precision of its own, so it takes the
                    # one in the encoding rather than rounding to something
                    # else. That is Go's `var rx Float`.
                    var rx = big.Float()
                    rx.gob_decode(Span(encoded))

                    assert_equal(rx.cmp(tx), 0, label)
                    assert_equal(rx.prec(), prec, label)
                    assert_true(rx.mode() == mode, label)
                    assert_true(rx.acc() == tx.acc(), label)


def test_gob_decode_rounds_to_the_receivers_precision() raises:
    # Not a test of Go's, but a documented part of `GobDecode`: a receiver that
    # already has a precision keeps it and rounds the incoming number, and a
    # receiver with none takes the sender's. Both halves are worth pinning
    # because the round trip above only ever exercises the second.
    var tx = big.Float()
    tx.set_prec(1000)
    _ = tx.parse("0.1", 0)
    var encoded = tx.gob_encode()

    var wide = big.Float()
    wide.gob_decode(Span(encoded))
    assert_equal(wide.prec(), 1000)
    assert_equal(wide.cmp(tx), 0)

    var narrow = big.Float()
    narrow.set_prec(53)
    narrow.gob_decode(Span(encoded))
    assert_equal(narrow.prec(), 53)
    assert_true(narrow.cmp(tx) != 0, "a tenth does not fit in 53 bits")

    var want = big.Float()
    want.set_prec(53)
    _ = want.parse("0.1", 0)
    assert_equal(narrow.cmp(want), 0)


def test_gob_decode_empty_is_zero() raises:
    # Go's encoder sends nothing at all for a zero value, and its decoder has
    # to read that back as the zero value rather than as an error.
    var z = big.Float()
    z.set_prec(64)
    z.set_mode(big.ToPositiveInf)
    _ = z.parse("1234", 0)

    var empty = List[UInt8]()
    z.gob_decode(Span(empty))
    assert_equal(z.sign(), 0)
    assert_equal(z.prec(), 0)
    assert_true(z.mode() == big.ToNearestEven)
    assert_true(z.acc() == big.Exact)


def test_gob_decode_rejects_another_version() raises:
    # Go returns an error naming the version rather than guessing at the bytes.
    var versions: List[UInt8] = [0, 2, 3, 4, 0xFE, 0xFF]
    for v in versions:
        var z = big.Float()
        var buf: List[UInt8] = [v, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        var raised = False
        var err = Error()
        try:
            z.gob_decode(Span(buf))
        except e:
            raised = True
            err = e
        assert_true(raised, "version byte " + String(v))
        assert_true(
            matches(err, ErrInvalidArgument), "version byte " + String(v)
        )


def test_gob_decode_rejects_a_short_buffer() raises:
    # Go's `TestFloatGobDecodeShortBuffer`. The first stops before the
    # precision is complete and the second before the exponent is.
    var short1: List[UInt8] = [0x1, 0x0, 0x0, 0x0]
    var short2: List[UInt8] = [0x1, 0xFA, 0x0, 0x0, 0x0, 0x0]

    var z = big.Float()
    z.set_prec(53)
    with assert_raises():
        z.gob_decode(Span(short1))

    # Go reaches the length check on the second one. This reaches the mode
    # check first, since a mode of seven is not a mode, and raises there. Both
    # are a refusal to read the buffer, which is what the test is for.
    var y = big.Float()
    y.set_prec(53)
    with assert_raises():
        y.gob_decode(Span(short2))


def test_gob_decode_rejects_an_impossible_number() raises:
    # Go's `TestFloatGobDecodeInvalid`. Two encodings that are the right length
    # and describe a number that cannot exist, which `_validate` catches after
    # the bytes have been read.
    var msb: List[UInt8] = [
        0x1,
        0x2A,
        0x20,
        0x20,
        0x20,
        0x20,
        0x0,
        0x20,
        0x20,
        0x20,
        0x0,
        0x20,
        0x20,
        0x20,
        0x20,
        0x0,
        0x0,
        0x0,
        0x0,
        0xC,
    ]
    var z = big.Float()
    z.set_prec(53)
    with assert_raises(contains="the top bit of the mantissa is not set"):
        z.gob_decode(Span(msb))

    var empty_mant: List[UInt8] = [1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    var y = big.Float()
    y.set_prec(53)
    with assert_raises(contains="a finite number has an empty mantissa"):
        y.gob_decode(Span(empty_mant))


def test_text_round_trip() raises:
    # Go's `TestFloatAppendText`, and its `TestFloatJSONEncoding`, which goes
    # through the same two methods. Go appends to a buffer that already has
    # four bytes in it and reads back from past them, which is the whole point
    # of having an append form, so the same is done here.
    var prefix: List[UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
    var vals = _float_vals()
    var signs = _signs()
    var precs = _precs()
    for val in vals:
        for sign in signs:
            for prec in precs:
                var x = sign + val
                var tx = _parsed(x, prec)
                var label = x + " at " + format_int(Int64(prec), 10)

                var buf = prefix.copy()
                tx.append_text(buf)
                for i in range(4):
                    assert_equal(buf[i], prefix[i], "the prefix was kept")

                var rx = big.Float()
                rx.set_prec(prec)
                rx.unmarshal_text(Span(buf)[4:])
                assert_equal(rx.cmp(tx), 0, label)

                # `marshal_text` is the same bytes with nothing in front.
                var marshalled = tx.marshal_text()
                assert_equal(len(marshalled), len(buf) - 4, label)
                for i in range(len(marshalled)):
                    assert_equal(marshalled[i], buf[i + 4], label)


def test_text_is_the_shortest_form() raises:
    # The text form is `text('g', -1)`, so it is the shortest string that reads
    # back as the same number and it says nothing about the precision or the
    # mode the number was held at.
    var rows: List[List[String]] = [
        ["0", "0"],
        ["-0", "-0"],
        ["1", "1"],
        ["0.1", "0.1"],
        ["2.71828", "2.71828"],
        ["1234567890", "1.23456789e+09"],
        ["inf", "+Inf"],
        ["-inf", "-Inf"],
    ]
    for row in rows:
        var x = big.Float()
        x.set_prec(53)
        _ = x.parse(row[0], 0)
        var text = x.marshal_text()
        assert_equal(String(from_utf8_lossy=Span(text)), row[1], row[0])


def test_unmarshal_text_rejects_rubbish() raises:
    # Go returns an error rather than a zero, so that a caller reading a
    # malformed document finds out.
    var bad: List[String] = ["", "abc", "0x", "-", "12 34", "1..5"]
    for s in bad:
        var z = big.Float()
        z.set_prec(53)
        _ = z.parse("7", 0)
        with assert_raises():
            z.unmarshal_text(s.as_bytes())
