"""A struct whose fields come from three different places, and one field that
`mojo doc` will not report."""

from core.math.big import Int as BigInt
from core.strings import Builder

from .shapes import Point


def forget(n: Int) -> None:
    """A drop that does nothing, so that `Record` has one to hold."""
    pass


struct Record(Movable):
    """One row of something, with a field the JSON cannot see."""

    var name: String
    """What the row is called. `json:"name" xml:"Name"`"""

    var spot: Point
    """Where the row is, using a struct from another module of this package.
    `json:"spot"`"""

    var into: Builder
    """Where the row writes itself, using a struct from another package
    entirely. Nothing in the JSON says where `Builder` came from, so the
    reader has to have read the import line above. `json:"-"`"""

    var total: BigInt
    """A number that will not fit in a machine word.

    This one is written `BigInt` and `mojo doc` prints it as `Int`, because
    what it prints is the declared name rather than the local one. That is the
    same string as the prelude's own integer, so the JSON on its own cannot
    tell the two apart and the line at the top of this file is what settles it.
    Both readings are checked: from the source it is the big integer, and from
    the JSON alone it is reported as a collision rather than picked.
    `json:"total"`
    """

    var drop: def(Int) thin -> None
    """Something to call when the row goes away.

    A function is not a type a codec can be written for, and it is not a name
    that failed to resolve either, so the reader gives it a kind of its own
    rather than calling it unknown. `json:"-"`
    """

    var _seed: Int
    """A private field, which is absent from the JSON entirely. A decoder
    generated without knowing about it would construct a `Record` that is
    missing a field, so the reader reports the struct as incomplete."""

    def __init__(out self, var name: String):
        """A row with a name and nothing else."""
        self.name = name^
        self.spot = Point(0, 0)
        self.into = Builder()
        self.total = BigInt()
        self.drop = forget
        self._seed = 0
