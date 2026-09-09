"""One value in and one value out, with Go's struct tags applied to it.

Go's `Marshal` takes an `any`, asks reflection what type it holds and writes
the DER for it. `Unmarshal` takes a pointer, asks reflection what it points at
and reads into it. Neither question can be asked here, so what stands in for
the answer is an overload per type: the nine types Go's own walk bottoms out at
each have their own `marshal` and their own `unmarshal`, chosen at build time
by the type of the argument rather than at run time by a type switch.

That is the whole of the difference. Everything above the type switch is the
same code doing the same thing, because the interesting part of Go's two
functions was never the reflection: it is the struct tag grammar, and what a
tag does to the header a value is written under. `MarshalWithParams` takes that
grammar as a string, and `marshal_with_params` takes the same string and reads
it the same way, so `"optional,explicit,tag:0"` means here what it means there.

What is not here is the struct walk. A SEQUENCE is a list of fields with a tag
string on each, and walking one is what generated code does, a field at a time,
against `Builder` and `Parser` directly. These six calls are what such code is
made of, and are also what a caller with a single value in hand wants, which is
why Go exports them separately from the walk.

Two of Go's types have no overload. `Enumerated` is a name for `Int` here and
`Flag` is a name for `Bool`, so a call passing one would be a call passing the
other and the tag written would be a coin toss. An ENUMERATED goes out through
`Builder.add_enumerated` and comes back through `Parser.read_enumerated`, which
is the same one call with the ambiguity spelled out of it.
"""

from core.io import Byte
from core.math.big import Int as BigInt
from core.time import Time

from .build import Builder, _outside_utc_range
from .errors import _structural, _syntax
from .parse import (
    Parser,
    _is_printable,
    _parse_big_int,
    _parse_bit_string,
    _parse_bool,
    _parse_generalized_time,
    _parse_int64,
    _parse_object_identifier,
    _parse_string,
    _parse_utc_time,
)
from .tags import (
    ClassApplication,
    ClassContextSpecific,
    ClassPrivate,
    ClassUniversal,
    TagAndLength,
    TagBMPString,
    TagBitString,
    TagBoolean,
    TagGeneralString,
    TagGeneralizedTime,
    TagIA5String,
    TagInteger,
    TagNumericString,
    TagOID,
    TagOctetString,
    TagPrintableString,
    TagSet,
    TagT61String,
    TagUTCTime,
    TagUTF8String,
)
from .value import BitString, ObjectIdentifier, RawValue

comptime _INT64_MAX = Int64(9223372036854775807)
"""The largest `default:` value that will be read out of a tag string. Anything
above it is a tag Go's `strconv.ParseInt` refuses, and a refused number leaves
the field unset rather than raising, here as there."""


struct _Params(Copyable, Movable):
    """What a struct tag said. Go's `fieldParameters`.

    One invariant, which is Go's: if `explicit` is set then `tag` is set, since
    an explicit tag with no number to wrap in is not something the grammar can
    say.
    """

    var optional: Bool
    """The value may be absent. Go's `optional`."""

    var explicit: Bool
    """The tag wraps the value's own header rather than replacing it. Go's
    `explicit`."""

    var application: Bool
    """The tag is application class. Go's `application`."""

    var private: Bool
    """The tag is private class. Go's `private`."""

    var is_set: Bool
    """Write a SET rather than a SEQUENCE. Go's `set`, which is a name this
    library keeps for a Mojo builtin."""

    var omit_empty: Bool
    """An empty slice is written as nothing at all. Go's `omitEmpty`."""

    var tag: Optional[Int]
    """The tag number, when one was given. Go's `tag`, which is a pointer
    there for the same reason this is an `Optional`: zero is a tag number."""

    var default_value: Optional[Int64]
    """What an absent INTEGER is worth. Go's `defaultValue`."""

    var string_type: Int
    """The tag a string is written under, or zero for none. Go's
    `stringType`."""

    var time_type: Int
    """The tag a time is written under, or zero for none. Go's `timeType`."""

    def __init__(out self):
        """What an empty tag string says, which is nothing."""
        self.optional = False
        self.explicit = False
        self.application = False
        self.private = False
        self.is_set = False
        self.omit_empty = False
        self.tag = None
        self.default_value = None
        self.string_type = 0
        self.time_type = 0


def _atoi(text: StringSlice) -> Optional[Int64]:
    """`text` as a number, or nothing if it is not one.

    Go parses the number after `default:` and `tag:` with `strconv` and drops
    the part on an error rather than reporting it, so a tag string with a
    typo in it is a tag string with one fewer part. Nothing comes back here
    for the same cases: no digits, a stray character, or a number too large
    for the sixty four bits Go parses into.
    """
    var data = text.as_bytes()
    if len(data) == 0:
        return None
    var negative = data[0] == 0x2D  # `-`
    var i = 1 if negative or data[0] == 0x2B else 0  # `+`
    if i >= len(data):
        return None

    var value = Int64(0)
    while i < len(data):
        var b = data[i]
        if b < 0x30 or b > 0x39:
            return None
        var digit = Int64(Int(b) - 0x30)
        if value > (_INT64_MAX - digit) // 10:
            return None
        value = value * 10 + digit
        i += 1
    return -value if negative else value


def _has_prefix(text: StringSlice, prefix: StringSlice) -> Bool:
    """Whether `text` starts with `prefix`."""
    if text.byte_length() < prefix.byte_length():
        return False
    return text[byte = 0 : prefix.byte_length()] == prefix


def _apply(mut p: _Params, part: StringSlice):
    """One comma separated part of a tag string, applied.

    A part nobody recognises is ignored, which is Go's rule and is what lets
    the same tag string carry parameters for more than one encoding.
    """
    if part == "optional":
        p.optional = True
    elif part == "explicit":
        p.explicit = True
        if not Bool(p.tag):
            p.tag = 0
    elif part == "generalized":
        p.time_type = TagGeneralizedTime
    elif part == "utc":
        p.time_type = TagUTCTime
    elif part == "ia5":
        p.string_type = TagIA5String
    elif part == "printable":
        p.string_type = TagPrintableString
    elif part == "numeric":
        p.string_type = TagNumericString
    elif part == "utf8":
        p.string_type = TagUTF8String
    elif _has_prefix(part, "default:"):
        var n = _atoi(part[byte = 8 : part.byte_length()])
        if n:
            p.default_value = n.value()
    elif _has_prefix(part, "tag:"):
        var n = _atoi(part[byte = 4 : part.byte_length()])
        if n:
            p.tag = Int(n.value())
    elif part == "set":
        p.is_set = True
    elif part == "application":
        p.application = True
        if not Bool(p.tag):
            p.tag = 0
    elif part == "private":
        p.private = True
        if not Bool(p.tag):
            p.tag = 0
    elif part == "omitempty":
        p.omit_empty = True


def _parse_params(params: StringSlice) -> _Params:
    """A tag string, read. Go's `parseFieldParameters`."""
    var out = _Params()
    var data = params.as_bytes()
    var start = 0
    for i in range(len(data) + 1):
        if i == len(data) or data[i] == 0x2C:  # `,`
            if i > start:
                _apply(out, params[byte=start:i])
            start = i + 1
    return out^


def _check(p: _Params, universal_tag: Int) raises:
    """Refuse a tag string that asks a type for something it cannot give.

    Go's three checks in `makeField`. The third of them is the one that fires
    most often here: `set` says to write a SET rather than a SEQUENCE, none of
    the nine types below is a SEQUENCE, and so `set` on any of them is the
    error Go raises for a field that is not a collection.
    """
    if p.time_type != 0 and universal_tag != TagUTCTime:
        raise _structural("explicit time type given to non-time member")
    if p.string_type != 0 and universal_tag != TagPrintableString:
        raise _structural("explicit string type given to non-string member")
    if p.is_set:
        raise _structural("non sequence tagged as set")


struct _Wrap(Copyable, Movable):
    """Which headers a value is written under, after its tag string.

    Two of them at most: the value's own, and an explicit tag around it. Go
    builds the same pair out of two `taggedEncoder`s.
    """

    var outer_class: Int
    """The class of the explicit wrapper, or -1 when there is no wrapper."""

    var outer_tag: Int
    """The tag number of the explicit wrapper."""

    var tag_class: Int
    """The class the value itself is written under."""

    var tag: Int
    """The tag number the value itself is written under."""

    def __init__(
        out self, outer_class: Int, outer_tag: Int, tag_class: Int, tag: Int
    ):
        self.outer_class = outer_class
        self.outer_tag = outer_tag
        self.tag_class = tag_class
        self.tag = tag


def _wrap(p: _Params, universal_tag: Int) -> _Wrap:
    """The headers `universal_tag` goes out under, given `p`.

    No tag number is the universal header and nothing around it. A tag number
    with `explicit` keeps the universal header and wraps a compound one around
    it, which is what makes an optional field with an explicit tag readable
    without knowing the type. A tag number without `explicit` replaces the
    universal header, which is smaller and is why implicit tagging exists.
    """
    if not Bool(p.tag):
        return _Wrap(-1, 0, ClassUniversal, universal_tag)

    var tag_class = ClassContextSpecific
    if p.application:
        tag_class = ClassApplication
    elif p.private:
        tag_class = ClassPrivate

    if p.explicit:
        return _Wrap(tag_class, p.tag.value(), ClassUniversal, universal_tag)
    return _Wrap(-1, 0, tag_class, p.tag.value())


def _open(mut b: Builder, w: _Wrap) raises:
    """Start the explicit wrapper, if there is one."""
    if w.outer_class >= 0:
        b.begin(w.outer_class, w.outer_tag, True)


def _close(mut b: Builder, w: _Wrap) raises:
    """Finish the explicit wrapper, if there is one."""
    if w.outer_class >= 0:
        b.end()


def _string_tag(s: StringSlice) -> Int:
    """The tag a string with no type named for it goes out under.

    Go's rule: a PrintableString if every character is in that set, and a
    UTF8String otherwise. The asterisk and the ampersand are both outside the
    set here, which is Go's `rejectAsterisk, rejectAmpersand`: a caller who
    named the type gets what they asked for and a caller who did not gets the
    type that is right rather than the type that is older.
    """
    var data = s.as_bytes()
    for i in range(len(data)):
        if data[i] >= 0x80 or not _is_printable(
            data[i], asterisk=False, ampersand=False
        ):
            return TagUTF8String
    return TagPrintableString


def _add_string(
    mut b: Builder, s: StringSlice, string_tag: Int, tag_class: Int, tag: Int
) raises:
    """A string of type `string_tag`, written under the header `tag_class` and
    `tag` name.

    The two are the same header until an implicit tag replaces it, and then
    the type is still what says which characters are allowed even though the
    number written down is the field's.
    """
    if string_tag == TagUTF8String:
        b.add_utf8_string(s, tag_class, tag)
    elif string_tag == TagPrintableString:
        b.add_printable_string(s, tag_class, tag)
    elif string_tag == TagIA5String:
        b.add_ia5_string(s, tag_class, tag)
    elif string_tag == TagNumericString:
        b.add_numeric_string(s, tag_class, tag)
    elif string_tag == TagT61String:
        b.add_t61_string(s, tag_class, tag)
    elif string_tag == TagBMPString:
        b.add_bmp_string(s, tag_class, tag)
    else:
        raise _structural("tag " + String(string_tag) + " is not a string type")


# Marshalling. One pair per type, and the pair is always the same shape: read
# the tag string, decide whether the value is written at all, check the tag
# string against the type, work out the headers, and write it.


def marshal(v: Bool) raises -> List[Byte]:
    """A BOOLEAN. Go's `Marshal` for a `bool`.

    ```mojo
    from core.encoding.asn1 import marshal

    def main() raises:
        var der = marshal(True)
        print(len(der), der[0], der[2])  # 3 1 255
    ```
    """
    return marshal_with_params(v, "")


def marshal_with_params(v: Bool, params: StringSlice) raises -> List[Byte]:
    """A BOOLEAN, under `params`. Go's `MarshalWithParams` for a `bool`.

    ```mojo
    from core.encoding.asn1 import marshal_with_params

    def main() raises:
        # An implicit context specific tag replaces the universal one.
        var der = marshal_with_params(True, "tag:0")
        print(der[0])  # 128, which is context specific tag 0
    ```
    """
    var p = _parse_params(params)
    if p.optional and not Bool(p.default_value) and not v:
        return List[Byte]()
    _check(p, TagBoolean)

    var w = _wrap(p, TagBoolean)
    var b = Builder()
    _open(b, w)
    b.add_bool(v, w.tag_class, w.tag)
    _close(b, w)
    return b^.finish()


def marshal(v: Int64) raises -> List[Byte]:
    """An INTEGER. Go's `Marshal` for an `int64`."""
    return marshal_with_params(v, "")


def marshal_with_params(v: Int64, params: StringSlice) raises -> List[Byte]:
    """An INTEGER, under `params`.

    The one type `default:` applies to, since Go only sets a default value on
    a field whose kind is an integer. An optional field equal to its default
    is written as nothing, because the reader will supply the same number.
    """
    var p = _parse_params(params)
    if p.optional:
        if Bool(p.default_value):
            if v == p.default_value.value():
                return List[Byte]()
        elif v == 0:
            return List[Byte]()
    _check(p, TagInteger)

    var w = _wrap(p, TagInteger)
    var b = Builder()
    _open(b, w)
    b.add_int64(v, w.tag_class, w.tag)
    _close(b, w)
    return b^.finish()


def marshal(v: BigInt) raises -> List[Byte]:
    """An INTEGER of any width. Go's `Marshal` for a `*big.Int`."""
    return marshal_with_params(v, "")


def marshal_with_params(v: BigInt, params: StringSlice) raises -> List[Byte]:
    """An INTEGER of any width, under `params`.

    Go's field is a pointer and an optional one is skipped when it is nil.
    This one is a value, so what is skipped is zero, which is the same test
    every other type here gets.
    """
    var p = _parse_params(params)
    if p.optional and not Bool(p.default_value) and v == BigInt():
        return List[Byte]()
    _check(p, TagInteger)

    var w = _wrap(p, TagInteger)
    var b = Builder()
    _open(b, w)
    b.add_big_int(v, w.tag_class, w.tag)
    _close(b, w)
    return b^.finish()


def marshal(v: StringSlice) raises -> List[Byte]:
    """A string, under whichever type holds it. Go's `Marshal` for a
    `string`."""
    return marshal_with_params(v, "")


def marshal_with_params(
    v: StringSlice, params: StringSlice
) raises -> List[Byte]:
    """A string, under `params`.

    `printable`, `utf8`, `ia5` and `numeric` each name a type and get it, and
    a string with no type named for it gets a PrintableString if the character
    set allows and a UTF8String if it does not.

    ```mojo
    from core.encoding.asn1 import marshal, marshal_with_params

    def main() raises:
        print(marshal("hello")[0])  # 19, a PrintableString
        print(marshal("héllo")[0])  # 12, a UTF8String
        print(marshal_with_params("hello", "ia5")[0])  # 22
    ```
    """
    var p = _parse_params(params)
    if p.optional and not Bool(p.default_value) and v.byte_length() == 0:
        return List[Byte]()
    _check(p, TagPrintableString)

    var tag = p.string_type if p.string_type != 0 else _string_tag(v)
    var w = _wrap(p, tag)
    var b = Builder()
    _open(b, w)
    _add_string(b, v, tag, w.tag_class, w.tag)
    _close(b, w)
    return b^.finish()


def marshal(v: Span[Byte, _]) raises -> List[Byte]:
    """An OCTET STRING. Go's `Marshal` for a `[]byte`."""
    return marshal_with_params(v, "")


def marshal_with_params(
    v: Span[Byte, _], params: StringSlice
) raises -> List[Byte]:
    """An OCTET STRING, under `params`.

    One of the two types `omitempty` applies to, since Go tests it on the
    length of a slice and a byte slice is one.
    """
    var p = _parse_params(params)
    if len(v) == 0 and p.omit_empty:
        return List[Byte]()
    if p.optional and not Bool(p.default_value) and len(v) == 0:
        return List[Byte]()
    _check(p, TagOctetString)

    var w = _wrap(p, TagOctetString)
    var b = Builder()
    _open(b, w)
    b.add_octet_string(v, w.tag_class, w.tag)
    _close(b, w)
    return b^.finish()


def marshal(v: ObjectIdentifier) raises -> List[Byte]:
    """An OBJECT IDENTIFIER. Go's `Marshal` for an `ObjectIdentifier`."""
    return marshal_with_params(v, "")


def marshal_with_params(
    v: ObjectIdentifier, params: StringSlice
) raises -> List[Byte]:
    """An OBJECT IDENTIFIER, under `params`.

    The other type `omitempty` applies to, since Go's is a slice of `int`.
    """
    var p = _parse_params(params)
    if len(v) == 0 and p.omit_empty:
        return List[Byte]()
    if p.optional and not Bool(p.default_value) and len(v) == 0:
        return List[Byte]()
    _check(p, TagOID)

    var w = _wrap(p, TagOID)
    var b = Builder()
    _open(b, w)
    b.add_object_identifier(v, w.tag_class, w.tag)
    _close(b, w)
    return b^.finish()


def marshal(v: BitString) raises -> List[Byte]:
    """A BIT STRING. Go's `Marshal` for a `BitString`."""
    return marshal_with_params(v, "")


def marshal_with_params(v: BitString, params: StringSlice) raises -> List[Byte]:
    """A BIT STRING, under `params`."""
    var p = _parse_params(params)
    if p.optional and not Bool(p.default_value) and v == BitString():
        return List[Byte]()
    _check(p, TagBitString)

    var w = _wrap(p, TagBitString)
    var b = Builder()
    _open(b, w)
    b.add_bit_string(v, w.tag_class, w.tag)
    _close(b, w)
    return b^.finish()


def marshal(v: Time) raises -> List[Byte]:
    """A time, under whichever of the two time types holds it. Go's `Marshal`
    for a `time.Time`."""
    return marshal_with_params(v, "")


def marshal_with_params(v: Time, params: StringSlice) raises -> List[Byte]:
    """A time, under `params`.

    `generalized` asks for a GeneralizedTime and gets one. `utc` asks for a
    UTCTime and gets one only if the year fits in two digits, since a UTCTime
    cannot say 2050 at all, and this is Go's order of tests rather than an
    error for a request that cannot be met.
    """
    var p = _parse_params(params)
    if p.optional and not Bool(p.default_value) and v.is_zero():
        return List[Byte]()
    _check(p, TagUTCTime)

    var tag = TagUTCTime
    if p.time_type == TagGeneralizedTime or _outside_utc_range(v):
        tag = TagGeneralizedTime

    var w = _wrap(p, tag)
    var b = Builder()
    _open(b, w)
    if tag == TagGeneralizedTime:
        b.add_generalized_time(v, w.tag_class, w.tag)
    else:
        b.add_utc_time(v, w.tag_class, w.tag)
    _close(b, w)
    return b^.finish()


def marshal(v: RawValue) raises -> List[Byte]:
    """A value that was read rather than built. Go's `Marshal` for a
    `RawValue`."""
    return marshal_with_params(v, "")


def marshal_with_params(v: RawValue, params: StringSlice) raises -> List[Byte]:
    """A value that was read rather than built, under `params`.

    Only `optional` is looked at. Go returns the encoding a `RawValue` holds
    before it reaches any of the tagging code, which is the point of the type:
    the bytes are what a signature was taken over, and a tag string cannot be
    allowed to change them.
    """
    var p = _parse_params(params)
    if p.optional and not Bool(p.default_value) and v == RawValue():
        return List[Byte]()

    var b = Builder()
    b.add_raw_value(v)
    return b^.finish()


# Unmarshalling. The header is read and checked in one place, and each type
# adds the parse of the contents and what an absent optional field leaves
# behind.


struct _Read[o: ImmOrigin](Movable):
    """A field, read as far as its contents. What `_read_field` hands back."""

    var matched: Bool
    """Whether the header was the one the field wanted. False only for an
    optional field that was not there."""

    var header: TagAndLength
    """The header the contents came under, after any explicit tag has been
    unwrapped."""

    var universal_tag: Int
    """Which type the contents are, after the wire tag and the tag string have
    both had their say. A string and a time are the two that move."""

    var offset: Int
    """How many bytes of the input the field took."""

    var inner: Span[Byte, Self.o]
    """The contents, without the header."""

    def __init__(
        out self,
        matched: Bool,
        header: TagAndLength,
        universal_tag: Int,
        offset: Int,
        inner: Span[Byte, Self.o],
    ):
        self.matched = matched
        self.header = header.copy()
        self.universal_tag = universal_tag
        self.offset = offset
        self.inner = inner


def _read_field[
    o: ImmOrigin
](
    bytes: Span[Byte, o],
    p: _Params,
    universal_tag: Int,
    is_compound: Bool,
    match_any: Bool,
) raises -> _Read[o]:
    """The header of the next field, checked against what `p` said it is.

    Go's `parseField` down to the point where it switches on the destination
    type. An optional field whose header does not match is not an error: the
    bytes belong to whatever comes after it, so nothing is consumed and the
    caller is told the field was not there.
    """
    var missed = _Read[o](
        False, TagAndLength(0, 0, 0, False), universal_tag, 0, bytes[0:0]
    )
    if len(bytes) == 0:
        if p.optional:
            return missed^
        raise _syntax("sequence truncated")

    var reader = Parser[o](bytes)
    var header = reader.read_header()

    if p.explicit:
        var expected = ClassContextSpecific
        if p.application:
            expected = ClassApplication
        if reader.at_end():
            raise _structural("explicit tag has no child")
        if (
            header.tag_class == expected
            and header.tag == p.tag.value()
            and (header.length == 0 or header.is_compound)
        ):
            if match_any:
                pass  # A RawValue keeps the wrapper, since it keeps everything.
            elif header.length > 0:
                header = reader.read_header()
            else:
                raise _structural(
                    "zero length explicit tag was not an asn1.Flag"
                )
        else:
            if p.optional:
                return missed^
            raise _structural("explicitly tagged member didn't match")

    # Every string type maps to `String` and both time types map to `Time`, so
    # the tag on the wire is what says which one arrived. Go does the same,
    # and falls back to the tag string when the class is not universal and so
    # the tag number says nothing about the type.
    var wanted = universal_tag
    if wanted == TagPrintableString:
        if header.tag_class == ClassUniversal:
            if (
                header.tag == TagIA5String
                or header.tag == TagGeneralString
                or header.tag == TagT61String
                or header.tag == TagUTF8String
                or header.tag == TagNumericString
                or header.tag == TagBMPString
            ):
                wanted = header.tag
        elif p.string_type != 0:
            wanted = p.string_type
    elif wanted == TagUTCTime:
        if header.tag_class == ClassUniversal:
            if header.tag == TagGeneralizedTime:
                wanted = header.tag
        elif p.time_type != 0:
            wanted = p.time_type
    if p.is_set:
        wanted = TagSet

    var match_class_and_tag = match_any
    var expected_class = ClassUniversal
    var expected_tag = wanted
    if not p.explicit and Bool(p.tag):
        match_class_and_tag = False
        expected_tag = p.tag.value()
        expected_class = ClassContextSpecific
        if p.application:
            expected_class = ClassApplication
        elif p.private:
            expected_class = ClassPrivate

    var wrong_tag = not match_class_and_tag and (
        header.tag_class != expected_class or header.tag != expected_tag
    )
    if wrong_tag or (not match_any and header.is_compound != is_compound):
        if p.optional:
            return missed^
        raise _structural(
            "tags don't match, wanted class "
            + String(expected_class)
            + " tag "
            + String(expected_tag)
            + ", got class "
            + String(header.tag_class)
            + " tag "
            + String(header.tag)
        )

    var inner = reader.read_contents(header.length)
    return _Read[o](True, header, wanted, reader.pos, inner)


def unmarshal[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: Bool) raises -> Span[Byte, o]:
    """A BOOLEAN into `v`, and back the bytes after it. Go's `Unmarshal`.

    ```mojo
    from core.encoding.asn1 import unmarshal

    def main() raises:
        var der: List[UInt8] = [UInt8(1), UInt8(1), UInt8(255)]
        var flag = False
        var rest = unmarshal(Span(der), flag)
        print(flag, len(rest))  # True 0
    ```
    """
    return unmarshal_with_params(bytes, v, "")


def unmarshal_with_params[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: Bool, params: StringSlice) raises -> Span[
    Byte, o
]:
    """A BOOLEAN into `v`, under `params`. Go's `UnmarshalWithParams`.

    An optional field that was not there leaves `v` as the zero value and
    gives back every byte it was passed, since the bytes are the next field's.
    Go's is a struct field that was zero already; this one is the caller's own
    variable, so it is set rather than left.
    """
    var p = _parse_params(params)
    var read = _read_field(bytes, p, TagBoolean, False, False)
    if not read.matched:
        v = False
        return bytes
    v = _parse_bool(read.inner)
    return bytes[read.offset : len(bytes)]


def unmarshal[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: Int64) raises -> Span[Byte, o]:
    """An INTEGER into `v`, and back the bytes after it."""
    return unmarshal_with_params(bytes, v, "")


def unmarshal_with_params[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: Int64, params: StringSlice) raises -> Span[
    Byte, o
]:
    """An INTEGER into `v`, under `params`.

    An absent optional field leaves the `default:` value in `v` when the tag
    string gave one, which is the whole of what a default is for.
    """
    var p = _parse_params(params)
    var read = _read_field(bytes, p, TagInteger, False, False)
    if not read.matched:
        v = p.default_value.value() if p.default_value else Int64(0)
        return bytes
    v = _parse_int64(read.inner)
    return bytes[read.offset : len(bytes)]


def unmarshal[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: BigInt) raises -> Span[Byte, o]:
    """An INTEGER of any width into `v`, and back the bytes after it."""
    return unmarshal_with_params(bytes, v, "")


def unmarshal_with_params[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: BigInt, params: StringSlice) raises -> Span[
    Byte, o
]:
    """An INTEGER of any width into `v`, under `params`."""
    var p = _parse_params(params)
    var read = _read_field(bytes, p, TagInteger, False, False)
    if not read.matched:
        v = BigInt()
        return bytes
    v = _parse_big_int(read.inner)
    return bytes[read.offset : len(bytes)]


def unmarshal[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: String) raises -> Span[Byte, o]:
    """A string into `v`, whichever string type it arrived as."""
    return unmarshal_with_params(bytes, v, "")


def unmarshal_with_params[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: String, params: StringSlice) raises -> Span[
    Byte, o
]:
    """A string into `v`, under `params`.

    The tag on the wire says which of the six string types arrived and the
    contents are read as that type, so a UTF8String is checked for valid
    UTF-8 and a PrintableString is checked against its character set. Under an
    implicit tag the wire says nothing, and then `printable`, `utf8`, `ia5` or
    `numeric` in the tag string is what says how to read it.
    """
    var p = _parse_params(params)
    var read = _read_field(bytes, p, TagPrintableString, False, False)
    if not read.matched:
        v = String()
        return bytes
    v = _parse_string(read.inner, read.universal_tag)
    return bytes[read.offset : len(bytes)]


def unmarshal[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: List[Byte]) raises -> Span[Byte, o]:
    """An OCTET STRING into `v`, and back the bytes after it."""
    return unmarshal_with_params(bytes, v, "")


def unmarshal_with_params[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: List[Byte], params: StringSlice) raises -> Span[
    Byte, o
]:
    """An OCTET STRING into `v`, under `params`.

    Go's field is a slice of the input and shares its bytes. This copies, as
    everything else in this package that hands back a `List` copies, so that
    what is read outlives what it was read from.
    """
    var p = _parse_params(params)
    var read = _read_field(bytes, p, TagOctetString, False, False)
    v.clear()
    if not read.matched:
        return bytes
    v.extend(read.inner)
    return bytes[read.offset : len(bytes)]


def unmarshal[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: ObjectIdentifier) raises -> Span[Byte, o]:
    """An OBJECT IDENTIFIER into `v`, and back the bytes after it."""
    return unmarshal_with_params(bytes, v, "")


def unmarshal_with_params[
    o: ImmOrigin
](
    bytes: Span[Byte, o], mut v: ObjectIdentifier, params: StringSlice
) raises -> Span[Byte, o]:
    """An OBJECT IDENTIFIER into `v`, under `params`."""
    var p = _parse_params(params)
    var read = _read_field(bytes, p, TagOID, False, False)
    if not read.matched:
        v = ObjectIdentifier(List[Int]())
        return bytes
    v = _parse_object_identifier(read.inner)
    return bytes[read.offset : len(bytes)]


def unmarshal[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: BitString) raises -> Span[Byte, o]:
    """A BIT STRING into `v`, and back the bytes after it."""
    return unmarshal_with_params(bytes, v, "")


def unmarshal_with_params[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: BitString, params: StringSlice) raises -> Span[
    Byte, o
]:
    """A BIT STRING into `v`, under `params`."""
    var p = _parse_params(params)
    var read = _read_field(bytes, p, TagBitString, False, False)
    if not read.matched:
        v = BitString()
        return bytes
    v = _parse_bit_string(read.inner)
    return bytes[read.offset : len(bytes)]


def unmarshal[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: Time) raises -> Span[Byte, o]:
    """A time into `v`, whichever of the two time types it arrived as."""
    return unmarshal_with_params(bytes, v, "")


def unmarshal_with_params[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: Time, params: StringSlice) raises -> Span[
    Byte, o
]:
    """A time into `v`, under `params`.

    A certificate's validity dates are UTCTime before 2050 and GeneralizedTime
    from then on, chosen by whoever wrote them, so the tag on the wire is what
    says which one this is.
    """
    var p = _parse_params(params)
    var read = _read_field(bytes, p, TagUTCTime, False, False)
    if not read.matched:
        v = Time()
        return bytes
    if read.universal_tag == TagUTCTime:
        v = _parse_utc_time(read.inner)
    else:
        v = _parse_generalized_time(read.inner)
    return bytes[read.offset : len(bytes)]


def unmarshal[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: RawValue) raises -> Span[Byte, o]:
    """The next value into `v` without decoding it, and back the bytes after
    it."""
    return unmarshal_with_params(bytes, v, "")


def unmarshal_with_params[
    o: ImmOrigin
](bytes: Span[Byte, o], mut v: RawValue, params: StringSlice) raises -> Span[
    Byte, o
]:
    """The next value into `v` without decoding it, under `params`.

    The one type that takes any class and any tag, since not decoding a value
    means having no opinion about what it is. An explicit tag is kept rather
    than unwrapped, for the same reason: the bytes are the answer.
    """
    var p = _parse_params(params)
    var read = _read_field(bytes, p, -1, False, True)
    if not read.matched:
        v = RawValue()
        return bytes

    var inner = List[Byte](capacity=len(read.inner))
    inner.extend(read.inner)
    var whole = bytes[0 : read.offset]
    var full = List[Byte](capacity=len(whole))
    full.extend(whole)
    v = RawValue(
        read.header.tag_class,
        read.header.tag,
        read.header.is_compound,
        inner^,
        full^,
    )
    return bytes[read.offset : len(bytes)]
