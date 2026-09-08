"""Writing DER, over Go's own tables.

`marshal_test.go` builds a Go value, marshals it and compares the hex. There is
no reflection here, so what Go expresses as a struct with tags on it is
expressed as the calls a generated writer would make: `intStruct{64}` is a
sequence opened, an integer written and the sequence closed. Every expected
string is Go's, character for character, so a row that disagrees disagrees with
Go rather than with an idea of what DER should be.

The rest of the file is what Go's table cannot reach: lengths that outgrow the
byte reserved for them, a SET OF put into the order X.690 asks for, and the
round trip back through `Parser`, which is the property the whole package
exists for.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.encoding.asn1 import (
    BitString,
    Builder,
    ClassApplication,
    ClassContextSpecific,
    ClassPrivate,
    ClassUniversal,
    ObjectIdentifier,
    Parser,
    RawValue,
    StructuralError,
)
from core.errors import matches
from core.errors.codes import ErrASN1Structural
from core.io import Byte
from core.math.big import Int as BigInt
from core.time import APRIL, JANUARY, NOVEMBER, date, fixed_zone, unix, utc

comptime _DIGITS = "0123456789abcdef"
"""Lower case, because Go's tables are written in lower case."""


def _hex(bytes: List[Byte]) -> String:
    """`bytes` the way Go's test table writes them."""
    var out = String()
    for i in range(len(bytes)):
        var b = Int(bytes[i])
        out += _DIGITS[byte=b >> 4]
        out += _DIGITS[byte=b & 0xF]
    return out^


def _repeat(text: StringSlice, times: Int) -> String:
    """`text` written `times` over, for the two rows that are a long
    string."""
    var out = String()
    for _ in range(times):
        out += text
    return out^


def _bytes(text: StringSlice) -> List[Byte]:
    """`text` as the bytes it is written in."""
    var out = List[Byte](capacity=text.byte_length())
    out.extend(text.as_bytes())
    return out^


def _bytes_of(span: Span[Byte, _]) -> List[Byte]:
    """A span as a list of its own, for the hex helper."""
    var out = List[Byte](capacity=len(span))
    out.extend(span)
    return out^


def test_gos_integers() raises:
    """The five bare integers Go's table opens with.

    The interesting pairs are 127 against 128 and -128 against -129, which are
    where the width goes up because the top bit would otherwise say the wrong
    thing about the sign.
    """
    var ten = Builder()
    ten.add_int64(10)
    assert_equal(_hex(ten^.finish()), "02010a")

    var high = Builder()
    high.add_int64(127)
    assert_equal(_hex(high^.finish()), "02017f")

    var wider = Builder()
    wider.add_int64(128)
    assert_equal(_hex(wider^.finish()), "02020080")

    var low = Builder()
    low.add_int64(-128)
    assert_equal(_hex(low^.finish()), "020180")

    var lower = Builder()
    lower.add_int64(-129)
    assert_equal(_hex(lower^.finish()), "0202ff7f")


def test_gos_sequences_of_integers() raises:
    """Go's `intStruct`, `twoIntStruct` and `nestedStruct` rows.

    A struct is a SEQUENCE and a struct inside a struct is a SEQUENCE inside a
    SEQUENCE, which here is two `begin_sequence` calls before the first `end`.
    """
    var one = Builder()
    one.begin_sequence()
    one.add_int64(64)
    one.end()
    assert_equal(_hex(one^.finish()), "3003020140")

    var two = Builder()
    two.begin_sequence()
    two.add_int64(64)
    two.add_int64(65)
    two.end()
    assert_equal(_hex(two^.finish()), "3006020140020141")

    var nested = Builder()
    nested.begin_sequence()
    nested.begin_sequence()
    nested.add_int64(127)
    nested.end()
    nested.end()
    assert_equal(_hex(nested^.finish()), "3005300302017f")


def test_gos_big_integer_row() raises:
    """Go's `bigIntStruct{big.NewInt(0x123456)}`."""
    var b = Builder()
    b.begin_sequence()
    b.add_big_int(BigInt(0x123456))
    b.end()
    assert_equal(_hex(b^.finish()), "30050203123456")


def test_gos_octet_string_row() raises:
    """Go's `[]byte{1, 2, 3}`, which marshals as an OCTET STRING."""
    var contents: List[Byte] = [Byte(1), Byte(2), Byte(3)]
    var b = Builder()
    b.add_octet_string(Span(contents))
    assert_equal(_hex(b^.finish()), "0403010203")


def test_gos_implicit_and_explicit_tag_rows() raises:
    """Go's `implicitTagTest` and `explicitTagTest`.

    An implicit tag replaces the value's own header, which is what the two
    defaulted arguments on every writer are for. An explicit tag wraps it, so
    the integer keeps its INTEGER header and gains a compound one outside it.
    """
    var implicit = Builder()
    implicit.begin_sequence()
    implicit.add_int64(64, ClassContextSpecific, 5)
    implicit.end()
    assert_equal(_hex(implicit^.finish()), "3003850140")

    var explicit = Builder()
    explicit.begin_sequence()
    explicit.begin_explicit(5)
    explicit.add_int64(64)
    explicit.end()
    explicit.end()
    assert_equal(_hex(explicit^.finish()), "3005a503020140")


def test_gos_flag_rows() raises:
    """Go's `flagTest`, where the value is whether the field is there at all.

    A `Flag` that is set writes an empty tagged value and one that is not
    writes nothing, which is why the second row is an empty SEQUENCE.
    """
    var present = Builder()
    present.begin_sequence()
    present.begin_implicit(0, False)
    present.end()
    present.end()
    assert_equal(_hex(present^.finish()), "30028000")

    var absent = Builder()
    absent.begin_sequence()
    absent.end()
    assert_equal(_hex(absent^.finish()), "3000")


def test_gos_time_rows() raises:
    """The four bare times in Go's table, and the sequence around one of them.

    The third is Go's only row in a zone that is not UTC, and it is eight bytes
    longer because the offset is written out where a `Z` would go. The fourth
    is far enough away that a two digit year cannot say it, so `add_time`
    reaches for the other type without being told to.
    """
    var epoch = Builder()
    epoch.add_time(unix(0, 0).utc())
    assert_equal(_hex(epoch^.finish()), "170d3730303130313030303030305a")

    var later = Builder()
    later.add_time(unix(1258325776, 0).utc())
    assert_equal(_hex(later^.finish()), "170d3039313131353232353631365a")

    var pst = fixed_zone("PST", -8 * 60 * 60)
    var zoned = Builder()
    zoned.add_time(unix(1258325776, 0).in_location(pst))
    assert_equal(
        _hex(zoned^.finish()), "17113039313131353134353631362d30383030"
    )

    var far = Builder()
    far.add_time(date(2100, APRIL, 5, 12, 1, 1, 0, utc()))
    assert_equal(_hex(far^.finish()), "180f32313030303430353132303130315a")

    var asked = Builder()
    asked.begin_sequence()
    asked.add_generalized_time(unix(1258325776, 0).utc())
    asked.end()
    assert_equal(
        _hex(asked^.finish()), "3011180f32303039313131353232353631365a"
    )


def test_gos_bit_string_rows() raises:
    """Go's two `BitString` rows, one bit and twelve.

    The first byte of the contents is how many bits of the last byte are
    padding, so one bit of a byte pads seven and twelve bits of two bytes pad
    four.
    """
    var one_bit = Builder()
    one_bit.add_bit_string(BitString([Byte(0x80)], 1))
    assert_equal(_hex(one_bit^.finish()), "03020780")

    var twelve = Builder()
    twelve.add_bit_string(BitString([Byte(0x81), Byte(0xF0)], 12))
    assert_equal(_hex(twelve^.finish()), "03030481f0")


def test_gos_object_identifier_rows() raises:
    """The three in Go's table and the two in its `TestMarshalOID`.

    The first two numbers share one base 128 integer, which is why 1.2 is one
    byte and why 2.100 and 2.999 need more than the second number alone would.
    """
    var short = Builder()
    short.add_object_identifier(ObjectIdentifier([1, 2, 3, 4]))
    assert_equal(_hex(short^.finish()), "06032a0304")

    var long = Builder()
    long.add_object_identifier(ObjectIdentifier([1, 2, 840, 133549, 1, 1, 5]))
    assert_equal(_hex(long^.finish()), "06092a864888932d010105")

    var hundred = Builder()
    hundred.add_object_identifier(ObjectIdentifier([2, 100, 3]))
    assert_equal(_hex(hundred^.finish()), "0603813403")

    var example = Builder()
    example.add_object_identifier(ObjectIdentifier([2, 999, 3]))
    assert_equal(_hex(example^.finish()), "0603883703")

    var zero = Builder()
    zero.add_object_identifier(ObjectIdentifier([0, 0]))
    assert_equal(_hex(zero^.finish()), "060100")


def test_gos_string_rows() raises:
    """Every string row in Go's table, including the two that pick a type.

    `add_string` is the one that picks, and Go's rule is that a string gets a
    PrintableString if the whole of it fits and a UTF8String otherwise. The
    asterisk and the ampersand are both outside that set, which is why the
    two rows with them in come back tagged 0x0c.
    """
    var plain = Builder()
    plain.add_string("test")
    assert_equal(_hex(plain^.finish()), "130474657374")

    var ia5 = Builder()
    ia5.begin_sequence()
    ia5.add_ia5_string("test")
    ia5.end()
    assert_equal(_hex(ia5^.finish()), "3006160474657374")

    var printable = Builder()
    printable.begin_sequence()
    printable.add_printable_string("test")
    printable.end()
    assert_equal(_hex(printable^.finish()), "3006130474657374")

    var starred = Builder()
    starred.begin_sequence()
    starred.add_printable_string("test*")
    starred.end()
    assert_equal(_hex(starred^.finish()), "30071305746573742a")

    var chosen = Builder()
    chosen.begin_sequence()
    chosen.add_string("test")
    chosen.end()
    assert_equal(_hex(chosen^.finish()), "3006130474657374")

    var chosen_star = Builder()
    chosen_star.begin_sequence()
    chosen_star.add_string("test*")
    chosen_star.end()
    assert_equal(_hex(chosen_star^.finish()), "30070c05746573742a")

    var chosen_amp = Builder()
    chosen_amp.begin_sequence()
    chosen_amp.add_string("test&")
    chosen_amp.end()
    assert_equal(_hex(chosen_amp^.finish()), "30070c057465737426")

    var numeric = Builder()
    numeric.begin_sequence()
    numeric.add_numeric_string("1 9")
    numeric.end()
    assert_equal(_hex(numeric^.finish()), "30051203312039")

    var sigma = Builder()
    sigma.add_string(String(chr(0x3A3)))
    assert_equal(_hex(sigma^.finish()), "0c02cea3")


def test_gos_two_rows_that_straddle_the_short_length_form() raises:
    """127 and 128 of the same character, which is where the length grows.

    A length below 128 is one byte. From 128 up the first byte says how many
    bytes of length follow, so 128 costs two bytes to say where 127 cost one.
    This is the row that proves `end` widening a placeholder produces the same
    bytes as writing the length up front.
    """
    var short = Builder()
    short.add_string(_repeat("x", 127))
    var short_hex = _hex(short^.finish())
    assert_equal(short_hex[byte=0:4], "137f")
    assert_equal(short_hex.byte_length(), 4 + 127 * 2)

    var long = Builder()
    long.add_string(_repeat("x", 128))
    var long_hex = _hex(long^.finish())
    assert_equal(long_hex[byte=0:6], "138180")
    assert_equal(long_hex.byte_length(), 6 + 128 * 2)


def test_gos_raw_value_rows() raises:
    """Go's `optionalRawValueTest`, `rawContentsStruct` and `RawValue` rows.

    A raw value with no full encoding gets a header built from its class, tag
    and compound bit. A raw content is the bytes of the structure it belongs
    to, and Go strips the header off them and writes its own, which is what
    `add_encoded` inside an open SEQUENCE does here.
    """
    var absent = Builder()
    absent.begin_sequence()
    absent.end()
    assert_equal(_hex(absent^.finish()), "3000")

    var raw = Builder()
    var contents: List[Byte] = [Byte(1), Byte(2), Byte(3)]
    raw.add_raw_value(
        RawValue(ClassContextSpecific, 1, False, contents.copy(), List[Byte]())
    )
    assert_equal(_hex(raw^.finish()), "8103010203")

    var fields = Builder()
    fields.begin_sequence()
    fields.add_int64(64)
    fields.end()
    assert_equal(_hex(fields^.finish()), "3003020140")

    var kept = Builder()
    kept.begin_sequence()
    kept.add_encoded(Span(contents))
    kept.end()
    assert_equal(_hex(kept^.finish()), "3003010203")


def test_gos_set_and_omitempty_rows() raises:
    """Go's `testSET`, `omitEmptyTest` and the three `MarshalWithParams`
    rows.

    A field that is empty and marked `omitempty` writes nothing, so the row
    with an empty slice in it is an empty SEQUENCE.
    """
    var set_of = Builder()
    set_of.begin_set_of()
    set_of.add_int64(10)
    set_of.end()
    assert_equal(_hex(set_of^.finish()), "310302010a")

    var empty = Builder()
    empty.begin_sequence()
    empty.end()
    assert_equal(_hex(empty^.finish()), "3000")

    var one = Builder()
    one.begin_sequence()
    one.begin_sequence()
    one.add_string("1")
    one.end()
    one.end()
    assert_equal(_hex(one^.finish()), "30053003130131")

    var as_set = Builder()
    as_set.begin_set()
    as_set.add_int64(10)
    as_set.end()
    assert_equal(_hex(as_set^.finish()), "310302010a")

    var as_application = Builder()
    as_application.begin(ClassApplication, 0, True)
    as_application.add_int64(10)
    as_application.end()
    assert_equal(_hex(as_application^.finish()), "600302010a")

    var as_private = Builder()
    as_private.begin(ClassPrivate, 0, True)
    as_private.add_int64(10)
    as_private.end()
    assert_equal(_hex(as_private^.finish()), "e00302010a")


def test_gos_application_and_private_rows() raises:
    """Go's `applicationTest` and `privateTest`.

    The private row is the one that matters most: its third field has tag 31
    and its fourth has tag 128, which are the first tag that cannot fit in the
    identifier octet and the first that needs two base 128 groups. Go's
    comments on those two fields say the same thing.
    """
    var application = Builder()
    application.begin_sequence()
    application.add_int64(1, ClassApplication, 0)
    application.begin(ClassApplication, 1, True)
    application.add_int64(2)
    application.end()
    application.end()
    assert_equal(_hex(application^.finish()), "30084001016103020102")

    var private = Builder()
    private.begin_sequence()
    private.add_int64(1, ClassPrivate, 0)
    private.begin(ClassPrivate, 1, True)
    private.add_int64(2)
    private.end()
    private.add_int64(3, ClassPrivate, 31)
    private.add_int64(4, ClassPrivate, 128)
    private.end()
    assert_equal(
        _hex(private^.finish()), "3011c00101e103020102df1f0103df81000104"
    )


def test_gos_rows_that_fail() raises:
    """Go's `marshalErrTests`, minus the one about a nil pointer.

    Go's first row is a `*big.Int` that is nil, which cannot happen here
    because a `BigInt` is a value and a value with nothing in it is zero.
    """
    var numeric = Builder()
    with assert_raises(contains="invalid character"):
        numeric.add_numeric_string("a")

    var ia5 = Builder()
    with assert_raises(contains="invalid character"):
        ia5.add_ia5_string(String(chr(0xB0)))

    var printable = Builder()
    with assert_raises(contains="invalid character"):
        printable.add_printable_string("!")


def test_a_refusal_is_a_structural_error() raises:
    """Which is the code Go's writer raises everywhere but one place.

    Go's single exception is the invalid UTF-8 check, which returns a plain
    `errors.New`. There is nothing to check here, because a `StringSlice`
    holds UTF-8 by construction, so every refusal this writer makes is
    structural and a caller has one code to look for.
    """
    var b = Builder()
    var said = Error()
    try:
        b.add_printable_string("!")
    except e:
        said = e.copy()
    assert_true(matches(said, ErrASN1Structural))
    var failure = StructuralError.of(said)
    assert_true(Bool(failure))
    assert_equal(
        failure.value().msg, "PrintableString contains invalid character"
    )


def test_a_length_that_outgrows_its_placeholder_moves_the_contents() raises:
    """The one thing writing forward has to get right.

    A SEQUENCE is opened with one byte of room for its length. Three lengths
    are tried here: one that fits, one that needs a second byte and one that
    needs a third. Each is read back to prove the contents that were shifted
    up are still the contents that went in.
    """
    for count in [100, 200, 40000]:
        var b = Builder()
        b.begin_sequence()
        var payload = List[Byte](capacity=count)
        for i in range(count):
            payload.append(Byte(i & 0xFF))
        b.add_octet_string(Span(payload))
        b.end()
        var der = b^.finish()

        var top = Parser(Span(der))
        var body = top.read_sequence()
        var read = body.read_octet_string()
        body.end()
        top.end()
        assert_equal(len(read), count)
        for i in range(count):
            assert_equal(read[i], Byte(i & 0xFF))


def test_an_outer_length_counts_what_an_inner_one_grew_by() raises:
    """Nesting, where the inner value widens after the outer one was opened.

    The outer length has to count the bytes the inner length gained, which it
    does because the outer one is not written until the outer value is closed
    and by then the inner one is already the size it will stay.
    """
    var payload = List[Byte](capacity=300)
    for i in range(300):
        payload.append(Byte(i & 0xFF))

    var b = Builder()
    b.begin_sequence()
    b.begin_sequence()
    b.add_octet_string(Span(payload))
    b.end()
    b.add_int64(7)
    b.end()
    var der = b^.finish()

    var top = Parser(Span(der))
    var outer = top.read_sequence()
    var inner = outer.read_sequence()
    assert_equal(len(inner.read_octet_string()), 300)
    inner.end()
    assert_equal(outer.read_int64(), 7)
    outer.end()
    top.end()


def test_a_set_of_is_sorted_and_a_set_is_not() raises:
    """X.690 section 11.6, which is what makes two writers agree.

    The same three integers are written in the same order into both, and only
    the SET OF comes back in ascending octet order. A SET keeps what the
    caller wrote, because its components are named fields and their order is
    the order they were declared in.
    """
    var sorted = Builder()
    sorted.begin_set_of()
    sorted.add_int64(3)
    sorted.add_int64(1)
    sorted.add_int64(2)
    sorted.end()
    assert_equal(_hex(sorted^.finish()), "3109020101020102020103")

    var kept = Builder()
    kept.begin_set()
    kept.add_int64(3)
    kept.add_int64(1)
    kept.add_int64(2)
    kept.end()
    assert_equal(_hex(kept^.finish()), "3109020103020101020102")


def test_a_set_of_sorts_a_shorter_element_before_a_longer_one() raises:
    """The padding rule in X.690, arrived at without doing any padding.

    X.690 says the shorter element is padded with zero octets before the
    comparison. Go points out that the length octet decides the comparison
    before any padding could matter, and this relies on the same thing: a
    plain byte comparison with the shorter one first on a tie.
    """
    var b = Builder()
    b.begin_set_of()
    b.add_octet_string(_bytes("bb"))
    b.add_octet_string(_bytes("a"))
    b.add_octet_string(_bytes("b"))
    b.end()
    var der = b^.finish()

    var top = Parser(Span(der))
    var body = top.read_set()
    var first = body.read_octet_string()
    var second = body.read_octet_string()
    var third = body.read_octet_string()
    assert_equal(String(from_utf8=Span(first)), "a")
    assert_equal(String(from_utf8=Span(second)), "b")
    assert_equal(String(from_utf8=Span(third)), "bb")
    body.end()
    top.end()


def test_an_empty_set_of_is_still_a_set() raises:
    """Sorting nothing is nothing, and the header is still written."""
    var b = Builder()
    b.begin_set_of()
    b.end()
    assert_equal(_hex(b^.finish()), "3100")


def test_finishing_with_a_value_open_raises() raises:
    """The mistake this shape makes possible, caught before bytes get out.

    A value that was never closed has a placeholder where its length should
    be, and handing those bytes back would be handing back a document with a
    hole in it.
    """
    var b = Builder()
    b.begin_sequence()
    b.add_int64(1)
    assert_equal(b.depth(), 1)
    with assert_raises(contains="unfinished value"):
        _ = b^.finish()


def test_ending_nothing_raises() raises:
    """The other half of the same mistake."""
    var b = Builder()
    b.add_int64(1)
    with assert_raises(contains="no open value to end"):
        b.end()


def test_a_bit_string_whose_two_halves_disagree_is_refused() raises:
    """Which Go writes without looking.

    A `BitString` carrying more bytes than its bit length calls for would be
    read back as a shorter string than the one that was written, silently, so
    the byte count has to be the one the bit length asks for.
    """
    var b = Builder()
    with assert_raises(contains="needs 1 bytes, has 2"):
        b.add_bit_string(BitString([Byte(0x80), Byte(0)], 1))

    var short = Builder()
    with assert_raises(contains="needs 2 bytes, has 1"):
        short.add_bit_string(BitString([Byte(0x80)], 9))

    var negative = Builder()
    with assert_raises(contains="negative BIT STRING length"):
        negative.add_bit_string(BitString([Byte(0x80)], -1))


def test_a_bit_string_with_padding_that_is_not_zero_is_refused() raises:
    """DER says the padding is zero and the reader here enforces it.

    Go writes whatever bits are in the last byte, so Go can produce a bit
    string this package will not read.
    """
    var b = Builder()
    with assert_raises(contains="invalid padding bits"):
        b.add_bit_string(BitString([Byte(0x81)], 1))


def test_an_object_identifier_that_is_not_one_is_refused() raises:
    """Go's check, plus the negative number Go writes as no bytes at all.

    An identifier of fewer than two numbers has nothing to pack into the first
    byte. A first number above two does not exist. A second number of forty or
    more only fits when the first is two, since that is the case the packing
    leaves room for.
    """
    var alone = Builder()
    with assert_raises(contains="invalid object identifier"):
        alone.add_object_identifier(ObjectIdentifier([1]))

    var high = Builder()
    with assert_raises(contains="invalid object identifier"):
        high.add_object_identifier(ObjectIdentifier([3, 1]))

    var crowded = Builder()
    with assert_raises(contains="invalid object identifier"):
        crowded.add_object_identifier(ObjectIdentifier([1, 40]))

    var negative = Builder()
    with assert_raises(contains="invalid object identifier"):
        negative.add_object_identifier(ObjectIdentifier([1, 2, -1]))


def test_an_enumerated_too_large_to_read_back_is_refused() raises:
    """The reader will not hand back an ENUMERATED above what thirty two bits
    hold, so writing one would be writing a value this package cannot read."""
    var b = Builder()
    b.add_enumerated(64)
    assert_equal(_hex(b^.finish()), "0a0140")

    var big = Builder()
    with assert_raises(contains="integer too large"):
        big.add_enumerated(1 << 40)


def test_a_header_with_a_class_or_a_length_that_is_not_one_is_refused() raises:
    """Four bits of the identifier octet and a length are all a header is, and
    three of the four can be given a number that does not fit in them."""
    var b = Builder()
    with assert_raises(contains="invalid tag class"):
        b.add_header(4, 1, False, 0)
    with assert_raises(contains="invalid tag"):
        b.add_header(ClassUniversal, -1, False, 0)
    with assert_raises(contains="invalid length"):
        b.add_header(ClassUniversal, 1, False, -1)


def test_a_utc_time_outside_two_digits_is_refused_and_add_time_is_not() raises:
    """1950 and 2049 are the ends of what a two digit year can say.

    `add_utc_time` refuses a year outside them, which is Go's
    `outsideUTCRange`. `add_time` reads the same range and reaches for
    GeneralizedTime instead of refusing, which is the rule RFC 5280 gives for
    a certificate's validity dates.
    """
    var early = Builder()
    with assert_raises(contains="cannot represent time as UTCTime"):
        early.add_utc_time(date(1949, JANUARY, 1, 0, 0, 0, 0, utc()))

    var late = Builder()
    with assert_raises(contains="cannot represent time as UTCTime"):
        late.add_utc_time(date(2050, JANUARY, 1, 0, 0, 0, 0, utc()))

    var chosen_early = Builder()
    chosen_early.add_time(date(1949, JANUARY, 1, 0, 0, 0, 0, utc()))
    assert_equal(
        _hex(chosen_early^.finish()), "180f31393439303130313030303030305a"
    )

    var chosen_late = Builder()
    chosen_late.add_time(date(2050, JANUARY, 1, 0, 0, 0, 0, utc()))
    assert_equal(
        _hex(chosen_late^.finish()), "180f32303530303130313030303030305a"
    )

    var edge = Builder()
    edge.add_time(date(1950, JANUARY, 1, 0, 0, 0, 0, utc()))
    assert_equal(_hex(edge^.finish()), "170d3530303130313030303030305a")


def test_a_generalized_time_keeps_a_fraction_where_gos_drops_it() raises:
    """Go writes whole seconds and this writes what it was given.

    X.690 section 11.7 says the fraction has no trailing zeros and no trailing
    dot, which is exactly the form this writes and the form the reader here
    reads. So the time that comes back is the time that went in, where Go's
    would come back rounded down to the second.
    """
    var b = Builder()
    var when = date(2009, NOVEMBER, 15, 22, 56, 16, 500000000, utc())
    b.add_generalized_time(when)
    var der = b^.finish()
    assert_equal(_hex(der), "181132303039313131353232353631362e355a")

    var p = Parser(Span(der))
    var read = p.read_generalized_time()
    p.end()
    assert_equal(read.nanosecond(), 500000000)


def test_every_string_type_goes_out_and_comes_back() raises:
    """The six the reader reads, written and read again.

    T61String and BMPString are the two Go cannot write at all, and they are
    here because a name that arrived in one of them has to go back out in the
    same one or the signature over it stops verifying.
    """
    var b = Builder()
    b.begin_sequence()
    b.add_utf8_string("héllo")
    b.add_printable_string("plain")
    b.add_numeric_string("12 34")
    b.add_ia5_string("a@b.example")
    b.add_t61_string("café")
    b.add_bmp_string("wide")
    b.end()
    var der = b^.finish()

    var top = Parser(Span(der))
    var body = top.read_sequence()
    assert_equal(body.read_string(), "héllo")
    assert_equal(body.read_string(), "plain")
    assert_equal(body.read_string(), "12 34")
    assert_equal(body.read_string(), "a@b.example")
    assert_equal(body.read_string(), "café")
    assert_equal(body.read_string(), "wide")
    body.end()
    top.end()


def test_a_bmp_string_refuses_what_ucs2_cannot_hold() raises:
    """A character above the basic multilingual plane needs a surrogate pair,
    and UCS-2 has no surrogates, so there is nothing to write."""
    var b = Builder()
    with assert_raises(contains="above the basic multilingual plane"):
        b.add_bmp_string(String(chr(0x1F600)))

    var noncharacter = Builder()
    with assert_raises(contains="BMPString contains invalid character"):
        noncharacter.add_bmp_string(String(chr(0xFFFE)))


def test_a_t61_string_refuses_what_latin1_cannot_hold() raises:
    """One byte to a character, so a character above 255 has nowhere to go."""
    var b = Builder()
    with assert_raises(contains="T61String contains invalid character"):
        b.add_t61_string(String(chr(0x3A3)))


def test_a_tag_above_thirty_is_written_and_read_back() raises:
    """The base 128 tag form, over the boundary and well past it.

    Thirty is the last tag the identifier octet holds. Thirty one is the first
    that moves out of it, and 128 is the first that needs two groups, which
    are the two Go's `privateTest` pins by hex.
    """
    for tag in [30, 31, 127, 128, 16383, 16384]:
        var b = Builder()
        b.begin_explicit(tag)
        b.add_int64(7)
        b.end()
        var der = b^.finish()

        var top = Parser(Span(der))
        var header = top.peek_header()
        assert_equal(header.tag, tag)
        assert_equal(header.tag_class, ClassContextSpecific)
        var body = top.read_explicit(tag)
        assert_equal(body.read_int64(), 7)
        body.end()
        top.end()


def test_a_whole_certificate_shaped_value_round_trips() raises:
    """Everything at once, in roughly the shape a certificate has.

    A version wrapped in an explicit tag, a serial number too wide for a
    machine word, an algorithm identifier, a name as a SET OF, two validity
    dates and a public key as a BIT STRING. This is the shape the writer
    exists for, and reading it back is the property the whole package is
    for.
    """
    var serial = BigInt.must_set_string("123456789012345678901234567890", 10)
    var key: List[Byte] = [Byte(0x04), Byte(0xAB), Byte(0xCD)]

    var b = Builder()
    b.begin_sequence()

    b.begin_explicit(0)
    b.add_int64(2)
    b.end()

    b.add_big_int(serial)

    b.begin_sequence()
    b.add_object_identifier(ObjectIdentifier([1, 2, 840, 113549, 1, 1, 11]))
    b.add_null()
    b.end()

    b.begin_set_of()
    b.begin_sequence()
    b.add_object_identifier(ObjectIdentifier([2, 5, 4, 3]))
    b.add_string("Example CA")
    b.end()
    b.end()

    b.begin_sequence()
    b.add_time(date(2024, JANUARY, 1, 0, 0, 0, 0, utc()))
    b.add_time(date(2099, JANUARY, 1, 0, 0, 0, 0, utc()))
    b.end()

    b.add_bit_string(BitString(key.copy(), 24))
    b.end()
    var der = b^.finish()

    var top = Parser(Span(der))
    var cert = top.read_sequence()

    var version = cert.read_explicit(0)
    assert_equal(version.read_int64(), 2)
    version.end()

    assert_true(cert.read_big_int() == serial)

    var algorithm = cert.read_sequence()
    assert_true(
        algorithm.read_object_identifier().equal(
            ObjectIdentifier([1, 2, 840, 113549, 1, 1, 11])
        )
    )
    algorithm.read_null()
    algorithm.end()

    var name = cert.read_set()
    var attribute = name.read_sequence()
    assert_true(
        attribute.read_object_identifier().equal(ObjectIdentifier([2, 5, 4, 3]))
    )
    assert_equal(attribute.read_string(), "Example CA")
    attribute.end()
    name.end()

    var validity = cert.read_sequence()
    assert_equal(validity.read_time().year(), 2024)
    assert_equal(validity.read_time().year(), 2099)
    validity.end()

    var read_key = cert.read_bit_string()
    assert_equal(read_key.bit_length, 24)
    assert_equal(_hex(read_key.bytes), _hex(key))

    cert.end()
    top.end()


def test_reading_it_back_and_writing_it_again_gives_the_same_bytes() raises:
    """The property `core.crypto.x509` needs, on a value built here.

    A structure is written, read back with a `Parser` and written out again
    from what was read, and the two encodings are the same bytes. That is the
    test the milestone turns on, run on a value small enough to see, and it is
    what makes a certificate bundle round tripping believable.
    """
    var first = Builder()
    first.begin_sequence()
    first.add_bool(True)
    first.add_int64(-129)
    first.add_octet_string(_bytes("payload"))
    first.add_object_identifier(ObjectIdentifier([1, 3, 6, 1, 4, 1, 11129]))
    first.add_time(date(2031, APRIL, 5, 12, 1, 1, 0, utc()))
    first.add_bit_string(BitString([Byte(0x81), Byte(0xF0)], 12))
    first.end()
    var der = first^.finish()

    var top = Parser(Span(der))
    var body = top.read_sequence()
    var flag = body.read_bool()
    var number = body.read_int64()
    var payload = body.read_octet_string()
    var oid = body.read_object_identifier()
    var when = body.read_time()
    var bits = body.read_bit_string()
    body.end()
    top.end()

    var second = Builder()
    second.begin_sequence()
    second.add_bool(flag)
    second.add_int64(number)
    second.add_octet_string(Span(payload))
    second.add_object_identifier(oid)
    second.add_time(when)
    second.add_bit_string(bits)
    second.end()
    var again = second^.finish()

    assert_equal(_hex(again), _hex(der))


def test_a_raw_value_read_from_one_document_writes_into_another() raises:
    """How a field is carried across without being understood.

    The bytes a signature was taken over are the bytes that go back out, which
    is why `add_raw_value` writes the whole encoding when it has one rather
    than building a header again.
    """
    var source = Builder()
    source.begin_sequence()
    source.add_int64(1)
    source.begin_sequence()
    source.add_string("inner")
    source.add_int64(2)
    source.end()
    source.end()
    var der = source^.finish()

    var top = Parser(Span(der))
    var body = top.read_sequence()
    assert_equal(body.read_int64(), 1)
    var kept = body.read_raw_value()
    body.end()
    top.end()

    var again = Builder()
    again.begin_sequence()
    again.add_raw_value(kept)
    again.end()
    var copied = again^.finish()

    assert_equal(_hex(kept.full_bytes), "300a1305696e6e6572020102")
    assert_equal(_hex(copied), "300c" + _hex(kept.full_bytes))


def test_the_bytes_written_so_far_can_be_counted() raises:
    """`len` says how many bytes are down, placeholders and all, and `depth`
    says how many values are still waiting for their length."""
    var b = Builder()
    assert_equal(len(b), 0)
    assert_equal(b.depth(), 0)
    b.begin_sequence()
    assert_equal(len(b), 2)
    assert_equal(b.depth(), 1)
    b.add_int64(1)
    assert_equal(len(b), 5)
    b.end()
    assert_equal(len(b), 5)
    assert_equal(b.depth(), 0)


def test_an_implicit_tag_replaces_a_header_of_every_type() raises:
    """The defaulted arguments, exercised across the writers that take them.

    An implicitly tagged field carries the contents of its type under a tag
    the structure chose, so the reader has to know what it is reading. Each of
    these is read back through `read_implicit`, which is the call that says
    so.
    """
    var b = Builder()
    b.begin_sequence()
    b.add_bool(True, ClassContextSpecific, 0)
    b.add_octet_string(_bytes("hi"), ClassContextSpecific, 1)
    b.add_printable_string("ok", ClassContextSpecific, 2)
    b.add_int64(300, ClassContextSpecific, 3)
    b.end()
    var der = b^.finish()

    var top = Parser(Span(der))
    var body = top.read_sequence()
    assert_equal(_hex(_bytes_of(body.read_implicit(0, False))), "ff")
    assert_equal(_hex(_bytes_of(body.read_implicit(1, False))), "6869")
    assert_equal(_hex(_bytes_of(body.read_implicit(2, False))), "6f6b")
    assert_equal(_hex(_bytes_of(body.read_implicit(3, False))), "012c")
    body.end()
    top.end()
