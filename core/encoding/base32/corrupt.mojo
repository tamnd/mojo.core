"""Where a base32 string stopped being base32. Go's `CorruptInputError`.

The same shape as the one in `core.encoding.base64`, down to the wording of the
message, because Go's two are the same declaration twice. They stay two types
and two codes for the reason Go keeps two: a caller decoding base32 never
wanted base64, and a failure that names the wrong one names the wrong bug.

Two numbers come out of a failed decode and they answer different questions.
The offset is where the input went wrong, which is what this carries. The count
is how many bytes were decoded before that happened, which `errors.partial`
carries, because Go's `Decode` returns it alongside the error and a raise would
otherwise drop it.
"""

from core.errors import Report, capture, matches
from core.errors.codes import ErrCorruptBase32


struct CorruptInputError(Copyable, Movable, Writable):
    """The offset of the byte that stopped a decode. Go's `CorruptInputError`.

    Built from a raised error by `of`, not by hand.

    ```mojo
    from core.encoding.base32 import CorruptInputError, std_encoding

    def main():
        try:
            _ = std_encoding().decode_string("A=")
        except e:
            var bad = CorruptInputError.of(e)
            if bad:
                print(bad.value().offset)  # 1
    ```
    """

    var offset: Int64
    """Which byte of the input the decode refused, counting from zero."""

    def __init__(out self, offset: Int64):
        self.offset = offset

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as a `CorruptInputError`, or nothing if it came from elsewhere.

        Go's `err.(base32.CorruptInputError)`. Nothing comes back when the
        error was raised by something other than this package's decoder, which
        is the case a type assertion covers by failing.
        """
        if not matches(e, ErrCorruptBase32):
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

        `illegal base32 data at input byte 1`.
        """
        return "illegal base32 data at input byte " + String(self.offset)

    def write_to[W: Writer](self, mut writer: W):
        """`error` as this library spells `String`."""
        writer.write(self.error())


def _corrupt(offset: Int, decoded: Int) -> Error:
    """The raise every refusal in this package makes.

    One function rather than a `Report` built at each site, because the code,
    the field name and the message all have to agree for `CorruptInputError.of`
    to find them, and three of those in eight places is three chances to
    disagree.
    """
    return (
        Report(CorruptInputError(Int64(offset)).error())
        .with_code(ErrCorruptBase32)
        .with_field("offset", String(offset))
        .with_count(decoded)
        .error()
    )
