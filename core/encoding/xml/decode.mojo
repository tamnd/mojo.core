"""Reading a document a token at a time. Go's `Decoder`, the token half.

Two ways to read the same bytes. `raw_token` hands back what the document says,
tag by tag, and checks nothing beyond the document being well formed. `token`
hands back the same tokens with the start and end elements matched against each
other and the name space prefixes turned into the URLs they were declared as.
Almost every caller wants `token`; `raw_token` is for a program rewriting a
document that has to write back the prefixes it read.

The parser is one byte at a time through a buffer, which is Go's arrangement
and is not a performance mistake: XML is a format where the meaning of a byte
depends on the four before it, and every attempt to read it in blocks ends up
reconstructing the same state machine with more places to be wrong.

## What it will not do

No document type definition is parsed. A `<!DOCTYPE ...>` arrives as a
`Directive` holding its own text and nothing in it is acted on, which is Go's
decision and is what makes the two classic attacks on an XML parser impossible
here rather than merely guarded against. A document cannot declare an entity,
so a billion laughs expansion has nothing to expand, and `&lol1;` in the body
is an entity nobody defined and raises. A document cannot name an external
file, so nothing is ever fetched.

The one thing added is `max_depth`. Go caps nesting at ten thousand inside
`Unmarshal`, where the recursion is real, and does not cap the token path at
all, because that one is a loop over a heap allocated stack and Go is content
to let it grow. A decoder here refuses to nest deeper than `max_depth`, so a
document that is nothing but a hundred million open tags is refused early
instead of being allowed to allocate a stack the size of itself.
"""

from core.bufio import Reader as BufReader
from core.bufio import new_reader as new_buffered
from core.errors import Report, matches
from core.errors.codes import EOF, ErrXMLCharset, ErrXMLDepth, ErrXMLVersion
from core.io import Byte, Reader as IoReader
from core.iter import Cursor
from core.strconv import parse_uint, quote
from core.strings import count, cut, equal_fold, index, index_byte
from core.unicode.utf8 import MAX_RUNE, RUNE_ERROR, RUNE_SELF, decode_rune

from .escape import is_in_character_range
from .syntax import _syntax_error
from .token import (
    Attr,
    CharData,
    Comment,
    Directive,
    END_ELEMENT,
    EndElement,
    Name,
    ProcInst,
    START_ELEMENT,
    StartElement,
    Token,
    _as_text,
    _is_name,
)

comptime _XML_URL = "http://www.w3.org/XML/1998/namespace"
"""The one name space every document has whether it says so or not."""

comptime _XMLNS_PREFIX = "xmlns"
"""The attribute prefix that declares a name space."""

comptime _XML_PREFIX = "xml"
"""The prefix bound to `_XML_URL` in every document, undeclared."""

comptime _DEFAULT_MAX_DEPTH = 10000
"""How deep elements may nest before the decoder refuses.

Go's `maxUnmarshalDepth`, which it applies to `Unmarshal` and not to the token
path. Ten thousand rather than a smaller number because it has to be above
anything a real document does, and a document a thousand elements deep is
already something nobody wrote by hand.
"""

comptime _STK_START = 0
"""A stack frame for an element that is open."""

comptime _STK_NS = 1
"""A stack frame remembering what a name space prefix meant before."""

comptime _TAB = Byte(ord("\t"))
comptime _NL = Byte(ord("\n"))
comptime _CR = Byte(ord("\r"))
comptime _SPACE = Byte(ord(" "))
comptime _AMP = Byte(ord("&"))
comptime _LT = Byte(ord("<"))
comptime _GT = Byte(ord(">"))
comptime _SLASH = Byte(ord("/"))
comptime _EQUALS = Byte(ord("="))
comptime _HASH = Byte(ord("#"))
comptime _SEMI = Byte(ord(";"))
comptime _DQUOTE = Byte(ord('"'))
comptime _SQUOTE = Byte(ord("'"))
comptime _DASH = Byte(ord("-"))
comptime _BANG = Byte(ord("!"))
comptime _QUERY = Byte(ord("?"))
comptime _LBRACK = Byte(ord("["))
comptime _RBRACK = Byte(ord("]"))


def _is_name_byte(c: Byte) -> Bool:
    """Whether `c` may appear in a name, judged one byte at a time.
    Go's `isNameByte`.

    Deliberately loose. It answers for the ASCII half only and the caller
    checks the whole name afterwards, because a name may hold multi byte
    characters and deciding those here would mean decoding while reading.
    """
    return (
        (c >= Byte(ord("A")) and c <= Byte(ord("Z")))
        or (c >= Byte(ord("a")) and c <= Byte(ord("z")))
        or (c >= Byte(ord("0")) and c <= Byte(ord("9")))
        or c == Byte(ord("_"))
        or c == Byte(ord(":"))
        or c == Byte(ord("."))
        or c == _DASH
    )


def _builtin_entity(name: StringSlice) -> String:
    """The five entities every parser recognises, or empty for anything else.

    The specification requires these five whether or not a document declares
    them, and they are the reason `Decoder.entity` starts empty rather than
    starting with them in it: a caller who assigns a table of their own does
    not thereby lose `&amp;`.
    """
    if name == "lt":
        return "<"
    if name == "gt":
        return ">"
    if name == "amp":
        return "&"
    if name == "apos":
        return "'"
    if name == "quot":
        return '"'
    return ""


def _code_point(r: Int32) -> String:
    """`r` as `U+0041`. Go's `%U` verb, which `core.fmt` does not have.

    Four hex digits at least, upper case, which is what Go prints and is what
    the specification writes code points as.
    """
    comptime digits = "0123456789ABCDEF"
    var out = String()
    var n = Int(r)
    while n > 0:
        out = String(digits[codepoint=n & 15]) + out
        n >>= 4
    while out.byte_length() < 4:
        out = "0" + out
    return "U+" + out


def _proc_inst[
    o1: ImmOrigin, o2: ImmOrigin
](param: StringSlice[o1], s: StringSlice[o2]) -> String:
    """The `param="..."` value out of a processing instruction, or empty.
    Go's `procInst`.

    Go's own comment calls this parsing lame and not exact, and says it works
    for every case that occurs. It is kept as it is rather than improved,
    because the only thing it reads is the XML declaration and a decoder that
    disagreed with Go about what a declaration says would accept documents Go
    refuses.
    """
    var want = String(param) + "="
    var lenp = want.byte_length()
    var n = s.byte_length()
    var i = 0
    var sep = Byte(0)
    while i < n:
        var sub = s[byte=i:n]
        var k = index(sub, want)
        if k < 0 or lenp + k >= sub.byte_length():
            return ""
        i += lenp + k + 1
        var c = sub.as_bytes()[lenp + k]
        if c == _SQUOTE or c == _DQUOTE:
            sep = c
            break
    if sep == 0:
        return ""
    var j = index_byte(s[byte=i:n], sep)
    if j < 0:
        return ""
    return String(s[byte = i : i + j])


struct _Frame(Copyable, Movable):
    """One entry of the parser's stack. Go's `stack`.

    Go writes it as a linked list with a free list hanging off the decoder, so
    that a deep document does not allocate a node per element more than once.
    A `List` here does the same job: it grows to the depth of the document and
    stays that size, and pushing is an append onto memory it already has.
    """

    var kind: Int
    """`_STK_START` for an open element, `_STK_NS` for a saved translation."""

    var name: Name
    """The element name, or the prefix and its old URL for an `_STK_NS`."""

    var ok: Bool
    """For an `_STK_NS`, whether the prefix had a meaning before this element.
    Undoing is putting the old meaning back when it did and removing the
    prefix when it did not, and those are different operations."""

    def __init__(out self, kind: Int, name: Name, ok: Bool):
        self.kind = kind
        self.name = name
        self.ok = ok


struct Decoder[R: IoReader & Deinitable & Movable](Movable):
    """A parser reading one document. Go's `Decoder`.

    ```mojo
    from core.bytes import new_buffer_string
    from core.encoding.xml import CHAR_DATA, START_ELEMENT, new_decoder

    def main() raises:
        var d = new_decoder(new_buffer_string("<greet>hello</greet>"))
        var t = d.token()
        print(t.name.local)  # greet
        print(d.token().text())  # hello
    ```

    The input has to be UTF-8. A document declaring any other encoding is
    refused rather than converted, which is what Go does when its
    `CharsetReader` is nil, and that field is not here because it hands back a
    reader chosen at run time and there is no existential reader type to hand
    back. The deviations page has the row.

    Not `Copyable`. Two decoders over one source would each read bytes the
    other needed, which is why `bufio.Reader` is not copyable either.
    """

    var strict: Bool
    """Whether the document has to be well formed XML. Go's `Strict`.

    True unless changed. Setting it false forgives the two mistakes HTML is
    full of: an element with no end tag, which is invented as needed, and an
    entity that is not one, which is left in the text as it was written. It
    does not forgive anything about name spaces, and an undeclared prefix is
    recorded as its own URL in both modes.

    ```mojo
    from core.bytes import new_buffer_string
    from core.encoding.xml import html_auto_close, html_entity, new_decoder

    def main() raises:
        var d = new_decoder(new_buffer_string("<p>caf&eacute;<br><p>x"))
        d.strict = False
        d.auto_close = html_auto_close()
        d.entity = html_entity()
        _ = d.token()
    ```

    Those three lines are the whole of reading typical HTML with this package,
    and they are the three Go's own documentation gives.
    """

    var auto_close: List[String]
    """Elements to treat as closed the moment they are opened. Go's
    `AutoClose`.

    Only consulted when `strict` is false. `html_auto_close()` is the HTML 4
    list, and the names are matched without regard to case.
    """

    var entity: Dict[String, String]
    """Extra entity names and what they expand to. Go's `Entity`.

    Empty unless assigned, and the five the specification requires are
    recognised either way. `html_entity()` is the HTML 4 table.

    Every value is text that is used as it stands and never scanned again, so
    an entry cannot refer to another entry and a table of any size expands to
    at most its own size. That is why there is no expansion limit here to go
    with the depth limit: there is nothing that could expand twice.
    """

    var default_space: String
    """The name space for names written with no prefix. Go's `DefaultSpace`.

    As if the whole document were inside an element carrying
    `xmlns="default_space"`. Empty unless assigned, which means an unprefixed
    name has no name space, and that is what a document without an `xmlns`
    means.
    """

    var max_depth: Int
    """How deep elements may nest before `token` refuses. Go has no
    counterpart on this path.

    Ten thousand unless changed, which is the number Go uses inside
    `Unmarshal`. Set it higher for a document that really is deeper; set it
    lower when the documents are yours and you know how deep they go.
    `raw_token` is not affected, because it keeps no stack and a document of
    nothing but open tags costs it nothing.
    """

    var r: BufReader[Self.R]
    """The source, with a buffer in front of it. Owned, so the call is direct.
    """

    var _buf: List[Byte]
    """Scratch for the token being read. One buffer for the whole document,
    which is where the parser's speed comes from and why a token has to be
    copied out of it before the next call. Every token this hands back owns its
    bytes, so that copying has already happened by the time a caller sees one.
    """

    var _stk: List[_Frame]
    """Open elements, with the name space translations they overrode."""

    var _depth: Int
    """How many `_STK_START` frames are on the stack, kept rather than counted
    because `max_depth` is checked on every start element."""

    var _need_close: Bool
    """Whether a `<br/>` was read and its end half has still to be handed
    back."""

    var _to_close: Name
    """The name of that end half."""

    var _next_token: Optional[Token]
    """A token read ahead of an invented end tag, waiting its turn. Only ever
    set when `strict` is false."""

    var _entity_at: Int
    """Where on the buffer the `&` of the reference being read sits.

    Set by `_entity` and read by `_text`, which is the one that builds the
    message when the reference turns out not to be one. Go keeps it as a local
    because the two are one function there.
    """

    var _next_byte: Int
    """One byte of pushback, or a negative number for none.

    Go's `nextByte`, and separate from the buffered reader's own pushback
    because the parser ungets bytes it never read: `text` pushes a `<` back so
    that the next call reads a tag.
    """

    var _ns: Dict[String, String]
    """What each prefix currently means. Go's `ns`."""

    var _err: Optional[Error]
    """The failure this decoder is stuck on, if any.

    Once set it stays set, so every later call reports the same thing rather
    than trying to carry on from a position it does not understand. The end of
    the input lives here too, which is why reading past the end goes on raising
    `EOF` instead of starting again.
    """

    var _line: Int
    """The line the parser is on, counting from one."""

    var _line_start: Int
    """The offset that line began at, for `input_pos`."""

    var _offset: Int
    """How many bytes have been consumed, for `input_offset`."""

    def __init__(out self, var r: Self.R):
        """Read `r` as a document. Go's `NewDecoder`, with Go's defaults."""
        self.strict = True
        self.auto_close = List[String]()
        self.entity = Dict[String, String]()
        self.default_space = String()
        self.max_depth = _DEFAULT_MAX_DEPTH
        self.r = new_buffered(r^)
        self._buf = List[Byte]()
        self._stk = List[_Frame]()
        self._depth = 0
        self._need_close = False
        self._to_close = Name("", "")
        self._next_token = None
        self._entity_at = 0
        self._next_byte = -1
        self._ns = Dict[String, String]()
        self._err = None
        self._line = 1
        self._line_start = 0
        self._offset = 0

    def input_offset(self) -> Int:
        """How many bytes have been read. Go's `InputOffset`.

        The end of the token just handed back and the start of the next one.
        Go returns an `int64` and this returns an `Int`, which is the same
        width on every platform this builds for.
        """
        return self._offset

    def input_pos(self) -> Tuple[Int, Int]:
        """The line and column the parser is at. Go's `InputPos`.

        Both count from one. The column is a byte offset into the line rather
        than a character offset, which is Go's rule and is what lets a caller
        index the line they still have in hand.
        """
        return (self._line, self._offset - self._line_start + 1)

    def _stuck(mut self, var e: Error) -> Error:
        """Remember `e` as the failure and hand it back to be raised.

        Every raise in this file goes through here, so there is no way to
        report a failure and leave the decoder willing to carry on from a
        position it does not understand.
        """
        self._err = e.copy()
        return e^

    def _getc(mut self) -> Optional[Byte]:
        """One byte, or nothing. Go's `getc`.

        Nothing means the failure is on `_err`, which is either the end of the
        input or something the reader said. Does not raise, because Go's
        version does not either and half the parser is written around checking
        the flag rather than catching.
        """
        if self._err:
            return None
        var b: Byte
        if self._next_byte >= 0:
            b = Byte(self._next_byte)
            self._next_byte = -1
        else:
            try:
                b = self.r.read_byte()
            except e:
                self._err = e
                return None
        if b == _NL:
            self._line += 1
            self._line_start = self._offset + 1
        self._offset += 1
        return b

    def _mustgetc(mut self) -> Optional[Byte]:
        """One byte, where the end of the input is a malformed document.
        Go's `mustgetc`.

        Everywhere the parser is in the middle of something, a `<` with no `>`
        after it is not an orderly end and should not be reported as one.
        """
        var b = self._getc()
        if not b and self._err and matches(self._err.value(), EOF):
            self._err = _syntax_error("unexpected EOF", self._line)
        return b

    def _ungetc(mut self, b: Byte):
        """Put `b` back. Go's `ungetc`."""
        if b == _NL:
            self._line -= 1
        self._next_byte = Int(b)
        self._offset -= 1

    def _space(mut self):
        """Skip whatever whitespace is next. Go's `space`."""
        while True:
            var got = self._getc()
            if not got:
                return
            var b = got.value()
            if b == _SPACE or b == _CR or b == _NL or b == _TAB:
                continue
            self._ungetc(b)
            return

    def _read_name(mut self) -> Bool:
        """Read a name onto the scratch buffer. Go's `readName`.

        Stops at the first single byte character that cannot be in a name.
        Every multi byte character is taken, and whether it was allowed is
        `_name`'s question rather than this one's.

        Does not record a failure when there is simply no name here, so that
        the caller can say what it was expecting one for.
        """
        var got = self._mustgetc()
        if not got:
            return False
        var b = got.value()
        if Int(b) < RUNE_SELF and not _is_name_byte(b):
            self._ungetc(b)
            return False
        self._buf.append(b)
        while True:
            got = self._mustgetc()
            if not got:
                return False
            b = got.value()
            if Int(b) < RUNE_SELF and not _is_name_byte(b):
                self._ungetc(b)
                break
            self._buf.append(b)
        return True

    def _name(mut self) -> Optional[String]:
        """The next name, checked against the specification. Go's `name`."""
        self._buf.clear()
        if not self._read_name():
            return None
        if not _is_name(Span(self._buf)):
            var bad = _as_text(Span(self._buf))
            self._err = _syntax_error("invalid XML name: " + bad, self._line)
            return None
        return _as_text(Span(self._buf))

    def _nsname(mut self) -> Optional[Name]:
        """The next name, split at its colon. Go's `nsname`.

        A name with two colons in it is not a name and comes back as nothing.
        A name with a colon at either end is a name with a colon in it and no
        prefix, which is what Go decides and is worth knowing because it means
        `<:a>` parses.
        """
        var got = self._name()
        if not got:
            return None
        var s = got.value()
        if count(s, ":") > 1:
            return None
        var parts = cut(s, ":")
        if (
            not parts[2]
            or parts[0].byte_length() == 0
            or parts[1].byte_length() == 0
        ):
            return Name("", s)
        return Name(parts[0], parts[1])

    def _text(mut self, quote_byte: Int, cdata: Bool) raises -> List[Byte]:
        """A run of character data, with the entities expanded. Go's `text`.

        `quote_byte` is the quote to stop at when this is an attribute value,
        or negative in a document body. `cdata` says the run is inside a
        `<![CDATA[` section, where nothing is an entity and the only thing that
        ends it is `]]>`.

        Go writes this with a labelled break out of the entity handling.
        There are no labels in Mojo and none are needed, because everything
        that breaks or continues the outer loop is in the loop body rather than
        in a nested loop.
        """
        var b0 = Byte(0)
        var b1 = Byte(0)
        var trunc = 0
        self._buf.clear()
        while True:
            var got = self._getc()
            if not got:
                if cdata:
                    if self._err and matches(self._err.value(), EOF):
                        self._err = _syntax_error(
                            "unexpected EOF in CDATA section", self._line
                        )
                    raise self._err.value()
                break
            var b = got.value()

            # `]]>` ends a CDATA section, and outside one it is forbidden
            # rather than merely odd, because a document holding it cannot be
            # embedded in another. Inside a quoted attribute value it is data.
            if quote_byte < 0 and b0 == _RBRACK and b1 == _RBRACK and b == _GT:
                if cdata:
                    trunc = 2
                    break
                raise self._stuck(
                    _syntax_error(
                        "unescaped ]]> not in CDATA section", self._line
                    )
                )

            if b == _LT and not cdata:
                if quote_byte >= 0:
                    raise self._stuck(
                        _syntax_error(
                            "unescaped < inside quoted string", self._line
                        )
                    )
                self._ungetc(_LT)
                break
            if quote_byte >= 0 and b == Byte(quote_byte):
                break

            if b == _AMP and not cdata:
                if self._entity(b0, b1):
                    b0 = 0
                    b1 = 0
                    continue
                # The reference was not one and `strict` is set, so the text
                # of it is on the buffer and is what the message quotes.
                var before = self._entity_at
                var ent = _as_text(Span(self._buf)[before : len(self._buf)])
                if not ent.endswith(";"):
                    ent += " (no semicolon)"
                raise self._stuck(
                    _syntax_error("invalid character entity " + ent, self._line)
                )

            # A raw carriage return is a newline and a raw `\r\n` is one
            # newline, which the specification requires of every parser and is
            # why a document written on Windows reads the same as one written
            # on Linux.
            if b == _CR:
                self._buf.append(_NL)
            elif b1 == _CR and b == _NL:
                pass
            else:
                self._buf.append(b)

            b0 = b1
            b1 = b

        var data = List[Byte](Span(self._buf)[0 : len(self._buf) - trunc])

        # Every rune, checked for being something a document may hold at all.
        # This is the last gate before bytes reach a caller, so a `CharData`
        # out of a decoder is always valid UTF-8 and always inside the
        # character range.
        var i = 0
        while i < len(data):
            var decoded = decode_rune(Span(data)[i : len(data)])
            var r = decoded[0]
            var size = decoded[1]
            if r == RUNE_ERROR and size == 1:
                raise self._stuck(_syntax_error("invalid UTF-8", self._line))
            i += size
            if not is_in_character_range(r):
                raise self._stuck(
                    _syntax_error(
                        "illegal character code " + _code_point(r), self._line
                    )
                )
        return data^

    def _entity(mut self, b0: Byte, b1: Byte) raises -> Bool:
        """Read one `&...;` and expand it onto the buffer. Part of Go's `text`.

        The `&` has been read and nothing has been written for it yet. True
        means the buffer now holds what the reference stood for, or that
        `strict` is unset and the reference has been left as it was written.
        False means it was not a reference and the caller is to complain, with
        `_entity_at` marking where on the buffer its text starts.

        Split out of `_text` because Go's version is a hundred lines inside a
        loop inside a switch, and because the security argument for this
        package is a paragraph about this function: an entity expands to text
        that is never scanned again, so nothing here can expand twice and
        there is no bound to enforce.
        """
        var before = len(self._buf)
        self._entity_at = before
        self._buf.append(_AMP)
        var text = String()
        var have_text = False

        var got = self._mustgetc()
        if not got:
            raise self._err.value()
        var b = got.value()

        if b == _HASH:
            # A numeric reference: `&#65;` or `&#x41;`.
            self._buf.append(b)
            got = self._mustgetc()
            if not got:
                raise self._err.value()
            b = got.value()
            var base = 10
            if b == Byte(ord("x")):
                base = 16
                self._buf.append(b)
                got = self._mustgetc()
                if not got:
                    raise self._err.value()
                b = got.value()
            var start = len(self._buf)
            while _is_digit(b, base):
                self._buf.append(b)
                got = self._mustgetc()
                if not got:
                    raise self._err.value()
                b = got.value()
            if b != _SEMI:
                self._ungetc(b)
            else:
                var digits = _as_text(Span(self._buf)[start : len(self._buf)])
                self._buf.append(_SEMI)
                try:
                    var n = parse_uint(digits, base, 64)
                    if n <= UInt64(Int(MAX_RUNE)):
                        var r = Int(n)
                        # Go writes `string(rune(n))`, and a surrogate through
                        # that conversion comes out as the replacement
                        # character rather than as itself. Doing it here keeps
                        # the two in agreement, and a lone surrogate is not a
                        # character a document may hold anyway.
                        if r >= 0xD800 and r <= 0xDFFF:
                            r = 0xFFFD
                        text = chr(r)
                        have_text = True
                except:
                    pass
        else:
            # A named reference: `&amp;` or whatever the caller's table has.
            self._ungetc(b)
            if not self._read_name():
                if self._err:
                    raise self._err.value()
            got = self._mustgetc()
            if not got:
                raise self._err.value()
            b = got.value()
            if b != _SEMI:
                self._ungetc(b)
            else:
                var span = Span(self._buf)[before + 1 : len(self._buf)]
                var named = _is_name(span)
                var name = _as_text(span)
                self._buf.append(_SEMI)
                if named:
                    var built = _builtin_entity(name)
                    if built:
                        text = built
                        have_text = True
                    else:
                        var found = self.entity.get(name)
                        if found:
                            text = found.value()
                            have_text = True

        if have_text:
            # The reference is replaced by what it stood for, and what it
            # stood for is text. It is not read back, so it cannot hold
            # another reference and cannot expand a second time.
            self._buf.shrink(before)
            self._buf.extend(text.as_bytes())
            return True
        if not self.strict:
            # Left exactly as the document wrote it, which is what a browser
            # does with `&copy` in the middle of a sentence.
            return True
        return False

    def _attrval(mut self) raises -> List[Byte]:
        """One attribute value. Go's `attrval`."""
        var got = self._mustgetc()
        if not got:
            raise self._err.value()
        var b = got.value()
        if b == _DQUOTE or b == _SQUOTE:
            return self._text(Int(b), False)
        if self.strict:
            raise self._stuck(
                _syntax_error(
                    "unquoted or missing attribute value in element",
                    self._line,
                )
            )
        # An unquoted value, which HTML allows and XML does not. The run of
        # characters HTML 4 permits is narrower than a name, so this is its own
        # test rather than `_is_name_byte`.
        self._ungetc(b)
        self._buf.clear()
        while True:
            got = self._mustgetc()
            if not got:
                raise self._err.value()
            b = got.value()
            if (
                (b >= Byte(ord("a")) and b <= Byte(ord("z")))
                or (b >= Byte(ord("A")) and b <= Byte(ord("Z")))
                or (b >= Byte(ord("0")) and b <= Byte(ord("9")))
                or b == Byte(ord("_"))
                or b == Byte(ord(":"))
                or b == _DASH
            ):
                self._buf.append(b)
            else:
                self._ungetc(b)
                break
        return List[Byte](Span(self._buf))

    def raw_token(mut self) raises -> Token:
        """The next token, exactly as the document wrote it. Go's `RawToken`.

        Start and end elements are not matched against each other and prefixes
        are not turned into URLs, so `<a:b>` arrives with `a` as its space.
        Raises `EOF` at the end of the input, wherever that is, because
        this one has no idea whether anything is still open.

        Go refuses this call from inside an `UnmarshalXML` method, since the
        decoder is part way through a value there. There is no such method
        here, so there is nothing to refuse.
        """
        if self._err:
            raise self._err.value()
        if self._need_close:
            # The last thing read was a `<br/>` and only its start half has
            # been handed back.
            self._need_close = False
            return Token(EndElement(self._to_close))

        var got = self._getc()
        if not got:
            raise self._err.value()
        var b = got.value()

        if b != _LT:
            self._ungetc(b)
            var data = self._text(-1, False)
            return Token(CharData(data^))

        got = self._mustgetc()
        if not got:
            raise self._err.value()
        b = got.value()

        if b == _SLASH:
            return self._end_element()
        if b == _QUERY:
            return self._proc_inst_token()
        if b == _BANG:
            return self._bang()
        self._ungetc(b)
        return self._start_element()

    def _end_element(mut self) raises -> Token:
        """`</name>`, with the `</` already read."""
        var name = self._nsname()
        if not name:
            if not self._err:
                self._err = _syntax_error(
                    "expected element name after </", self._line
                )
            raise self._err.value()
        self._space()
        var got = self._mustgetc()
        if not got:
            raise self._err.value()
        if got.value() != _GT:
            raise self._stuck(
                _syntax_error(
                    "invalid characters between </"
                    + name.value().local
                    + " and >",
                    self._line,
                )
            )
        return Token(EndElement(name.value()))

    def _proc_inst_token(mut self) raises -> Token:
        """`<?target inst?>`, with the `<?` already read."""
        var target = self._name()
        if not target:
            if not self._err:
                self._err = _syntax_error(
                    "expected target name after <?", self._line
                )
            raise self._err.value()
        self._space()
        self._buf.clear()
        var b0 = Byte(0)
        while True:
            var got = self._mustgetc()
            if not got:
                raise self._err.value()
            var b = got.value()
            self._buf.append(b)
            if b0 == _QUERY and b == _GT:
                break
            b0 = b
        var data = List[Byte](Span(self._buf)[0 : len(self._buf) - 2])

        if target.value() == "xml":
            self._declaration(_as_text(Span(data)))
        return Token(ProcInst(target.value(), data^))

    def _declaration(mut self, content: String) raises:
        """Check the `<?xml ...?>` at the top of a document.

        Two things are refused. A version other than 1.0, because 1.1 changed
        the line ending rules and the name rules and neither is implemented
        here, so parsing it by these rules would be answering a question that
        was not asked. And an encoding other than UTF-8, because converting it
        would mean handing the decoder a different reader part way through and
        there is no reader type here to hand it. Go refuses the second one too
        whenever its `CharsetReader` is nil, which is its default.
        """
        var ver = _proc_inst("version", content)
        if ver and ver != "1.0":
            raise self._stuck(
                Report(
                    "xml: unsupported version "
                    + quote(ver)
                    + "; only version 1.0 is supported"
                )
                .with_code(ErrXMLVersion)
                .with_field("version", ver)
                .error()
            )
        var enc = _proc_inst("encoding", content)
        if enc and not equal_fold(enc, "utf-8"):
            raise self._stuck(
                Report(
                    "xml: encoding "
                    + quote(enc)
                    + " declared but only UTF-8 is supported"
                )
                .with_code(ErrXMLCharset)
                .with_field("encoding", enc)
                .error()
            )

    def _bang(mut self) raises -> Token:
        """`<!`, which is a comment, a CDATA section, or a directive."""
        var got = self._mustgetc()
        if not got:
            raise self._err.value()
        var b = got.value()

        if b == _DASH:
            return self._comment()
        if b == _LBRACK:
            return self._cdata()
        return self._directive(b)

    def _comment(mut self) raises -> Token:
        """`<!--...-->`, with `<!-` already read."""
        var got = self._mustgetc()
        if not got:
            raise self._err.value()
        if got.value() != _DASH:
            raise self._stuck(
                _syntax_error(
                    "invalid sequence <!- not part of <!--", self._line
                )
            )
        self._buf.clear()
        var b0 = Byte(0)
        var b1 = Byte(0)
        while True:
            got = self._mustgetc()
            if not got:
                raise self._err.value()
            var b = got.value()
            self._buf.append(b)
            if b0 == _DASH and b1 == _DASH:
                # A comment may not hold `--` at all, not even away from the
                # end, which is a rule of the specification that surprises
                # everybody and is what makes `<!-- a -- b -->` invalid.
                if b != _GT:
                    raise self._stuck(
                        _syntax_error(
                            'invalid sequence "--" not allowed in comments',
                            self._line,
                        )
                    )
                break
            b0 = b1
            b1 = b
        var data = List[Byte](Span(self._buf)[0 : len(self._buf) - 3])
        return Token(Comment(data^))

    def _cdata(mut self) raises -> Token:
        """`<![CDATA[...]]>`, with `<![` already read."""
        var want = StringSlice("CDATA[")
        for i in range(want.byte_length()):
            var got = self._mustgetc()
            if not got:
                raise self._err.value()
            if got.value() != want.as_bytes()[i]:
                raise self._stuck(
                    _syntax_error("invalid <![ sequence", self._line)
                )
        var data = self._text(-1, True)
        return Token(CharData(data^))

    def _directive(mut self, first: Byte) raises -> Token:
        """`<!...>`, a doctype most of the time, with `<!` and `first` read.

        Nothing in it is parsed. Angle brackets inside quotes do not count
        towards the nesting and a comment inside is dropped, and those two
        rules are the whole of what this understands about a document type
        definition. It does not read an entity declaration, so a document
        cannot teach this parser a new entity, which is why a billion laughs
        document is a directive followed by a raise rather than a memory
        exhaustion.
        """
        self._buf.clear()
        self._buf.append(first)
        var inquote = Byte(0)
        var depth = 0
        while True:
            var got = self._mustgetc()
            if not got:
                raise self._err.value()
            var b = got.value()
            if inquote == 0 and b == _GT and depth == 0:
                break

            # Go reaches this point again with a `goto` when a `<` turns out
            # not to start a comment. The loop below runs at most twice, once
            # for the `<` and once for whatever followed it.
            var handle = True
            while handle:
                handle = False
                self._buf.append(b)
                if b == inquote:
                    inquote = 0
                elif inquote != 0:
                    pass
                elif b == _SQUOTE or b == _DQUOTE:
                    inquote = b
                elif b == _GT:
                    depth -= 1
                elif b == _LT:
                    var opener = StringSlice("!--")
                    var matched = 0
                    while matched < opener.byte_length():
                        got = self._mustgetc()
                        if not got:
                            raise self._err.value()
                        b = got.value()
                        if b != opener.as_bytes()[matched]:
                            break
                        matched += 1
                    if matched < opener.byte_length():
                        for j in range(matched):
                            self._buf.append(opener.as_bytes()[j])
                        depth += 1
                        handle = True
                        continue
                    # Drop the `<` written just above and read to the `-->`.
                    self._buf.shrink(len(self._buf) - 1)
                    var b0 = Byte(0)
                    var b1 = Byte(0)
                    while True:
                        got = self._mustgetc()
                        if not got:
                            raise self._err.value()
                        b = got.value()
                        if b0 == _DASH and b1 == _DASH and b == _GT:
                            break
                        b0 = b1
                        b1 = b
                    # A space stands in for the comment, so that a `<` and a
                    # `!` that the comment kept apart are not joined into
                    # markup when the directive is written back out.
                    self._buf.append(_SPACE)
        return Token(Directive(List[Byte](Span(self._buf))))

    def _start_element(mut self) raises -> Token:
        """`<name attr="value">` or `<name/>`, with `<` already read."""
        var name = self._nsname()
        if not name:
            if not self._err:
                self._err = _syntax_error(
                    "expected element name after <", self._line
                )
            raise self._err.value()

        var attr = List[Attr]()
        var empty = False
        while True:
            self._space()
            var got = self._mustgetc()
            if not got:
                raise self._err.value()
            var b = got.value()
            if b == _SLASH:
                empty = True
                got = self._mustgetc()
                if not got:
                    raise self._err.value()
                if got.value() != _GT:
                    raise self._stuck(
                        _syntax_error("expected /> in element", self._line)
                    )
                break
            if b == _GT:
                break
            self._ungetc(b)

            var attr_name = self._nsname()
            if not attr_name:
                if not self._err:
                    self._err = _syntax_error(
                        "expected attribute name in element", self._line
                    )
                raise self._err.value()
            self._space()
            got = self._mustgetc()
            if not got:
                raise self._err.value()
            b = got.value()
            if b != _EQUALS:
                if self.strict:
                    raise self._stuck(
                        _syntax_error(
                            "attribute name without = in element", self._line
                        )
                    )
                # HTML's bare attribute, where `<input disabled>` means the
                # value is the name.
                self._ungetc(b)
                var bare = attr_name.value()
                var value = bare.local.copy()
                attr.append(Attr(bare, value))
            else:
                self._space()
                var data = self._attrval()
                attr.append(Attr(attr_name.value(), _as_text(Span(data))))

        if empty:
            self._need_close = True
            self._to_close = name.value()
        return Token(StartElement(name.value(), attr^))

    def _push(mut self, kind: Int, name: Name, ok: Bool):
        """Put a frame on the stack. Go's `push`."""
        if kind == _STK_START:
            self._depth += 1
        self._stk.append(_Frame(kind, name, ok))

    def _pop(mut self) -> Optional[_Frame]:
        """Take the top frame off. Go's `pop`."""
        if len(self._stk) == 0:
            return None
        var top = self._stk.pop()
        if top.kind == _STK_START:
            self._depth -= 1
        return Optional[_Frame](top^)

    def _translate(self, mut n: Name, is_element_name: Bool):
        """Turn a prefix into the URL it was declared as. Go's `translate`.

        The default name space applies to element names and not to attribute
        names, which is a rule of the name spaces recommendation and is the
        only reason this takes a flag. An attribute written with no prefix has
        no name space, whatever `xmlns` says.

        A prefix nobody declared is left as it is, so it becomes its own URL.
        That is Go's decision and its own documentation calls it out: strict
        mode does not enforce the name spaces recommendation, and a document
        using an undeclared prefix parses.
        """
        if n.space == _XMLNS_PREFIX:
            return
        if n.space == "" and not is_element_name:
            return
        if n.space == _XML_PREFIX:
            n.space = _XML_URL
        elif n.space == "" and n.local == _XMLNS_PREFIX:
            return
        var found = self._ns.get(n.space)
        if found:
            n.space = found.value()
        elif n.space == "":
            n.space = self.default_space

    def _pop_element(mut self, mut t: EndElement) raises:
        """Match an end element against what is open. Go's `popElement`."""
        var frame = self._pop()
        var name = t.name
        if not frame or frame.value().kind != _STK_START:
            raise self._stuck(
                _syntax_error(
                    "unexpected end element </" + name.local + ">", self._line
                )
            )
        var top = frame.value().name
        if top.local != name.local:
            if not self.strict:
                # The document closed something that is not what is open, so
                # the open one is closed here and the caller's end tag is held
                # back to be handed over next.
                self._need_close = True
                self._to_close = t.name
                t.name = top
                return
            raise self._stuck(
                _syntax_error(
                    "element <"
                    + top.local
                    + "> closed by </"
                    + name.local
                    + ">",
                    self._line,
                )
            )
        if top.space != name.space:
            var ns = name.space if name.space else String('""')
            raise self._stuck(
                _syntax_error(
                    "element <"
                    + top.local
                    + "> in space "
                    + top.space
                    + " closed by </"
                    + name.local
                    + "> in space "
                    + ns,
                    self._line,
                )
            )

        self._translate(t.name, True)

        # Undo every translation this element declared, in the order they were
        # made, so that a prefix means outside the element what it meant
        # before it.
        while (
            len(self._stk) > 0
            and self._stk[len(self._stk) - 1].kind != _STK_START
        ):
            var popped = self._pop()
            var undo_ok = popped.value().ok
            var undo_name = popped.value().name
            if undo_ok:
                self._ns[undo_name.local] = undo_name.space
            elif undo_name.local in self._ns:
                _ = self._ns.pop(undo_name.local)

    def _auto_close(self, t: Token) -> Optional[Token]:
        """The end tag to invent before `t`, if the open element wants one.
        Go's `autoClose`.
        """
        if (
            len(self._stk) == 0
            or self._stk[len(self._stk) - 1].kind != _STK_START
        ):
            return None
        var top = self._stk[len(self._stk) - 1].name
        for i in range(len(self.auto_close)):
            if equal_fold(self.auto_close[i], top.local):
                if t.kind != END_ELEMENT or not equal_fold(
                    t.name.local, top.local
                ):
                    return Token(EndElement(top))
                break
        return None

    def token(mut self) raises -> Token:
        """The next token, matched and with its name spaces resolved.
        Go's `Token`.

        Start and end elements are guaranteed to be properly nested: an end
        tag that closes the wrong element raises, and so does the end of the
        input with anything still open. A `<br/>` arrives as a start element
        and then an end element on the call after, so a caller counting depth
        never has to know which spelling the document used.

        Raises `EOF` when the document is finished. The failure is sticky, so
        a decoder that has raised once raises the same thing every time after.
        """
        var t: Token
        if self._next_token:
            t = self._next_token.take()
        else:
            try:
                t = self.raw_token()
            except e:
                # The end of the input with elements still open is a truncated
                # document rather than a finished one, and saying so is most of
                # what this method is for.
                if matches(e, EOF) and len(self._stk) > 0:
                    raise self._stuck(
                        _syntax_error("unexpected EOF", self._line)
                    )
                raise e

        if not self.strict:
            var invented = self._auto_close(t)
            if invented:
                self._next_token = t.copy()
                t = invented.take()

        if t.kind == START_ELEMENT:
            # The declarations on this element apply to its own name and to
            # its own attributes, so they are recorded before anything is
            # translated.
            for i in range(len(t.attr)):
                var a_name = t.attr[i].name
                var a_value = t.attr[i].value
                if a_name.space == _XMLNS_PREFIX:
                    self._save_ns(a_name.local)
                    self._ns[a_name.local] = a_value
                if a_name.space == "" and a_name.local == _XMLNS_PREFIX:
                    self._save_ns("")
                    self._ns[String("")] = a_value

            if self._depth >= self.max_depth:
                raise self._stuck(
                    Report(
                        "xml: element nested more than "
                        + String(self.max_depth)
                        + " deep"
                    )
                    .with_code(ErrXMLDepth)
                    .with_field("max_depth", String(self.max_depth))
                    .error()
                )
            self._push(_STK_START, t.name, False)
            self._translate(t.name, True)
            for i in range(len(t.attr)):
                self._translate(t.attr[i].name, False)
        elif t.kind == END_ELEMENT:
            var end = EndElement(t.name)
            self._pop_element(end)
            t.name = end.name
        return t^

    def _save_ns(mut self, local: StringSlice):
        """Remember what `local` meant, so closing the element can put it back.
        Go's `pushNs`.
        """
        var old = self._ns.get(String(local))
        if old:
            self._push(_STK_NS, Name(old.value(), local), True)
        else:
            self._push(_STK_NS, Name("", local), False)

    def skip(mut self) raises:
        """Read to the end of the element that is open. Go's `Skip`.

        Everything nested inside is read and thrown away, and the call returns
        with the matching end element consumed. Raises whatever `token` raises,
        which includes the end of the input arriving first.
        """
        var depth = 0
        while True:
            var t = self.token()
            if t.kind == START_ELEMENT:
                depth += 1
            elif t.kind == END_ELEMENT:
                if depth == 0:
                    return
                depth -= 1

    def tokens(mut self) -> Tokens[Self.R, origin_of(self)]:
        """The tokens left, as a `core.iter.Cursor`. Go has no counterpart.

        Go's loop is a `Token` and a comparison against `io.EOF`, and the whole
        of that loop's correctness is in the comparison: leave it out and a
        malformed document ends the loop quietly and reports nothing.
        design.md section 7 says a fallible sequence is a `Cursor` here, and
        this is why.

        The decoder is usable afterwards, so taking a few tokens through a
        cursor and reading the rest with `token` is fine.
        """
        return Tokens[Self.R, origin_of(self)](self)


struct Tokens[R: IoReader & Deinitable & Movable, o: MutOrigin](
    Cursor, Movable
):
    """A cursor over the tokens left in a decoder. Go has no counterpart.

    ```mojo
    from core.bytes import new_buffer_string
    from core.encoding.xml import START_ELEMENT, new_decoder

    def main() raises:
        var d = new_decoder(new_buffer_string("<a><b/></a>"))
        var tokens = d.tokens()
        var starts = 0
        while tokens.has_next():
            if tokens.next().kind == START_ELEMENT:
                starts += 1
        print(starts)  # 2
    ```

    It holds a pointer at the decoder rather than the decoder itself, the same
    arrangement `sort.Reverse` has and for the same reason: a copy would be
    read to the end and the caller's decoder would be left where it was.

    A malformed document raises out of whichever of the two calls found it, so
    a loop that ignores failures does not compile and one that catches them
    says which token it was on.
    """

    comptime Element = Token

    var inner: Pointer[Decoder[Self.R], Self.o]
    """The decoder being walked. Nothing is copied and nothing is owned."""

    var pending: Optional[Token]
    """The token `has_next` read in order to answer, waiting for `next`."""

    var done: Bool
    """Whether the end of the document has been reached.

    Kept so that `has_next` goes on answering `False` once it has, which is the
    first of the trait's three rules.
    """

    def __init__(out self, ref[Self.o] d: Decoder[Self.R]):
        """Points at `d`. Reading starts wherever `d` currently is."""
        self.inner = Pointer(to=d)
        self.pending = None
        self.done = False

    def has_next(mut self) raises -> Bool:
        """Whether another token is available, by reading one to find out.

        There is no way to know a document has another token without parsing
        one. The end of the input is not a failure and is the answer `False`;
        anything else raises here, so a malformed document cannot be mistaken
        for the end of one.
        """
        if self.done:
            return False
        if self.pending:
            return True
        try:
            self.pending = self.inner[].token()
        except e:
            if matches(e, EOF):
                self.done = True
                return False
            raise e
        return True

    def next(mut self) raises -> Token:
        """The next token, moved out. Raises `EOF` past the last one."""
        if not self.has_next():
            raise (
                Report("xml: read past the last token").with_code(EOF).error()
            )
        var got = self.pending.take()
        return got^


def new_decoder[R: IoReader & Deinitable & Movable](var r: R) -> Decoder[R]:
    """A decoder over `r`. Go's `NewDecoder`.

    Go takes an `io.Reader` interface and this takes the concrete type, so the
    call through the buffer is direct. `core.io.AnyReader` is the way to hold
    one of several sources in the same variable.

    Go's version checks whether `r` is already an `io.ByteReader` and skips its
    own buffering when it is. The buffer here is unconditional, because a
    `bufio.Reader` wrapped in another one is a case the type system can see and
    a caller has no reason to write.
    """
    return Decoder[R](r^)


def _is_digit(b: Byte, base: Int) -> Bool:
    """Whether `b` is a digit in `base`, where base is ten or sixteen."""
    if b >= Byte(ord("0")) and b <= Byte(ord("9")):
        return True
    if base != 16:
        return False
    return (b >= Byte(ord("a")) and b <= Byte(ord("f"))) or (
        b >= Byte(ord("A")) and b <= Byte(ord("F"))
    )
