"""Where a document stopped being XML. Go's `SyntaxError`, read rather than
raised.

Go returns a `*SyntaxError` holding a message and a line, and a caller who wants
to point at the offending line needs the number rather than the English. There
is no error value to return here, so the message and the line go on the record
as a code and two fields, and `SyntaxError.of(e)` reads them back out. That is
what `core.encoding.csv` does with `ParseError` and what `core.strconv` does with
`NumError`, and design.md section 8 says why: `core.errors` has no type
assertion and is not going to grow one.

`errors.matches(e, ErrXMLSyntax)` is the question most callers have, and
`errors.field(e, "line")` is the other one. This type is for the caller who
wants both at once, usually to build a message of their own.
"""

from core.errors import Report, capture
from core.errors.codes import ErrXMLSyntax


struct SyntaxError(Copyable, Movable, Writable):
    """A malformed document, with what was wrong and the line it was on.

    Built from a raised error by `of` rather than by hand, and both fields are
    copies, so it outlives the `Error` it came from.

    ```mojo
    from core.bytes import new_buffer_string
    from core.encoding.xml import SyntaxError, new_decoder

    def main():
        var d = new_decoder(new_buffer_string("<a>\\n<b></a>"))
        try:
            while True:
                _ = d.token()
        except e:
            var failure = SyntaxError.of(e)
            if failure:
                print(failure.value().line)  # 2
                print(failure.value().msg)  # element <b> closed by </a>
    ```
    """

    var msg: String
    """What was wrong, in Go's words. Go's `Msg`."""

    var line: Int
    """The line it was on, counting from one. Go's `Line`."""

    def __init__(out self, msg: StringSlice, line: Int):
        self.msg = String(msg)
        self.line = line

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as a `SyntaxError`, or nothing if it did not come from here.

        Go's `err.(*xml.SyntaxError)`. Nothing comes back when the document was
        fine and something else went wrong: a failure from the underlying
        reader, the end of the input, a depth cap, or a declared encoding this
        cannot read. Those are their own codes and none of them is a statement
        about the shape of the document.
        """
        var value = capture(e)
        if value.code() != ErrXMLSyntax:
            return None
        var msg = value.field("msg")
        var line = value.field("line")
        if not msg or not line:
            return None
        try:
            return Self(msg.value(), Int(line.value()))
        except:
            return None

    def error(self) -> String:
        """The message Go's `Error` builds, character for character."""
        return (
            String("XML syntax error on line ")
            + String(self.line)
            + ": "
            + self.msg
        )

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.error())


def _syntax_error(msg: StringSlice, line: Int) -> Error:
    """The raise every malformed document in this package produces.

    One place, so the message and the two fields cannot drift apart and
    `SyntaxError.of` has exactly one shape to read.
    """
    var built = SyntaxError(msg, line)
    return (
        Report(built.error())
        .with_code(ErrXMLSyntax)
        .with_field("msg", built.msg)
        .with_field("line", String(line))
        .error()
    )
