"""A program that uses a generated codec, built and run by the selftest.

This is the only evidence that any of the generator works. Everything else
checks that the right text came out; this checks that the text compiles, that
what it writes is the JSON it should be down to the byte, and that what it
reads back is what went in.

It lives outside the `inventory` package, the way somebody's own program would,
and it is copied out of this repository along with the package before it is
built, so that nothing here can quietly depend on being inside the library.
"""

from inventory.items import Item, Sparse
from inventory.json_codec import (
    marshal_json,
    unmarshal_json_item,
    unmarshal_json_sparse,
    unmarshal_json_vendor,
)
from inventory.summaries import Summary
from inventory.vendors import Vendor

comptime FULL = (
    '{"name":"bolt","id":7,"weight":0.25,"code":3,'
    + '"vendor":{"name":"acme","rating":4.5,"active":true},'
    + '"alternates":[{"name":"other","rating":3,"active":false}],'
    + '"sizes":{"large":2,"small":10},"tags":["metal"],"count":12,"note":"ok"}'
)
"""One item with every field carrying something."""

comptime EMPTY = (
    '{"name":"nail","id":8,"weight":0,"code":0,'
    + '"vendor":{"name":"acme","rating":4.5,"active":true},'
    + '"alternates":[],"sizes":{},"note":null}'
)
"""The same struct with everything that can be empty being empty."""


struct Checks(Movable):
    """A running count, and a raise on the first thing that is not right."""

    var ran: Int

    def __init__(out self):
        self.ran = 0

    def equal(mut self, what: String, got: String, want: String) raises:
        self.ran += 1
        if got != want:
            raise Error(what + ": got " + got + ", wanted " + want)

    def equal(mut self, what: String, got: Int, want: Int) raises:
        self.equal(what, String(got), String(want))

    def equal(mut self, what: String, got: Bool, want: Bool) raises:
        self.equal(what, String(got), String(want))

    def equal(mut self, what: String, got: Float64, want: Float64) raises:
        self.equal(what, String(got), String(want))


def vendor() -> Vendor:
    """The supplier both items are from."""
    return Vendor("acme", 4.5, True)


def full() -> Item:
    """The item `FULL` is the JSON of."""
    var sizes = Dict[String, Int64]()
    sizes["small"] = 10
    sizes["large"] = 2
    var alternates = List[Vendor]()
    alternates.append(Vendor("other", 3.0, False))
    var tags = List[String]()
    tags.append("metal")
    return Item(
        "bolt", 7, 0.25, 3, vendor(), alternates^, sizes^, tags^, Optional[Int](12), "ok"
    )


def empty() -> Item:
    """The item `EMPTY` is the JSON of."""
    return Item(
        "nail",
        8,
        0.0,
        0,
        vendor(),
        List[Vendor](),
        Dict[String, Int64](),
        List[String](),
        None,
        None,
    )


def encoding(mut c: Checks) raises:
    """What comes out."""
    c.equal("a full item", marshal_json(full()), FULL)
    c.equal("an empty one", marshal_json(empty()), EMPTY)

    # `omitempty` on the fields in front of the only one that is always
    # written, which is where the commas have to be worked out as it goes.
    c.equal("a sparse struct with nothing in it", marshal_json(Sparse(None, [], "z")),
            '{"last":"z"}')
    c.equal("with the first field", marshal_json(Sparse(Optional[Int](1), [], "z")),
            '{"first":1,"last":"z"}')
    c.equal("with the second", marshal_json(Sparse(None, ["a"], "z")),
            '{"rest":["a"],"last":"z"}')
    c.equal("with both", marshal_json(Sparse(Optional[Int](1), ["a"], "z")),
            '{"first":1,"rest":["a"],"last":"z"}')

    # A field tagged `-` is not in the document, which is what makes this
    # struct one that encodes and does not decode.
    c.equal("a summary", marshal_json(Summary("day", 12.5, 0.4)),
            '{"label":"day","takings":12.5}')

    # Go's escaping, which is more than JSON asks for. The three HTML
    # characters go out as escapes and so do the two JavaScript line
    # terminators, and what is already UTF-8 is left alone.
    var awkward = Summary('a"b<c>&d' + chr(10) + chr(9) + "é😀" + chr(0x2028), 0.0, 0.0)
    c.equal(
        "an awkward label",
        marshal_json(awkward),
        '{"label":"a\\"b\\u003cc\\u003e\\u0026d\\n\\té😀\\u2028","takings":0}',
    )

    # A number with no fraction is written without one, and the exponent form
    # is only used where the plain one stops being readable. Both are Go's
    # rules rather than the shortest text that reads back.
    c.equal("a whole float", marshal_json(Summary("n", 3.0, 0.0)),
            '{"label":"n","takings":3}')
    c.equal("a large one", marshal_json(Summary("n", 1e21, 0.0)),
            '{"label":"n","takings":1e+21}')
    c.equal("a small one", marshal_json(Summary("n", 1e-7, 0.0)),
            '{"label":"n","takings":1e-7}')


def decoding(mut c: Checks) raises:
    """What goes back in."""
    var back: Item = unmarshal_json_item(FULL.as_bytes())
    c.equal("the name", back.name, "bolt")
    c.equal("the renamed field", Int(back.sku), 7)
    c.equal("the narrow one", Int(back.code), 3)
    c.equal("the untagged one", Float64(back.weight), 0.25)
    c.equal("the nested struct", back.vendor.name, "acme")
    c.equal("its float", back.vendor.rating, 4.5)
    c.equal("its bool", back.vendor.active, True)
    c.equal("a list of structs", back.alternates[0].name, "other")
    c.equal("a dictionary", Int(back.sizes["small"]), 10)
    c.equal("a list", back.tags[0], "metal")
    c.equal("an optional that is there", back.count.value(), 12)
    c.equal("another", back.note.value(), "ok")
    c.equal("and the whole thing again", marshal_json(back), FULL)

    var bare: Item = unmarshal_json_item(EMPTY.as_bytes())
    c.equal("a missing list", len(bare.tags), 0)
    c.equal("a missing dictionary", len(bare.sizes), 0)
    c.equal("an optional that is not there", bare.count.__bool__(), False)
    c.equal("an explicit null", bare.note.__bool__(), False)
    c.equal("and that whole thing again", marshal_json(bare), EMPTY)

    # A key nothing matches is stepped over, whatever is in it, which is how a
    # document written by a newer program still reads.
    var extra: Vendor = unmarshal_json_vendor(
        '{"name":"acme","later":{"a":[1,2,{"b":null}]},"rating":4.5,"active":true}'.as_bytes()
    )
    c.equal("an unknown key", extra.name, "acme")

    # A key the document repeats is read as the last one, which is Go's answer
    # and the only one that does not depend on how the decoder is written.
    var twice: Vendor = unmarshal_json_vendor(
        '{"name":"acme","rating":1,"active":true,"rating":4.5}'.as_bytes()
    )
    c.equal("a repeated key", twice.rating, 4.5)

    # Whitespace anywhere it is allowed, and nowhere it is not.
    var spaced: Sparse = unmarshal_json_sparse(
        ' { "rest" : [ "a" , "b" ] , "last" : "z" } '.as_bytes()
    )
    c.equal("whitespace", spaced.rest[1], "b")

    # The escapes, including a pair of them that is one character and a lone
    # half of a pair, which is Go's replacement character rather than a refusal.
    var escaped: Vendor = unmarshal_json_vendor(
        '{"name":"\\u00e9\\ud83d\\ude00\\ud800\\/\\n","rating":0,"active":false}'.as_bytes()
    )
    c.equal("the escapes", escaped.name, "é😀" + chr(0xFFFD) + "/" + chr(10))


def refusing(mut c: Checks) raises:
    """What the decoder will not read."""

    def fails(document: String) -> Bool:
        try:
            var read: Item = unmarshal_json_item(document.as_bytes())
            return read.name == ""
        except:
            return True

    var whole = String(FULL)
    c.equal("a document with no name in it", fails('{"id":1}'), True)
    c.equal("a number that does not fit", fails(whole.replace('"code":3', '"code":300')), True)
    c.equal("a fraction in a whole field", fails(whole.replace('"id":7', '"id":7.5')), True)
    c.equal("a string where a number goes", fails(whole.replace('"id":7', '"id":"7"')), True)
    c.equal("a leading zero", fails(whole.replace('"id":7', '"id":07')), True)
    c.equal("something after the value", fails(whole + " {}"), True)
    c.equal("nothing at all", fails(""), True)
    c.equal("an unclosed object", fails(String(whole[byte=0 : whole.byte_length() - 1])), True)
    c.equal("and the document itself", fails(whole), False)


def main() raises:
    var c = Checks()
    encoding(c)
    decoding(c)
    refusing(c)
    print("the generated codec passed", c.ran, "checks")
