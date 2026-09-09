"""One value in and one value out, over Go's own tables.

`marshal_test.go` marshals a Go value and compares the hex. Every row of it
that is a single value rather than a struct is a row here, unchanged, because a
single value is what these calls take: Go reaches them through reflection and
this reaches them through an overload, and the bytes on the other side are the
same bytes.

The rows that are structs live in `test_build.mojo`, written as the calls a
generated writer makes. What the struct rows carried that a single value can
carry too is the tag string, since `MarshalWithParams` applies one to the top
level value, so `implicit,tag:5` on a field is `tag:5` on an integer here and
the header it produces is Go's.

The second half is the round trip. Go's `Unmarshal` is tested against its own
tables of bytes; this is tested against what `marshal` wrote, plus the cases
bytes alone reach: an optional field that is not there, a default that arrives
when nothing does, and the rest of the input coming back.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.encoding.asn1 import (
    BitString,
    ObjectIdentifier,
    RawValue,
    marshal,
    marshal_with_params,
    unmarshal,
    unmarshal_with_params,
)
from core.errors import matches
from core.errors.codes import ErrASN1Structural, ErrASN1Syntax
from core.io import Byte
from core.math.big import Int as BigInt
from core.time import APRIL, NOVEMBER, date, fixed_zone, unix, utc

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


def _hex_of(span: Span[Byte, _]) -> String:
    """The same, for a span."""
    var out = List[Byte](capacity=len(span))
    out.extend(span)
    return _hex(out)


def _repeat(text: StringSlice, times: Int) -> String:
    """`text` written `times` over, for the two rows that are a long
    string."""
    var out = String()
    for _ in range(times):
        out += text
    return out^


def _unhex(text: StringSlice) -> List[Byte]:
    """A row of Go's table as the bytes it stands for."""
    var digits = text.as_bytes()
    var out = List[Byte](capacity=len(digits) // 2)
    for i in range(0, len(digits) - 1, 2):
        out.append(
            Byte(Int(_value(digits[i])) * 16 + Int(_value(digits[i + 1])))
        )
    return out^


def _value(digit: Byte) -> Byte:
    """One hex digit as the number it names."""
    if digit >= 0x61:  # `a`
        return digit - 0x61 + 10
    return digit - 0x30


def test_gos_bare_integers() raises:
    """The five integers Go's table opens with.

    The interesting pairs are 127 against 128 and -128 against -129, which are
    where the width goes up because the top bit would otherwise say the wrong
    thing about the sign.
    """
    assert_equal(_hex(marshal(Int64(10))), "02010a")
    assert_equal(_hex(marshal(Int64(127))), "02017f")
    assert_equal(_hex(marshal(Int64(128))), "02020080")
    assert_equal(_hex(marshal(Int64(-128))), "020180")
    assert_equal(_hex(marshal(Int64(-129))), "0202ff7f")


def test_gos_big_integer() raises:
    """Go's `bigIntStruct{big.NewInt(0x123456)}`, without the sequence around
    it."""
    assert_equal(_hex(marshal(BigInt(0x123456))), "0203123456")


def test_gos_byte_slice() raises:
    """An OCTET STRING, which is the one Go type that maps to one by
    itself."""
    var data: List[Byte] = [Byte(1), Byte(2), Byte(3)]
    assert_equal(_hex(marshal(Span(data))), "0403010203")


def test_gos_times() raises:
    """The four times in Go's table, plus the one its tag string asks for.

    The third is in a zone eight hours behind UTC and keeps the offset rather
    than being moved, which is what a UTCTime allows and what Go writes.
    """
    assert_equal(
        _hex(marshal(unix(0, 0).utc())), "170d3730303130313030303030305a"
    )
    assert_equal(
        _hex(marshal(unix(1258325776, 0).utc())),
        "170d3039313131353232353631365a",
    )

    var pst = fixed_zone("PST", -8 * 60 * 60)
    assert_equal(
        _hex(marshal(unix(1258325776, 0).in_location(pst))),
        "17113039313131353134353631362d30383030",
    )

    # A year a two digit year cannot say, so the type changes by itself.
    assert_equal(
        _hex(marshal(date(2100, APRIL, 5, 12, 1, 1, 0, utc()))),
        "180f32313030303430353132303130315a",
    )

    # And a year it can say, asked for the other type anyway.
    assert_equal(
        _hex(marshal_with_params(unix(1258325776, 0).utc(), "generalized")),
        "180f32303039313131353232353631365a",
    )


def test_gos_bit_strings() raises:
    """Two BIT STRINGs, one of a single bit and one that stops part way
    through the second byte."""
    assert_equal(_hex(marshal(BitString([Byte(0x80)], 1))), "03020780")
    assert_equal(
        _hex(marshal(BitString([Byte(0x81), Byte(0xF0)], 12))), "03030481f0"
    )


def test_gos_object_identifiers() raises:
    """The three OIDs in Go's table.

    The last is the one whose first number is 2, where the packing of the
    first two numbers stops being forty times one plus the other and starts
    being eighty plus the other.
    """
    assert_equal(_hex(marshal(ObjectIdentifier([1, 2, 3, 4]))), "06032a0304")
    assert_equal(
        _hex(marshal(ObjectIdentifier([1, 2, 840, 133549, 1, 1, 5]))),
        "06092a864888932d010105",
    )
    assert_equal(_hex(marshal(ObjectIdentifier([2, 100, 3]))), "0603813403")


def test_gos_strings() raises:
    """A string with no type named for it gets the type that fits it.

    Go's rows: `test` is printable, `test*` and `test&` are not, because the
    asterisk and the ampersand are outside the set a string nobody named a
    type for is allowed. The last is two bytes of UTF-8 for one character.
    """
    assert_equal(_hex(marshal("test")), "130474657374")
    assert_equal(_hex(marshal("test*")), "0c05746573742a")
    assert_equal(_hex(marshal("test&")), "0c057465737426")
    assert_equal(_hex(marshal("Σ")), "0c02cea3")


def test_gos_long_strings() raises:
    """The two rows where the length outgrows the byte it was written in.

    A hundred and twenty seven bytes is the last length that fits in the seven
    bits the short form has, and a hundred and twenty eight is the first that
    needs a byte of its own.
    """
    var short = _repeat("x", 127)
    assert_equal(_hex(marshal(short)), "137f" + _repeat("78", 127))

    var long = _repeat("x", 128)
    assert_equal(_hex(marshal(long)), "138180" + _repeat("78", 128))


def test_gos_named_string_types() raises:
    """The four types a tag string can name, and what naming one allows.

    `test*` under `printable` is written as a PrintableString, where the same
    string with no type named for it is a UTF8String. Go allows the asterisk
    to whoever asks for the type by name, on the grounds that they have said
    what they want.
    """
    assert_equal(_hex(marshal_with_params("test", "ia5")), "160474657374")
    assert_equal(_hex(marshal_with_params("test", "printable")), "130474657374")
    assert_equal(
        _hex(marshal_with_params("test*", "printable")), "1305746573742a"
    )
    assert_equal(_hex(marshal_with_params("test", "utf8")), "0c0474657374")
    assert_equal(_hex(marshal_with_params("1 9", "numeric")), "1203312039")


def test_gos_raw_value() raises:
    """A value built out of a class, a tag and contents, which is how a caller
    writes something this package has no other way to spell."""
    var v = RawValue(2, 1, False, [Byte(1), Byte(2), Byte(3)], List[Byte]())
    assert_equal(_hex(marshal(v)), "8103010203")


def test_an_implicit_tag_replaces_the_header() raises:
    """Go's `implicitTagTest`, which is a field tagged `implicit,tag:5`.

    Nothing says implicit in the bytes: the universal INTEGER header is simply
    not there and a context specific one is, which is the smaller encoding and
    the reason implicit tagging exists.
    """
    assert_equal(_hex(marshal_with_params(Int64(64), "tag:5")), "850140")


def test_an_explicit_tag_wraps_the_header() raises:
    """Go's `explicitTagTest`.

    The universal header is kept and a compound context specific one goes
    around it, so a reader that finds the outer tag knows what type is inside
    without being told.
    """
    assert_equal(
        _hex(marshal_with_params(Int64(64), "explicit,tag:5")), "a503020140"
    )


def test_the_other_two_classes() raises:
    """Go's `applicationTest` and `privateTest`, field by field.

    The last two are the rows Go wrote for the tag number outgrowing the five
    bits it is usually written in: thirty one is the first that needs a second
    byte and a hundred and twenty eight is the first that needs a third.
    """
    assert_equal(
        _hex(marshal_with_params(Int64(1), "application,tag:0")), "400101"
    )
    assert_equal(
        _hex(marshal_with_params(Int64(2), "application,tag:1,explicit")),
        "6103020102",
    )
    assert_equal(_hex(marshal_with_params(Int64(1), "private,tag:0")), "c00101")
    assert_equal(
        _hex(marshal_with_params(Int64(2), "private,tag:1,explicit")),
        "e103020102",
    )
    assert_equal(
        _hex(marshal_with_params(Int64(3), "private,tag:31")), "df1f0103"
    )
    assert_equal(
        _hex(marshal_with_params(Int64(4), "private,tag:128")), "df81000104"
    )


def test_a_default_is_written_only_when_it_differs() raises:
    """Go's `defaultTest`, whose field is `optional,default:1`.

    Zero is written, because a field equal to its default is the one that is
    left out and zero is not the default here. One is left out. Two is
    written. Go's three rows in order.
    """
    assert_equal(
        _hex(marshal_with_params(Int64(0), "optional,default:1")), "020100"
    )
    assert_equal(len(marshal_with_params(Int64(1), "optional,default:1")), 0)
    assert_equal(
        _hex(marshal_with_params(Int64(2), "optional,default:1")), "020102"
    )


def test_an_optional_zero_is_written_as_nothing() raises:
    """The rule Go applies when no default was given: the zero value is the
    default.

    Go says in a comment that this is not obviously right and is what Go has
    always done. It is kept because a structure written one way and read the
    other has to agree about which fields are there.
    """
    assert_equal(len(marshal_with_params(False, "optional")), 0)
    assert_equal(_hex(marshal_with_params(True, "optional")), "0101ff")
    assert_equal(len(marshal_with_params(Int64(0), "optional")), 0)
    assert_equal(len(marshal_with_params("", "optional")), 0)
    assert_equal(len(marshal_with_params(BigInt(), "optional")), 0)
    assert_equal(len(marshal_with_params(BitString(), "optional")), 0)
    assert_equal(len(marshal_with_params(RawValue(), "optional")), 0)


def test_an_empty_slice_can_be_left_out() raises:
    """Go's `omitEmptyTest`, which is the only thing `omitempty` applies to.

    A slice with nothing in it, and the two types that are slices in Go: a
    byte slice and an object identifier.
    """
    var empty = List[Byte]()
    assert_equal(len(marshal_with_params(Span(empty), "omitempty")), 0)
    assert_equal(
        len(marshal_with_params(ObjectIdentifier(List[Int]()), "omitempty")), 0
    )

    var one: List[Byte] = [Byte(1)]
    assert_equal(_hex(marshal_with_params(Span(one), "omitempty")), "040101")


def test_a_tag_string_the_type_cannot_answer_is_refused() raises:
    """Go's three checks in `makeField`.

    The third fires for every type here, because `set` says to write a SET
    rather than a SEQUENCE and none of these is a SEQUENCE. A structure that
    is one is written by generated code against `Builder.begin_set`.
    """
    with assert_raises(contains="explicit time type given to non-time member"):
        _ = marshal_with_params(Int64(1), "utc")
    with assert_raises(
        contains="explicit string type given to non-string member"
    ):
        _ = marshal_with_params(Int64(1), "ia5")
    with assert_raises(contains="non sequence tagged as set"):
        _ = marshal_with_params(Int64(1), "set")


def test_a_refusal_is_a_structural_error() raises:
    """Which is the code Go's writer raises, and what a caller reads back."""
    try:
        _ = marshal_with_params(Int64(1), "set")
    except e:
        assert_true(matches(e, ErrASN1Structural))


def test_gos_string_refusals() raises:
    """Go's `marshalErrTests`, for the three that are a named string type.

    Each names a type and hands it a character the type does not have.
    """
    with assert_raises(contains="invalid character"):
        _ = marshal_with_params("a", "numeric")
    with assert_raises(contains="invalid character"):
        _ = marshal_with_params(String(chr(0xB0)), "ia5")
    with assert_raises(contains="invalid character"):
        _ = marshal_with_params("!", "printable")


def test_a_tag_number_that_is_not_a_number_is_ignored() raises:
    """Go parses the number after `tag:` with `strconv` and drops the part on
    an error rather than reporting it, so a typo is a part that says
    nothing."""
    assert_equal(_hex(marshal_with_params(Int64(64), "tag:x")), "020140")
    assert_equal(_hex(marshal_with_params(Int64(64), "nonsense")), "020140")

    # A dropped `default:` leaves the zero value as the default, so five is
    # written where it would have been left out had the number been read.
    assert_equal(
        _hex(marshal_with_params(Int64(5), "optional,default:x")), "020105"
    )
    assert_equal(len(marshal_with_params(Int64(5), "optional,default:5")), 0)


def test_every_type_reads_back_what_it_wrote() raises:
    """The round trip, once per type.

    This is the property the pair exists for, and the one that a table of
    golden bytes on its own does not establish.
    """
    var flag = False
    _ = unmarshal(Span(marshal(True)), flag)
    assert_true(flag)

    var number = Int64(0)
    _ = unmarshal(Span(marshal(Int64(-129))), number)
    assert_equal(number, -129)

    var wide = BigInt()
    _ = unmarshal(Span(marshal(BigInt(0x123456))), wide)
    assert_true(wide == BigInt(0x123456))

    var text = String()
    _ = unmarshal(Span(marshal("test&")), text)
    assert_equal(text, "test&")

    var data: List[Byte] = [Byte(1), Byte(2), Byte(3)]
    var read = List[Byte]()
    _ = unmarshal(Span(marshal(Span(data))), read)
    assert_equal(read, data)

    var oid = ObjectIdentifier(List[Int]())
    _ = unmarshal(
        Span(marshal(ObjectIdentifier([1, 2, 840, 133549, 1, 1, 5]))), oid
    )
    assert_true(oid == ObjectIdentifier([1, 2, 840, 133549, 1, 1, 5]))

    var bits = BitString()
    _ = unmarshal(Span(marshal(BitString([Byte(0x81), Byte(0xF0)], 12))), bits)
    assert_true(bits == BitString([Byte(0x81), Byte(0xF0)], 12))

    var when = unix(0, 0).utc()
    _ = unmarshal(Span(marshal(unix(1258325776, 0).utc())), when)
    assert_equal(when.unix(), 1258325776)

    var raw = RawValue()
    _ = unmarshal(Span(marshal(Int64(64))), raw)
    assert_equal(raw.tag, 2)
    assert_equal(_hex(raw.full_bytes), "020140")


def test_what_is_left_over_comes_back() raises:
    """Go's `rest`, which is how a caller reads a value out of the front of a
    buffer and keeps the position of everything after it."""
    var der = _unhex("020140" + "0101ff")
    var number = Int64(0)
    var rest = unmarshal(Span(der), number)
    assert_equal(number, 64)
    assert_equal(_hex_of(rest), "0101ff")

    var flag = False
    var nothing = unmarshal(rest, flag)
    assert_true(flag)
    assert_equal(len(nothing), 0)


def test_an_optional_field_that_is_not_there_keeps_its_bytes() raises:
    """A header that does not match an optional field is not an error.

    The bytes belong to whatever comes after it, so nothing is read and every
    byte comes back, which is what lets a caller try the next field against
    the same input.
    """
    var der = _unhex("0101ff")
    var number = Int64(7)
    var rest = unmarshal_with_params(Span(der), number, "optional")
    assert_equal(number, 0)
    assert_equal(_hex_of(rest), "0101ff")

    var flag = False
    _ = unmarshal(rest, flag)
    assert_true(flag)


def test_a_default_arrives_when_the_field_does_not() raises:
    """Which is the whole of what a default is for."""
    var der = _unhex("0101ff")
    var number = Int64(0)
    var rest = unmarshal_with_params(Span(der), number, "optional,default:42")
    assert_equal(number, 42)
    assert_equal(len(rest), len(der))


def test_a_field_that_is_not_optional_and_not_there_is_refused() raises:
    """The other half: a required field whose bytes have run out."""
    var nothing = List[Byte]()
    var number = Int64(0)
    with assert_raises(contains="sequence truncated"):
        _ = unmarshal(Span(nothing), number)

    try:
        _ = unmarshal(Span(nothing), number)
    except e:
        assert_true(matches(e, ErrASN1Syntax))


def test_a_tag_that_does_not_match_is_refused() raises:
    """And says which tag was wanted, since the bytes are DER for something
    else rather than broken."""
    var der = _unhex("0101ff")
    var number = Int64(0)
    with assert_raises(contains="tags don't match"):
        _ = unmarshal(Span(der), number)


def test_a_tagged_value_reads_back_under_its_tag() raises:
    """Both kinds of tag, written and read through the same tag string."""
    var implicit = marshal_with_params(Int64(64), "tag:5")
    var number = Int64(0)
    _ = unmarshal_with_params(Span(implicit), number, "tag:5")
    assert_equal(number, 64)

    var explicit = marshal_with_params(Int64(64), "explicit,tag:5")
    number = 0
    _ = unmarshal_with_params(Span(explicit), number, "explicit,tag:5")
    assert_equal(number, 64)

    var private = marshal_with_params(Int64(4), "private,tag:128")
    number = 0
    _ = unmarshal_with_params(Span(private), number, "private,tag:128")
    assert_equal(number, 4)


def test_an_explicit_tag_with_nothing_in_it_is_refused() raises:
    """Go's message, which names the one type an empty explicit tag is legal
    for.

    `Flag` is a name for `Bool` here rather than a type of its own, so there
    is no overload that could accept this and the refusal is the whole of the
    behaviour.
    """
    var der = _unhex("a500" + "020140")
    var number = Int64(0)
    with assert_raises(contains="zero length explicit tag"):
        _ = unmarshal_with_params(Span(der), number, "explicit,tag:5")


def test_an_explicit_tag_that_does_not_match_is_refused() raises:
    """Unless the field is optional, in which case it was simply not
    there."""
    var der = _unhex("020140")
    var number = Int64(0)
    with assert_raises(contains="explicitly tagged member didn't match"):
        _ = unmarshal_with_params(Span(der), number, "explicit,tag:5")

    var optional = Int64(7)
    var rest = unmarshal_with_params(
        Span(der), optional, "explicit,tag:5,optional"
    )
    assert_equal(optional, 0)
    assert_equal(len(rest), len(der))


def test_the_wire_says_which_string_type_arrived() raises:
    """Every string type maps to `String`, so the tag is what says which one
    this is and what the contents are checked against."""
    var text = String()
    _ = unmarshal(Span(_unhex("160474657374")), text)  # IA5String
    assert_equal(text, "test")

    _ = unmarshal(Span(_unhex("0c02cea3")), text)  # UTF8String
    assert_equal(text, "Σ")

    _ = unmarshal(Span(_unhex("1203312039")), text)  # NumericString
    assert_equal(text, "1 9")

    # A UTF8String that is not UTF-8 is refused, which is the check the tag
    # asked for.
    with assert_raises(contains="invalid UTF-8"):
        _ = unmarshal(Span(_unhex("0c01ff")), text)


def test_an_implicit_string_is_read_as_the_type_the_tag_string_names() raises:
    """An implicit tag says nothing about the type, so the tag string is the
    only thing left that can."""
    var der = marshal_with_params("1 9", "numeric,tag:3")
    assert_equal(_hex(der), "8303312039")

    var text = String()
    _ = unmarshal_with_params(Span(der), text, "numeric,tag:3")
    assert_equal(text, "1 9")

    # Read as a printable string instead, the space is fine and the digits are
    # fine, so this one succeeds and says something different about the same
    # bytes. Read as an IA5String it would too. That is what an implicit tag
    # costs, here and in Go.
    var again = String()
    _ = unmarshal_with_params(Span(der), again, "printable,tag:3")
    assert_equal(again, "1 9")


def test_the_wire_says_which_time_type_arrived() raises:
    """A certificate's dates are UTCTime before 2050 and GeneralizedTime from
    then on, chosen by whoever wrote them."""
    var when = unix(0, 0).utc()
    _ = unmarshal(Span(_unhex("170d3039313131353232353631365a")), when)
    assert_equal(when.unix(), 1258325776)

    _ = unmarshal(Span(marshal(date(2100, APRIL, 5, 12, 1, 1, 0, utc()))), when)
    assert_equal(when.year(), 2100)


def test_a_raw_value_takes_any_tag() raises:
    """Not decoding a value means having no opinion about what it is, so no
    class and no tag is refused and the explicit wrapper is kept rather than
    unwrapped."""
    var raw = RawValue()
    var rest = unmarshal(Span(_unhex("8103010203")), raw)
    assert_equal(raw.tag_class, 2)
    assert_equal(raw.tag, 1)
    assert_false(raw.is_compound)
    assert_equal(_hex(raw.bytes), "010203")
    assert_equal(_hex(raw.full_bytes), "8103010203")
    assert_equal(len(rest), 0)

    var wrapped = RawValue()
    _ = unmarshal_with_params(
        Span(_unhex("a503020140")), wrapped, "explicit,tag:5"
    )
    assert_equal(_hex(wrapped.full_bytes), "a503020140")


def test_a_truncated_value_is_refused() raises:
    """A header that promises more bytes than are there."""
    var number = Int64(0)
    with assert_raises(contains="data truncated"):
        _ = unmarshal(Span(_unhex("0204ff")), number)


def test_a_compound_header_on_a_primitive_type_is_refused() raises:
    """The compound bit says the contents are values rather than bytes, so a
    compound INTEGER is DER for something that is not an integer."""
    var number = Int64(0)
    with assert_raises(contains="tags don't match"):
        _ = unmarshal(Span(_unhex("220140")), number)
