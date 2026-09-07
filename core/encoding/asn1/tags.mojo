"""The tag and the class that precede every value, and the pair they arrive as.

Go's `common.go`. The constants are Go's, spelled the way Go spells them,
because a tag number written into a certificate profile is quoted by number and
by name in every specification that mentions it and renaming them here would
make those documents harder to check against this code, not easier.
"""

from core.io import Byte

comptime TagBoolean = 1
"""BOOLEAN. One contents octet, zero or all ones and nothing else."""

comptime TagInteger = 2
"""INTEGER. Two's complement, big endian, minimally encoded."""

comptime TagBitString = 3
"""BIT STRING. A count of padding bits and then the bits."""

comptime TagOctetString = 4
"""OCTET STRING. Bytes, whatever they are."""

comptime TagNull = 5
"""NULL. No contents at all, and the length says so."""

comptime TagOID = 6
"""OBJECT IDENTIFIER. Go shortens this one and so does this."""

comptime TagEnum = 10
"""ENUMERATED. An integer from a list somebody wrote down."""

comptime TagUTF8String = 12
"""UTF8String. The only string type here that holds all of Unicode."""

comptime TagSequence = 16
"""SEQUENCE and SEQUENCE OF. Compound, and ordered."""

comptime TagSet = 17
"""SET and SET OF. Compound, and unordered."""

comptime TagNumericString = 18
"""NumericString. Digits and the space, and nothing else."""

comptime TagPrintableString = 19
"""PrintableString. A subset of ASCII from 1988 that nobody would pick now."""

comptime TagT61String = 20
"""T61String. A defunct encoding, read as Latin-1, which is what everybody
else does."""

comptime TagIA5String = 22
"""IA5String. ASCII, all seven bits of it."""

comptime TagUTCTime = 23
"""UTCTime. A two digit year, so it cannot say anything from 2050 on."""

comptime TagGeneralizedTime = 24
"""GeneralizedTime. A four digit year, and fractional seconds."""

comptime TagGeneralString = 27
"""GeneralString. Read here the way Go reads it, which is not at all."""

comptime TagBMPString = 30
"""BMPString. UCS-2, big endian, two bytes to a character."""

comptime ClassUniversal = 0
"""The tag means what X.680 says it means."""

comptime ClassApplication = 1
"""The tag means what the application that defined it says."""

comptime ClassContextSpecific = 2
"""The tag means what the structure it appears in says. This is the class
every `[0]` and `[1]` in a certificate is in."""

comptime ClassPrivate = 3
"""The tag means what some enterprise says. Rare, and still a class."""

comptime _CLASS_SHIFT = 6
"""Where the two class bits sit in the identifier octet."""

comptime _COMPOUND_BIT = Byte(0x20)
"""The bit that says the contents are values rather than bytes."""

comptime _TAG_MASK = Byte(0x1F)
"""The low five bits of the identifier octet, which hold the tag number until
they are all set and the number moves to the bytes after it."""

comptime _HIGH_TAG = 0x1F
"""The tag number that means the real one follows in base 128."""


struct TagAndLength(Copyable, Movable, Writable):
    """What precedes a value: its class, its tag, whether it is compound and
    how many bytes of contents follow.

    Go has this as an unexported `tagAndLength` because nothing outside its
    package can do anything with one. It is public here because the code that
    reads a structure is generated rather than written by reflection, and that
    code has to be able to look at a header, decide the field it belongs to and
    read the contents itself.

    Go maps SET onto SEQUENCE while parsing, on the reasoning that its decoder
    does not tell an ordered collection from an unordered one. Nothing is
    mapped here: the tag is the tag that was in the bytes, and a caller that
    wants Go's behaviour compares against both.
    """

    var tag_class: Int
    """Universal, application, context specific or private. Go calls this
    `class`, which is a Mojo keyword."""

    var tag: Int
    """The tag number, after the base 128 form has been read if it was
    used."""

    var length: Int
    """How many bytes of contents follow. Never indefinite, because an
    indefinite length is BER and not DER."""

    var is_compound: Bool
    """Whether the contents are values rather than bytes."""

    def __init__(
        out self, tag_class: Int, tag: Int, length: Int, is_compound: Bool
    ):
        self.tag_class = tag_class
        self.tag = tag
        self.length = length
        self.is_compound = is_compound

    def expect(self, tag_class: Int, tag: Int, is_compound: Bool) -> Bool:
        """Whether this header is the one a caller was looking for.

        The three together, because a tag number means nothing without the
        class it is in and a compound value holding bytes is a different
        mistake from a primitive one holding values.
        """
        return (
            self.tag_class == tag_class
            and self.tag == tag
            and self.is_compound == is_compound
        )

    def write_to[W: Writer](self, mut writer: W):
        """The four fields, in the order the bytes carry them."""
        writer.write("asn1.TagAndLength(class=", self.tag_class)
        writer.write(", tag=", self.tag)
        writer.write(", length=", self.length)
        writer.write(", compound=", self.is_compound, ")")
