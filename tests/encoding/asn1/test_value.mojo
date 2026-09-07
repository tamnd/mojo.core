"""The types a value arrives as, apart from the reader that fills them in.

Go tests most of these through `Unmarshal`, because reflection is the only way
into the package. They are reachable on their own here, so they are tested on
their own here.
"""

from std.testing import assert_equal, assert_true

from core.encoding.asn1 import (
    BitString,
    ClassApplication,
    ClassContextSpecific,
    ClassPrivate,
    ClassUniversal,
    Enumerated,
    Flag,
    NullBytes,
    NullRawValue,
    ObjectIdentifier,
    RawContent,
    RawValue,
    TagAndLength,
    TagBoolean,
    TagNull,
    TagSequence,
)
from core.io import Byte


def test_a_header_matches_on_all_three_at_once() raises:
    """`expect`, which is what every read of a known field goes through.

    A tag number means nothing without the class it is in, and a compound
    value holding bytes is a different mistake from a primitive one holding
    values, so all three have to agree.
    """
    var header = TagAndLength(ClassUniversal, TagSequence, 7, True)
    assert_true(header.expect(ClassUniversal, TagSequence, True))
    assert_true(not header.expect(ClassContextSpecific, TagSequence, True))
    assert_true(not header.expect(ClassUniversal, TagBoolean, True))
    assert_true(not header.expect(ClassUniversal, TagSequence, False))

    assert_equal(
        String(header),
        "asn1.TagAndLength(class=0, tag=16, length=7, compound=True)",
    )


def test_the_four_classes_are_the_two_top_bits() raises:
    """Which is why they are 0 through 3 and not something else."""
    assert_equal(ClassUniversal, 0)
    assert_equal(ClassApplication, 1)
    assert_equal(ClassContextSpecific, 2)
    assert_equal(ClassPrivate, 3)


def test_a_bit_string_prints_as_bits() raises:
    """The bits it holds, and not the bytes they are packed into.

    A BIT STRING of nine bits is two bytes, and printing the bytes would show
    seven bits that are not there.
    """
    assert_equal(String(BitString([Byte(0x80), Byte(0x80)], 9)), "100000001")
    assert_equal(String(BitString(List[Byte](), 0)), "")
    assert_equal(String(BitString([Byte(0xCE)], 8)), "11001110")


def test_two_bit_strings_are_equal_when_they_hold_the_same_bits() raises:
    """Both halves, since the byte count alone cannot say how many bits."""
    var eight = BitString([Byte(0xFF)], 8)
    assert_true(eight == BitString([Byte(0xFF)], 8))
    assert_true(eight != BitString([Byte(0xFF)], 7))
    assert_true(eight != BitString([Byte(0x7F)], 8))


def test_an_empty_bit_string_is_the_one_a_field_starts_as() raises:
    """The zero value, which is what a field with nothing read into it
    holds."""
    var none = BitString()
    assert_equal(none.bit_length, 0)
    assert_equal(len(none.bytes), 0)
    assert_equal(none.at(0), 0)


def test_an_object_identifier_is_a_list_with_dots_between() raises:
    """Indexing, length and printing, all of which Go gets from `[]int`."""
    var sha256 = ObjectIdentifier([2, 16, 840, 1, 101, 3, 4, 2, 1])
    assert_equal(String(sha256), "2.16.840.1.101.3.4.2.1")
    assert_equal(len(sha256), 9)
    assert_equal(sha256[0], 2)
    assert_equal(sha256[8], 1)

    var empty = ObjectIdentifier()
    assert_equal(String(empty), "")
    assert_equal(len(empty), 0)

    assert_true(
        sha256.equal(ObjectIdentifier([2, 16, 840, 1, 101, 3, 4, 2, 1]))
    )
    assert_true(not sha256.equal(ObjectIdentifier([2, 16, 840])))


def test_the_null_value_and_the_null_bytes() raises:
    """Go has these as package level variables and this has them as calls.

    A `List` is not a compile time value, so a variable holding one cannot be
    a global here. `core.unicode` does the same with Go's six maps, and the
    Go names are kept so that a reader following a specification finds them.
    """
    var value = NullRawValue()
    assert_equal(value.tag_class, ClassUniversal)
    assert_equal(value.tag, TagNull)
    assert_equal(value.is_compound, False)
    assert_equal(len(value.bytes), 0)
    assert_equal(len(value.full_bytes), 0)

    var bytes = NullBytes()
    assert_equal(len(bytes), 2)
    assert_equal(bytes[0], Byte(TagNull))
    assert_equal(bytes[1], Byte(0))


def test_a_raw_value_prints_its_header_and_a_byte_count() raises:
    """Not the bytes, since a raw value is often a whole certificate."""
    var raw = RawValue(
        ClassContextSpecific,
        3,
        True,
        [Byte(0x01), Byte(0x02)],
        [Byte(0xA3), Byte(0x02), Byte(0x01), Byte(0x02)],
    )
    assert_equal(
        String(raw), "asn1.RawValue(class=2, tag=3, compound=True, bytes=2)"
    )
    assert_true(raw != RawValue())
    assert_true(RawValue() == RawValue())


def test_the_three_aliases_are_the_types_they_name() raises:
    """`Enumerated`, `Flag` and `RawContent`, which are defined types in Go.

    They exist there so that reflection can tell a field that wants an
    ENUMERATED from one that wants an INTEGER. The generator reads the name a
    field was declared with instead, so a name for the underlying type is
    enough, and an alias leaves the arithmetic and the indexing alone.
    """
    var count: Enumerated = 3
    assert_equal(count + 1, 4)

    var present: Flag = True
    assert_true(present)

    var body: RawContent = [Byte(0x30), Byte(0x00)]
    assert_equal(len(body), 2)
    assert_equal(body[0], Byte(0x30))
