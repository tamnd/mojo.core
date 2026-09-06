"""Where a record went wrong. Go's `ParseError`, read rather than raised.

Go returns a `*ParseError` holding four things: the line the record started on,
the line the failure was on, the column, and the sentinel saying why. Those are
not all in the message, and a caller who wants to point at the offending
character needs the numbers rather than the English.

There is no error value to return here, so the four go on the record as a code
and three fields, and `ParseError.of(e)` reads them back out. That is the same
arrangement `core.strconv.NumError` uses and for the same reason: the shape of
the failure survives the trip without the caller having to type assert, which
`core.errors` does not have and design.md section 8 says it will not.

The common questions do not need this type. `errors.matches(e, ErrQuote)` asks
why, and `errors.field(e, "line")` asks where. `ParseError` is for the caller
who wants all of it at once, usually to build their own message.
"""

from core.errors import Code, Report, capture
from core.errors.codes import ErrBareQuote, ErrFieldCount, ErrQuote


def _reason(c: Code) -> String:
    """Go's message for a code, which is the tail of every `Error` string."""
    if c == ErrBareQuote:
        return 'bare " in non-quoted-field'
    if c == ErrQuote:
        return 'extraneous or missing " in quoted-field'
    if c == ErrFieldCount:
        return "wrong number of fields"
    return "unknown error"


struct ParseError(Copyable, Movable, Writable):
    """A record that could not be read, with both lines, the column and why.

    Built from a raised error by `of`, not by hand, and every field is a copy,
    so it outlives the `Error` it came from. Lines and columns count from one,
    and a column is a byte offset rather than a rune offset, which is Go's rule
    and is what lets a caller index the line they still have in hand.

    ```mojo
    from core.bytes import new_buffer_string
    from core.encoding.csv import ParseError, new_reader

    def main():
        var r = new_reader(new_buffer_string('a,"b\\n'))
        try:
            _ = r.read()
        except e:
            var failure = ParseError.of(e)
            if failure:
                print(failure.value().line)  # 1
                print(failure.value().column)  # 3
                print(failure.value().error())
    ```
    """

    var start_line: Int
    """The line the record started on. Go's `StartLine`.

    Different from `line` only for a record with a quoted field spanning more
    than one line, which is the case the longer message exists for.
    """

    var line: Int
    """The line the failure was on. Go's `Line`."""

    var column: Int
    """The byte offset in that line, counting from one. Go's `Column`."""

    var err: Code
    """Why: `ErrBareQuote`, `ErrQuote` or `ErrFieldCount`. Go's `Err`."""

    def __init__(out self, start_line: Int, line: Int, column: Int, err: Code):
        self.start_line = start_line
        self.line = line
        self.column = column
        self.err = err

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as a `ParseError`, or nothing if it did not come from here.

        Go's `err.(*csv.ParseError)`. Nothing comes back when the error was
        raised somewhere else, which is the case a type assertion covers by
        failing and this covers by being empty. A failure from the underlying
        reader is one of those, and so is the end of the input.
        """
        var value = capture(e)
        var c = value.code()
        if c != ErrBareQuote and c != ErrQuote and c != ErrFieldCount:
            return None
        var start = value.field("start_line")
        var at = value.field("line")
        var col = value.field("column")
        if not start or not at or not col:
            return None
        try:
            return Self(
                Int(start.value()), Int(at.value()), Int(col.value()), c
            )
        except:
            return None

    def unwrap(self) -> Code:
        """The reason on its own. Go's `Unwrap`, which hands back the `Err`.

        Go needs it so `errors.Is(err, csv.ErrQuote)` sees through the wrapper.
        Nothing here is wrapped, so `errors.matches(e, ErrQuote)` already
        worked on the error itself and this is for symmetry.
        """
        return self.err

    def error(self) -> String:
        """The message Go's `Error` builds, character for character.

        Three shapes, which is Go's own arrangement. A field count failure has
        no column worth printing, so it names the line and stops. A record that
        started and failed on the same line names that line once. A record with
        a quoted field spanning lines names both, because the line the reader
        stopped on is not the line the caller has to go and look at.
        """
        if self.err == ErrFieldCount:
            return (
                String("record on line ")
                + String(self.line)
                + ": "
                + _reason(self.err)
            )
        if self.start_line != self.line:
            return (
                String("record on line ")
                + String(self.start_line)
                + "; parse error on line "
                + String(self.line)
                + ", column "
                + String(self.column)
                + ": "
                + _reason(self.err)
            )
        return (
            String("parse error on line ")
            + String(self.line)
            + ", column "
            + String(self.column)
            + ": "
            + _reason(self.err)
        )

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.error())


def _parse_error(start_line: Int, line: Int, column: Int, c: Code) -> Error:
    """The raise every parse failure in this package makes.

    One place, so that the message and the three fields cannot drift apart, and
    so that `ParseError.of` has exactly one shape to read.
    """
    var built = ParseError(start_line, line, column, c)
    return (
        Report(built.error())
        .with_code(c)
        .with_field("start_line", String(start_line))
        .with_field("line", String(line))
        .with_field("column", String(column))
        .error()
    )
