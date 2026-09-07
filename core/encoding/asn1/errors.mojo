"""The two ways DER goes wrong, kept apart the way Go keeps them apart.

A `SyntaxError` says the bytes are not DER. A `StructuralError` says they are
DER for something other than what the reader was asked to read. Go makes that
split because the two mean different things to whoever has to fix the problem:
the first says the sender is broken, the second says the sender and the reader
disagree about what a field holds, and a certificate parser reports them
differently.

Go's are two structs a caller separates with a type assertion. There is nothing
to assert against here, so each is a code on the raise and a reader that builds
the record back, which is what `core.encoding.json.SyntaxError` does for the
same reason.
"""

from core.errors import Report, capture
from core.errors.codes import ErrASN1Structural, ErrASN1Syntax

comptime _SYNTAX_PREFIX = "asn1: syntax error: "
"""What Go's `SyntaxError.Error` puts in front of the message."""

comptime _STRUCTURAL_PREFIX = "asn1: structure error: "
"""What Go's `StructuralError.Error` puts in front of the message."""


def _after(text: StringSlice, prefix: StringSlice) -> String:
    """`text` with `prefix` taken off the front, or all of it if it is not
    there."""
    if text.byte_length() < prefix.byte_length():
        return String(text)
    if text[byte = 0 : prefix.byte_length()] != prefix:
        return String(text)
    return String(text[byte = prefix.byte_length() : text.byte_length()])


struct SyntaxError(Copyable, Movable, Writable):
    """The bytes are not DER. Go's `SyntaxError`.

    Built from a raised error by `of` rather than by hand, so it outlives the
    `Error` it came from. Go's type carries a message and nothing else, and so
    does this.

    ```mojo
    from core.encoding.asn1 import Parser, SyntaxError

    def main():
        var der: List[UInt8] = [UInt8(1), UInt8(1), UInt8(2)]
        var p = Parser(Span(der))
        try:
            _ = p.read_bool()
        except e:
            var failure = SyntaxError.of(e)
            if failure:
                print(failure.value().msg)  # invalid boolean
    ```
    """

    var msg: String
    """What went wrong, without the prefix. Go's `Msg`, which is exported
    there and is a field here for the same reason."""

    def __init__(out self, msg: String):
        self.msg = msg.copy()

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as a `SyntaxError`, or nothing if it came from somewhere else.

        Go's `err.(asn1.SyntaxError)`. Nothing comes back for a structural
        error, which is the case that assertion covers by failing.
        """
        var value = capture(e)
        if value.code() != ErrASN1Syntax:
            return None
        return Self(_after(value.message(), _SYNTAX_PREFIX))

    def error(self) -> String:
        """The whole message, prefix and all. Go's `Error`."""
        return _SYNTAX_PREFIX + self.msg

    def write_to[W: Writer](self, mut writer: W):
        writer.write(_SYNTAX_PREFIX, self.msg)


struct StructuralError(Copyable, Movable, Writable):
    """The bytes are DER for something else. Go's `StructuralError`.

    The same shape as `SyntaxError` and a different code, so that a caller can
    tell a malformed encoding from one that is simply not what was expected
    without reading the message.
    """

    var msg: String
    """What was wrong with the structure, without the prefix. Go's `Msg`."""

    def __init__(out self, msg: String):
        self.msg = msg.copy()

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as a `StructuralError`, or nothing if it came from somewhere
        else."""
        var value = capture(e)
        if value.code() != ErrASN1Structural:
            return None
        return Self(_after(value.message(), _STRUCTURAL_PREFIX))

    def error(self) -> String:
        """The whole message, prefix and all. Go's `Error`."""
        return _STRUCTURAL_PREFIX + self.msg

    def write_to[W: Writer](self, mut writer: W):
        writer.write(_STRUCTURAL_PREFIX, self.msg)


def _syntax(msg: StringSlice) -> Error:
    """The raise for bytes that are not DER.

    One place, so that the prefix and the code cannot drift apart and so that
    `SyntaxError.of` has a single shape to read back.
    """
    return Report(_SYNTAX_PREFIX + msg).with_code(ErrASN1Syntax).error()


def _structural(msg: StringSlice) -> Error:
    """The raise for DER that says something other than what was asked for."""
    return Report(_STRUCTURAL_PREFIX + msg).with_code(ErrASN1Structural).error()
