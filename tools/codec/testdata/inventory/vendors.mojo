"""Who the stock came from."""


@fieldwise_init
struct Vendor(Copyable, Movable):
    """A supplier, and the struct another one is nested inside.

    `codec:"json"`
    """

    var name: String
    """What they trade as. `json:"name"`"""

    var rating: Float64
    """Out of five, with a fraction. `json:"rating"`"""

    var active: Bool
    """Whether they are still trading. `json:"active"`"""
