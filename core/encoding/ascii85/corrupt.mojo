"""Where an ascii85 string stopped being ascii85. Go's `CorruptInputError`.

The third of these in this directory and the same shape as the base64 and
base32 pair, down to the wording of the message, because Go's three are the
same declaration three times. They stay three types and three codes for the
reason Go keeps three: a caller decoding ascii85 never wanted base64, and a
failure that names the wrong one names the wrong bug.
"""

from core.errors import Report, capture, matches
from core.errors.codes import ErrCorruptAscii85


struct CorruptInputError(Copyable, Movable, Writable):
    """The offset of the byte that stopped a decode. Go's `CorruptInputError`.

    Built from a raised error by `of`, not by hand.

    ```mojo
    from core.encoding.ascii85 import CorruptInputError, decode

    def main():
        var out = List[UInt8](length=8, fill=0)
        try:
            _ = decode(Span(out), "abc~".as_bytes(), True)
        except e:
            var bad = CorruptInputError.of(e)
            if bad:
                print(bad.value().offset)  # 3
    ```
    """

    var offset: Int64
    """Which byte of the input the decode refused, counting from zero."""

    def __init__(out self, offset: Int64):
        self.offset = offset

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as a `CorruptInputError`, or nothing if it came from elsewhere.

        Go's `err.(ascii85.CorruptInputError)`. Nothing comes back when the
        error was raised by something other than this package's decoder, which
        is the case a type assertion covers by failing.
        """
        if not matches(e, ErrCorruptAscii85):
            return None
        var found = capture(e).field("offset")
        if not found:
            return None
        try:
            return Self(Int64(Int(found.value())))
        except:
            return None

    def error(self) -> String:
        """Go's `Error` text, byte for byte.

        `illegal ascii85 data at input byte 3`.
        """
        return "illegal ascii85 data at input byte " + String(self.offset)

    def write_to[W: Writer](self, mut writer: W):
        """`error` as this library spells `String`."""
        writer.write(self.error())


def _corrupt(offset: Int) -> Error:
    """The raise every refusal in this package makes.

    No count goes on it, because Go's `Decode` returns zero for both of its
    counts when it refuses, so nothing was decoded as far as the caller is
    concerned even though the destination was written to on the way.
    """
    return (
        Report(CorruptInputError(Int64(offset)).error())
        .with_code(ErrCorruptAscii85)
        .with_field("offset", String(offset))
        .error()
    )
