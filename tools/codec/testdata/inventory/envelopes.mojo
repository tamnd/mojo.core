"""A message whose shape is decided by something inside it."""

from core.encoding.json import RawMessage


@fieldwise_init
struct Envelope(Copyable, Movable):
    """Something addressed, and a payload nobody has read yet.

    What the payload is depends on the kind, which is not known until the kind
    has been read, so the payload is kept as its bytes and read a second time
    once there is something to read it into.

    `codec:"json"`
    """

    var kind: String
    """Which decoder the payload is for. `json:"kind"`"""

    var payload: RawMessage
    """The message itself, still as it was written. `json:"payload"`"""

    var trailer: RawMessage
    """A second one, left out when there is nothing in it.
    `json:"trailer,omitempty"`"""
