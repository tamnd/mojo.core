"""Where a base64 string stopped being base64. Go's `CorruptInputError`.

Go declares `type CorruptInputError int64`, so the offset of the offending byte
is the error value itself and a caller reads it with a type assertion. There is
nothing to assert against here, design.md section 8, so the offset goes on the
error record as a field and this reads it back.

Two numbers come out of a failed decode and they answer different questions.
The offset is where the input went wrong, which is what this carries. The count
is how many bytes were decoded before that happened, which `errors.partial`
carries, because Go's `Decode` returns it alongside the error and a raise would
otherwise drop it. A caller who wants the good prefix of a bad document reads
the count; a caller who wants to point at the damage reads the offset.
"""

from core.errors import Report, capture, matches
from core.errors.codes import ErrCorruptBase64


struct CorruptInputError(Copyable, Movable, Writable):
    """The offset of the byte that stopped a decode. Go's `CorruptInputError`.

    Built from a raised error by `of`, not by hand.

    ```mojo
    from core.encoding.base64 import CorruptInputError, std_encoding

    def main():
        try:
            _ = std_encoding().decode_string("A=AA")
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

        Go's `err.(base64.CorruptInputError)`. Nothing comes back when the
        error was raised by something other than this package's decoder, which
        is the case a type assertion covers by failing.
        """
        if not matches(e, ErrCorruptBase64):
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

        `illegal base64 data at input byte 1`.
        """
        return "illegal base64 data at input byte " + String(self.offset)

    def write_to[W: Writer](self, mut writer: W):
        """`error` as this library spells `String`."""
        writer.write(self.error())


def _corrupt(offset: Int, decoded: Int) -> Error:
    """The raise every refusal in this package makes.

    One function rather than a `Report` built at each site, because the code,
    the field name and the message all have to agree for `CorruptInputError.of`
    to find them, and three of those in eleven places is three chances to
    disagree.
    """
    return (
        Report(CorruptInputError(Int64(offset)).error())
        .with_code(ErrCorruptBase64)
        .with_field("offset", String(offset))
        .with_count(decoded)
        .error()
    )
