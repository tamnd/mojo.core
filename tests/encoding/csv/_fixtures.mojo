"""Go's `readTests`, and the position marker scheme that goes with them.

Go writes its reader table with three characters carrying meaning: a section
sign marks the start of a field, a pilcrow marks a record boundary and a
summation sign marks where the failure is. `make_positions` strips them and
turns them into the line and column numbers `field_pos` is checked against, so
one string says both what the input is and where every field in it starts.

The table itself is not harvested. `tools/testgen` writes a row of scalars or a
row of lists of scalars, and Go's rows hold a list of lists of strings and an
`error`, so there is nothing here it can copy. The rows are written out instead,
in Go's order and with Go's names, so the two files can be read side by side.
"""

from core.errors import NO_CODE, Code
from core.errors.codes import (
    ErrBareQuote,
    ErrFieldCount,
    ErrInvalidDelim,
    ErrQuote,
)
from core.strings import repeat
from core.unicode.utf8 import RUNE_ERROR, decode_rune

comptime _FIELD = Int32(0xA7)
"""The section sign, which marks the start of a field."""

comptime _RECORD = Int32(0xB6)
"""The pilcrow, which marks a record boundary."""

comptime _FAILURE = Int32(0x2211)
"""The summation sign, which marks where a record stops parsing."""


def fields(*items: String) -> List[String]:
    """One record, written as its fields."""
    var out = List[String]()
    for i in range(len(items)):
        out.append(items[i].copy())
    return out^


def rows(*items: List[String]) -> List[List[String]]:
    """The records a case expects, written as records."""
    var out = List[List[String]]()
    for i in range(len(items)):
        out.append(items[i].copy())
    return out^


def codes(*items: Code) -> List[Code]:
    """What each record raises, `NO_CODE` for one that reads."""
    var out = List[Code]()
    for i in range(len(items)):
        out.append(items[i])
    return out^


struct Spot(Copyable, ImplicitlyCopyable, Movable):
    """A line and a column, both counting from one."""

    var line: Int
    var col: Int

    def __init__(out self, line: Int, col: Int):
        self.line = line
        self.col = col


struct Marked(Copyable, Movable):
    """What `make_positions` works out from a marked up input."""

    var positions: List[List[Spot]]
    """Where every field of every record starts."""

    var failures: Dict[Int, Spot]
    """Where the record at each index stops parsing, for the ones that do."""

    var text: String
    """The input with the three markers taken back out."""

    def __init__(
        out self,
        var positions: List[List[Spot]],
        var failures: Dict[Int, Spot],
        var text: String,
    ):
        self.positions = positions^
        self.failures = failures^
        self.text = text^


def make_positions(marked: String) raises -> Marked:
    """Go's `makePositions`, rune for rune.

    A newline moves to the next line and back to column one. A field marker
    records the current spot against the current record. A record marker starts
    a new record. A failure marker records the spot the record is expected to
    stop at. Everything else is copied out and moves the column along by its own
    width in bytes, which is why the columns come out as byte offsets.
    """
    var raw = marked.as_bytes()
    var out = List[UInt8]()
    var positions = List[List[Spot]]()
    var failures = Dict[Int, Spot]()
    var line = 1
    var col = 1
    var rec = 0
    var i = 0
    while i < len(raw):
        var got = decode_rune(raw[i : len(raw)])
        var r = got[0]
        var size = got[1]
        if r == Int32(ord("\n")):
            line += 1
            col = 1
            out.append(UInt8(ord("\n")))
        elif r == _FIELD:
            if len(positions) == 0:
                positions.append(List[Spot]())
            positions[len(positions) - 1].append(Spot(line, col))
        elif r == _RECORD:
            positions.append(List[Spot]())
            rec += 1
        elif r == _FAILURE:
            failures[rec] = Spot(line, col)
        else:
            for k in range(size):
                out.append(raw[i + k])
            col += size
        i += size
    return Marked(positions^, failures^, String(from_utf8=Span(out)))


struct ReadCase(Copyable, Movable):
    """One row of Go's `readTests`.

    The settings are set by the builder methods rather than by keyword, so a
    row that leaves one alone does not mention it, which is how Go's rows read.
    A comma of zero means leave the default alone, and that is Go's convention
    in this table too rather than a delimiter of zero, which is refused.
    """

    var name: String
    var input: String
    var output: List[List[String]]
    var errors: List[Code]
    var comma: Int32
    var comment: Int32
    var use_fields_per_record: Bool
    var fields_per_record: Int
    var lazy_quotes: Bool
    var trim_leading_space: Bool

    def __init__(out self, var name: String, var input: String):
        self.name = name^
        self.input = input^
        self.output = List[List[String]]()
        self.errors = List[Code]()
        self.comma = 0
        self.comment = 0
        self.use_fields_per_record = False
        self.fields_per_record = 0
        self.lazy_quotes = False
        self.trim_leading_space = False

    def out(var self, var records: List[List[String]]) -> Self:
        """The records this case expects. Go's `Output`."""
        self.output = records^
        return self^

    def fails(var self, var which: List[Code]) -> Self:
        """What each record raises. Go's `Errors`."""
        self.errors = which^
        return self^

    def comma_is(var self, r: Int32) -> Self:
        """Go's `Comma`."""
        self.comma = r
        return self^

    def comment_is(var self, r: Int32) -> Self:
        """Go's `Comment`."""
        self.comment = r
        return self^

    def counting(var self, n: Int) -> Self:
        """Go's `UseFieldsPerRecord` with `FieldsPerRecord` set to `n`."""
        self.use_fields_per_record = True
        self.fields_per_record = n
        return self^

    def lazy(var self) -> Self:
        """Go's `LazyQuotes`."""
        self.lazy_quotes = True
        return self^

    def trimmed(var self) -> Self:
        """Go's `TrimLeadingSpace`."""
        self.trim_leading_space = True
        return self^


comptime _POUND = Int32(0xA3)
"""The pound sign, which four of Go's rows use as a delimiter."""

comptime _EURO = Int32(0x20AC)
"""The euro sign, used as both a delimiter and a comment character."""

comptime _LAMBDA = Int32(0x3BB)
"""Greek lambda. Shares a first byte with theta, which is the point."""

comptime _THETA = Int32(0x3B8)
"""Greek theta."""


def _simple_cases() -> List[ReadCase]:
    """Files that read, up to Go's `LazyQuotes` row."""
    var out = List[ReadCase]()
    out.append(
        ReadCase("Simple", "§a,§b,§c\n").out(rows(fields("a", "b", "c")))
    )
    out.append(
        ReadCase("CRLF", "§a,§b\r\n¶§c,§d\r\n").out(
            rows(fields("a", "b"), fields("c", "d"))
        )
    )
    out.append(
        ReadCase("BareCR", "§a,§b\rc,§d\r\n").out(
            rows(fields("a", "b\rc", "d"))
        )
    )
    out.append(
        ReadCase(
            "RFC4180test",
            '§#field1,§field2,§field3\n¶§"aaa",§"bb\nb",§"ccc"\n¶§"a,a",§"b""bb",§"ccc"\n¶§zzz,§yyy,§xxx\n',
        )
        .out(
            rows(
                fields("#field1", "field2", "field3"),
                fields("aaa", "bb\nb", "ccc"),
                fields("a,a", 'b"bb', "ccc"),
                fields("zzz", "yyy", "xxx"),
            )
        )
        .counting(0)
    )
    out.append(
        ReadCase("NoEOLTest", "§a,§b,§c").out(rows(fields("a", "b", "c")))
    )
    out.append(
        ReadCase("Semicolon", "§a;§b;§c\n")
        .out(rows(fields("a", "b", "c")))
        .comma_is(Int32(ord(";")))
    )
    out.append(
        ReadCase(
            "MultiLine",
            '§"two\nline",§"one line",§"three\nline\nfield"',
        ).out(rows(fields("two\nline", "one line", "three\nline\nfield")))
    )
    out.append(
        ReadCase("BlankLine", "§a,§b,§c\n\n¶§d,§e,§f\n\n").out(
            rows(fields("a", "b", "c"), fields("d", "e", "f"))
        )
    )
    out.append(
        ReadCase("BlankLineFieldCount", "§a,§b,§c\n\n¶§d,§e,§f\n\n")
        .out(rows(fields("a", "b", "c"), fields("d", "e", "f")))
        .counting(0)
    )
    out.append(
        ReadCase("TrimSpace", " §a,  §b,   §c\n")
        .out(rows(fields("a", "b", "c")))
        .trimmed()
    )
    out.append(
        ReadCase("LeadingSpace", "§ a,§  b,§   c\n").out(
            rows(fields(" a", "  b", "   c"))
        )
    )
    out.append(
        ReadCase("Comment", "#1,2,3\n§a,§b,§c\n#comment")
        .out(rows(fields("a", "b", "c")))
        .comment_is(Int32(ord("#")))
    )
    out.append(
        ReadCase("NoComment", "§#1,§2,§3\n¶§a,§b,§c").out(
            rows(fields("#1", "2", "3"), fields("a", "b", "c"))
        )
    )
    return out^


def _quote_cases() -> List[ReadCase]:
    """Stray quotes, forgiven and refused, and the field count check."""
    var out = List[ReadCase]()
    out.append(
        ReadCase("LazyQuotes", '§a "word",§"1"2",§a",§"b')
        .out(rows(fields('a "word"', '1"2', 'a"', "b")))
        .lazy()
    )
    out.append(
        ReadCase("BareQuotes", '§a "word",§"1"2",§a"')
        .out(rows(fields('a "word"', '1"2', 'a"')))
        .lazy()
    )
    out.append(
        ReadCase("BareDoubleQuotes", '§a""b,§c')
        .out(rows(fields('a""b', "c")))
        .lazy()
    )
    out.append(
        ReadCase("BadDoubleQuotes", '§a∑""b,c').fails(codes(ErrBareQuote))
    )
    out.append(
        ReadCase("TrimQuote", ' §"a",§" b",§c')
        .out(rows(fields("a", " b", "c")))
        .trimmed()
    )
    out.append(
        ReadCase("BadBareQuote", '§a ∑"word","b"').fails(codes(ErrBareQuote))
    )
    out.append(
        ReadCase("BadTrailingQuote", '§"a word",b∑"').fails(codes(ErrBareQuote))
    )
    out.append(
        ReadCase("ExtraneousQuote", '§"a ∑"word","b"').fails(codes(ErrQuote))
    )
    out.append(
        ReadCase("BadFieldCount", "§a,§b,§c\n¶∑§d,§e")
        .out(rows(fields("a", "b", "c"), fields("d", "e")))
        .fails(codes(NO_CODE, ErrFieldCount))
        .counting(0)
    )
    out.append(
        ReadCase("BadFieldCountMultiple", "§a,§b,§c\n¶∑§d,§e\n¶∑§f")
        .out(rows(fields("a", "b", "c"), fields("d", "e"), fields("f")))
        .fails(codes(NO_CODE, ErrFieldCount, ErrFieldCount))
        .counting(0)
    )
    out.append(
        ReadCase("BadFieldCount1", "§∑a,§b,§c")
        .out(rows(fields("a", "b", "c")))
        .fails(codes(ErrFieldCount))
        .counting(2)
    )
    out.append(
        ReadCase("FieldCount", "§a,§b,§c\n¶§d,§e").out(
            rows(fields("a", "b", "c"), fields("d", "e"))
        )
    )
    return out^


def _comma_cases() -> List[ReadCase]:
    """Trailing commas, empty fields and the two `StartLine` rows."""
    var out = List[ReadCase]()
    out.append(
        ReadCase("TrailingCommaEOF", "§a,§b,§c,§").out(
            rows(fields("a", "b", "c", ""))
        )
    )
    out.append(
        ReadCase("TrailingCommaEOL", "§a,§b,§c,§\n").out(
            rows(fields("a", "b", "c", ""))
        )
    )
    out.append(
        ReadCase("TrailingCommaSpaceEOF", "§a,§b,§c, §")
        .out(rows(fields("a", "b", "c", "")))
        .trimmed()
    )
    out.append(
        ReadCase("TrailingCommaSpaceEOL", "§a,§b,§c, §\n")
        .out(rows(fields("a", "b", "c", "")))
        .trimmed()
    )
    out.append(
        ReadCase("TrailingCommaLine3", "§a,§b,§c\n¶§d,§e,§f\n¶§g,§hi,§")
        .out(
            rows(
                fields("a", "b", "c"),
                fields("d", "e", "f"),
                fields("g", "hi", ""),
            )
        )
        .trimmed()
    )
    out.append(
        ReadCase("NotTrailingComma3", "§a,§b,§c,§ \n").out(
            rows(fields("a", "b", "c", " "))
        )
    )
    out.append(
        ReadCase(
            "CommaFieldTest",
            '§x,§y,§z,§w\n¶§x,§y,§z,§\n¶§x,§y,§,§\n¶§x,§,§,§\n¶§,§,§,§\n¶§"x",§"y",§"z",§"w"\n¶§"x",§"y",§"z",§""\n¶§"x",§"y",§"",§""\n¶§"x",§"",§"",§""\n¶§"",§"",§"",§""\n',
        ).out(
            rows(
                fields("x", "y", "z", "w"),
                fields("x", "y", "z", ""),
                fields("x", "y", "", ""),
                fields("x", "", "", ""),
                fields("", "", "", ""),
                fields("x", "y", "z", "w"),
                fields("x", "y", "z", ""),
                fields("x", "y", "", ""),
                fields("x", "", "", ""),
                fields("", "", "", ""),
            )
        )
    )
    out.append(
        ReadCase("TrailingCommaIneffective1", "§a,§b,§\n¶§c,§d,§e")
        .out(rows(fields("a", "b", ""), fields("c", "d", "e")))
        .trimmed()
    )
    # Go sets `ReuseRecord` here. There is no such setting, so what is left is
    # an ordinary two record file, and it is kept so the row count matches.
    out.append(
        ReadCase("ReadAllReuseRecord", "§a,§b\n¶§c,§d").out(
            rows(fields("a", "b"), fields("c", "d"))
        )
    )
    out.append(ReadCase("StartLine1", '§a,"b\nc∑"d,e').fails(codes(ErrQuote)))
    out.append(
        ReadCase("StartLine2", '§a,§b\n¶§"d\n\n,e∑')
        .out(rows(fields("a", "b")))
        .fails(codes(NO_CODE, ErrQuote))
    )
    return out^


def _return_cases() raises -> List[ReadCase]:
    """Carriage returns in every arrangement, and the non-ASCII delimiters."""
    var out = List[ReadCase]()
    out.append(
        ReadCase("CRLFInQuotedField", '§A,§"Hello\r\nHi",§B\r\n').out(
            rows(fields("A", "Hello\nHi", "B"))
        )
    )
    # Go's `BinaryBlobField` row is not here. Its field holds bytes that are not
    # valid UTF-8, and `test_reader.mojo` checks that same input raises
    # `ErrNotText` instead.
    out.append(
        ReadCase("TrailingCR", "§field1,§field2\r").out(
            rows(fields("field1", "field2"))
        )
    )
    out.append(
        ReadCase("QuotedTrailingCR", '§"field"\r').out(rows(fields("field")))
    )
    out.append(
        ReadCase("QuotedTrailingCRCR", '§"field∑"\r\r').fails(codes(ErrQuote))
    )
    out.append(
        ReadCase("FieldCR", "§field\rfield\r").out(rows(fields("field\rfield")))
    )
    out.append(
        ReadCase("FieldCRCR", "§field\r\rfield\r\r").out(
            rows(fields("field\r\rfield\r"))
        )
    )
    out.append(
        ReadCase("FieldCRCRLF", "§field\r\r\n¶§field\r\r\n").out(
            rows(fields("field\r"), fields("field\r"))
        )
    )
    out.append(
        ReadCase("FieldCRCRLFCR", "§field\r\r\n¶§\rfield\r\r\n\r").out(
            rows(fields("field\r"), fields("\rfield\r"))
        )
    )
    out.append(
        ReadCase("FieldCRCRLFCRCR", "§field\r\r\n¶§\r\rfield\r\r\n¶§\r\r").out(
            rows(fields("field\r"), fields("\r\rfield\r"), fields("\r"))
        )
    )
    out.append(
        ReadCase(
            "MultiFieldCRCRLFCRCR",
            "§field1,§field2\r\r\n¶§\r\rfield1,§field2\r\r\n¶§\r\r,§",
        ).out(
            rows(
                fields("field1", "field2\r"),
                fields("\r\rfield1", "field2\r"),
                fields("\r\r", ""),
            )
        )
    )
    out.append(
        ReadCase("NonASCIICommaAndComment", "§a£§b,c£ \t§d,e\n€ comment\n")
        .out(rows(fields("a", "b,c", "d,e")))
        .trimmed()
        .comma_is(_POUND)
        .comment_is(_EURO)
    )
    out.append(
        ReadCase(
            "NonASCIICommaAndCommentWithQuotes", '§a€§"  b,"€§ c\nλ comment\n'
        )
        .out(rows(fields("a", "  b,", " c")))
        .comma_is(_EURO)
        .comment_is(_LAMBDA)
    )
    # Lambda and theta start with the same byte, and this checks that the
    # parser does not confuse the two.
    out.append(
        ReadCase("NonASCIICommaConfusion", '§"abθcd"λ§efθgh')
        .out(rows(fields("abθcd", "efθgh")))
        .comma_is(_LAMBDA)
        .comment_is(_EURO)
    )
    out.append(
        ReadCase("NonASCIICommentConfusion", "§λ\n¶§λ\nθ\n¶§λ\n")
        .out(rows(fields("λ"), fields("λ"), fields("λ")))
        .comment_is(_THETA)
    )
    out.append(
        ReadCase("QuotedFieldMultipleLF", '§"\n\n\n\n"').out(
            rows(fields("\n\n\n\n"))
        )
    )
    out.append(ReadCase("MultipleCRLF", "\r\n\r\n\r\n\r\n"))
    # A line longer than the buffer is read in several goes, and this is the
    # row that takes that path.
    out.append(
        ReadCase(
            "HugeLines",
            repeat("#ignore\n", 10000)
            + "§"
            + repeat("@", 5000)
            + ",§"
            + repeat("*", 5000),
        )
        .out(rows(fields(repeat("@", 5000), repeat("*", 5000))))
        .comment_is(Int32(ord("#")))
    )
    out.append(
        ReadCase("QuoteWithTrailingCRLF", '§"foo∑"bar"\r\n').fails(
            codes(ErrQuote)
        )
    )
    out.append(
        ReadCase("LazyQuoteWithTrailingCRLF", '§"foo"bar"\r\n')
        .out(rows(fields('foo"bar')))
        .lazy()
    )
    out.append(
        ReadCase("DoubleQuoteWithTrailingCRLF", '§"foo""bar"\r\n').out(
            rows(fields('foo"bar'))
        )
    )
    out.append(ReadCase("EvenQuotes", '§""""""""').out(rows(fields('"""'))))
    out.append(ReadCase("OddQuotes", '§"""""""∑').fails(codes(ErrQuote)))
    out.append(
        ReadCase("LazyOddQuotes", '§"""""""').out(rows(fields('"""'))).lazy()
    )
    return out^


def _delim_cases() -> List[ReadCase]:
    """The eight rows that refuse a delimiter before reading anything."""
    var out = List[ReadCase]()
    out.append(
        ReadCase("BadComma1", "")
        .comma_is(Int32(ord("\n")))
        .fails(codes(ErrInvalidDelim))
    )
    out.append(
        ReadCase("BadComma2", "")
        .comma_is(Int32(ord("\r")))
        .fails(codes(ErrInvalidDelim))
    )
    out.append(
        ReadCase("BadComma3", "")
        .comma_is(Int32(ord('"')))
        .fails(codes(ErrInvalidDelim))
    )
    out.append(
        ReadCase("BadComma4", "")
        .comma_is(RUNE_ERROR)
        .fails(codes(ErrInvalidDelim))
    )
    out.append(
        ReadCase("BadComment1", "")
        .comment_is(Int32(ord("\n")))
        .fails(codes(ErrInvalidDelim))
    )
    out.append(
        ReadCase("BadComment2", "")
        .comment_is(Int32(ord("\r")))
        .fails(codes(ErrInvalidDelim))
    )
    out.append(
        ReadCase("BadComment3", "")
        .comment_is(RUNE_ERROR)
        .fails(codes(ErrInvalidDelim))
    )
    out.append(
        ReadCase("BadCommaComment", "")
        .comma_is(Int32(ord("X")))
        .comment_is(Int32(ord("X")))
        .fails(codes(ErrInvalidDelim))
    )
    return out^


def read_cases() raises -> List[ReadCase]:
    """Go's `readTests`, in Go's order."""
    var out = _simple_cases()
    out.extend(_quote_cases())
    out.extend(_comma_cases())
    out.extend(_return_cases())
    out.extend(_delim_cases())
    return out^
