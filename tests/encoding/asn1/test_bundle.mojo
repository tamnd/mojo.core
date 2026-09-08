"""Mozilla's root store, read and written again.

A hundred and twenty one real certificates, the set a browser trusts, taken
apart with `Parser` down to the last integer and put back together with
`Builder`, and the result compared with what came in byte for byte.

This is the test issue 35 names, and it is the one that matters. A table
written by hand tests what the person writing it thought of. A certificate
authority bundle was written by a hundred different programs over twenty five
years, and it holds the algorithm parameters that are a NULL name a modern
encoder would leave the field out, the two hundred and forty one booleans that
are all ones rather than one, and the two hundred and forty two integers that a
signature was computed over and that therefore have to come back with the same
leading byte they went in with. DER exists so that two programs looking at the
same object agree about its bytes, and until something round trips this bundle
there is no evidence that the pair here does.

The second half is the malformed corpus. Every certificate is damaged in the
ways a document is damaged in practice, one at a time, and each one has to be
refused with the message for that damage rather than a general complaint that
something is wrong. A parser of hostile input that says only that the input was
invalid is a parser nobody can debug the other end of.

The corpus is embedded by `tools/gen/cabundle.py`, because nothing in this
suite opens a file at run time.
"""

from std.testing import assert_equal, assert_true

from core.encoding.asn1 import (
    Builder,
    ClassUniversal,
    Parser,
    StructuralError,
    SyntaxError,
    TagAndLength,
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
from core.errors import matches
from core.errors.codes import ErrASN1Structural, ErrASN1Syntax
from core.io import Byte
from tests.generated.cabundle import root_certificates


def _no_reader(header: TagAndLength) -> Error:
    """What to raise for a value this test has no typed reader for.

    There is nothing in this bundle it fires on, which is checked. It is a
    raise rather than the obvious fallback of copying the bytes over, because
    a fallback would let a value the pair here cannot round trip pass through
    the test as bytes and take the whole claim with it. If a later bundle
    holds a VisibleString then this fails by name and somebody adds one.
    """
    return Error(
        "no reader for class "
        + String(header.tag_class)
        + " tag "
        + String(header.tag)
    )


def _one[o: ImmOrigin](mut p: Parser[o], mut out: Builder) raises:
    """One value, read as what it holds and written again from that.

    A compound value is opened, its contents are walked, and it is closed,
    which means the length `Builder` writes is one it worked out rather than
    one copied over. A primitive is decoded to the value it holds and encoded
    from that value, so an integer goes through `BigInt` and a time through
    `Time` and neither is a slice anybody moved.

    This recurses, which nothing in the package does. A test is allowed to: the
    depth here is what a certificate has, which is six or seven, and writing it
    with an explicit stack would only hide what it is doing.
    """
    var header = p.peek_header()
    if header.is_compound:
        _ = p.read_header()
        var body = p.read_contents(header.length)
        out.begin(header.tag_class, header.tag, True)
        var inner = Parser[o](body)
        while not inner.at_end():
            _one(inner, out)
        out.end()
        return
    if header.tag_class != ClassUniversal:
        raise _no_reader(header)
    var tag = header.tag
    if tag == TagBoolean:
        out.add_bool(p.read_bool())
    elif tag == TagInteger:
        out.add_big_int(p.read_big_int())
    elif tag == TagEnum:
        out.add_enumerated(p.read_enumerated())
    elif tag == TagBitString:
        out.add_bit_string(p.read_bit_string())
    elif tag == TagOctetString:
        var octets = p.read_octet_string()
        out.add_octet_string(Span(octets))
    elif tag == TagNull:
        p.read_null()
        out.add_null()
    elif tag == TagOID:
        out.add_object_identifier(p.read_object_identifier())
    elif tag == TagUTF8String:
        out.add_utf8_string(p.read_utf8_string())
    elif tag == TagPrintableString:
        out.add_printable_string(p.read_printable_string())
    elif tag == TagNumericString:
        out.add_numeric_string(p.read_numeric_string())
    elif tag == TagIA5String:
        out.add_ia5_string(p.read_ia5_string())
    elif tag == TagT61String:
        out.add_t61_string(p.read_t61_string())
    elif tag == TagBMPString:
        out.add_bmp_string(p.read_bmp_string())
    elif tag == TagUTCTime:
        out.add_utc_time(p.read_utc_time())
    elif tag == TagGeneralizedTime:
        out.add_generalized_time(p.read_generalized_time())
    else:
        raise _no_reader(header)


def _round_trip(der: List[Byte]) raises -> List[Byte]:
    """One whole certificate read to its values and written back from them."""
    var p = Parser(Span(der))
    var out = Builder()
    _one(p, out)
    p.end()
    return out^.finish()


def _same(got: List[Byte], want: List[Byte], name: String) raises:
    """Two byte lists, byte for byte, naming the first place they differ."""
    if len(got) != len(want):
        raise Error(
            name
            + ": wrote "
            + String(len(got))
            + " bytes, read "
            + String(len(want))
        )
    for i in range(len(got)):
        if got[i] != want[i]:
            raise Error(
                name
                + ": byte "
                + String(i)
                + " is "
                + String(Int(got[i]))
                + ", was "
                + String(Int(want[i]))
            )


def test_every_root_certificate_round_trips() raises:
    """The whole bundle, out and back, byte for byte.

    Nothing here is copied through. Every integer goes through `BigInt`, every
    object identifier through `ObjectIdentifier`, every time through `Time`,
    and every length is one `Builder` worked out after its contents had been
    written. So this says the readers and the writers are inverse over a
    hundred and twenty nine thousand bytes of documents neither of them was
    written against.
    """
    var bundle = root_certificates()
    assert_equal(len(bundle), 121)
    for i in range(len(bundle)):
        var again = _round_trip(bundle[i].der)
        _same(again, bundle[i].der, bundle[i].name)


struct _Tally(Copyable, Movable):
    """What a walk of the bundle found, by kind."""

    var sequences: Int
    var sets: Int
    var tagged: Int
    var booleans: Int
    var integers: Int
    var bit_strings: Int
    var octet_strings: Int
    var nulls: Int
    var oids: Int
    var strings: Int
    var times: Int

    def __init__(out self):
        self.sequences = 0
        self.sets = 0
        self.tagged = 0
        self.booleans = 0
        self.integers = 0
        self.bit_strings = 0
        self.octet_strings = 0
        self.nulls = 0
        self.oids = 0
        self.strings = 0
        self.times = 0


def _tally[o: ImmOrigin](mut p: Parser[o], mut found: _Tally) raises:
    """One value added to the tallies it belongs to, and everything inside it.
    """
    var header = p.peek_header()
    _ = p.read_header()
    var body = p.read_contents(header.length)
    if header.is_compound:
        if header.tag_class != ClassUniversal:
            found.tagged += 1
        elif header.tag == TagSequence:
            found.sequences += 1
        elif header.tag == TagSet:
            found.sets += 1
        var inner = Parser[o](body)
        while not inner.at_end():
            _tally(inner, found)
        return
    if header.tag_class != ClassUniversal:
        return
    if header.tag == TagBoolean:
        found.booleans += 1
    elif header.tag == TagInteger:
        found.integers += 1
    elif header.tag == TagBitString:
        found.bit_strings += 1
    elif header.tag == TagOctetString:
        found.octet_strings += 1
    elif header.tag == TagNull:
        found.nulls += 1
    elif header.tag == TagOID:
        found.oids += 1
    elif header.tag == TagUTCTime or header.tag == TagGeneralizedTime:
        found.times += 1
    elif (
        header.tag == TagUTF8String
        or header.tag == TagPrintableString
        or header.tag == TagIA5String
    ):
        found.strings += 1


def test_the_bundle_holds_what_a_certificate_is_made_of() raises:
    """An inventory, so that a round trip of nothing cannot pass as one.

    A walk that refused to descend and copied each certificate over whole
    would satisfy the test above and prove nothing at all, so this counts what
    is in there by kind and pins the totals.

    The numbers are worth reading. Two hundred and forty two integers across a
    hundred and twenty one certificates is exactly two each, the serial number
    and the RSA modulus or the curve order, and every one of them is signed
    over. Two hundred and forty nulls is the algorithm parameters of the two
    signature fields of the hundred and twenty RSA certificates, which is the
    field a modern encoder would leave out and DER says has to be there if the
    algorithm says so. Eight hundred and fifty two sets are the relative
    distinguished names, each of which is a SET OF that has to have been
    sorted, and this is the only test in the tree that reads real ones.
    """
    var found = _Tally()
    var bundle = root_certificates()
    for i in range(len(bundle)):
        var p = Parser(Span(bundle[i].der))
        _tally(p, found)
        p.end()
    assert_equal(found.sequences, 2473)
    assert_equal(found.sets, 852)
    assert_equal(found.tagged, 242)
    assert_equal(found.booleans, 241)
    assert_equal(found.integers, 242)
    assert_equal(found.bit_strings, 242)
    assert_equal(found.octet_strings, 411)
    assert_equal(found.nulls, 240)
    assert_equal(found.oids, 1667)
    assert_equal(found.strings, 852)
    assert_equal(found.times, 242)


def _refused(der: List[Byte]) raises -> String:
    """The message a damaged document was refused with, or an empty string.

    The whole document is walked rather than only its outer header, because a
    damaged byte in the middle of a certificate is refused by whatever reaches
    it and this has to be the same test for all of them.
    """
    try:
        _ = _round_trip(der)
        return String("")
    except e:
        var syntax = SyntaxError.of(e)
        if Bool(syntax):
            assert_true(matches(e, ErrASN1Syntax))
            return syntax.value().msg
        var structure = StructuralError.of(e)
        if Bool(structure):
            assert_true(matches(e, ErrASN1Structural))
            return structure.value().msg
        return String(e)


def _check(der: List[Byte], want: String, name: String) raises:
    """One damaged document, refused with the message that names the damage."""
    var said = _refused(der)
    if said != want:
        raise Error(name + ": refused with " + said + ", wanted " + want)


def _shortened(der: List[Byte], by: Int) -> List[Byte]:
    """`der` with its last `by` bytes taken off."""
    var out = List[Byte](capacity=len(der) - by)
    out.extend(Span(der)[0 : len(der) - by])
    return out^


def test_a_certificate_that_stops_early_is_refused() raises:
    """Truncation, which is what a connection that dropped looks like.

    Every certificate in the bundle, cut off at a quarter, a half and three
    quarters of its length, and one byte short of all of it. The message says
    the data was truncated in every case, which is the one thing a caller can
    act on: what arrived is a prefix, so wait for the rest or give up, rather
    than anything about what the document meant.
    """
    var bundle = root_certificates()
    for i in range(len(bundle)):
        var whole = bundle[i].der.copy()
        var cuts: List[Int] = [
            len(whole) // 4,
            len(whole) // 2,
            len(whole) - len(whole) // 4,
            1,
        ]
        for j in range(len(cuts)):
            _check(_shortened(whole, cuts[j]), "data truncated", bundle[i].name)


def test_a_certificate_with_something_after_it_is_refused() raises:
    """A byte on the end, which is what a framing bug looks like.

    Go reports trailing data through a second return value that callers
    routinely drop. Here the whole document is the unit and `end` raises, so a
    certificate followed by anything at all is not a certificate.
    """
    var bundle = root_certificates()
    for i in range(len(bundle)):
        var damaged = bundle[i].der.copy()
        damaged.append(Byte(0x00))
        _check(damaged, "trailing data", bundle[i].name)


def test_a_certificate_relabelled_as_a_set_is_refused() raises:
    """The outer SEQUENCE called a SET, which Go reads without complaint.

    Go maps the two onto each other while it parses, so a document with them
    the wrong way round is accepted there. A SET says order carries no meaning
    and a SEQUENCE says it does, and a certificate is signed over its bytes in
    the order they are in, so the two are not interchangeable here.
    """
    var bundle = root_certificates()
    for i in range(len(bundle)):
        var damaged = bundle[i].der.copy()
        damaged[0] = Byte(0x31)
        var p = Parser(Span(damaged))
        try:
            _ = p.read_sequence()
            raise Error(bundle[i].name + ": a set was read as a sequence")
        except e:
            assert_true(matches(e, ErrASN1Structural))


def test_a_length_written_longer_than_it_needs_is_refused() raises:
    """A leading zero in the length, which is BER and is not DER.

    Every certificate here is longer than 255 bytes, so its outer length is
    already in the long form with two bytes after the count. Giving it three,
    with a zero at the front, encodes the same number and is a second encoding
    of the same document, which is exactly what DER exists to rule out.
    """
    var bundle = root_certificates()
    for i in range(len(bundle)):
        var whole = bundle[i].der.copy()
        assert_equal(Int(whole[1]), 0x82)
        var damaged = List[Byte](capacity=len(whole) + 1)
        damaged.append(whole[0])
        damaged.append(Byte(0x83))
        damaged.append(Byte(0x00))
        damaged.extend(Span(whole)[2 : len(whole)])
        _check(damaged, "superfluous leading zeros in length", bundle[i].name)


def test_a_certificate_with_no_length_at_all_is_refused() raises:
    """The indefinite form, which BER allows and DER does not.

    A length byte of 0x80 says the value ends at a pair of zero bytes
    somewhere later, which makes the end of a value something a reader
    discovers rather than something it is told. DER forbids it, so this refuses
    it at the header rather than looking for the pair.
    """
    var bundle = root_certificates()
    for i in range(len(bundle)):
        var whole = bundle[i].der.copy()
        var damaged = List[Byte](capacity=len(whole) + 1)
        damaged.append(whole[0])
        damaged.append(Byte(0x80))
        damaged.extend(Span(whole)[4 : len(whole)])
        damaged.append(Byte(0x00))
        damaged.append(Byte(0x00))
        _check(damaged, "indefinite length found (not DER)", bundle[i].name)


def test_a_tag_written_longer_than_it_needs_is_refused() raises:
    """The high tag form for a tag that fits in five bits.

    A tag under thirty one has one encoding and it is the low form. Writing
    the outer SEQUENCE as `0x3f 0x10` says the same thing in two bytes, which
    is a second encoding of the same document again.
    """
    var bundle = root_certificates()
    for i in range(len(bundle)):
        var whole = bundle[i].der.copy()
        var damaged = List[Byte](capacity=len(whole) + 1)
        damaged.append(Byte(0x3F))
        damaged.append(Byte(0x10))
        damaged.extend(Span(whole)[1 : len(whole)])
        _check(damaged, "non-minimal tag", bundle[i].name)
