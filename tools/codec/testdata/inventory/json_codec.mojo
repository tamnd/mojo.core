"""JSON for Envelope, Item, Sparse, Summary and Vendor, generated from the structs themselves.

Written by `tools/codec` out of the fields and struct tags of the
`inventory` package. Do not edit it: change the struct or its tags and
run the generator again. It is checked in so that it can be read, reviewed and
built without running anything, and regenerating it has to produce this file
byte for byte.

Each struct has two entry points:

```mojo
var text = marshal_json(envelope)
var back: Envelope = unmarshal_json_envelope(text.as_bytes())
```

The encoder is overloaded on its argument, so every struct here has one called
`marshal_json`. The decoder is told apart from the others only by the type it
produces, which Mojo will not overload on, so its name carries the struct.

A key in the document that no field matches is skipped, the way Go skips one,
unless the decoder is given `True` for its second argument, which is Go's
`Decoder.DisallowUnknownFields`. A field that is not in the document is an
error, because Mojo has no zero value to leave it at. `Optional` is how a field
says it may be absent.

The scanner and the writers come from `core.encoding.json`, so what is below is
the codecs and nothing else, and every codec anywhere reads the same JSON that
package's own `parse` reads.
"""

from core.encoding.json import (
    RawMessage,
    ValueScanner,
    append_bool,
    append_float,
    append_raw,
    append_signed,
    append_string,
    append_unsigned,
    missing_key,
)

from .envelopes import Envelope
from .items import Item, Sparse
from .summaries import Summary
from .vendors import Vendor


# ----------------------------------------------------------------------------
# inventory.envelopes.Envelope
# ----------------------------------------------------------------------------


def marshal_json(value: Envelope) raises -> String:
    """`value` as a JSON object."""
    var out = List[Byte]()
    _encode_envelope(value, out)
    return String(from_utf8=Span(out))


def _encode_envelope(value: Envelope, mut out: List[Byte]) raises:
    """One object onto the end of `out`, for a field or for the whole value."""
    out.append(Byte(ord("{")))
    out.extend('"kind":'.as_bytes())
    append_string(out, value.kind)
    out.append(Byte(ord(",")))
    out.extend('"payload":'.as_bytes())
    append_raw(out, value.payload)
    if len(value.trailer) != 0:
        out.append(Byte(ord(",")))
        out.extend('"trailer":'.as_bytes())
        append_raw(out, value.trailer)
    out.append(Byte(ord("}")))


def unmarshal_json_envelope(
    out result: Envelope,
    data: Span[Byte, _],
    disallow_unknown: Bool = False,
) raises:
    """The whole of `data` as one `Envelope`.

    With `disallow_unknown` set, a key that no field matches is an error
    rather than something to step over, which is Go's
    `Decoder.DisallowUnknownFields`.
    """
    var sc = ValueScanner(data, disallow_unknown)
    result = _decode_envelope(sc)
    sc.end()


def _decode_envelope(out result: Envelope, mut sc: ValueScanner[_]) raises:
    """One object out of `sc`, wherever in the document it is."""
    var v_kind = Optional[String]()
    var v_payload = RawMessage()
    var v_trailer = RawMessage()
    sc.enter()
    sc.expect(Byte(ord("{")))
    if not sc.accept(Byte(ord("}"))):
        while True:
            var key = sc.read_key()
            sc.expect(Byte(ord(":")))
            sc.at_field("Envelope", key)
            if key == "kind":
                v_kind = sc.read_string()
            elif key == "payload":
                v_payload = sc.read_raw()
            elif key == "trailer":
                v_trailer = sc.read_raw()
            else:
                sc.unknown_key(key)
            if sc.accept(Byte(ord(","))):
                continue
            break
        sc.expect(Byte(ord("}")))
    sc.leave()
    if not v_kind:
        raise missing_key("Envelope", "kind")
    result = Envelope(v_kind.take(), v_payload^, v_trailer^)


# ----------------------------------------------------------------------------
# inventory.items.Item
# ----------------------------------------------------------------------------


def marshal_json(value: Item) raises -> String:
    """`value` as a JSON object."""
    var out = List[Byte]()
    _encode_item(value, out)
    return String(from_utf8=Span(out))


def _encode_item(value: Item, mut out: List[Byte]) raises:
    """One object onto the end of `out`, for a field or for the whole value."""
    out.append(Byte(ord("{")))
    out.extend('"name":'.as_bytes())
    append_string(out, value.name)
    out.append(Byte(ord(",")))
    out.extend('"id":'.as_bytes())
    append_signed(out, Int64(value.sku))
    out.append(Byte(ord(",")))
    out.extend('"weight":'.as_bytes())
    append_float(out, Float64(value.weight), 32)
    out.append(Byte(ord(",")))
    out.extend('"code":'.as_bytes())
    append_unsigned(out, UInt64(value.code))
    out.append(Byte(ord(",")))
    out.extend('"vendor":'.as_bytes())
    _encode_vendor(value.vendor, out)
    out.append(Byte(ord(",")))
    out.extend('"alternates":'.as_bytes())
    out.append(Byte(ord("[")))
    var first2 = True
    for item1 in value.alternates:
        if not first2:
            out.append(Byte(ord(",")))
        first2 = False
        _encode_vendor(item1, out)
    out.append(Byte(ord("]")))
    out.append(Byte(ord(",")))
    out.extend('"sizes":'.as_bytes())
    out.append(Byte(ord("{")))
    var keys3 = List[String]()
    for entry4 in value.sizes.items():
        keys3.append(entry4.key)
    sort(keys3)
    var first6 = True
    for key5 in keys3:
        if not first6:
            out.append(Byte(ord(",")))
        first6 = False
        append_string(out, key5)
        out.append(Byte(ord(":")))
        append_signed(out, Int64(value.sizes[key5]))
    out.append(Byte(ord("}")))
    if len(value.tags) != 0:
        out.append(Byte(ord(",")))
        out.extend('"tags":'.as_bytes())
        out.append(Byte(ord("[")))
        var first8 = True
        for item7 in value.tags:
            if not first8:
                out.append(Byte(ord(",")))
            first8 = False
            append_string(out, item7)
        out.append(Byte(ord("]")))
    if value.count:
        out.append(Byte(ord(",")))
        out.extend('"count":'.as_bytes())
        append_signed(out, Int64(value.count.value()))
    out.append(Byte(ord(",")))
    out.extend('"note":'.as_bytes())
    if value.note:
        append_string(out, value.note.value())
    else:
        out.extend("null".as_bytes())
    out.append(Byte(ord("}")))


def unmarshal_json_item(
    out result: Item,
    data: Span[Byte, _],
    disallow_unknown: Bool = False,
) raises:
    """The whole of `data` as one `Item`.

    With `disallow_unknown` set, a key that no field matches is an error
    rather than something to step over, which is Go's
    `Decoder.DisallowUnknownFields`.
    """
    var sc = ValueScanner(data, disallow_unknown)
    result = _decode_item(sc)
    sc.end()


def _decode_item(out result: Item, mut sc: ValueScanner[_]) raises:
    """One object out of `sc`, wherever in the document it is."""
    var v_name = Optional[String]()
    var v_sku = Optional[Int64]()
    var v_weight = Optional[Float32]()
    var v_code = Optional[UInt8]()
    var v_vendor = Optional[Vendor]()
    var v_alternates = List[Vendor]()
    var v_sizes = Dict[String, Int64]()
    var v_tags = List[String]()
    var v_count = Optional[Int]()
    var v_note = Optional[String]()
    sc.enter()
    sc.expect(Byte(ord("{")))
    if not sc.accept(Byte(ord("}"))):
        while True:
            var key = sc.read_key()
            sc.expect(Byte(ord(":")))
            sc.at_field("Item", key)
            if key == "name":
                v_name = sc.read_string()
            elif key == "id":
                v_sku = Int64(sc.read_signed(64))
            elif key == "weight":
                v_weight = Float32(sc.read_float(32))
            elif key == "code":
                v_code = UInt8(sc.read_unsigned(8))
            elif key == "vendor":
                v_vendor = _decode_vendor(sc)
            elif key == "alternates":
                var held1 = List[Vendor]()
                sc.enter()
                sc.expect(Byte(ord("[")))
                if not sc.accept(Byte(ord("]"))):
                    while True:
                        var item2 = _decode_vendor(sc)
                        held1.append(item2^)
                        if sc.accept(Byte(ord(","))):
                            continue
                        break
                    sc.expect(Byte(ord("]")))
                sc.leave()
                v_alternates = held1^
            elif key == "sizes":
                var held3 = Dict[String, Int64]()
                sc.enter()
                sc.expect(Byte(ord("{")))
                if not sc.accept(Byte(ord("}"))):
                    while True:
                        var key4 = sc.read_key()
                        sc.expect(Byte(ord(":")))
                        var held5 = Int64(sc.read_signed(64))
                        held3[key4^] = held5
                        if sc.accept(Byte(ord(","))):
                            continue
                        break
                    sc.expect(Byte(ord("}")))
                sc.leave()
                v_sizes = held3^
            elif key == "tags":
                var held6 = List[String]()
                sc.enter()
                sc.expect(Byte(ord("[")))
                if not sc.accept(Byte(ord("]"))):
                    while True:
                        var item7 = sc.read_string()
                        held6.append(item7^)
                        if sc.accept(Byte(ord(","))):
                            continue
                        break
                    sc.expect(Byte(ord("]")))
                sc.leave()
                v_tags = held6^
            elif key == "count":
                var held8 = Optional[Int]()
                if not sc.accept_null():
                    var held9 = Int(sc.read_signed(0))
                    held8 = held9
                v_count = held8^
            elif key == "note":
                var held10 = Optional[String]()
                if not sc.accept_null():
                    var held11 = sc.read_string()
                    held10 = held11^
                v_note = held10^
            else:
                sc.unknown_key(key)
            if sc.accept(Byte(ord(","))):
                continue
            break
        sc.expect(Byte(ord("}")))
    sc.leave()
    if not v_name:
        raise missing_key("Item", "name")
    if not v_sku:
        raise missing_key("Item", "id")
    if not v_weight:
        raise missing_key("Item", "weight")
    if not v_code:
        raise missing_key("Item", "code")
    if not v_vendor:
        raise missing_key("Item", "vendor")
    result = Item(
        v_name.take(),
        v_sku.take(),
        v_weight.take(),
        v_code.take(),
        v_vendor.take(),
        v_alternates^,
        v_sizes^,
        v_tags^,
        v_count^,
        v_note^,
    )


# ----------------------------------------------------------------------------
# inventory.items.Sparse
# ----------------------------------------------------------------------------


def marshal_json(value: Sparse) raises -> String:
    """`value` as a JSON object."""
    var out = List[Byte]()
    _encode_sparse(value, out)
    return String(from_utf8=Span(out))


def _encode_sparse(value: Sparse, mut out: List[Byte]) raises:
    """One object onto the end of `out`, for a field or for the whole value."""
    out.append(Byte(ord("{")))
    var wrote = False
    if value.first:
        out.extend('"first":'.as_bytes())
        append_signed(out, Int64(value.first.value()))
        wrote = True
    if len(value.rest) != 0:
        if wrote:
            out.append(Byte(ord(",")))
        out.extend('"rest":'.as_bytes())
        out.append(Byte(ord("[")))
        var first2 = True
        for item1 in value.rest:
            if not first2:
                out.append(Byte(ord(",")))
            first2 = False
            append_string(out, item1)
        out.append(Byte(ord("]")))
        wrote = True
    if wrote:
        out.append(Byte(ord(",")))
    out.extend('"last":'.as_bytes())
    append_string(out, value.last)
    out.append(Byte(ord("}")))


def unmarshal_json_sparse(
    out result: Sparse,
    data: Span[Byte, _],
    disallow_unknown: Bool = False,
) raises:
    """The whole of `data` as one `Sparse`.

    With `disallow_unknown` set, a key that no field matches is an error
    rather than something to step over, which is Go's
    `Decoder.DisallowUnknownFields`.
    """
    var sc = ValueScanner(data, disallow_unknown)
    result = _decode_sparse(sc)
    sc.end()


def _decode_sparse(out result: Sparse, mut sc: ValueScanner[_]) raises:
    """One object out of `sc`, wherever in the document it is."""
    var v_first = Optional[Int]()
    var v_rest = List[String]()
    var v_last = Optional[String]()
    sc.enter()
    sc.expect(Byte(ord("{")))
    if not sc.accept(Byte(ord("}"))):
        while True:
            var key = sc.read_key()
            sc.expect(Byte(ord(":")))
            sc.at_field("Sparse", key)
            if key == "first":
                var held1 = Optional[Int]()
                if not sc.accept_null():
                    var held2 = Int(sc.read_signed(0))
                    held1 = held2
                v_first = held1^
            elif key == "rest":
                var held3 = List[String]()
                sc.enter()
                sc.expect(Byte(ord("[")))
                if not sc.accept(Byte(ord("]"))):
                    while True:
                        var item4 = sc.read_string()
                        held3.append(item4^)
                        if sc.accept(Byte(ord(","))):
                            continue
                        break
                    sc.expect(Byte(ord("]")))
                sc.leave()
                v_rest = held3^
            elif key == "last":
                v_last = sc.read_string()
            else:
                sc.unknown_key(key)
            if sc.accept(Byte(ord(","))):
                continue
            break
        sc.expect(Byte(ord("}")))
    sc.leave()
    if not v_last:
        raise missing_key("Sparse", "last")
    result = Sparse(v_first^, v_rest^, v_last.take())


# ----------------------------------------------------------------------------
# inventory.summaries.Summary
# ----------------------------------------------------------------------------


def marshal_json(value: Summary) raises -> String:
    """`value` as a JSON object."""
    var out = List[Byte]()
    _encode_summary(value, out)
    return String(from_utf8=Span(out))


def _encode_summary(value: Summary, mut out: List[Byte]) raises:
    """One object onto the end of `out`, for a field or for the whole value."""
    out.append(Byte(ord("{")))
    out.extend('"label":'.as_bytes())
    append_string(out, value.label)
    out.append(Byte(ord(",")))
    out.extend('"takings":'.as_bytes())
    append_float(out, Float64(value.takings), 64)
    out.append(Byte(ord("}")))


# Summary has a field tagged `-`, which the document does not carry,
# so there is nothing to construct one from and it encodes only.


# ----------------------------------------------------------------------------
# inventory.vendors.Vendor
# ----------------------------------------------------------------------------


def marshal_json(value: Vendor) raises -> String:
    """`value` as a JSON object."""
    var out = List[Byte]()
    _encode_vendor(value, out)
    return String(from_utf8=Span(out))


def _encode_vendor(value: Vendor, mut out: List[Byte]) raises:
    """One object onto the end of `out`, for a field or for the whole value."""
    out.append(Byte(ord("{")))
    out.extend('"name":'.as_bytes())
    append_string(out, value.name)
    out.append(Byte(ord(",")))
    out.extend('"rating":'.as_bytes())
    append_float(out, Float64(value.rating), 64)
    out.append(Byte(ord(",")))
    out.extend('"active":'.as_bytes())
    append_bool(out, value.active)
    out.append(Byte(ord("}")))


def unmarshal_json_vendor(
    out result: Vendor,
    data: Span[Byte, _],
    disallow_unknown: Bool = False,
) raises:
    """The whole of `data` as one `Vendor`.

    With `disallow_unknown` set, a key that no field matches is an error
    rather than something to step over, which is Go's
    `Decoder.DisallowUnknownFields`.
    """
    var sc = ValueScanner(data, disallow_unknown)
    result = _decode_vendor(sc)
    sc.end()


def _decode_vendor(out result: Vendor, mut sc: ValueScanner[_]) raises:
    """One object out of `sc`, wherever in the document it is."""
    var v_name = Optional[String]()
    var v_rating = Optional[Float64]()
    var v_active = Optional[Bool]()
    sc.enter()
    sc.expect(Byte(ord("{")))
    if not sc.accept(Byte(ord("}"))):
        while True:
            var key = sc.read_key()
            sc.expect(Byte(ord(":")))
            sc.at_field("Vendor", key)
            if key == "name":
                v_name = sc.read_string()
            elif key == "rating":
                v_rating = Float64(sc.read_float(64))
            elif key == "active":
                v_active = sc.read_bool()
            else:
                sc.unknown_key(key)
            if sc.accept(Byte(ord(","))):
                continue
            break
        sc.expect(Byte(ord("}")))
    sc.leave()
    if not v_name:
        raise missing_key("Vendor", "name")
    if not v_rating:
        raise missing_key("Vendor", "rating")
    if not v_active:
        raise missing_key("Vendor", "active")
    result = Vendor(v_name.take(), v_rating.take(), v_active.take())
