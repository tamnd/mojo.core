"""Reading records. Go's `Reader`, line for line where the language allows it.

The whole of the parser is one loop over fields with a nested loop inside the
quoted case, and Go writes it with a labelled `break parseField` from four
places in that inner loop. Mojo has no labels, so the label is a `done` flag
and the inner loop breaks twice. Nothing else about the shape has changed, and
the branches are in Go's order so the two can be read side by side.

The forgiving parts are deliberate and are what the format is: a blank line is
skipped, a comment line is skipped, a bare carriage return is data, and a
record may span as many lines as its quoted fields need.
"""

from core.bufio import Reader as BufReader
from core.bufio import new_reader as new_buffered
from core.bytes import index_byte, index_func, index_rune
from core.errors import NO_CODE, Report, matches
from core.errors.codes import (
    EOF,
    ErrBareQuote,
    ErrFieldCount,
    ErrInvalidDelim,
    ErrNotText,
    ErrQuote,
)
from core.io import Byte, Reader as IoReader
from core.iter import Cursor
from core.unicode import is_space
from core.unicode.utf8 import RUNE_ERROR, decode_rune, rune_len, valid_rune

from .parse_error import _parse_error

comptime _NEWLINE = Byte(ord("\n"))
"""The line ending this parser works in. Carriage returns are removed first."""

comptime _RETURN = Byte(ord("\r"))
"""Half of a Windows line ending, and data anywhere else."""

comptime _QUOTE = Byte(ord('"'))
"""The one byte with a meaning inside a field."""

comptime _QUOTE_RUNE = Int32(ord('"'))
"""The same byte as a rune, for the comparisons against a decoded one."""

comptime _COMMA = Int32(ord(","))
"""What `new_reader` sets `comma` to. Go's `NewReader` sets the same."""


def _valid_delim(r: Int32) -> Bool:
    """Whether a rune may be used as a delimiter. Go's `validDelim`.

    Zero is out because it is Go's "unset" for `Comment` and a reader that
    treated it as a character would find one in every run of padding. A quote
    and the two line ending bytes are out because the parser reads them before
    it reads a delimiter, so a file using one could not be parsed by the parser
    that wrote it. The replacement character is out because it is what a decode
    of invalid bytes produces, so accepting it would make every broken byte a
    field boundary.
    """
    return (
        r != 0
        and r != _QUOTE_RUNE
        and r != Int32(ord("\r"))
        and r != Int32(ord("\n"))
        and valid_rune(r)
        and r != RUNE_ERROR
    )


def _invalid_delim() -> Error:
    """Go's `errInvalidDelim`, which Go keeps unexported and this gives a code.

    Go's message word for word, so a program printing it reads the same.
    """
    return (
        Report("csv: invalid field or comment delimiter")
        .with_code(ErrInvalidDelim)
        .error()
    )


def _length_nl[o: Origin](b: Span[Byte, o]) -> Int:
    """One if `b` ends in a newline, zero otherwise. Go's `lengthNL`."""
    if len(b) > 0 and b[len(b) - 1] == _NEWLINE:
        return 1
    return 0


def _next_rune[o: Origin](b: Span[Byte, o]) -> Int32:
    """The first rune of `b`, or `RUNE_ERROR`. Go's `nextRune`."""
    var got = decode_rune(b)
    return got[0]


struct _Position(Copyable, ImplicitlyCopyable, Movable):
    """Where a field started. Go's unexported `position`."""

    var line: Int
    """One based, counting the lines the reader has consumed."""

    var col: Int
    """One based, in bytes rather than runes, which is Go's rule."""

    def __init__(out self, line: Int, col: Int):
        self.line = line
        self.col = col


struct Reader[R: IoReader & Deinitable & Movable](Movable):
    """Records out of a CSV encoded stream. Go's `csv.Reader`.

    ```mojo
    from core.bytes import new_buffer_string
    from core.encoding.csv import new_reader

    def main():
        var r = new_reader(new_buffer_string("a,b,c\\nd,e,f\\n"))
        for row in r.read_all():
            print(len(row), row[0])  # 3 a, then 3 d
    ```

    The settings are plain fields and are meant to be assigned between building
    the reader and the first `read`, which is exactly how Go's are used. They
    are read on every record rather than frozen, so changing one halfway
    through takes effect from the next record, and that is Go's behaviour too
    rather than a promise either library makes.

    Not `Copyable`, for the reason `bufio.Reader` is not: two copies over one
    source would each hold bytes the other did not.
    """

    var comma: Int32
    """The field delimiter, a comma unless changed. Go's `Comma`.

    Any rune `_valid_delim` accepts, so a tab separated file is one assignment.
    """

    var comment: Int32
    """The comment character, or zero for none. Go's `Comment`.

    A line whose first rune is this one is skipped whole. The rune has to be
    first: with leading whitespace in front of it the character is data, even
    when `trim_leading_space` is set, which is Go's rule and is what keeps a
    field that happens to start with a hash from disappearing.
    """

    var fields_per_record: Int
    """How many fields a record must have. Go's `FieldsPerRecord`.

    Positive means every record must have exactly that many and one that does
    not raises `ErrFieldCount`. Zero, which is what `new_reader` leaves, means
    the first record decides and the rest must match it. Negative means no
    check at all and records may be ragged.
    """

    var lazy_quotes: Bool
    """Whether a stray quote is data rather than a failure. Go's `LazyQuotes`.

    With it set, a quote may appear in an unquoted field and a quote inside a
    quoted field need not be doubled. It is what to reach for on a file some
    other program wrote badly, and it cannot be the default because it makes
    two different files parse to the same records.
    """

    var trim_leading_space: Bool
    """Whether leading whitespace in a field is dropped. Go's
    `TrimLeadingSpace`.

    Whitespace means anything `core.unicode.is_space` accepts, and the trim
    happens even when `comma` is itself a space, which is Go's documented
    behaviour and is worth knowing before setting both.
    """

    var r: BufReader[Self.R]
    """The source, with a buffer in front of it. Owned, so the call is direct.
    """

    var num_line: Int
    """Lines consumed so far. The line number a failure reports."""

    var offset: Int64
    """Bytes consumed so far. What `input_offset` hands back."""

    var record_buffer: List[Byte]
    """Every field of the current record, unescaped, one after another.

    For the row `a,"b","c""d",e` this holds `abc"de` and `field_indexes` holds
    1, 2, 5 and 6. One buffer rather than a list of fields, which is Go's
    arrangement, so a record costs one growable allocation instead of one per
    field.
    """

    var field_indexes: List[Int]
    """Where each field ends in `record_buffer`."""

    var field_positions: List[_Position]
    """Where each field started in the input, for `field_pos`."""

    var last: List[String]
    """The record the last `read` was working on when it failed, if it did.

    Empty after a read that succeeded. `last_record` is the way to read it and
    says what it is for.
    """

    def __init__(out self, var r: Self.R):
        """Wrap `r`. Go's `NewReader`, with Go's defaults."""
        self.comma = _COMMA
        self.comment = 0
        self.fields_per_record = 0
        self.lazy_quotes = False
        self.trim_leading_space = False
        self.r = new_buffered(r^)
        self.num_line = 0
        self.offset = 0
        self.record_buffer = List[Byte]()
        self.field_indexes = List[Int]()
        self.field_positions = List[_Position]()
        self.last = List[String]()

    def input_offset(self) -> Int64:
        """Bytes read so far. Go's `InputOffset`.

        The end of the record most recently returned and the start of the next
        one, so a caller keeping an index into a file has the number to store.
        """
        return self.offset

    def field_pos(self, field: Int) raises -> Tuple[Int, Int]:
        """The line and column the given field of the last record started on.
        Go's `FieldPos`.

        Both count from one, and the column counts bytes rather than runes,
        which is what lets a caller index the line they still have in hand.

        Go panics on an index out of range and this raises, which is the
        library wide rule about aborting on a caller's mistake and is on the
        deviations page.
        """
        if field < 0 or field >= len(self.field_positions):
            raise Report(
                "csv.field_pos: out of range index, "
                + String(field)
                + " of "
                + String(len(self.field_positions))
            ).error()
        var p = self.field_positions[field]
        return (p.line, p.col)

    def last_record(self) -> List[String]:
        """The record the last `read` failed on, or nothing if it succeeded.

        This has no counterpart in Go because Go does not need one: `Read`
        returns the record and the error together, so a caller who set
        `fields_per_record` sees both the count failure and the row that caused
        it. A raise carries one value and it is the failure, so the row is left
        here instead.

        `ErrFieldCount` is the case it exists for, since that record is
        complete and the caller usually wants to look at it or write it out to
        a file of rejects. A record that failed to parse is left here as well,
        holding the fields that were read before the failure, which is the
        partial record Go documents.
        """
        return self.last.copy()

    def records(mut self) -> Records[Self.R, origin_of(self)]:
        """The records left, as a `core.iter.Cursor`.

        Go's loop is `rec, err := r.Read()` with a comparison against `io.EOF`
        in it, and the whole of that loop's correctness is in the comparison.
        Leave it out and the loop ends on the first malformed row and reports
        nothing, which is the flaw `bufio.Scanner` has and the reason
        design.md section 7 says a fallible sequence is a `Cursor` here.

        The reader is usable afterwards, so taking a few records through a
        cursor and reading the rest with `read` is fine.
        """
        return Records[Self.R, origin_of(self)](self)

    def _read_line(mut self) raises -> List[Byte]:
        """The next line, with its ending, normalised. Go's `readLine`.

        Raises `EOF` when there is nothing left at all. A last line with no
        ending on it comes back without one and the end arrives from the call
        after, which is `bufio.Reader.read_bytes`'s rule and happens to be
        exactly the two outcomes Go spells with a nil error and an `io.EOF`.

        `read_bytes` rather than `read_slice`, so a line longer than the buffer
        grows instead of raising. A CSV field has no length limit and a file
        with one very long line is not malformed.
        """
        var line = self.r.read_bytes(_NEWLINE)
        var read_size = len(line)
        if read_size > 0 and line[read_size - 1] != _NEWLINE:
            # The input ended without a line ending. Go drops a trailing
            # carriage return here for backwards compatibility and so does
            # this, and the byte is still counted in the offset.
            if line[read_size - 1] == _RETURN:
                line.resize(read_size - 1, 0)
        self.num_line += 1
        self.offset += Int64(read_size)
        # Every line ending becomes a bare newline, including the ones inside a
        # quoted field, so what comes out does not depend on which convention
        # the file was written with.
        var n = len(line)
        if n >= 2 and line[n - 2] == _RETURN and line[n - 1] == _NEWLINE:
            line[n - 2] = _NEWLINE
            line.resize(n - 1, 0)
        return line^

    def _text(self, start: Int, stop: Int) raises -> String:
        """One field out of `record_buffer`, as text.

        Go writes `string(r.recordBuffer)` once and slices it, which costs one
        allocation for the whole record. That works because a Go string is any
        bytes at all. Here each field is validated and built on its own, and a
        field that is not UTF-8 raises `ErrNotText` rather than being carried
        around as something that only looks like text.
        """
        try:
            return String(from_utf8=Span(self.record_buffer)[start:stop])
        except e:
            raise (
                Report("csv.read: a field is not valid UTF-8")
                .with_code(ErrNotText)
                .wrapping(e)
                .error()
            )

    def read(mut self) raises -> List[String]:
        """One record. Go's `Read`.

        Raises `EOF` when there is nothing left, which is Go returning nil and
        `io.EOF` and is what ends a read loop. A record that will not parse
        raises with a `ParseError` on the record, and one with the wrong number
        of fields raises `ErrFieldCount`; in both cases `last_record` holds
        what was read.

        ```mojo
        from core.bytes import new_buffer_string
        from core.encoding.csv import new_reader
        from core.errors import matches
        from core.errors.codes import EOF

        def main():
            var r = new_reader(new_buffer_string("a,b\\nc,d\\n"))
            while True:
                try:
                    print(r.read()[0])  # a, then c
                except e:
                    if not matches(e, EOF):
                        raise e
                    break
        ```
        """
        return self._read_record()

    def read_all(mut self) raises -> List[List[String]]:
        """Every remaining record. Go's `ReadAll`.

        The end of the input is not a failure here, same as Go, so a file that
        parses gives every record and no error. Anything that does raise raises
        with nothing returned, because a caller who asked for all of them
        cannot use some of them, and that is Go's rule as well.
        """
        var out = List[List[String]]()
        while True:
            var record: List[String]
            try:
                record = self._read_record()
            except e:
                if matches(e, EOF):
                    return out^
                raise e
            out.append(record^)

    def _read_record(mut self) raises -> List[String]:
        """Go's `readRecord`, which is the whole parser."""
        if (
            self.comma == self.comment
            or not _valid_delim(self.comma)
            or (self.comment != 0 and not _valid_delim(self.comment))
        ):
            raise _invalid_delim()

        # Find a line with something on it, skipping blank ones and comments.
        # `_read_line` raises `EOF` when there is nothing left, and that is the
        # raise a read loop stops on, so it goes straight out.
        var line = List[Byte]()
        while True:
            line = self._read_line()
            var view = Span(line)
            if self.comment != 0 and _next_rune(view) == self.comment:
                continue
            if len(line) == _length_nl(view):
                continue
            break

        var comma_len = rune_len(self.comma)
        var rec_line = self.num_line
        self.record_buffer.clear()
        self.field_indexes.clear()
        self.field_positions.clear()
        var pos_line = self.num_line
        var pos_col = 1
        var at = 0

        @parameter
        def not_space(r: Int32) -> Bool:
            """What `trim_leading_space` searches for: the first rune that is
            not whitespace. A parameter rather than a value, which is what
            `index_func` takes and why."""
            return not is_space(r)

        # Go builds a `*ParseError` and carries it to the bottom of the
        # function. Building the `Error` here instead would install its record
        # on the thread, and the record is meant to be installed by the raise,
        # so the four numbers are carried and the error is built at the end.
        var bad = NO_CODE
        var bad_start = 0
        var bad_line = 0
        var bad_col = 0

        # Go's `parseField` label. `done` is the label and the inner loop
        # breaks twice to reach it, which is the one structural difference.
        var done = False
        while not done:
            if self.trim_leading_space:
                var head = Span(line)[at : len(line)]
                var i = index_func[not_space](head)
                if i < 0:
                    i = len(head)
                    pos_col -= _length_nl(head)
                at += i
                pos_col += i

            var rest = Span(line)[at : len(line)]
            if len(rest) == 0 or rest[0] != _QUOTE:
                # An unquoted field, which runs to the next comma or the end.
                var i = index_rune(rest, self.comma)
                var stop = len(rest) - _length_nl(rest)
                if i >= 0:
                    stop = i
                var field = rest[0:stop]
                if not self.lazy_quotes:
                    var j = index_byte(field, _QUOTE)
                    if j >= 0:
                        bad = ErrBareQuote
                        bad_start = rec_line
                        bad_line = self.num_line
                        bad_col = pos_col + j
                        break
                for k in range(len(field)):
                    self.record_buffer.append(field[k])
                self.field_indexes.append(len(self.record_buffer))
                self.field_positions.append(_Position(pos_line, pos_col))
                if i >= 0:
                    at += i + comma_len
                    pos_col += i + comma_len
                    continue
                break

            # A quoted field, which runs to a quote that is not doubled and may
            # cross as many lines as it likes on the way there.
            var field_line = pos_line
            var field_col = pos_col
            at += 1
            pos_col += 1
            while True:
                var body = Span(line)[at : len(line)]
                var i = index_byte(body, _QUOTE)
                if i >= 0:
                    for k in range(i):
                        self.record_buffer.append(body[k])
                    at += i + 1
                    pos_col += i + 1
                    var after = Span(line)[at : len(line)]
                    var rn = _next_rune(after)
                    if rn == _QUOTE_RUNE:
                        # A doubled quote, which is one quote of data.
                        self.record_buffer.append(_QUOTE)
                        at += 1
                        pos_col += 1
                    elif rn == self.comma:
                        # The field ended and another one follows.
                        at += comma_len
                        pos_col += comma_len
                        self.field_indexes.append(len(self.record_buffer))
                        self.field_positions.append(
                            _Position(field_line, field_col)
                        )
                        break
                    elif _length_nl(after) == len(after):
                        # The field ended and so did the record.
                        self.field_indexes.append(len(self.record_buffer))
                        self.field_positions.append(
                            _Position(field_line, field_col)
                        )
                        done = True
                        break
                    elif self.lazy_quotes:
                        # A bare quote, taken literally because it was asked
                        # for.
                        self.record_buffer.append(_QUOTE)
                    else:
                        bad = ErrQuote
                        bad_start = rec_line
                        bad_line = self.num_line
                        bad_col = pos_col - 1
                        done = True
                        break
                elif len(body) > 0:
                    # No closing quote on this line, so the field continues on
                    # the next one and the newline is part of it.
                    for k in range(len(body)):
                        self.record_buffer.append(body[k])
                    pos_col += len(body)
                    at = 0
                    try:
                        line = self._read_line()
                    except e:
                        if not matches(e, EOF):
                            raise e
                        # Go clears `io.EOF` here on purpose, so that running
                        # out of input inside a quoted field is reported by the
                        # branch below as a missing quote rather than as an
                        # orderly end.
                        line = List[Byte]()
                    if len(line) > 0:
                        pos_line += 1
                        pos_col = 1
                else:
                    # The input ended in the middle of a quoted field.
                    if not self.lazy_quotes:
                        bad = ErrQuote
                        bad_start = rec_line
                        bad_line = pos_line
                        bad_col = pos_col
                        done = True
                        break
                    self.field_indexes.append(len(self.record_buffer))
                    self.field_positions.append(
                        _Position(field_line, field_col)
                    )
                    done = True
                    break
            if bad:
                break

        var record = List[String](capacity=len(self.field_indexes))
        var pre = 0
        for i in range(len(self.field_indexes)):
            var idx = self.field_indexes[i]
            record.append(self._text(pre, idx))
            pre = idx

        if self.fields_per_record > 0:
            if len(record) != self.fields_per_record and not bad:
                bad = ErrFieldCount
                bad_start = rec_line
                bad_line = rec_line
                bad_col = 1
        elif self.fields_per_record == 0:
            self.fields_per_record = len(record)

        if bad:
            self.last = record^
            raise _parse_error(bad_start, bad_line, bad_col, bad)
        self.last = List[String]()
        return record^


struct Records[R: IoReader & Deinitable & Movable, o: MutOrigin](
    Cursor, Movable
):
    """A cursor over the records left in a reader. Go has no counterpart.

    ```mojo
    from core.bytes import new_buffer_string
    from core.encoding.csv import new_reader

    def main():
        var r = new_reader(new_buffer_string("a,b\\nc,d\\n"))
        var records = r.records()
        while records.has_next():
            var record = records.next()
            print(record[0])  # a, then c
    ```

    It holds a pointer at the reader rather than the reader itself, the same
    arrangement `sort.Reverse` has and for the same reason: a copy would be
    read to the end and the caller's reader would be left where it was.

    A malformed row raises out of whichever of the two calls found it, so a
    loop that ignores failures does not compile and one that catches them says
    which record it was on. `ErrFieldCount` arrives the same way, and the
    record it counted is on the reader for `last_record`, so a program building
    a file of rejects can catch it and carry on.
    """

    comptime Element = List[String]

    var inner: Pointer[Reader[Self.R], Self.o]
    """The reader being walked. Nothing is copied and nothing is owned."""

    var pending: Optional[List[String]]
    """The record `has_next` read in order to answer, waiting for `next`."""

    var done: Bool
    """Whether the end of the input has been reached.

    Kept so that `has_next` goes on answering `False` once it has, which is the
    first of the trait's three rules, rather than asking a reader that has
    already said it is finished.
    """

    def __init__(out self, ref[Self.o] r: Reader[Self.R]):
        """Points at `r`. Reading starts wherever `r` currently is."""
        self.inner = Pointer(to=r)
        self.pending = None
        self.done = False

    def has_next(mut self) raises -> Bool:
        """Whether another record is available, by reading one to find out.

        There is no way to know a file has another record without parsing one,
        which is the case the trait's own documentation names and this is the
        package it names it about. The end of the input is not a failure and is
        the answer `False`; anything else raises here, so a malformed row in
        the middle of a file cannot be mistaken for the end of it.
        """
        if self.done:
            return False
        if self.pending:
            return True
        try:
            self.pending = self.inner[].read()
        except e:
            if matches(e, EOF):
                self.done = True
                return False
            raise e
        return True

    def next(mut self) raises -> List[String]:
        """The next record, moved out. Raises `EOF` past the last one."""
        if not self.has_next():
            raise (
                Report("csv: read past the last record").with_code(EOF).error()
            )
        var got = self.pending.take()
        return got^


def new_reader[R: IoReader & Deinitable & Movable](var r: R) -> Reader[R]:
    """A reader over `r`, with a comma for a delimiter. Go's `NewReader`.

    Go takes an `io.Reader` interface and this takes the concrete type, so the
    call through the buffer is direct. `core.io.AnyReader` is the way to hold
    one of several sources in the same variable.
    """
    return Reader[R](r^)
