"""One line of stock, and a struct that is optional all the way through."""

from .vendors import Vendor


@fieldwise_init
struct Item(Copyable, Movable):
    """Something on a shelf.

    Every kind of field the generator handles is here once, which is what makes
    the generated file worth reading: whatever a codec looks like, it looks
    like this.

    `codec:"json"`
    """

    var name: String
    """What it is called. `json:"name"`"""

    var sku: Int64
    """The stock number, which is `id` on the wire and `sku` here. A rename is
    the ordinary reason to write a tag at all. `json:"id"`"""

    var weight: Float32
    """How heavy one is, in kilograms.

    No tag, so the key is the name of the field, which is Go's rule and is why
    most fields of most structs need no tag.
    """

    var code: UInt8
    """A shelf code, unsigned and narrow, so the decoder has to check that what
    the document holds fits. `json:"code"`"""

    var vendor: Vendor
    """Who supplies it, which makes this the nested case. `json:"vendor"`"""

    var alternates: List[Vendor]
    """Who else does, which makes this a list of the nested case.
    `json:"alternates"`"""

    var sizes: Dict[String, Int64]
    """How many of each size are in stock. `json:"sizes"`"""

    var tags: List[String]
    """Whatever anybody has labelled it with. `json:"tags,omitempty"`"""

    var count: Optional[Int]
    """How many there are, when anybody has counted.

    `Optional` rather than a count of nought, because a shelf nobody has
    counted is not a shelf with nothing on it, and this is the field that says
    so on the wire: absent, rather than zero. `json:"count,omitempty"`
    """

    var note: Optional[String]
    """Anything somebody wrote down.

    Optional and not `omitempty`, so it goes out as `null` when there is none
    rather than being left out. Both spellings read back as nothing, and which
    one to write is about the reader on the other end. `json:"note"`
    """


@fieldwise_init
struct Sparse(Copyable, Movable):
    """A struct whose first fields may all be missing.

    Whether a field needs a comma in front of it is worked out while the codec
    is generated rather than while it runs, and this is the struct that cannot
    be worked out: nothing before `last` is certainly written, so the comma in
    front of it is the one decision left until run time.

    `codec:"json"`
    """

    var first: Optional[Int]
    """`json:"first,omitempty"`"""

    var rest: List[String]
    """`json:"rest,omitempty"`"""

    var last: String
    """The one field that is always written. `json:"last"`"""
