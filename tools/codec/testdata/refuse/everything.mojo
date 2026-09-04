"""Eleven ways to not get a codec, one struct each."""

from core.strings import Builder


@fieldwise_init
struct Generic[T: Copyable & Deinitable](Copyable, Movable):
    """A codec is written for one type and this is a family of them.

    `codec:"json"`
    """

    var value: String
    """`json:"value"`"""


@fieldwise_init
struct Hidden(Copyable, Movable):
    """A struct with a field `mojo doc` does not report.

    `codec:"json"`
    """

    var name: String
    """`json:"name"`"""

    var _secret: Int
    """Private, and so invisible to the reader. A decoder written from what is
    visible would construct a value that is missing a field."""


struct Bare(Copyable, Movable):
    """A struct with no `@fieldwise_init`, and so no way to construct one.

    `codec:"json"`
    """

    var name: String
    """`json:"name"`"""


@fieldwise_init
struct Funcy(Copyable, Movable):
    """A struct holding something that is not data.

    `codec:"json"`
    """

    var run: def (Int) thin -> None
    """A function, which no wire format has a shape for. `json:"run"`"""


@fieldwise_init
struct Typo(Copyable, Movable):
    """A struct whose tag is a near miss.

    `codec:"json"`
    """

    var name: String
    """The space after the colon means this is not a tag at all, so Go would
    encode the field under its own name and never say anything.
    `json: "name"`"""


@fieldwise_init
struct Option(Copyable, Movable):
    """A struct asking for an option nobody implements.

    `codec:"json"`
    """

    var count: Int
    """Go ignores an option it does not know, which is how `omitEmpty` gets
    into a struct and stays there. `json:"count,omitEmpty"`"""


@fieldwise_init
struct Clash(Copyable, Movable):
    """Two fields, one name.

    `codec:"json"`
    """

    var first: String
    """Go writes both keys and reads whichever comes last. `json:"a"`"""

    var second: String
    """`json:"a"`"""


@fieldwise_init
struct Wrong(Copyable, Movable):
    """`omitempty` on a field that has no empty.

    `codec:"json"`
    """

    var count: Int
    """Left out when it is nought, and then there is nothing to read back into
    it. `json:"count,omitempty"`"""


@fieldwise_init
struct Foreign(Movable):
    """A struct holding one from another package.

    `codec:"json"`
    """

    var into: Builder
    """A codec for this would have to be generated where `Builder` is declared.
    `json:"into"`"""


@fieldwise_init
struct Ignored(Copyable, Movable):
    """A struct that never asked for a codec, and so has not got one."""

    var name: String
    """`json:"name"`"""


@fieldwise_init
struct Holder(Copyable, Movable):
    """A struct holding one that did not opt in.

    `codec:"json"`
    """

    var what: Ignored
    """`json:"what"`"""


@fieldwise_init
struct Chained(Copyable, Movable):
    """A struct holding one that was refused, which refuses this one too.

    `codec:"json"`
    """

    var inner: Hidden
    """`json:"inner"`"""
