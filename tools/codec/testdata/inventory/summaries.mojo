"""A struct that goes out and does not come back."""


@fieldwise_init
struct Summary(Copyable, Movable):
    """A line for a report, with a field the report does not carry.

    A field tagged `-` is not in the document, so there is nothing to build one
    of these out of and the generator writes an encoder and no decoder. That is
    a real thing to want rather than a hole: a summary written into a log has
    no reader on the other end.

    `codec:"json"`
    """

    var label: String
    """What the line says. `json:"label"`"""

    var takings: Float64
    """What it came to. `json:"takings"`"""

    var margin: Float64
    """What the shop made on it, which is nobody else's business.
    `json:"-"`"""
