"""Writing a document a token at a time. Go's `Encoder`, the token half.

`encode_token` takes any of the six tokens and writes it out, checking the two
things a stream of tokens can get wrong: that every start element is matched by
an end element with the same name, and that no token carries bytes that would
read back as markup. A comment holding `-->` and a directive with unbalanced
angle brackets are refused rather than written, because writing them would
produce a document that does not parse back to what was written.

Everything is buffered, so `flush` or `close` has to be called before the bytes
reach the writer. `close` is the one to prefer: it flushes and then says
whether anything was left open, and an encoder that is never closed can produce
a truncated document without complaining.

Go's other half, `Encode` and `EncodeElement`, turns a struct into elements by
reflecting over its fields. That is not here yet; `docs/packages.md` says which
symbols are outstanding and what they are waiting on.
"""

from core.bufio import Writer as BufWriter
from core.bufio import new_writer as new_buffered
from core.bytes import index as index_bytes
from core.errors import Report
from core.errors.codes import ErrXMLEncode
from core.io import Byte, Writer as IoWriter
from core.strings import contains, equal_fold, last_index, trim_right

from .decode import _DQUOTE, _GT, _LT, _SQUOTE, _XML_PREFIX, _XML_URL
from .escape import _escape, escape_text
from .token import (
    Attr,
    CHAR_DATA,
    COMMENT,
    DIRECTIVE,
    END_ELEMENT,
    Name,
    PROC_INST,
    START_ELEMENT,
    Token,
    _is_name,
    _is_name_string,
)

comptime HEADER = '<?xml version="1.0" encoding="UTF-8"?>\n'
"""The declaration to put at the top of a document. Go's `Header`.

Nothing writes it for you, here or in Go. It is a constant because almost every
document starts with these exact bytes and nobody should have to remember the
order of the two attributes.

Go spells it `Header` and this spells it `HEADER`, which is what the naming
rules make of an exported constant. `tools/parity/renames.toml` has the row.
"""

comptime _BEG_COMMENT = "<!--"
"""What opens a comment, which a directive is allowed to contain."""

comptime _END_COMMENT = "-->"
"""What closes one, which a comment is not allowed to contain."""

comptime _END_PROC_INST = "?>"
"""What closes a processing instruction, likewise."""


def _is_valid_directive[o: Origin](dir: Span[Byte, o]) -> Bool:
    """Whether `dir` can be written between `<!` and `>` and read back.
    Go's `isValidDirective`.

    Angle brackets have to balance, and the ones inside a comment or inside
    quotes do not count towards the balance. That is the whole check: the
    contents are not parsed here any more than they are when reading, so a
    doctype that is nonsense but balanced goes out as it was given.
    """
    var depth = 0
    var inquote = Byte(0)
    var incomment = False
    var opening = _BEG_COMMENT.as_bytes()
    var closing = _END_COMMENT.as_bytes()
    for i in range(len(dir)):
        var c = dir[i]
        if incomment:
            if c == _GT:
                var n = 1 + i - len(closing)
                if n >= 0 and dir[n : i + 1] == closing:
                    incomment = False
        elif inquote != 0:
            if c == inquote:
                inquote = 0
        elif c == _SQUOTE or c == _DQUOTE:
            inquote = c
        elif c == _LT:
            if (
                i + len(opening) < len(dir)
                and dir[i : i + len(opening)] == opening
            ):
                incomment = True
            else:
                depth += 1
        elif c == _GT:
            if depth == 0:
                return False
            depth -= 1
    return depth == 0 and inquote == 0 and not incomment


def _encode_error(msg: StringSlice) -> Error:
    """The raise for a stream of tokens that cannot be written."""
    return Report(String(msg)).with_code(ErrXMLEncode).error()


struct Encoder[W: IoWriter & Deinitable & Movable](Movable):
    """Tokens onto a stream. Go's `Encoder`.

    ```mojo
    from core.bytes import new_buffer
    from core.encoding.xml import CharData, Name, StartElement, Token
    from core.encoding.xml import new_encoder
    from core.io import Byte

    def main() raises:
        var e = new_encoder(new_buffer(List[Byte]()))
        var start = StartElement(Name("", "greet"), List[Attr]())
        e.encode_token(Token(start.copy()))
        e.encode_token(Token(CharData("hello")))
        e.encode_token(Token(start.end()))
        e.close()
        print(e.w.w.string())  # <greet>hello</greet>
    ```

    Not `Copyable`, for the reason `bufio.Writer` is not: two encoders over one
    sink would each hold bytes the other did not, and flushing them would
    interleave.
    """

    var w: BufWriter[Self.W]
    """The sink, with a buffer in front of it. Owned, so the call is direct."""

    var _indent: String
    """One level of indentation, or empty for none."""

    var _prefix: String
    """What every line starts with, or empty."""

    var _depth: Int
    """How many elements are open, for the indentation."""

    var _indented_in: Bool
    """Whether the last thing written opened a level.

    An element with nothing inside it goes out on one line, which is what this
    is for: the end tag sees that the start tag was the last thing written and
    skips its own newline.
    """

    var _put_newline: Bool
    """Whether a newline is owed before the next line. False for the first
    line, so an indented document does not begin with a blank one."""

    var _seq: Int
    """A counter for making up a prefix nobody has used."""

    var _attr_ns: Dict[String, String]
    """Prefix to URL, for the prefixes this encoder invented."""

    var _attr_prefix: Dict[String, String]
    """URL to prefix, the same table read the other way."""

    var _prefixes: List[String]
    """The invented prefixes, with an empty string marking each element
    boundary so that closing one can drop exactly the prefixes it declared."""

    var _tags: List[Name]
    """The elements that are open, innermost last."""

    var _closed: Bool
    """Whether `close` has been called. Writing after it raises."""

    var _wrote: Bool
    """Whether anything at all has been written.

    Go asks its buffered writer whether it holds anything, which answers the
    same question only until the first `Flush`: flush and then write an xml
    declaration and Go accepts it in the middle of a document. This flag is the
    question Go meant to ask.
    """

    def __init__(out self, var w: Self.W):
        """Write to `w`. Go's `NewEncoder`."""
        self.w = new_buffered(w^)
        self._indent = String()
        self._prefix = String()
        self._depth = 0
        self._indented_in = False
        self._put_newline = False
        self._seq = 0
        self._attr_ns = Dict[String, String]()
        self._attr_prefix = Dict[String, String]()
        self._prefixes = List[String]()
        self._tags = List[Name]()
        self._closed = False
        self._wrote = False

    def indent(mut self, prefix: StringSlice, indent: StringSlice):
        """Put every element on its own line. Go's `Indent`.

        Each line begins with `prefix` and then one copy of `indent` per level
        of nesting. Both empty, which is the default, writes no whitespace of
        its own at all.

        Changing this part way through a document is allowed and changes only
        what is written after it, which is Go's behaviour and is occasionally
        what a caller wants for one deeply nested subtree.
        """
        self._prefix = String(prefix)
        self._indent = String(indent)

    def _out(mut self, s: StringSlice) raises:
        """Write text."""
        _ = self.w.write(s.as_bytes())
        self._wrote = True

    def _out_bytes[o: Origin](mut self, s: Span[Byte, o]) raises:
        """Write bytes."""
        _ = self.w.write(s)
        self._wrote = True

    def encode_token(mut self, t: Token) raises:
        """Write one token. Go's `EncodeToken`.

        Does not flush, because a document is many tokens and a sink is usually
        a file. Call `close` when the last one is written.

        Raises when the token cannot be written as itself: an end element that
        does not match what is open, a comment holding `-->`, a processing
        instruction holding `?>`, a directive whose angle brackets do not
        balance, or an `xml` processing instruction anywhere but at the very
        start, which is the one place a declaration may go.

        Also raises after `close`, which is checked here rather than on every
        write because this is the only door in.
        """
        if self._closed:
            raise _encode_error("xml: use of closed Encoder")
        if t.kind == START_ELEMENT:
            self._write_start(t.name, Span(t.attr))
        elif t.kind == END_ELEMENT:
            self._write_end(t.name)
        elif t.kind == CHAR_DATA:
            # Newlines are written as themselves here and escaped inside an
            # attribute value, because a newline in a document body is
            # whitespace and a newline in an attribute value is turned into a
            # space by any conforming parser.
            _escape(self.w, Span(t.data), False)
            self._wrote = True
        elif t.kind == COMMENT:
            if index_bytes(Span(t.data), _END_COMMENT.as_bytes()) >= 0:
                raise _encode_error(
                    "xml: EncodeToken of Comment containing --> marker"
                )
            self._out("<!--")
            self._out_bytes(Span(t.data))
            self._out("-->")
        elif t.kind == PROC_INST:
            self._write_proc_inst(t)
        elif t.kind == DIRECTIVE:
            if not _is_valid_directive(Span(t.data)):
                raise _encode_error(
                    "xml: EncodeToken of Directive containing wrong < or >"
                    " markers"
                )
            self._out("<!")
            self._out_bytes(Span(t.data))
            self._out(">")
        else:
            raise _encode_error("xml: EncodeToken of invalid token type")

    def _write_proc_inst(mut self, t: Token) raises:
        """`<?target inst?>`, with the three things that can be wrong with it.
        """
        if t.target == "xml" and self._wrote:
            raise _encode_error(
                "xml: EncodeToken of ProcInst xml target only valid for xml"
                " declaration, first token encoded"
            )
        if not _is_name_string(t.target):
            raise _encode_error(
                "xml: EncodeToken of ProcInst with invalid Target"
            )
        if index_bytes(Span(t.data), _END_PROC_INST.as_bytes()) >= 0:
            raise _encode_error(
                "xml: EncodeToken of ProcInst containing ?> marker"
            )
        self._out("<?")
        self._out(t.target)
        if len(t.data) > 0:
            self._out(" ")
            self._out_bytes(Span(t.data))
        self._out("?>")

    def _write_start[
        o: Origin
    ](mut self, name: Name, attr: Span[Attr, o]) raises:
        """`<name ...>`. Go's `printer.writeStart`.

        A name space on the element becomes an `xmlns` attribute on it, and a
        name space on an attribute becomes an invented prefix declared on the
        same element. An attribute with no local name is skipped rather than
        refused, which is Go's behaviour and is what lets a caller build an
        attribute list with holes in it.
        """
        if not name.local:
            raise _encode_error("xml: start tag with no name")

        self._tags.append(name)
        self._prefixes.append(String())

        self._write_indent(1)
        self._out("<")
        self._out(name.local)

        if name.space:
            self._out(' xmlns="')
            self._escape_string(name.space)
            self._out('"')

        for i in range(len(attr)):
            if not attr[i].name.local:
                continue
            self._out(" ")
            if attr[i].name.space:
                var prefix = self._create_attr_prefix(attr[i].name.space)
                self._out(prefix)
                self._out(":")
            self._out(attr[i].name.local)
            self._out('="')
            self._escape_string(attr[i].value)
            self._out('"')
        self._out(">")

    def _write_end(mut self, name: Name) raises:
        """`</name>`. Go's `printer.writeEnd`."""
        if not name.local:
            raise _encode_error("xml: end tag with no name")
        if len(self._tags) == 0 or not self._tags[len(self._tags) - 1].local:
            raise _encode_error(
                "xml: end tag </" + name.local + "> without start tag"
            )
        var top = self._tags[len(self._tags) - 1]
        if top != name:
            if top.local != name.local:
                raise _encode_error(
                    "xml: end tag </"
                    + name.local
                    + "> does not match start tag <"
                    + top.local
                    + ">"
                )
            raise _encode_error(
                "xml: end tag </"
                + name.local
                + "> in namespace "
                + name.space
                + " does not match start tag <"
                + top.local
                + "> in namespace "
                + top.space
            )
        _ = self._tags.pop()

        self._write_indent(-1)
        self._out("</")
        self._out(name.local)
        self._out(">")
        self._pop_prefix()

    def _escape_string(mut self, s: StringSlice) raises:
        """Write `s` escaped, for a place inside quotes.
        Go's `printer.EscapeString`.

        Newlines are escaped here and not in a document body, because a parser
        turns a raw newline inside an attribute value into a space and the
        value would not read back as it was written.
        """
        escape_text(self.w, s.as_bytes())
        self._wrote = True

    def _create_attr_prefix(mut self, url: StringSlice) raises -> String:
        """A prefix standing for `url`, declaring one if there is not already
        one. Go's `printer.createAttrPrefix`.

        The prefix is written out as an `xmlns:` attribute the moment it is
        invented, which is why this is called from the middle of writing a
        start tag and why it writes rather than only returning.
        """
        var found = self._attr_prefix.get(String(url))
        if found and found.value():
            return found.value()

        # One name space is predefined and has to be referred to by its
        # standard prefix rather than by one invented here.
        if url == _XML_URL:
            return String(_XML_PREFIX)

        # A readable prefix if the URL offers one, which is the last path
        # element of nearly every name space anybody writes.
        var trimmed = trim_right(url, "/")
        var prefix = String(trimmed)
        var at = last_index(trimmed, "/")
        if at >= 0:
            prefix = String(trimmed[byte = at + 1 : trimmed.byte_length()])
        if (
            not prefix
            or not _is_name(prefix.as_bytes())
            or contains(prefix, ":")
        ):
            prefix = String("_")

        # Anything beginning with the three letters of `xml` in any case is
        # reserved by section 2.3 of the specification, so it is pushed out of
        # the way rather than used.
        if prefix.byte_length() >= 3 and equal_fold(prefix[byte=0:3], "xml"):
            prefix = "_" + prefix

        var taken = self._attr_ns.get(prefix)
        if taken and taken.value():
            while True:
                self._seq += 1
                var candidate = prefix + "_" + String(self._seq)
                var used = self._attr_ns.get(candidate)
                if not used or not used.value():
                    prefix = candidate
                    break

        self._attr_prefix[String(url)] = prefix.copy()
        self._attr_ns[prefix.copy()] = String(url)

        self._out("xmlns:")
        self._out(prefix)
        self._out('="')
        self._escape_string(url)
        self._out('" ')

        self._prefixes.append(prefix.copy())
        return prefix^

    def _pop_prefix(mut self):
        """Forget the prefixes the element just closed declared.
        Go's `printer.popPrefix`.

        Back to the empty string `_write_start` pushed, which is the marker for
        where this element's declarations begin.
        """
        while len(self._prefixes) > 0:
            var prefix = self._prefixes.pop()
            if not prefix:
                break
            var url = self._attr_ns.get(prefix)
            if url:
                try:
                    _ = self._attr_prefix.pop(url.value())
                except:
                    pass
            try:
                _ = self._attr_ns.pop(prefix)
            except:
                pass

    def _write_indent(mut self, depth_delta: Int) raises:
        """The newline and the leading whitespace, if any.
        Go's `printer.writeIndent`.

        `depth_delta` is one for a start tag, minus one for an end tag. An
        element with nothing between its tags is written on one line, which is
        what `_indented_in` remembers.
        """
        if not self._prefix and not self._indent:
            return
        if depth_delta < 0:
            self._depth -= 1
            if self._indented_in:
                self._indented_in = False
                return
            self._indented_in = False
        # Built up first and written once, because `_out` borrows the encoder
        # mutably and the prefix it would be handed lives inside the encoder.
        var line = String()
        if self._put_newline:
            line += "\n"
        else:
            self._put_newline = True
        line += self._prefix
        for _ in range(self._depth):
            line += self._indent
        self._out(line)
        if depth_delta > 0:
            self._depth += 1
            self._indented_in = True

    def flush(mut self) raises:
        """Push the buffered bytes at the writer. Go's `Flush`.

        Says nothing about whether the document is finished. `close` is the one
        that does.
        """
        self.w.flush()

    def close(mut self) raises:
        """Flush and say whether anything was left open. Go's `Close`.

        Calling it twice is not a failure and does nothing the second time,
        which is Go's behaviour. Every write after it raises, so an encoder
        that has been closed cannot quietly append to a document that was
        already finished.
        """
        if self._closed:
            return
        self._closed = True
        self.w.flush()
        if len(self._tags) > 0:
            raise _encode_error(
                "unclosed tag <" + self._tags[len(self._tags) - 1].local + ">"
            )


def new_encoder[W: IoWriter & Deinitable & Movable](var w: W) -> Encoder[W]:
    """An encoder onto `w`. Go's `NewEncoder`.

    Go takes an `io.Writer` interface and this takes the concrete type, so the
    call through the buffer is direct. `core.io.AnyWriter` is the way to hold
    one of several sinks in the same variable.
    """
    return Encoder[W](w^)
