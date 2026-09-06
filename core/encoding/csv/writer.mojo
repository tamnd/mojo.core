"""Writing records. Go's `Writer`.

Short next to the reader, because writing has no ambiguity to resolve: a field
either needs quoting or it does not, and the rule for which is four lines long.
The interesting part is what Go decided not to quote, and `_field_needs_quotes`
carries that reasoning where it happens.
"""

from core.bufio import Writer as BufWriter
from core.bufio import new_writer as new_buffered
from core.io import Byte, Writer as IoWriter
from core.bytes import contains_any, contains_rune, index_any
from core.unicode import is_space
from core.unicode.utf8 import RUNE_SELF, decode_rune_in_string

from .reader import _COMMA, _invalid_delim, _valid_delim

comptime _SPECIAL = '"\r\n'
"""The three characters that have to be escaped inside a quoted field."""

comptime _POSTGRES_END = "\\."
"""Postgres reads this as the end of a copy, so Go quotes it and so does this.
"""


struct Writer[W: IoWriter & Deinitable & Movable](Movable):
    """Records into a CSV encoded stream. Go's `csv.Writer`.

    ```mojo
    from core.bytes import new_buffer
    from core.encoding.csv import new_writer
    from core.io import Byte

    def main():
        var w = new_writer(new_buffer(List[Byte]()))
        var row: List[String] = ["a", "b,c", 'a "quoted" word']
        w.write(Span(row))
        w.flush()
        print(w.w.w.string())  # a,"b,c","a ""quoted"" word"
    ```

    Writes are buffered, so `flush` has to be called before the bytes are
    anywhere useful. That is Go's arrangement and the reason for it is the same:
    a record is many small writes and a sink is usually a file.

    Not `Copyable`, for the reason `bufio.Writer` is not: two copies over one
    sink would each hold bytes the other did not, and flushing them would
    interleave.
    """

    var comma: Int32
    """The field delimiter, a comma unless changed. Go's `Comma`."""

    var use_crlf: Bool
    """Whether records end with a carriage return and a newline. Go's `UseCRLF`.

    RFC 4180 says they should. Go's default is a bare newline anyway, which its
    own package documentation calls out as the one place it departs from the
    RFC, and this keeps the default rather than the RFC so that a file written
    here and a file written by Go are the same bytes.
    """

    var w: BufWriter[Self.W]
    """The sink, with a buffer in front of it. Owned, so the call is direct."""

    def __init__(out self, var w: Self.W):
        """Wrap `w`. Go's `NewWriter`, with Go's defaults."""
        self.comma = _COMMA
        self.use_crlf = False
        self.w = new_buffered(w^)

    def _field_needs_quotes(self, field: String) -> Bool:
        """Whether `field` has to be written inside quotes. Go's
        `fieldNeedsQuotes`.

        A field needs them when it holds the delimiter, a quote or a line
        ending, or when it starts with whitespace, because in all four cases
        the bytes would read back as something else.

        The empty string is not quoted, which Go changed in 1.4 and explains at
        length: an empty field and a quoted empty field should mean the same
        thing, Postgres distinguishes them on import and has a flag to force
        quoting but none to force the absence of it, and Excel and Sheets both
        write the unquoted form. The one string quoted for Postgres alone is
        `\\.`, which it reads as the end of a copy.
        """
        if field == "":
            return False
        if field == _POSTGRES_END:
            return True

        if self.comma < RUNE_SELF:
            # A one byte delimiter can be compared a byte at a time, which
            # skips decoding the field at all. Go takes the same shortcut.
            var raw = field.as_bytes()
            var c = Byte(self.comma)
            for i in range(len(raw)):
                var b = raw[i]
                if (
                    b == Byte(ord("\n"))
                    or b == Byte(ord("\r"))
                    or b == Byte(ord('"'))
                    or b == c
                ):
                    return True
        else:
            var raw = field.as_bytes()
            if contains_rune(raw, self.comma) or contains_any(
                raw, _SPECIAL.as_bytes()
            ):
                return True

        var first = decode_rune_in_string(field)
        return is_space(first[0])

    def write[o: Origin](mut self, record: Span[String, o]) raises:
        """One record, quoting whatever needs it. Go's `Write`.

        Buffered, so nothing reaches the sink until `flush`. A record with no
        fields writes a line ending and nothing else, which is what Go does and
        is a line the reader then skips as blank.
        """
        if not _valid_delim(self.comma):
            raise _invalid_delim()

        for n in range(len(record)):
            if n > 0:
                _ = self.w.write_rune(self.comma)

            var field = record[n]
            if not self._field_needs_quotes(field):
                _ = self.w.write_string(field)
                continue

            self.w.write_byte(Byte(ord('"')))
            var rest = field.as_bytes()
            var specials = _SPECIAL.as_bytes()
            var at = 0
            while at < len(rest):
                # Everything up to the next character with a meaning goes out
                # untouched, and then that one character is spelled.
                var i = index_any(rest[at : len(rest)], specials)
                if i < 0:
                    i = len(rest) - at
                _ = self.w.write(rest[at : at + i])
                at += i
                if at < len(rest):
                    var b = rest[at]
                    if b == Byte(ord('"')):
                        _ = self.w.write_string('""')
                    elif b == Byte(ord("\r")):
                        # A bare carriage return would pair with the newline
                        # that follows it and become a line ending, so with
                        # `use_crlf` set it is dropped rather than written.
                        if not self.use_crlf:
                            self.w.write_byte(Byte(ord("\r")))
                    elif b == Byte(ord("\n")):
                        if self.use_crlf:
                            _ = self.w.write_string("\r\n")
                        else:
                            self.w.write_byte(Byte(ord("\n")))
                    at += 1
            self.w.write_byte(Byte(ord('"')))

        if self.use_crlf:
            _ = self.w.write_string("\r\n")
        else:
            self.w.write_byte(Byte(ord("\n")))

    def write_all[o: Origin](mut self, records: Span[List[String], o]) raises:
        """Every record, then a flush. Go's `WriteAll`.

        The flush is the difference from calling `write` in a loop, and it is
        why this is the call to reach for when the records are already in hand.
        """
        for i in range(len(records)):
            self.write(Span(records[i]))
        self.w.flush()

    def flush(mut self) raises:
        """Send the buffered bytes to the sink. Go's `Flush`.

        Go's returns nothing and leaves the failure for `error` to report. This
        raises, because everything else in this library that can fail raises,
        and `error` still answers afterwards for a caller who would rather ask.
        It is on the deviations page.
        """
        self.w.flush()

    def error(self) -> Optional[Error]:
        """The failure this writer is stuck on, or nothing. Go's `Error`.

        Go has to write a zero length slice to find out, because a `bufio`
        writer keeps its failure to itself. Here the failure is a field and
        this reads it, so asking costs nothing and cannot itself fail.

        Once a writer is stuck it stays stuck, so this answering means every
        record written since the failure has been dropped, not merely the last
        one.
        """
        if not self.w.pending:
            return None
        return self.w.pending.value().error()


def new_writer[W: IoWriter & Deinitable & Movable](var w: W) -> Writer[W]:
    """A writer over `w`, with a comma for a delimiter. Go's `NewWriter`.

    Go takes an `io.Writer` interface and this takes the concrete type, so the
    call through the buffer is direct. `core.io.AnyWriter` is the way to hold
    one of several sinks in the same variable.
    """
    return Writer[W](w^)
