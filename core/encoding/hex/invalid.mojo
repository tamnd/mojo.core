"""The byte that stopped a hex decode. Go's `InvalidByteError`.

The same job as `CorruptInputError` in the two base packages and the opposite
choice of number. Those carry the offset the decode stopped at; this carries
the character that stopped it, because that is what Go's type is, a `byte`. The
offset is not lost either way: the count of bytes decoded before the failure is
on `errors.partial`, and doubling it gives the character that broke, since two
characters spell one byte and hex has nothing to skip.
"""

from core.errors import Report, capture, matches
from core.errors.codes import ErrInvalidHexByte
from core.io import Byte
from core.unicode import is_print


struct InvalidByteError(Copyable, Movable, Writable):
    """The character a decode refused. Go's `InvalidByteError`.

    Built from a raised error by `of`, not by hand.

    ```mojo
    from core.encoding.hex import InvalidByteError, decode_string

    def main():
        try:
            _ = decode_string("0g")
        except e:
            var bad = InvalidByteError.of(e)
            if bad:
                print(bad.value().byte)  # 103, which is `g`
    ```
    """

    var byte: Byte
    """The character that is not a hex digit."""

    def __init__(out self, byte: Byte):
        self.byte = byte

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as an `InvalidByteError`, or nothing if it came from elsewhere.

        Go's `err.(hex.InvalidByteError)`. Nothing comes back when the error
        was raised by something other than this package's decoder, which is the
        case a type assertion covers by failing. An odd length string is one of
        those: it raises `ErrLength` and no single character was wrong.
        """
        if not matches(e, ErrInvalidHexByte):
            return None
        var found = capture(e).field("byte")
        if not found:
            return None
        try:
            return Self(Byte(Int(found.value())))
        except:
            return None

    def error(self) -> String:
        """Go's `Error` text, byte for byte.

        `encoding/hex: invalid byte: U+0067 'g'`.
        """
        return "encoding/hex: invalid byte: " + _sharp_u(self.byte)

    def write_to[W: Writer](self, mut writer: W):
        """`error` as this library spells `String`."""
        writer.write(self.error())


def _sharp_u(b: Byte) -> String:
    """One byte the way Go's `%#U` verb writes it.

    `U+0067 'g'` for a printable character and a bare `U+0001` for one that is
    not. Go appends the character raw rather than quoted, so a byte that is a
    quote comes out as `U+0027 '''` and a backslash as `U+005C '\\'`, and this
    does the same because the message is being matched byte for byte.

    Printable means what `unicode.IsPrint` means, which is what Go's `fmt` asks.
    That matters above 0x7f, where a byte can be a letter, as 0xe9 is, or an
    unprintable space, as 0xa0 is.
    """
    comptime digits = "0123456789ABCDEF"
    var table = digits.as_bytes()
    # Four digits with the leading zeros Go's verb pads to, and a byte never
    # reaches the top two of them.
    var out = String("U+00")
    out += chr(Int(table[Int(b >> 4)]))
    out += chr(Int(table[Int(b & 0x0F)]))
    if is_print(Int32(Int(b))):
        out += " '" + chr(Int(b)) + "'"
    return out^


def _invalid(b: Byte, decoded: Int) -> Error:
    """The raise a refused character makes.

    One function rather than a `Report` built at each site, because the code,
    the field name and the message all have to agree for `InvalidByteError.of`
    to find them.
    """
    return (
        Report(InvalidByteError(b).error())
        .with_code(ErrInvalidHexByte)
        .with_field("byte", String(Int(b)))
        .with_count(decoded)
        .error()
    )
