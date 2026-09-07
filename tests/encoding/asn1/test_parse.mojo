"""Reading DER, over Go's own tables.

`asn1_test.go` tests the parsing helpers directly, on the contents of a value
with the header already taken off. Those helpers are private here, because the
public way in is a `Parser`, so every row is wrapped in the header it would
have arrived with and read back through the public call. That tests one thing
more than Go's version does, which is that the header and the contents agree.

The rows are Go's, case for case, including the long tail of times that are
only refused because a time package that normalises rather than failing turns
the thirteenth month into January of the next year.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.encoding.asn1 import (
    BitString,
    ClassContextSpecific,
    ClassUniversal,
    ObjectIdentifier,
    Parser,
    StructuralError,
    SyntaxError,
    TagBMPString,
    TagBitString,
    TagBoolean,
    TagGeneralizedTime,
    TagIA5String,
    TagInteger,
    TagNumericString,
    TagOID,
    TagPrintableString,
    TagT61String,
    TagUTCTime,
    TagUTF8String,
)
from core.errors import matches
from core.errors.codes import ErrASN1Structural, ErrASN1Syntax
from core.io import Byte

comptime _ZONED = "Jan _2 15:04:05 -0700 2006"
"""Go's own comparison layout for these tests, which names the offset rather
than the zone, since a zone read out of a certificate has no name to print."""


def _der(tag: Int, contents: List[Byte]) -> List[Byte]:
    """`contents` with the header that would have carried them.

    Every row in these tables is short enough for a one byte length, which is
    what the short form of a length is for.
    """
    var out = List[Byte](capacity=len(contents) + 2)
    out.append(Byte(tag))
    out.append(Byte(len(contents)))
    out.extend(Span(contents))
    return out^


def _bytes(text: StringSlice) -> List[Byte]:
    """`text` as the bytes it is written in."""
    var out = List[Byte](capacity=text.byte_length())
    out.extend(text.as_bytes())
    return out^


def _text_der(tag: Int, text: StringSlice) -> List[Byte]:
    """The same as `_der`, for contents easier to write as text."""
    return _der(tag, _bytes(text))


def _same(got: List[Byte], want: List[Byte]) raises:
    """Two byte lists, byte for byte."""
    assert_equal(len(got), len(want))
    for i in range(len(got)):
        assert_equal(got[i], want[i])


def _bool(contents: List[Byte]) raises -> Bool:
    var der = _der(TagBoolean, contents)
    var p = Parser(Span(der))
    return p.read_bool()


def test_a_boolean_is_zero_or_all_ones() raises:
    """Go's `boolTestData`.

    BER takes any nonzero byte as true. DER takes only all ones, because two
    encodings of one value is the ambiguity DER exists to remove, and a hash
    over the encoding would differ for the two.
    """
    assert_equal(_bool([Byte(0x00)]), False)
    assert_equal(_bool([Byte(0xFF)]), True)

    with assert_raises(contains="invalid boolean"):
        _ = _bool(List[Byte]())
    with assert_raises(contains="invalid boolean"):
        _ = _bool([Byte(0x00), Byte(0x00)])
    with assert_raises(contains="invalid boolean"):
        _ = _bool([Byte(0xFF), Byte(0xFF)])
    with assert_raises(contains="invalid boolean"):
        _ = _bool([Byte(0x01)])


def _int64(contents: List[Byte]) raises -> Int64:
    var der = _der(TagInteger, contents)
    var p = Parser(Span(der))
    return p.read_int64()


def test_an_integer_is_two_s_complement_and_minimal() raises:
    """Go's `int64TestData`.

    The last two rows are the whole of why DER is worth having. `00 7f` and
    `ff f0` each say a number that one byte already said, so a writer that
    produced either was not writing DER, and a reader that accepts them lets
    two encodings of one number through.
    """
    assert_equal(_int64([Byte(0x00)]), 0)
    assert_equal(_int64([Byte(0x7F)]), 127)
    assert_equal(_int64([Byte(0x00), Byte(0x80)]), 128)
    assert_equal(_int64([Byte(0x01), Byte(0x00)]), 256)
    assert_equal(_int64([Byte(0x80)]), -128)
    assert_equal(_int64([Byte(0xFF), Byte(0x7F)]), -129)
    assert_equal(_int64([Byte(0xFF)]), -1)

    var least: List[Byte] = [
        Byte(0x80),
        Byte(0),
        Byte(0),
        Byte(0),
        Byte(0),
        Byte(0),
        Byte(0),
        Byte(0),
    ]
    assert_equal(_int64(least), Int64.MIN)

    var nine: List[Byte] = [
        Byte(0x80),
        Byte(0),
        Byte(0),
        Byte(0),
        Byte(0),
        Byte(0),
        Byte(0),
        Byte(0),
        Byte(0),
    ]
    with assert_raises(contains="integer too large"):
        _ = _int64(nine)
    with assert_raises(contains="empty integer"):
        _ = _int64(List[Byte]())
    with assert_raises(contains="minimally-encoded"):
        _ = _int64([Byte(0x00), Byte(0x7F)])
    with assert_raises(contains="minimally-encoded"):
        _ = _int64([Byte(0xFF), Byte(0xF0)])


def _int32(contents: List[Byte]) raises -> Int32:
    var der = _der(TagInteger, contents)
    var p = Parser(Span(der))
    return p.read_int32()


def test_an_integer_that_has_to_fit_in_thirty_two_bits() raises:
    """Go's `int32TestData`, the same rows against a narrower ceiling."""
    assert_equal(_int32([Byte(0x00)]), 0)
    assert_equal(_int32([Byte(0x7F)]), 127)
    assert_equal(_int32([Byte(0x00), Byte(0x80)]), 128)
    assert_equal(_int32([Byte(0x01), Byte(0x00)]), 256)
    assert_equal(_int32([Byte(0x80)]), -128)
    assert_equal(_int32([Byte(0xFF), Byte(0x7F)]), -129)
    assert_equal(_int32([Byte(0xFF)]), -1)
    assert_equal(_int32([Byte(0x80), Byte(0), Byte(0), Byte(0)]), Int32.MIN)

    var five: List[Byte] = [Byte(0x80), Byte(0), Byte(0), Byte(0), Byte(0)]
    with assert_raises(contains="integer too large"):
        _ = _int32(five)
    with assert_raises(contains="empty integer"):
        _ = _int32(List[Byte]())
    with assert_raises(contains="minimally-encoded"):
        _ = _int32([Byte(0x00), Byte(0x7F)])
    with assert_raises(contains="minimally-encoded"):
        _ = _int32([Byte(0xFF), Byte(0xF0)])


def _big(contents: List[Byte]) raises -> String:
    var der = _der(TagInteger, contents)
    var p = Parser(Span(der))
    return p.read_big_int().text(10)


def test_an_integer_of_any_width() raises:
    """Go's `bigIntTests`.

    A certificate serial number is an integer of up to twenty bytes, so the
    number that fits in no machine word has to be readable too. The negative
    rows are the ones worth having, since a two's complement number is read by
    complementing the bytes, reading the magnitude, adding one and negating.
    """
    assert_equal(_big([Byte(0xFF)]), "-1")
    assert_equal(_big([Byte(0x00)]), "0")
    assert_equal(_big([Byte(0x01)]), "1")
    assert_equal(_big([Byte(0x00), Byte(0xFF)]), "255")
    assert_equal(_big([Byte(0xFF), Byte(0x00)]), "-256")
    assert_equal(_big([Byte(0x01), Byte(0x00)]), "256")

    with assert_raises(contains="empty integer"):
        _ = _big(List[Byte]())
    with assert_raises(contains="minimally-encoded"):
        _ = _big([Byte(0x00), Byte(0x7F)])
    with assert_raises(contains="minimally-encoded"):
        _ = _big([Byte(0xFF), Byte(0xF0)])


def _bits(contents: List[Byte]) raises -> BitString:
    var der = _der(TagBitString, contents)
    var p = Parser(Span(der))
    return p.read_bit_string()


def test_a_bit_string_carries_its_padding_count() raises:
    """Go's `bitStringTestData`.

    The first byte says how many bits at the end of the last byte are not
    real, and DER says those bits are zero. A padding count with no bytes to
    pad, a count above seven, and a padding bit that is set are all refused,
    which is what stops one bit string having two encodings.
    """
    var empty = _bits([Byte(0x00)])
    assert_equal(empty.bit_length, 0)
    assert_equal(len(empty.bytes), 0)

    var one = _bits([Byte(0x07), Byte(0x00)])
    assert_equal(one.bit_length, 1)
    assert_equal(len(one.bytes), 1)

    with assert_raises(contains="zero length BIT STRING"):
        _ = _bits(List[Byte]())
    with assert_raises(contains="invalid padding bits"):
        _ = _bits([Byte(0x07), Byte(0x01)])
    with assert_raises(contains="invalid padding bits"):
        _ = _bits([Byte(0x07), Byte(0x40)])
    with assert_raises(contains="invalid padding bits"):
        _ = _bits([Byte(0x08), Byte(0x00)])


def test_a_bit_is_read_by_index() raises:
    """Go's `TestBitStringAt`, including both ends being out of range.

    Go returns zero for an index outside the string rather than panicking,
    which is unusual for Go and is the right answer here, because the callers
    that matter are reading key usage bits out of a certificate that may be
    shorter than the list of bits the specification defines.
    """
    var bits = BitString([Byte(0x82), Byte(0x40)], 16)
    assert_equal(bits.at(0), 1)
    assert_equal(bits.at(1), 0)
    assert_equal(bits.at(6), 1)
    assert_equal(bits.at(9), 1)
    assert_equal(bits.at(-1), 0)
    assert_equal(bits.at(17), 0)


def test_bits_move_to_the_right() raises:
    """Go's `bitStringRightAlignTests`.

    The bits are packed from the top down, and a caller who wants them as a
    number wants the padding at the front instead.
    """
    _same(BitString([Byte(0x80)], 1).right_align(), [Byte(0x01)])
    _same(
        BitString([Byte(0x80), Byte(0x80)], 9).right_align(),
        [Byte(0x01), Byte(0x01)],
    )
    _same(BitString(List[Byte](), 0).right_align(), List[Byte]())
    _same(BitString([Byte(0xCE)], 8).right_align(), [Byte(0xCE)])
    _same(
        BitString([Byte(0xCE), Byte(0x47)], 16).right_align(),
        [Byte(0xCE), Byte(0x47)],
    )
    _same(
        BitString([Byte(0x34), Byte(0x50)], 12).right_align(),
        [Byte(0x03), Byte(0x45)],
    )


def _oid(contents: List[Byte]) raises -> String:
    var der = _der(TagOID, contents)
    var p = Parser(Span(der))
    return String(p.read_object_identifier())


def test_an_object_identifier_packs_its_first_two_numbers() raises:
    """Go's `objectIdentifierTestData`.

    The first number can only be 0, 1 or 2, and the second is under forty
    whenever the first is 0 or 1, so the pair fits in one base 128 integer as
    forty times the first plus the second. Everything after them is one base
    128 integer each.
    """
    assert_equal(_oid([Byte(85)]), "2.5")
    assert_equal(_oid([Byte(85), Byte(0x02)]), "2.5.2")
    assert_equal(
        _oid([Byte(85), Byte(0x02), Byte(0xC0), Byte(0x00)]), "2.5.2.8192"
    )
    assert_equal(_oid([Byte(0x81), Byte(0x34), Byte(0x03)]), "2.100.3")

    with assert_raises(contains="zero length OBJECT IDENTIFIER"):
        _ = _oid(List[Byte]())

    var runs_on: List[Byte] = [
        Byte(85),
        Byte(0x02),
        Byte(0xC0),
        Byte(0x80),
        Byte(0x80),
        Byte(0x80),
        Byte(0x80),
    ]
    with assert_raises():
        _ = _oid(runs_on)

    var oid = ObjectIdentifier([1, 2, 3, 4])
    assert_equal(String(oid), "1.2.3.4")
    assert_equal(len(oid), 4)
    assert_equal(oid[2], 3)
    assert_true(oid.equal(ObjectIdentifier([1, 2, 3, 4])))
    assert_true(oid != ObjectIdentifier([1, 2, 3]))


def _header_of(bytes: List[Byte]) raises -> List[Int]:
    """A header as class, tag, length and compound, so a row is four asserts.

    `read_header` is the one call in the package that takes bytes with no
    contents behind them, which is why these rows go to it whole rather than
    through `_der`.
    """
    var p = Parser(Span(bytes))
    var header = p.read_header()
    var out: List[Int] = [
        header.tag_class,
        header.tag,
        header.length,
        1 if header.is_compound else 0,
    ]
    return out^


def _refuse_header(bytes: List[Byte]) raises:
    var p = Parser(Span(bytes))
    var failed = False
    try:
        _ = p.read_header()
    except:
        failed = True
    assert_true(failed, "a header that should have been refused was read")


def test_a_header_says_class_tag_and_length() raises:
    """Go's `tagAndLengthData`, every row of it.

    Four of the refusals are about minimality and they are the reason this is
    not a two line function. A tag that fits in five bits may not be written
    in the long form, a length under 128 may not be written in the long form,
    a length may not have leading zero bytes, and a first length byte of zero
    says indefinite, which is BER and not DER.
    """
    var context = _header_of([Byte(0x80), Byte(0x01)])
    assert_equal(context[0], ClassContextSpecific)
    assert_equal(context[1], 0)
    assert_equal(context[2], 1)
    assert_equal(context[3], 0)

    var compound = _header_of([Byte(0xA0), Byte(0x01)])
    assert_equal(compound[3], 1)

    var universal = _header_of([Byte(0x02), Byte(0x00)])
    assert_equal(universal[0], ClassUniversal)
    assert_equal(universal[1], 2)
    assert_equal(universal[2], 0)

    var private = _header_of([Byte(0xFE), Byte(0x00)])
    assert_equal(private[0], 3)
    assert_equal(private[1], 30)
    assert_equal(private[3], 1)

    assert_equal(_header_of([Byte(0x1F), Byte(0x1F), Byte(0x00)])[1], 31)
    assert_equal(
        _header_of([Byte(0x1F), Byte(0x81), Byte(0x00), Byte(0x00)])[1], 128
    )

    var widest: List[Byte] = [
        Byte(0x1F),
        Byte(0x81),
        Byte(0x80),
        Byte(0x01),
        Byte(0x00),
    ]
    assert_equal(_header_of(widest)[1], 0x4001)

    assert_equal(_header_of([Byte(0x00), Byte(0x81), Byte(0x80)])[2], 128)
    assert_equal(
        _header_of([Byte(0x00), Byte(0x82), Byte(0x01), Byte(0x00)])[2], 256
    )

    # Four bytes of length reaching the largest one there is. The check that
    # stops a longer one happens before each shift, so this is what fits.
    var largest: List[Byte] = [
        Byte(0xA0),
        Byte(0x84),
        Byte(0x7F),
        Byte(0xFF),
        Byte(0xFF),
        Byte(0xFF),
    ]
    assert_equal(_header_of(largest)[2], 0x7FFFFFFF)

    # A tag number of two to the thirty first minus one, which is as wide as
    # a tag is allowed to be.
    var biggest_tag: List[Byte] = [
        Byte(0x1F),
        Byte(0x87),
        Byte(0xFF),
        Byte(0xFF),
        Byte(0xFF),
        Byte(0x7F),
        Byte(0x00),
    ]
    assert_equal(_header_of(biggest_tag)[1], Int(Int32.MAX))

    # A length saying three bytes follow when two do.
    _refuse_header([Byte(0x00), Byte(0x83), Byte(0x01), Byte(0x00)])
    # A high tag number that never ends.
    _refuse_header([Byte(0x1F), Byte(0x85)])
    # An indefinite length, which is BER.
    _refuse_header([Byte(0x30), Byte(0x80)])
    # A length written with a leading zero byte.
    _refuse_header([Byte(0xA0), Byte(0x82), Byte(0x00), Byte(0xFF)])
    # A length one larger than the largest.
    _refuse_header(
        [Byte(0xA0), Byte(0x84), Byte(0x80), Byte(0), Byte(0), Byte(0)]
    )
    # A length under 128 written in the long form.
    _refuse_header([Byte(0xA0), Byte(0x81), Byte(0x7F)])
    # A tag number too large to hold.
    _refuse_header(
        [
            Byte(0x1F),
            Byte(0x88),
            Byte(0x80),
            Byte(0x80),
            Byte(0x80),
            Byte(0x00),
            Byte(0x00),
        ]
    )
    # A tag number that fits in the five bits, written in the long form.
    _refuse_header([Byte(0x1F), Byte(0x1E), Byte(0x00)])


def _utc(text: StringSlice) raises -> String:
    var der = _text_der(TagUTCTime, text)
    var p = Parser(Span(der))
    return p.read_utc_time().format(_ZONED)


def _refuse_utc(text: String) raises:
    var failed = False
    try:
        _ = _utc(text)
    except:
        failed = True
    assert_true(failed, text)


def test_a_utc_time_has_a_two_digit_year() raises:
    """Go's `utcTestData`.

    Two digits cannot say a year from 2050 on, so RFC 5280 reads 50 to 99 as
    the nineteen hundreds, which is the row that comes back as 1951. The long
    tail of refusals is Go's issue 11134: a time package that normalises turns
    the thirteenth month into January of the next year, so the time is written
    back out and compared with what came in, and anything that moved is
    refused.
    """
    assert_equal(_utc("910506164540-0700"), "May  6 16:45:40 -0700 1991")
    assert_equal(_utc("910506164540+0730"), "May  6 16:45:40 +0730 1991")
    assert_equal(_utc("910506234540Z"), "May  6 23:45:40 +0000 1991")
    assert_equal(_utc("9105062345Z"), "May  6 23:45:00 +0000 1991")
    assert_equal(_utc("5105062345Z"), "May  6 23:45:00 +0000 1951")

    var refused: List[String] = [
        "a10506234540Z",
        "91a506234540Z",
        "9105a6234540Z",
        "910506a34540Z",
        "910506334a40Z",
        "91050633444aZ",
        "910506334461Z",
        "910506334400Za",
        "000100000000Z",
        "101302030405Z",
        "100002030405Z",
        "100100030405Z",
        "100132030405Z",
        "100231030405Z",
        "100102240405Z",
        "100102036005Z",
        "100102030460Z",
        "-100102030410Z",
        "10-0102030410Z",
        "10-0002030410Z",
        "1001-02030410Z",
        "100102-030410Z",
        "10010203-0410Z",
        "1001020304-10Z",
    ]
    for text in refused:
        _refuse_utc(text)


def _generalized(text: StringSlice) raises -> String:
    var der = _text_der(TagGeneralizedTime, text)
    var p = Parser(Span(der))
    return p.read_generalized_time().format(_ZONED)


def _refuse_generalized(text: String) raises:
    var failed = False
    try:
        _ = _generalized(text)
    except:
        failed = True
    assert_true(failed, text)


def test_a_generalized_time_has_four() raises:
    """Go's `generalizedTimeTestData`.

    A GeneralizedTime says its year in full and may carry fractional seconds,
    and DER says it has to carry a zone, which is why every row without one is
    refused. A decimal point with no digits behind it goes as well, since the
    layout that reads the fraction reads at least one digit.
    """
    assert_equal(_generalized("20100102030405Z"), "Jan  2 03:04:05 +0000 2010")
    assert_equal(
        _generalized("20100102030405.123456Z"), "Jan  2 03:04:05 +0000 2010"
    )
    assert_equal(
        _generalized("20100102030405+0607"), "Jan  2 03:04:05 +0607 2010"
    )
    assert_equal(
        _generalized("20100102030405-0607"), "Jan  2 03:04:05 -0607 2010"
    )

    var refused: List[String] = [
        "20100102030405",
        "20100102030405.123456",
        "20100102030405.Z",
        "20100102030405.",
        "00000100000000Z",
        "20101302030405Z",
        "20100002030405Z",
        "20100100030405Z",
        "20100132030405Z",
        "20100231030405Z",
        "20100102240405Z",
        "20100102036005Z",
        "20100102030460Z",
        "-20100102030410Z",
        "2010-0102030410Z",
        "2010-0002030410Z",
        "201001-02030410Z",
        "20100102-030410Z",
        "2010010203-0410Z",
        "201001020304-10Z",
    ]
    for text in refused:
        _refuse_generalized(text)


def test_either_time_type_is_taken_where_a_certificate_allows_both() raises:
    """`read_time`, which is what a validity date is read with.

    A certificate writes a date as a UTCTime before 2050 and a
    GeneralizedTime from then on, and the writer chooses, so the reader of one
    has to take either.
    """
    var short = _text_der(TagUTCTime, "910506234540Z")
    var p = Parser(Span(short))
    assert_equal(p.read_time().format(_ZONED), "May  6 23:45:40 +0000 1991")

    var long = _text_der(TagGeneralizedTime, "20100102030405Z")
    var q = Parser(Span(long))
    assert_equal(q.read_time().format(_ZONED), "Jan  2 03:04:05 +0000 2010")


def _printable(contents: List[Byte]) raises -> String:
    var der = _der(TagPrintableString, contents)
    var p = Parser(Span(der))
    return p.read_printable_string()


def _numeric(contents: List[Byte]) raises -> String:
    var der = _der(TagNumericString, contents)
    var p = Parser(Span(der))
    return p.read_numeric_string()


def _ia5(contents: List[Byte]) raises -> String:
    var der = _der(TagIA5String, contents)
    var p = Parser(Span(der))
    return p.read_ia5_string()


def _utf8(contents: List[Byte]) raises -> String:
    var der = _der(TagUTF8String, contents)
    var p = Parser(Span(der))
    return p.read_utf8_string()


def _t61(contents: List[Byte]) raises -> String:
    var der = _der(TagT61String, contents)
    var p = Parser(Span(der))
    return p.read_t61_string()


def _bmp(contents: List[Byte]) raises -> String:
    var der = _der(TagBMPString, contents)
    var p = Parser(Span(der))
    return p.read_bmp_string()


def _any_string(tag: Int, contents: List[Byte]) raises -> String:
    var der = _der(tag, contents)
    var p = Parser(Span(der))
    return p.read_string()


def test_each_string_type_checks_its_own_alphabet() raises:
    """The sets that have one, and a character outside each.

    PrintableString is a 1988 subset of ASCII that leaves out `@` and `_`,
    which is why so many certificates put a mail address in an IA5String
    instead. Go allows `*` and `&` on top of the set, for wildcard names and
    for a handful of certificate authorities, and so does this.
    """
    assert_equal(_printable(_bytes("Acme Ltd.")), "Acme Ltd.")
    assert_equal(_printable(_bytes("*.example.com")), "*.example.com")
    assert_equal(_printable(_bytes("A & B")), "A & B")
    with assert_raises(contains="PrintableString"):
        _ = _printable(_bytes("a@b"))

    assert_equal(_numeric(_bytes("123 456")), "123 456")
    with assert_raises(contains="NumericString"):
        _ = _numeric(_bytes("12-34"))

    assert_equal(_ia5(_bytes("user@example.com")), "user@example.com")
    with assert_raises(contains="IA5String"):
        _ = _ia5([Byte(0x61), Byte(0x80)])

    assert_equal(_utf8(_bytes("café")), "café")
    with assert_raises(contains="invalid UTF-8"):
        _ = _utf8([Byte(0xFF)])


def test_a_t61_string_is_read_as_latin1() raises:
    """What Go does, what BoringSSL does, and what is not quite right.

    T.61 is a defunct encoding whose code page nearly matches Latin-1, the
    difference being characters T.61 does not have. Nobody maps the
    difference, because the strings this shows up in were written by software
    that meant Latin-1 anyway.
    """
    assert_equal(_t61([Byte(0x63), Byte(0x61), Byte(0x66), Byte(0xE9)]), "café")


def test_a_bmp_string_is_ucs2() raises:
    """Two bytes to a character, and no surrogates.

    UCS-2 is UTF-16 without the pairs, so a pair of bytes naming half of a
    surrogate is not a character at all. The permanent noncharacters go with
    them, which is what BoringSSL refuses and what Go refuses.
    """
    assert_equal(_bmp([Byte(0x00), Byte(0x68), Byte(0x00), Byte(0x69)]), "hi")
    assert_equal(_bmp([Byte(0x00), Byte(0xE9)]), "é")

    with assert_raises(contains="invalid BMPString"):
        _ = _bmp([Byte(0xD8), Byte(0x00)])
    with assert_raises(contains="invalid BMPString"):
        _ = _bmp([Byte(0x00)])


def test_a_string_can_be_read_without_knowing_which_type_it_is() raises:
    """`read_string`, which is how a name in a certificate arrives.

    A distinguished name says its parts may be any of several string types
    and does not say which, so the tag is what chooses. GeneralString is the
    one that is refused, because nothing says which of its several registered
    character sets a given string is in.
    """
    assert_equal(_any_string(TagPrintableString, _bytes("Example")), "Example")
    assert_equal(_any_string(TagUTF8String, _bytes("Beispiel")), "Beispiel")

    with assert_raises(contains="GeneralString is not supported"):
        _ = _any_string(27, _bytes("anything"))
    with assert_raises(contains="is not a string type"):
        _ = _any_string(TagInteger, [Byte(0x01)])


def test_a_sequence_hands_back_a_reader_for_its_contents() raises:
    """The call every structure is read through.

    A second `Parser` over the contents rather than a recursive call, which is
    what makes a deeply nested structure cost bytes rather than stack frames.
    """
    # SEQUENCE { INTEGER 1, BOOLEAN true, NULL }
    var der: List[Byte] = [
        Byte(0x30),
        Byte(0x08),
        Byte(0x02),
        Byte(0x01),
        Byte(0x01),
        Byte(0x01),
        Byte(0x01),
        Byte(0xFF),
        Byte(0x05),
        Byte(0x00),
    ]
    var top = Parser(Span(der))
    var body = top.read_sequence()
    assert_equal(body.read_int64(), 1)
    assert_equal(body.read_bool(), True)
    body.read_null()
    assert_equal(body.at_end(), True)
    body.end()
    top.end()


def test_a_set_is_not_a_sequence() raises:
    """Where this parts company with Go, on purpose.

    Go maps SET onto SEQUENCE while parsing and takes either wherever one is
    wanted. This does not, because the two say different things about whether
    order is meaningful, and a reader that cannot tell them apart cannot check
    that a SET OF was sorted.
    """
    var as_set: List[Byte] = [
        Byte(0x31),
        Byte(0x03),
        Byte(0x02),
        Byte(0x01),
        Byte(0x07),
    ]
    var one = Parser(Span(as_set))
    var body = one.read_set()
    assert_equal(body.read_int64(), 7)

    var two = Parser(Span(as_set))
    with assert_raises(contains="tag mismatch"):
        _ = two.read_sequence()

    var as_sequence: List[Byte] = [
        Byte(0x30),
        Byte(0x03),
        Byte(0x02),
        Byte(0x01),
        Byte(0x07),
    ]
    var three = Parser(Span(as_sequence))
    with assert_raises(contains="tag mismatch"):
        _ = three.read_set()


def test_trailing_data_is_refused() raises:
    """A structure carrying bytes after its last field.

    Reading the fields and ignoring the rest is how a signature ends up
    covering something other than what was checked, so `end` exists and says
    so.
    """
    var der: List[Byte] = [
        Byte(0x30),
        Byte(0x03),
        Byte(0x02),
        Byte(0x01),
        Byte(0x01),
        Byte(0x00),
    ]
    var top = Parser(Span(der))
    var body = top.read_sequence()
    assert_equal(body.read_int64(), 1)
    body.end()
    assert_equal(top.remaining(), 1)
    with assert_raises(contains="trailing data"):
        top.end()


def test_a_value_that_runs_off_the_end_is_refused() raises:
    """A length saying more bytes than there are."""
    var der: List[Byte] = [Byte(0x02), Byte(0x08), Byte(0x01)]
    var p = Parser(Span(der))
    with assert_raises(contains="data truncated"):
        _ = p.read_int64()

    var nothing = Parser(Span(List[Byte]()))
    with assert_raises(contains="truncated tag or length"):
        _ = nothing.read_header()


def test_a_null_has_no_contents() raises:
    """NULL is a tag and a length of zero, and nothing else is NULL."""
    var good: List[Byte] = [Byte(0x05), Byte(0x00)]
    var q = Parser(Span(good))
    q.read_null()
    assert_equal(q.at_end(), True)

    var padded: List[Byte] = [Byte(0x05), Byte(0x01), Byte(0x00)]
    var p = Parser(Span(padded))
    with assert_raises(contains="NULL with contents"):
        p.read_null()


def test_a_raw_value_keeps_the_bytes_it_came_from() raises:
    """Go's `RawValue`, which is how a signature over a field is checked.

    Go's two slices point into the input. These are lists of their own, so a
    value kept after the input has gone is still the value that was read.
    """
    var der: List[Byte] = [
        Byte(0x30),
        Byte(0x05),
        Byte(0x04),
        Byte(0x03),
        Byte(0x61),
        Byte(0x62),
        Byte(0x63),
    ]
    var top = Parser(Span(der))
    var body = top.read_sequence()
    var raw = body.read_raw_value()
    assert_equal(raw.tag_class, ClassUniversal)
    assert_equal(raw.tag, 4)
    assert_equal(raw.is_compound, False)
    _same(raw.bytes, [Byte(0x61), Byte(0x62), Byte(0x63)])
    _same(
        raw.full_bytes,
        [Byte(0x04), Byte(0x03), Byte(0x61), Byte(0x62), Byte(0x63)],
    )
    body.end()


def test_the_two_kinds_of_tagging() raises:
    """What `[0]` in a definition means, both ways it can mean it.

    EXPLICIT puts a second header in front of the value's own, so the reader
    opens the wrapper and finds a complete value inside. IMPLICIT replaces the
    value's header, so what is inside is contents with nothing in front of
    them and only the definition says what they hold.
    """
    # [0] EXPLICIT { INTEGER 7 }
    var explicit: List[Byte] = [
        Byte(0xA0),
        Byte(0x03),
        Byte(0x02),
        Byte(0x01),
        Byte(0x07),
    ]
    var outer = Parser(Span(explicit))
    var wrapper = outer.read_explicit(0)
    assert_equal(wrapper.read_int64(), 7)
    wrapper.end()

    # [1] IMPLICIT OCTET STRING "hi"
    var implicit: List[Byte] = [
        Byte(0x81),
        Byte(0x02),
        Byte(0x68),
        Byte(0x69),
    ]
    var p = Parser(Span(implicit))
    var contents = p.read_implicit(1, False)
    assert_equal(len(contents), 2)
    assert_equal(contents[0], Byte(0x68))
    assert_equal(contents[1], Byte(0x69))


def test_an_octet_string_comes_back_as_bytes_of_its_own() raises:
    """The one string type that is not text."""
    var der: List[Byte] = [
        Byte(0x04),
        Byte(0x03),
        Byte(0xDE),
        Byte(0xAD),
        Byte(0xBE),
    ]
    var p = Parser(Span(der))
    _same(p.read_octet_string(), [Byte(0xDE), Byte(0xAD), Byte(0xBE)])


def test_an_enumerated_is_an_integer_with_another_tag() raises:
    """ENUMERATED, which exists so that reflection can tell the two apart."""
    var der: List[Byte] = [Byte(0x0A), Byte(0x01), Byte(0x02)]
    var p = Parser(Span(der))
    assert_equal(p.read_enumerated(), 2)

    var as_integer: List[Byte] = [Byte(0x02), Byte(0x01), Byte(0x02)]
    var q = Parser(Span(as_integer))
    with assert_raises(contains="tag mismatch"):
        _ = q.read_enumerated()


def test_the_two_errors_are_told_apart() raises:
    """Go's split, and the reason for it.

    A syntax error says the bytes are not DER, which means the sender is
    broken. A structural error says they are DER for something else, which
    means the sender and the reader disagree about what a field holds. A
    certificate parser reports the two differently, so they are two codes.
    """
    # DER says true is all ones, so a boolean of two is not a boolean.
    var bad: List[Byte] = [Byte(0x01), Byte(0x01), Byte(0x02)]
    var p = Parser(Span(bad))
    try:
        _ = p.read_bool()
        raise Error("a boolean of two was read rather than refused")
    except e:
        assert_true(matches(e, ErrASN1Syntax))
        var failure = SyntaxError.of(e)
        assert_true(Bool(failure))
        assert_equal(failure.value().msg, "invalid boolean")
        assert_equal(
            failure.value().error(), "asn1: syntax error: invalid boolean"
        )
        assert_equal(
            String(failure.value()), "asn1: syntax error: invalid boolean"
        )
        assert_true(not Bool(StructuralError.of(e)))

    # An INTEGER where a BOOLEAN was wanted: well formed, and not what was
    # asked for.
    var wrong: List[Byte] = [Byte(0x02), Byte(0x01), Byte(0x01)]
    var q = Parser(Span(wrong))
    try:
        _ = q.read_bool()
        raise Error("an integer was read as a boolean")
    except e:
        assert_true(matches(e, ErrASN1Structural))
        var failure = StructuralError.of(e)
        assert_true(Bool(failure))
        assert_equal(
            failure.value().error(),
            (
                "asn1: structure error: tag mismatch, wanted class 0 tag 1,"
                " got class 0 tag 2"
            ),
        )
        assert_true(not Bool(SyntaxError.of(e)))


def test_a_value_can_be_skipped_whole() raises:
    """What a field nothing matches costs: the value is stepped over."""
    var der: List[Byte] = [
        Byte(0x30),
        Byte(0x08),
        Byte(0x30),
        Byte(0x03),
        Byte(0x02),
        Byte(0x01),
        Byte(0x09),
        Byte(0x01),
        Byte(0x01),
        Byte(0xFF),
    ]
    var top = Parser(Span(der))
    var body = top.read_sequence()
    body.skip_value()
    assert_equal(body.read_bool(), True)
    body.end()


def test_a_header_can_be_looked_at_without_reading_it() raises:
    """What a caller asks when the next field is optional."""
    var der: List[Byte] = [Byte(0x02), Byte(0x01), Byte(0x2A)]
    var p = Parser(Span(der))
    var ahead = p.peek_header()
    assert_equal(ahead.tag, TagInteger)
    assert_equal(ahead.length, 1)
    assert_equal(p.pos, 0)
    assert_equal(p.remaining(), 3)
    assert_equal(p.read_int64(), 42)
    assert_equal(p.at_end(), True)
