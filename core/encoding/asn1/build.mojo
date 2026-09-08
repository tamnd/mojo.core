"""Writing DER, one value at a time.

Go marshals a whole structure in one call by walking the source value with
reflection. There is none here, so this is the layer underneath that and the
mirror of `parse.mojo`: a buffer that writes one header, or one primitive
value, and holds a constructed value open until its contents are done and its
length is finally known. Generated code drives it, and so does anything hand
written that knows the shape it is writing, which is what `core.crypto.x509`
will be.

DER puts a length in front of contents and the length of a SEQUENCE is not
known until its last field has been written. Go answers that by building a tree
of encoders, asking the tree how long it is and then walking it a second time
to fill a buffer, so every value is visited twice and every nested value is
measured once per level above it. This writes forward into one buffer instead:
`begin_sequence` puts down the tag and one byte of room for a length, and `end`
works out what the length turned out to be and widens that byte if it needed
more room. The bytes come out in the order they will be read in and each value
is visited once.

Nothing here recurses, for the reason nothing in `parse.mojo` does. `begin`
pushes onto a list and `end` pops, so a structure nested a million deep costs a
million pushes rather than a million stack frames, and there is no depth to
cap.

Everything refuses rather than repairs. The reader in this package will not
read a non-minimal length, a non-canonical integer or a bit string whose
padding is not zero, so a writer that emitted one would be producing bytes its
own package rejects. Where Go would write those bytes and leave the problem for
whoever reads them, this raises.
"""

from core.io import Byte
from core.math.big import Int as BigInt
from core.sort import slice
from core.time import Time
from core.unicode.utf8 import decode_rune

from .errors import _structural
from .parse import (
    _GENERALIZED,
    _UTC_LONG,
    _is_numeric,
    _is_printable,
    Parser,
)
from .tags import (
    _CLASS_SHIFT,
    _COMPOUND_BIT,
    _HIGH_TAG,
    _TAG_MASK,
    ClassContextSpecific,
    ClassPrivate,
    ClassUniversal,
    TagBMPString,
    TagBitString,
    TagBoolean,
    TagEnum,
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
)
from .value import BitString, ObjectIdentifier, RawValue


def _length_length(length: Int) -> Int:
    """How many bytes the long form needs to spell `length`. Go's
    `lengthLength`."""
    var count = 1
    var rest = length
    while rest > 255:
        count += 1
        rest >>= 8
    return count


def _base128_length(n: Int) -> Int:
    """How many seven bit groups `n` needs. Go's `base128IntLength`."""
    if n == 0:
        return 1
    var count = 0
    var rest = n
    while rest > 0:
        count += 1
        rest >>= 7
    return count


def _append_base128(mut dst: List[Byte], n: Int):
    """`n` as base 128, most significant group first, the top bit set on every
    group but the last. Go's `appendBase128Int`."""
    var groups = _base128_length(n)
    for i in range(groups - 1, -1, -1):
        var group = Byte((n >> (i * 7)) & 0x7F)
        if i != 0:
            group |= 0x80
        dst.append(group)


def _int64_bytes(v: Int64) -> List[Byte]:
    """`v` as a minimally encoded two's complement big endian integer.

    Go's `int64Encoder`, which works out the width by shifting until the value
    fits in one signed byte. Only one of the two loops can run for a given
    value, since a positive number shifted down never becomes a negative one.
    """
    var width = 1
    var rest = v
    while rest > 127:
        width += 1
        rest >>= 8
    while rest < -128:
        width += 1
        rest >>= 8

    var out = List[Byte](capacity=width)
    for i in range(width):
        out.append(Byte(Int(v >> Int64((width - 1 - i) * 8)) & 0xFF))
    return out^


def _big_int_bytes(v: BigInt) -> List[Byte]:
    """`v` as a minimally encoded two's complement big endian integer.

    Go's `makeBigInt`. `core.math.big` holds a sign and a magnitude, so a
    negative number is written by running two's complement backwards: negate,
    subtract one, complement the bytes, and put an `0xff` in front if the top
    bit did not come out set. Zero is one zero byte rather than no bytes,
    because an INTEGER with no contents is not an encoding of anything.
    """
    if v.sign() < 0:
        var less_one = v.neg().sub(BigInt(1))
        var magnitude = less_one.bytes()
        for i in range(len(magnitude)):
            magnitude[i] = ~magnitude[i]
        if len(magnitude) == 0 or (magnitude[0] & 0x80) == 0:
            var out: List[Byte] = [Byte(0xFF)]
            out.extend(Span(magnitude))
            return out^
        return magnitude^

    if v.sign() == 0:
        var zero: List[Byte] = [Byte(0)]
        return zero^

    var magnitude = v.bytes()
    if len(magnitude) > 0 and (magnitude[0] & 0x80) != 0:
        var out: List[Byte] = [Byte(0)]
        out.extend(Span(magnitude))
        return out^
    return magnitude^


def _bmp_bytes(s: StringSlice) raises -> List[Byte]:
    """`s` as UCS-2, two big endian bytes to a character.

    A character above the basic multilingual plane needs a surrogate pair and
    UCS-2 has no surrogates, so it cannot be written at all rather than being
    written as something else. The permanent noncharacters go the same way,
    since the reader in this package refuses them and a writer that produced
    one would be producing bytes it cannot read back. Surrogates themselves
    need no check because a `String` cannot hold one.
    """
    var out = List[Byte]()
    var data = s.as_bytes()
    var i = 0
    while i < len(data):
        var got = decode_rune(data[i : len(data)])
        var point = Int(got[0])
        i += got[1]
        if point > 0xFFFF:
            raise _structural(
                "BMPString cannot hold a character above the basic"
                " multilingual plane"
            )
        if (
            point == 0xFFFE
            or point == 0xFFFF
            or (point >= 0xFDD0 and point <= 0xFDEF)
        ):
            raise _structural("BMPString contains invalid character")
        out.append(Byte((point >> 8) & 0xFF))
        out.append(Byte(point & 0xFF))
    return out^


def _t61_bytes(s: StringSlice) raises -> List[Byte]:
    """`s` as T61String, which is written as Latin-1 for the reason it is read
    as Latin-1: that is what every implementation does with the code page."""
    var out = List[Byte]()
    var data = s.as_bytes()
    var i = 0
    while i < len(data):
        var got = decode_rune(data[i : len(data)])
        var point = Int(got[0])
        i += got[1]
        if point > 0xFF:
            raise _structural("T61String contains invalid character")
        out.append(Byte(point))
    return out^


def _outside_utc_range(t: Time) -> Bool:
    """Whether `t` has a year a two digit year cannot say. Go's
    `outsideUTCRange`."""
    var year = t.year()
    return year < 1950 or year >= 2050


def _compare(a: List[Byte], b: List[Byte]) -> Int:
    """`a` against `b` as octet strings, negative, zero or positive.

    Shorter sorts before longer when one is a prefix of the other, which is
    what X.690 asks for once the padding it describes is accounted for.
    """
    var shared = len(a) if len(a) < len(b) else len(b)
    for i in range(shared):
        if a[i] != b[i]:
            return -1 if a[i] < b[i] else 1
    if len(a) == len(b):
        return 0
    return -1 if len(a) < len(b) else 1


def _make_room(mut buf: List[Byte], at: Int, count: Int):
    """Open `count` bytes of room at `at`, moving what follows up.

    This is what a length that outgrew its one placeholder byte costs. It is
    linear in what has already been written into the value being closed, and
    it happens once per value rather than once per byte, so a certificate pays
    it a few dozen times.
    """
    for _ in range(count):
        buf.append(0)
    var i = len(buf) - 1
    while i >= at + count:
        buf[i] = buf[i - count]
        i -= 1


struct Builder(Movable, Sized):
    """A buffer that DER is written into, one value at a time.

    Nothing here is Go's, because Go's writer is its reflection walk and there
    is no layer underneath it to borrow. What is Go's is every byte it
    produces: the same length form, the same integer widths, the same choice
    between the two time types and the same sorting of a SET OF.

    A constructed value is opened, its contents are written and then it is
    closed, and closing is what puts the length in. Forgetting to close one is
    caught by `finish`, which will not hand back bytes while anything is still
    open.

    ```mojo
    from core.encoding.asn1 import Builder

    def main() raises:
        var b = Builder()
        b.begin_sequence()
        b.add_int64(1)
        b.add_bool(True)
        b.end()
        var der = b^.finish()
        print(len(der))  # 8
    ```
    """

    var bytes: List[Byte]
    """Everything written so far. The length byte of a value that is still
    open is a placeholder until `end` fills it in."""

    var _open: List[Int]
    """Where each open value's length placeholder sits, innermost last.

    An offset here never moves, because room is only ever made after it.
    """

    var _sorted: List[Bool]
    """Whether each open value's contents are sorted when it is closed, which
    is true for a SET OF and false for everything else."""

    def __init__(out self):
        """An empty builder with nothing open."""
        self.bytes = List[Byte]()
        self._open = List[Int]()
        self._sorted = List[Bool]()

    def __len__(self) -> Int:
        """How many bytes have been written, open placeholders included."""
        return len(self.bytes)

    def depth(self) -> Int:
        """How many constructed values are open.

        Zero at the point the bytes are complete, which is what `finish`
        checks.
        """
        return len(self._open)

    def finish(deinit self) raises -> List[Byte]:
        """The bytes, taken out of a builder that is finished with.

        Raises if a value is still open, since the length of an unclosed value
        was never written and the bytes would be a document with a hole in
        them.
        """
        if len(self._open) != 0:
            raise _structural(
                "unfinished value: " + String(len(self._open)) + " still open"
            )
        return self.bytes^

    def add_header(
        mut self, tag_class: Int, tag: Int, is_compound: Bool, length: Int
    ) raises:
        """The class, tag, compound bit and length of a value.

        Go's `appendTagAndLength`. A tag number of thirty one or above moves
        into the base 128 form after the identifier octet, and a length of 128
        or above says in its first byte how many bytes of length follow. Both
        are written in the shortest form that holds the number, because the
        reader refuses any other.
        """
        if tag_class < ClassUniversal or tag_class > ClassPrivate:
            raise _structural("invalid tag class " + String(tag_class))
        if tag < 0:
            raise _structural("invalid tag " + String(tag))
        if length < 0:
            raise _structural("invalid length " + String(length))

        var identifier = Byte(tag_class) << Byte(_CLASS_SHIFT)
        if is_compound:
            identifier |= _COMPOUND_BIT
        if tag >= _HIGH_TAG:
            identifier |= _TAG_MASK
            self.bytes.append(identifier)
            _append_base128(self.bytes, tag)
        else:
            identifier |= Byte(tag)
            self.bytes.append(identifier)

        self._add_length(length)

    def _add_length(mut self, length: Int):
        """A length, short form below 128 and long form from there up."""
        if length < 0x80:
            self.bytes.append(Byte(length))
            return
        var count = _length_length(length)
        self.bytes.append(Byte(0x80 | count))
        for i in range(count - 1, -1, -1):
            self.bytes.append(Byte((length >> (i * 8)) & 0xFF))

    def add_encoded(mut self, der: Span[Byte, _]):
        """Bytes that are already a whole DER value, written as they are.

        What a caller reaches for when a value was read rather than built: a
        field kept as `RawValue.full_bytes`, or a structure being copied from
        one document into another. Nothing is checked, because the bytes came
        from somewhere that checked them.
        """
        self.bytes.extend(der)

    def _add_primitive(
        mut self, tag_class: Int, tag: Int, contents: Span[Byte, _]
    ) raises:
        """A whole primitive value: its header and then its contents."""
        self.add_header(tag_class, tag, False, len(contents))
        self.bytes.extend(contents)

    def begin(mut self, tag_class: Int, tag: Int, is_compound: Bool) raises:
        """Open a value whose length is not known yet.

        One byte of room for the length goes down now and `end` decides how
        many bytes it really needed.
        """
        self.add_header(tag_class, tag, is_compound, 0)
        self._open.append(len(self.bytes) - 1)
        self._sorted.append(False)

    def begin_sequence(mut self) raises:
        """Open a SEQUENCE, whose fields are written in the order they are
        declared in."""
        self.begin(ClassUniversal, TagSequence, True)

    def begin_set(mut self) raises:
        """Open a SET, whose fields are written in the order they are declared
        in.

        X.690 orders the components of a SET by tag and this writes them in
        the order the caller wrote them, which is Go's behaviour too. A caller
        building a SET from a fixed list of fields knows their tags and can
        declare them in order; a caller building a SET OF wants
        `begin_set_of`, which does the sorting because only it knows where one
        element ends and the next begins.
        """
        self.begin(ClassUniversal, TagSet, True)

    def begin_set_of(mut self) raises:
        """Open a SET OF, whose elements are sorted when it is closed.

        X.690 section 11.6 says the encodings of the elements are compared as
        octet strings and written in ascending order, which is the rule that
        makes two writers of the same set produce the same bytes. The caller
        writes the elements in any order and `end` puts them in that one.
        """
        self.begin(ClassUniversal, TagSet, True)
        self._sorted[len(self._sorted) - 1] = True

    def begin_explicit(mut self, tag: Int) raises:
        """Open an explicitly tagged field.

        An EXPLICIT tag is a compound context specific value wrapping the real
        value's own header, so the caller writes a whole value inside this one.
        """
        self.begin(ClassContextSpecific, tag, True)

    def begin_implicit(mut self, tag: Int, is_compound: Bool) raises:
        """Open an implicitly tagged field.

        An IMPLICIT tag replaces the value's own header, so the caller writes
        the contents of the value and nothing in front of them.
        """
        self.begin(ClassContextSpecific, tag, is_compound)

    def end(mut self) raises:
        """Close the innermost open value and write its length.

        The length went down as one byte when the value was opened. If it
        turned out to need more, room is made for the rest and what was
        written inside moves up.
        """
        if len(self._open) == 0:
            raise _structural("no open value to end")
        var mark = self._open.pop()
        var sorting = self._sorted.pop()
        if sorting:
            self._sort_contents(mark + 1)

        var length = len(self.bytes) - mark - 1
        if length < 0x80:
            self.bytes[mark] = Byte(length)
            return

        var count = _length_length(length)
        _make_room(self.bytes, mark + 1, count)
        self.bytes[mark] = Byte(0x80 | count)
        for i in range(count):
            self.bytes[mark + 1 + i] = Byte(
                (length >> ((count - 1 - i) * 8)) & 0xFF
            )

    def _sort_contents(mut self, start: Int) raises:
        """Put the elements written from `start` into ascending octet order.

        The elements are read back with a `Parser`, which is the only thing
        that knows where each of them ends, so a SET OF holding something the
        reader will not read is caught here rather than at the far end of a
        wire.
        """
        var body = List[Byte]()
        body.extend(Span(self.bytes)[start : len(self.bytes)])

        var elements = List[List[Byte]]()
        var walk = Parser(Span(body))
        while not walk.at_end():
            var at = walk.pos
            walk.skip_value()
            var one = List[Byte]()
            one.extend(Span(body)[at : walk.pos])
            elements.append(one^)

        var view = Span(elements)

        @parameter
        def before(i: Int, j: Int) -> Bool:
            return _compare(view[i], view[j]) < 0

        slice[before](view)

        var at = start
        for i in range(len(elements)):
            for j in range(len(elements[i])):
                self.bytes[at] = elements[i][j]
                at += 1

    def add_bool(
        mut self,
        v: Bool,
        tag_class: Int = ClassUniversal,
        tag: Int = TagBoolean,
    ) raises:
        """A BOOLEAN.

        DER says true is all eight bits set, so this writes 255 and not 1. BER
        would allow any nonzero byte, which is the ambiguity DER exists to
        remove and the reason the reader in this package refuses everything
        else.
        """
        var contents: List[Byte] = [Byte(0xFF) if v else Byte(0)]
        self._add_primitive(tag_class, tag, Span(contents))

    def add_int64(
        mut self,
        v: Int64,
        tag_class: Int = ClassUniversal,
        tag: Int = TagInteger,
    ) raises:
        """An INTEGER, as far as sixty four bits reach."""
        var contents = _int64_bytes(v)
        self._add_primitive(tag_class, tag, Span(contents))

    def add_int32(
        mut self,
        v: Int32,
        tag_class: Int = ClassUniversal,
        tag: Int = TagInteger,
    ) raises:
        """An INTEGER that came from thirty two bits."""
        self.add_int64(Int64(v), tag_class, tag)

    def add_big_int(
        mut self,
        v: BigInt,
        tag_class: Int = ClassUniversal,
        tag: Int = TagInteger,
    ) raises:
        """An INTEGER of any width.

        A certificate serial number is an integer of up to twenty bytes, which
        is why this exists beside the two that fit in a machine word.
        """
        var contents = _big_int_bytes(v)
        self._add_primitive(tag_class, tag, Span(contents))

    def add_enumerated(
        mut self, v: Int, tag_class: Int = ClassUniversal, tag: Int = TagEnum
    ) raises:
        """An ENUMERATED, which is an INTEGER with a different tag.

        Refused above what thirty two bits hold, because the reader refuses to
        hand one back above that and a value that cannot be read back is not
        worth writing.
        """
        if v != Int(Int32(v)):
            raise _structural("integer too large")
        var contents = _int64_bytes(Int64(v))
        self._add_primitive(tag_class, tag, Span(contents))

    def add_null(
        mut self, tag_class: Int = ClassUniversal, tag: Int = TagNull
    ) raises:
        """A NULL, which is a header and no contents at all."""
        self.add_header(tag_class, tag, False, 0)

    def add_bit_string(
        mut self,
        v: BitString,
        tag_class: Int = ClassUniversal,
        tag: Int = TagBitString,
    ) raises:
        """A BIT STRING.

        Go writes the padding count and the bytes and looks at neither. Two
        things are checked here. The byte count has to be the one the bit
        length calls for, since a `BitString` whose two do not agree would be
        read back as a different string than the one that was written. And the
        padding at the end of the last byte has to be zero, which DER requires
        and the reader in this package enforces.
        """
        if v.bit_length < 0:
            raise _structural("negative BIT STRING length")
        var needed = (v.bit_length + 7) // 8
        if needed != len(v.bytes):
            raise _structural(
                "BIT STRING of "
                + String(v.bit_length)
                + " bits needs "
                + String(needed)
                + " bytes, has "
                + String(len(v.bytes))
            )

        var padding = (8 - v.bit_length % 8) % 8
        if (
            len(v.bytes) > 0
            and (v.bytes[len(v.bytes) - 1] & ((Byte(1) << Byte(padding)) - 1))
            != 0
        ):
            raise _structural("invalid padding bits in BIT STRING")

        var contents = List[Byte](capacity=len(v.bytes) + 1)
        contents.append(Byte(padding))
        contents.extend(Span(v.bytes))
        self._add_primitive(tag_class, tag, Span(contents))

    def add_octet_string(
        mut self,
        v: Span[Byte, _],
        tag_class: Int = ClassUniversal,
        tag: Int = TagOctetString,
    ) raises:
        """An OCTET STRING, which holds whatever bytes it is given."""
        self._add_primitive(tag_class, tag, v)

    def add_object_identifier(
        mut self,
        v: ObjectIdentifier,
        tag_class: Int = ClassUniversal,
        tag: Int = TagOID,
    ) raises:
        """An OBJECT IDENTIFIER.

        The first two numbers share one base 128 integer, forty times the
        first plus the second, which only works because the first can be 0, 1
        or 2 and the second is under 40 whenever the first is 0 or 1. Go
        checks exactly that. A negative number is refused as well, which Go
        does not do and which would otherwise be written as no bytes at all.
        """
        if len(v) < 2:
            raise _structural("invalid object identifier")
        if v[0] < 0 or v[0] > 2 or v[1] < 0 or (v[0] < 2 and v[1] >= 40):
            raise _structural("invalid object identifier")

        var contents = List[Byte]()
        _append_base128(contents, v[0] * 40 + v[1])
        for i in range(2, len(v)):
            if v[i] < 0:
                raise _structural("invalid object identifier")
            _append_base128(contents, v[i])
        self._add_primitive(tag_class, tag, Span(contents))

    def add_utf8_string(
        mut self,
        s: StringSlice,
        tag_class: Int = ClassUniversal,
        tag: Int = TagUTF8String,
    ) raises:
        """A UTF8String.

        Go checks the string is valid UTF-8 because a Go string can hold
        anything. A `StringSlice` cannot, so there is nothing to check.
        """
        self._add_primitive(tag_class, tag, s.as_bytes())

    def add_printable_string(
        mut self,
        s: StringSlice,
        tag_class: Int = ClassUniversal,
        tag: Int = TagPrintableString,
    ) raises:
        """A PrintableString, which is a subset of ASCII from 1988.

        The asterisk is allowed, because a caller asking for this type by name
        has said what they want and wildcard names are written into it often
        enough that Go allows it too. The ampersand is not, which is the one
        place Go's writer is stricter than Go's reader: certificates with an
        ampersand in a name exist and have to be read, and there is no reason
        to make more of them.
        """
        var data = s.as_bytes()
        for i in range(len(data)):
            if not _is_printable(data[i], asterisk=True, ampersand=False):
                raise _structural("PrintableString contains invalid character")
        self._add_primitive(tag_class, tag, data)

    def add_numeric_string(
        mut self,
        s: StringSlice,
        tag_class: Int = ClassUniversal,
        tag: Int = TagNumericString,
    ) raises:
        """A NumericString, which is digits and the space."""
        var data = s.as_bytes()
        for i in range(len(data)):
            if not _is_numeric(data[i]):
                raise _structural("NumericString contains invalid character")
        self._add_primitive(tag_class, tag, data)

    def add_ia5_string(
        mut self,
        s: StringSlice,
        tag_class: Int = ClassUniversal,
        tag: Int = TagIA5String,
    ) raises:
        """An IA5String, which is seven bit ASCII."""
        var data = s.as_bytes()
        for i in range(len(data)):
            if data[i] >= 0x80:
                raise _structural("IA5String contains invalid character")
        self._add_primitive(tag_class, tag, data)

    def add_t61_string(
        mut self,
        s: StringSlice,
        tag_class: Int = ClassUniversal,
        tag: Int = TagT61String,
    ) raises:
        """A T61String, written as Latin-1.

        Go has no writer for this type at all: its reflection walk picks a tag
        from the Go type and no Go type asks for T61String. That is fine for
        making new certificates and not fine for copying an old one, where a
        name that arrived as T61String has to go back out as T61String or the
        signature over it stops verifying. So this exists, and the round trip
        it completes is why.
        """
        var contents = _t61_bytes(s)
        self._add_primitive(tag_class, tag, Span(contents))

    def add_bmp_string(
        mut self,
        s: StringSlice,
        tag_class: Int = ClassUniversal,
        tag: Int = TagBMPString,
    ) raises:
        """A BMPString, which is UCS-2 and two bytes to a character.

        Go has no writer for this one either, and for the same reason and with
        the same consequence.
        """
        var contents = _bmp_bytes(s)
        self._add_primitive(tag_class, tag, Span(contents))

    def add_string(mut self, s: StringSlice) raises:
        """A string as whichever of the two general types will hold it.

        Go's rule for a string field with no type named in its tag: a
        PrintableString if every character is in that set, and a UTF8String
        otherwise. The asterisk is not allowed here even though
        `add_printable_string` allows it, which is Go's split as well: a
        caller who names the type has said what they want, and a caller who
        did not gets the type that is right rather than the type that is
        older.
        """
        var data = s.as_bytes()
        var fits = True
        for i in range(len(data)):
            if data[i] >= 0x80 or not _is_printable(
                data[i], asterisk=False, ampersand=False
            ):
                fits = False
                break
        if fits:
            self._add_primitive(ClassUniversal, TagPrintableString, data)
            return
        self._add_primitive(ClassUniversal, TagUTF8String, data)

    def add_utc_time(
        mut self,
        t: Time,
        tag_class: Int = ClassUniversal,
        tag: Int = TagUTCTime,
    ) raises:
        """A UTCTime, which has a two digit year and so stops in 2050."""
        if _outside_utc_range(t):
            raise _structural("cannot represent time as UTCTime")
        var text = t.format(_UTC_LONG)
        self._add_primitive(tag_class, tag, text.as_bytes())

    def add_generalized_time(
        mut self,
        t: Time,
        tag_class: Int = ClassUniversal,
        tag: Int = TagGeneralizedTime,
    ) raises:
        """A GeneralizedTime, which has a four digit year.

        Go writes whole seconds and drops any fraction. This writes the
        fraction when there is one, with no trailing zeros and no trailing
        dot, which is what X.690 section 11.7 asks for and what the reader in
        this package reads back. So a time written here comes back as the time
        that went in, where Go's would come back rounded.
        """
        var year = t.year()
        if year < 0 or year > 9999:
            raise _structural("cannot represent time as GeneralizedTime")
        var text = t.format(_GENERALIZED)
        self._add_primitive(tag_class, tag, text.as_bytes())

    def add_time(mut self, t: Time) raises:
        """A time as whichever of the two types can hold it.

        Go's rule, and RFC 5280's: UTCTime through 2049 and GeneralizedTime
        from 2050 on, so that the reader of a certificate's validity dates has
        to accept both.
        """
        if _outside_utc_range(t):
            self.add_generalized_time(t)
            return
        self.add_utc_time(t)

    def add_raw_value(mut self, v: RawValue) raises:
        """A value that was read rather than built. Go's `RawValue` case.

        The whole encoding is written when there is one, since those bytes are
        what a signature was taken over. Otherwise the header is built from
        the class, tag and compound bit and the contents follow it, which is
        how a caller writes a value this package has no other way to spell.
        """
        if len(v.full_bytes) != 0:
            self.bytes.extend(Span(v.full_bytes))
            return
        self.add_header(v.tag_class, v.tag, v.is_compound, len(v.bytes))
        self.bytes.extend(Span(v.bytes))
