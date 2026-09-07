"""Reading DER, one value at a time.

Go reads a whole structure in one call by walking the destination type with
reflection. There is no reflection here, so this is the layer underneath that:
a cursor over bytes that reads one header, or one primitive value, or hands
back a cursor over the contents of a SEQUENCE. Generated code drives it, and so
does anything hand written that knows the shape it is reading, which is what
`core.crypto.x509` will be.

Everything here refuses rather than repairs. DER exists so that two programs
hashing the same object get the same bytes, and a reader that accepts a
non-minimal length or a non-canonical integer is a reader that will one day
disagree with the one at the other end about what a certificate says. So a
length that could have been shorter, an integer with a redundant leading byte,
a bit string whose padding is not zero and a tag number that is not minimally
encoded are all errors, even where the value they were trying to express is
obvious.

Nothing in this file recurses. A SEQUENCE gives back a second `Parser` over its
contents rather than calling into itself, so a structure nested a million deep
costs a million calls that each return, not a stack. That is why there is no
depth cap here where Go has one.
"""

from core.io import Byte
from core.math.big import Int as BigInt
from core.time import Time, parse as parse_time
from core.unicode.utf8 import append_rune, valid

from .errors import _structural, _syntax
from .tags import (
    _CLASS_SHIFT,
    _COMPOUND_BIT,
    _HIGH_TAG,
    _TAG_MASK,
    ClassContextSpecific,
    ClassUniversal,
    TagBMPString,
    TagBitString,
    TagBoolean,
    TagEnum,
    TagGeneralString,
    TagGeneralizedTime,
    TagIA5String,
    TagInteger,
    TagNull,
    TagNumericString,
    TagOID,
    TagOctetString,
    TagPrintableString,
    TagSequence,
    TagSet,
    TagT61String,
    TagUTCTime,
    TagUTF8String,
    TagAndLength,
)
from .value import BitString, ObjectIdentifier, RawValue

comptime _MAX_LENGTH = 1 << 23
"""What a length may hold before another byte is shifted into it.

Not a ceiling on the length itself. A length is built a byte at a time and
this is checked before each shift, so the largest one that gets through is
four bytes of length reaching two to the thirty first minus one, and the next
byte after that is what is refused. It is Go's check and Go's arithmetic, kept
so that the four byte lengths Go's own table pins are read the same way here.
"""

comptime _MAX_BASE128_SHIFTS = 5
"""Five groups of seven bits is thirty five, which is already more than an
`Int32` holds, so a sixth group is either non minimal or too large."""

comptime _UTC_SHORT = "0601021504Z0700"
"""A UTCTime with no seconds, which the encoding allows and certificates do
not use."""

comptime _UTC_LONG = "060102150405Z0700"
"""A UTCTime with seconds, which is what everything real writes."""

comptime _GENERALIZED = "20060102150405.999999999Z0700"
"""A GeneralizedTime, with a four digit year and optional fractional
seconds."""


def _is_numeric(b: Byte) -> Bool:
    """Whether `b` is in the NumericString set, which is digits and space."""
    return (b >= 0x30 and b <= 0x39) or b == 0x20


def _is_printable(b: Byte) -> Bool:
    """Whether `b` is in the PrintableString set, plus two that are not.

    Go allows `*` and `&` on top of what X.680 lists, and says why: wildcard
    names in certificates are written into the wrong string type often enough
    that refusing them would refuse working certificates, and there are
    certificate authorities with an ampersand in a name whose certificates do
    not expire until 2027. Go takes both as parameters and passes them
    everywhere from this package; there is one caller here, so they are simply
    allowed and this comment is the record of it.
    """
    return (
        (b >= 0x61 and b <= 0x7A)  # `a` to `z`
        or (b >= 0x41 and b <= 0x5A)  # `A` to `Z`
        or (b >= 0x30 and b <= 0x39)  # `0` to `9`
        or (b >= 0x27 and b <= 0x29)  # `'` to `)`
        or (b >= 0x2B and b <= 0x2F)  # `+` to `/`
        or b == 0x20  # space
        or b == 0x3A  # `:`
        or b == 0x3D  # `=`
        or b == 0x3F  # `?`
        or b == 0x2A  # `*`
        or b == 0x26  # `&`
    )


def _check_integer[o: ImmOrigin](bytes: Span[Byte, o]) raises:
    """Whether `bytes` are a minimally encoded two's complement INTEGER.

    Go's `checkInteger`. A leading zero in front of a byte whose top bit is
    clear, and a leading `0xff` in front of a byte whose top bit is set, both
    say the same number in one byte fewer, so DER forbids them.
    """
    if len(bytes) == 0:
        raise _structural("empty integer")
    if len(bytes) == 1:
        return
    if (bytes[0] == 0 and (bytes[1] & 0x80) == 0) or (
        bytes[0] == 0xFF and (bytes[1] & 0x80) == 0x80
    ):
        raise _structural("integer not minimally-encoded")


def _parse_int64[o: ImmOrigin](bytes: Span[Byte, o]) raises -> Int64:
    """`bytes` as a big endian, two's complement, sign extended integer."""
    _check_integer(bytes)
    if len(bytes) > 8:
        raise _structural("integer too large")
    var ret = Int64(0)
    for i in range(len(bytes)):
        ret <<= 8
        ret |= Int64(Int(bytes[i]))

    # Shift up and back down so the sign bit of the shortest encoding becomes
    # the sign bit of the result.
    var spare = Int64(64 - len(bytes) * 8)
    ret <<= spare
    ret >>= spare
    return ret


def _parse_big_int[o: ImmOrigin](bytes: Span[Byte, o]) raises -> BigInt:
    """`bytes` as an integer of any width. Go's `parseBigInt`.

    A negative number is stored two's complement, and `core.math.big` reads
    magnitudes, so the bytes are complemented, read, incremented and negated,
    which is the definition of two's complement run backwards.
    """
    _check_integer(bytes)
    var ret = BigInt()
    if len(bytes) > 0 and (bytes[0] & 0x80) == 0x80:
        var flipped = List[Byte](capacity=len(bytes))
        for i in range(len(bytes)):
            flipped.append(~bytes[i])
        ret.set_bytes(Span(flipped))
        return ret.add(BigInt(1)).neg()
    ret.set_bytes(bytes)
    return ret^


def _parse_bit_string[o: ImmOrigin](bytes: Span[Byte, o]) raises -> BitString:
    """`bytes` as a BIT STRING: a padding count and then the bits."""
    if len(bytes) == 0:
        raise _syntax("zero length BIT STRING")
    var padding = Int(bytes[0])
    if (
        padding > 7
        or (len(bytes) == 1 and padding > 0)
        or (bytes[len(bytes) - 1] & ((Byte(1) << bytes[0]) - 1)) != 0
    ):
        raise _syntax("invalid padding bits in BIT STRING")
    var packed = List[Byte](capacity=len(bytes) - 1)
    packed.extend(bytes[1 : len(bytes)])
    return BitString(packed^, (len(bytes) - 1) * 8 - padding)


def _parse_base128[
    o: ImmOrigin
](bytes: Span[Byte, o], start: Int) raises -> Tuple[Int, Int]:
    """One base 128 integer from `start`, and where it ended.

    Seven bits to a byte with the top bit saying another follows, which is the
    same shape as a varint and packed the other way round, most significant
    group first. Go's `parseBase128Int`.
    """
    var offset = start
    var ret = Int64(0)
    var shifted = 0
    while offset < len(bytes):
        if shifted == _MAX_BASE128_SHIFTS:
            raise _structural("base 128 integer too large")
        ret <<= 7
        var b = bytes[offset]

        # A leading group of zero says the number was written with a byte it
        # did not need, which DER does not allow.
        if shifted == 0 and b == 0x80:
            raise _syntax("integer is not minimally encoded")
        ret |= Int64(Int(b & 0x7F))
        offset += 1
        shifted += 1
        if (b & 0x80) == 0:
            if ret > Int64(Int32.MAX):
                raise _structural("base 128 integer too large")
            return (Int(ret), offset)
    raise _syntax("truncated base 128 integer")


def _parse_utc_time[o: ImmOrigin](bytes: Span[Byte, o]) raises -> Time:
    """`bytes` as a UTCTime, which has a two digit year.

    Both of Go's layouts are tried, the one with seconds and the one without,
    and the result is written back out and compared with what came in, which
    is how a time that parsed by luck rather than by being well formed is
    caught. A year from 2050 on cannot be spelled in two digits, so RFC 5280
    reads 50 to 99 as the nineteen hundreds and this does the same.
    """
    var s = String(from_utf8=bytes)
    var layout = String(_UTC_SHORT)
    var when: Time
    try:
        when = parse_time(layout, s)
    except:
        layout = String(_UTC_LONG)
        when = parse_time(layout, s)

    var again = when.format(layout)
    if again != s:
        raise _syntax(
            "time did not serialize back to the original value and may be"
            ' invalid: given "'
            + s
            + '", but serialized as "'
            + again
            + '"'
        )

    if when.year() >= 2050:
        return when.add_date(-100, 0, 0)
    return when^


def _parse_generalized_time[o: ImmOrigin](bytes: Span[Byte, o]) raises -> Time:
    """`bytes` as a GeneralizedTime, which has a four digit year."""
    var s = String(from_utf8=bytes)
    var when = parse_time(_GENERALIZED, s)
    var again = when.format(_GENERALIZED)
    if again != s:
        raise _syntax(
            "time did not serialize back to the original value and may be"
            ' invalid: given "'
            + s
            + '", but serialized as "'
            + again
            + '"'
        )
    return when^


def _parse_bmp_string[o: ImmOrigin](bytes: Span[Byte, o]) raises -> String:
    """`bytes` as a BMPString, which is UCS-2 and two bytes to a character.

    UCS-2 is UTF-16 without the surrogate pairs, so every pair of bytes is one
    character and a pair naming a surrogate is not a character at all. The
    permanent noncharacters go with them, which is what BoringSSL refuses and
    what Go refuses.
    """
    if len(bytes) % 2 != 0:
        raise _syntax("invalid BMPString")

    var end = len(bytes)
    if end >= 2 and bytes[end - 1] == 0 and bytes[end - 2] == 0:
        end -= 2

    var out = List[Byte](capacity=end)
    var i = 0
    while i < end:
        var point = (Int(bytes[i]) << 8) + Int(bytes[i + 1])
        if (
            point == 0xFFFE
            or point == 0xFFFF
            or (point >= 0xFDD0 and point <= 0xFDEF)
            or (point >= 0xD800 and point <= 0xDFFF)
        ):
            raise _syntax("invalid BMPString")
        _ = append_rune(out, Int32(point))
        i += 2
    return String(from_utf8=Span(out))


struct Parser[o: ImmOrigin](Movable):
    """A cursor over DER, reading one value at a time.

    Nothing here is Go's, because Go's reader is its reflection walk and there
    is no layer underneath it to borrow. What is Go's is every rule the reader
    enforces and every message it prints when one is broken.

    A `Parser` borrows the bytes it reads and never copies them, so the values
    it hands back that are spans are spans of the caller's own input. The ones
    that are strings or lists are new, since a `String` and a `List` own what
    they hold.

    ```mojo
    from core.encoding.asn1 import Parser

    def main() raises:
        # SEQUENCE { INTEGER 1, BOOLEAN true }
        var der: List[UInt8] = [
            UInt8(0x30), UInt8(0x06),
            UInt8(0x02), UInt8(0x01), UInt8(0x01),
            UInt8(0x01), UInt8(0x01), UInt8(0xFF),
        ]
        var top = Parser(Span(der))
        var body = top.read_sequence()
        print(body.read_int64())  # 1
        print(body.read_bool())  # True
        body.end()
        top.end()
    ```
    """

    var data: Span[Byte, Self.o]
    """The bytes, whole. The cursor is `pos` rather than a shortening span so
    that an offset in a message counts from the start of the input."""

    var pos: Int
    """How many bytes have been read."""

    def __init__(out self, data: Span[Byte, Self.o]):
        self.data = data
        self.pos = 0

    def remaining(self) -> Int:
        """How many bytes are left."""
        return len(self.data) - self.pos

    def at_end(self) -> Bool:
        """Whether everything has been read.

        The question a caller asks before reading an OPTIONAL field, since an
        optional field that is not there is an input that has run out.
        """
        return self.pos >= len(self.data)

    def end(self) raises:
        """Refuse anything left over.

        A structure that carries bytes after its last field is a structure the
        reader and the writer disagree about, and reading the fields and
        ignoring the rest is how a signature ends up covering something other
        than what was checked.
        """
        if not self.at_end():
            raise _syntax("trailing data")

    def read_header(mut self) raises -> TagAndLength:
        """The class, tag, compound bit and length of the next value.

        Go's `parseTagAndLength`. A tag number of thirty one means the real
        number follows in base 128, and one that could have been written in
        the five bits is refused there. A length above 127 says how many bytes
        of length follow, a length byte of zero says indefinite and is BER
        rather than DER, and a long form that could have been short is
        refused.
        """
        if self.at_end():
            raise _syntax("truncated tag or length")
        var b = self.data[self.pos]
        self.pos += 1
        var tag_class = Int(b >> _CLASS_SHIFT)
        var is_compound = (b & _COMPOUND_BIT) == _COMPOUND_BIT
        var tag = Int(b & _TAG_MASK)

        if tag == _HIGH_TAG:
            var read = _parse_base128(self.data, self.pos)
            tag = read[0]
            self.pos = read[1]
            if tag < _HIGH_TAG:
                raise _syntax("non-minimal tag")

        if self.at_end():
            raise _syntax("truncated tag or length")
        b = self.data[self.pos]
        self.pos += 1
        var length = 0
        if (b & 0x80) == 0:
            length = Int(b & 0x7F)
        else:
            var count = Int(b & 0x7F)
            if count == 0:
                raise _syntax("indefinite length found (not DER)")
            for _ in range(count):
                if self.at_end():
                    raise _syntax("truncated tag or length")
                b = self.data[self.pos]
                self.pos += 1
                if length >= _MAX_LENGTH:
                    raise _structural("length too large")
                length <<= 8
                length |= Int(b)
                if length == 0:
                    raise _structural("superfluous leading zeros in length")
            if length < 0x80:
                raise _structural("non-minimal length")

        return TagAndLength(tag_class, tag, length, is_compound)

    def peek_header(self) raises -> TagAndLength:
        """The next header without reading it.

        What a caller asks when the next field is OPTIONAL and the answer
        decides whether to read it at all.
        """
        var ahead = Parser[Self.o](self.data)
        ahead.pos = self.pos
        return ahead.read_header()

    def read_contents(mut self, length: Int) raises -> Span[Byte, Self.o]:
        """The next `length` bytes, which a header said were there."""
        if length < 0 or length > self.remaining():
            raise _syntax("data truncated")
        var start = self.pos
        self.pos += length
        return self.data[start : self.pos]

    def read_element(
        mut self, tag_class: Int, tag: Int, is_compound: Bool
    ) raises -> Span[Byte, Self.o]:
        """The contents of the next value, which has to be the one named.

        A header that does not match is a structural error rather than a
        syntax one, because the bytes are DER and are simply DER for something
        else.
        """
        var header = self.read_header()
        if not header.expect(tag_class, tag, is_compound):
            raise _structural(
                "tag mismatch, wanted class "
                + String(tag_class)
                + " tag "
                + String(tag)
                + ", got class "
                + String(header.tag_class)
                + " tag "
                + String(header.tag)
            )
        return self.read_contents(header.length)

    def read_sequence(mut self) raises -> Parser[Self.o]:
        """A cursor over the contents of the next SEQUENCE."""
        return Parser[Self.o](
            self.read_element(ClassUniversal, TagSequence, True)
        )

    def read_set(mut self) raises -> Parser[Self.o]:
        """A cursor over the contents of the next SET.

        Go maps SET onto SEQUENCE while parsing and so accepts either wherever
        one is wanted. This does not, because the two say different things
        about whether order is meaningful and a reader that cannot tell them
        apart cannot check a SET OF was sorted.
        """
        return Parser[Self.o](self.read_element(ClassUniversal, TagSet, True))

    def read_explicit(mut self, tag: Int) raises -> Parser[Self.o]:
        """A cursor over the contents of an explicitly tagged field.

        An EXPLICIT tag wraps the value's own header in a second, compound,
        context specific one, which is what makes an optional field with an
        explicit tag unambiguous. The parser this returns is over the wrapper,
        so the caller reads the real value out of it.
        """
        return Parser[Self.o](
            self.read_element(ClassContextSpecific, tag, True)
        )

    def read_implicit(
        mut self, tag: Int, is_compound: Bool
    ) raises -> Span[Byte, Self.o]:
        """The contents of an implicitly tagged field.

        An IMPLICIT tag replaces the value's own header, so what comes back is
        the contents of the value with nothing in front of them and the caller
        knows what they hold.
        """
        return self.read_element(ClassContextSpecific, tag, is_compound)

    def skip_value(mut self) raises:
        """Read the next value and throw it away, whatever it is."""
        var header = self.read_header()
        _ = self.read_contents(header.length)

    def read_raw_value(mut self) raises -> RawValue:
        """The next value, header and all, without decoding it.

        Go's `RawValue`, which is how a caller keeps the bytes of a field so
        that a signature over them can be checked after the rest has been
        read.
        """
        var start = self.pos
        var header = self.read_header()
        var body = self.read_contents(header.length)
        var bytes = List[Byte](capacity=len(body))
        bytes.extend(body)
        var whole = self.data[start : self.pos]
        var full = List[Byte](capacity=len(whole))
        full.extend(whole)
        return RawValue(
            header.tag_class, header.tag, header.is_compound, bytes^, full^
        )

    def read_bool(mut self) raises -> Bool:
        """The next BOOLEAN.

        DER says true is all eight bits set, so only zero and 255 are values a
        BOOLEAN can hold and anything else is refused. BER allows any nonzero
        byte, which is the ambiguity DER exists to remove.
        """
        var bytes = self.read_element(ClassUniversal, TagBoolean, False)
        if len(bytes) != 1:
            raise _syntax("invalid boolean")
        if bytes[0] == 0:
            return False
        if bytes[0] == 0xFF:
            return True
        raise _syntax("invalid boolean")

    def read_int64(mut self) raises -> Int64:
        """The next INTEGER, as far as sixty four bits reach."""
        return _parse_int64(
            self.read_element(ClassUniversal, TagInteger, False)
        )

    def read_int32(mut self) raises -> Int32:
        """The next INTEGER, refused if it does not fit in thirty two bits."""
        var wide = _parse_int64(
            self.read_element(ClassUniversal, TagInteger, False)
        )
        if wide != Int64(Int32(wide)):
            raise _structural("integer too large")
        return Int32(wide)

    def read_big_int(mut self) raises -> BigInt:
        """The next INTEGER, however wide it is.

        A certificate serial number is an integer of up to twenty bytes, which
        is why this exists beside the two that fit in a machine word.
        """
        return _parse_big_int(
            self.read_element(ClassUniversal, TagInteger, False)
        )

    def read_enumerated(mut self) raises -> Int:
        """The next ENUMERATED, which is an INTEGER with a different tag."""
        var wide = _parse_int64(
            self.read_element(ClassUniversal, TagEnum, False)
        )
        if wide != Int64(Int32(wide)):
            raise _structural("integer too large")
        return Int(wide)

    def read_null(mut self) raises:
        """The next NULL, which has no contents at all."""
        var bytes = self.read_element(ClassUniversal, TagNull, False)
        if len(bytes) != 0:
            raise _syntax("NULL with contents")

    def read_bit_string(mut self) raises -> BitString:
        """The next BIT STRING."""
        return _parse_bit_string(
            self.read_element(ClassUniversal, TagBitString, False)
        )

    def read_octet_string(mut self) raises -> List[Byte]:
        """The next OCTET STRING, as bytes of its own."""
        var bytes = self.read_element(ClassUniversal, TagOctetString, False)
        var out = List[Byte](capacity=len(bytes))
        out.extend(bytes)
        return out^

    def read_object_identifier(mut self) raises -> ObjectIdentifier:
        """The next OBJECT IDENTIFIER.

        The first byte holds two numbers, because the first can only be 0, 1
        or 2 and the second is under 40 whenever the first is 0 or 1, so the
        pair is packed as forty times one plus the other. Everything after it
        is one base 128 integer each.
        """
        var bytes = self.read_element(ClassUniversal, TagOID, False)
        if len(bytes) == 0:
            raise _syntax("zero length OBJECT IDENTIFIER")

        var values = List[Int]()
        var first = _parse_base128(bytes, 0)
        if first[0] < 80:
            values.append(first[0] // 40)
            values.append(first[0] % 40)
        else:
            values.append(2)
            values.append(first[0] - 80)

        var offset = first[1]
        while offset < len(bytes):
            var next = _parse_base128(bytes, offset)
            values.append(next[0])
            offset = next[1]
        return ObjectIdentifier(values^)

    def read_utf8_string(mut self) raises -> String:
        """The next UTF8String, refused if it is not UTF-8."""
        var bytes = self.read_element(ClassUniversal, TagUTF8String, False)
        if not valid(bytes):
            raise _syntax("invalid UTF-8 string")
        return String(from_utf8=bytes)

    def read_printable_string(mut self) raises -> String:
        """The next PrintableString, which is a subset of ASCII."""
        var bytes = self.read_element(ClassUniversal, TagPrintableString, False)
        for i in range(len(bytes)):
            if not _is_printable(bytes[i]):
                raise _syntax("PrintableString contains invalid character")
        return String(from_utf8=bytes)

    def read_numeric_string(mut self) raises -> String:
        """The next NumericString, which is digits and the space."""
        var bytes = self.read_element(ClassUniversal, TagNumericString, False)
        for i in range(len(bytes)):
            if not _is_numeric(bytes[i]):
                raise _syntax("NumericString contains invalid character")
        return String(from_utf8=bytes)

    def read_ia5_string(mut self) raises -> String:
        """The next IA5String, which is seven bit ASCII."""
        var bytes = self.read_element(ClassUniversal, TagIA5String, False)
        for i in range(len(bytes)):
            if bytes[i] >= 0x80:
                raise _syntax("IA5String contains invalid character")
        return String(from_utf8=bytes)

    def read_t61_string(mut self) raises -> String:
        """The next T61String, read as Latin-1.

        T.61 is a defunct encoding whose code page almost matches Latin-1, the
        difference being characters T.61 does not have at all. Nothing maps
        those, here or in Go or in BoringSSL: the bytes are read as Latin-1,
        which is what everybody does and what makes the certificates in the
        world readable.
        """
        var bytes = self.read_element(ClassUniversal, TagT61String, False)
        var out = List[Byte](capacity=len(bytes))
        for i in range(len(bytes)):
            _ = append_rune(out, Int32(Int(bytes[i])))
        return String(from_utf8=Span(out))

    def read_bmp_string(mut self) raises -> String:
        """The next BMPString, which is UCS-2."""
        return _parse_bmp_string(
            self.read_element(ClassUniversal, TagBMPString, False)
        )

    def read_utc_time(mut self) raises -> Time:
        """The next UTCTime."""
        return _parse_utc_time(
            self.read_element(ClassUniversal, TagUTCTime, False)
        )

    def read_generalized_time(mut self) raises -> Time:
        """The next GeneralizedTime."""
        return _parse_generalized_time(
            self.read_element(ClassUniversal, TagGeneralizedTime, False)
        )

    def read_time(mut self) raises -> Time:
        """The next value, which may be either of the two time types.

        A certificate's validity dates are UTCTime before 2050 and
        GeneralizedTime from then on, chosen by the writer, so the reader of
        one has to accept both.
        """
        var header = self.peek_header()
        if header.tag == TagGeneralizedTime:
            return self.read_generalized_time()
        return self.read_utc_time()

    def read_string(mut self) raises -> String:
        """The next value, whichever of the string types it is.

        Six tags land here. GeneralString is the one Go refuses and this
        refuses too, because nothing says which of its several registered
        character sets a given string is in, so there is no way to read one
        that is right more often than it is wrong.
        """
        var header = self.peek_header()
        if header.tag == TagUTF8String:
            return self.read_utf8_string()
        if header.tag == TagPrintableString:
            return self.read_printable_string()
        if header.tag == TagIA5String:
            return self.read_ia5_string()
        if header.tag == TagNumericString:
            return self.read_numeric_string()
        if header.tag == TagT61String:
            return self.read_t61_string()
        if header.tag == TagBMPString:
            return self.read_bmp_string()
        if header.tag == TagGeneralString:
            raise _structural("GeneralString is not supported")
        raise _structural("tag " + String(header.tag) + " is not a string type")
