"""The six things a document is made of, and the one type that holds any of them.

Go says `type Token any` and then defines six structs, and a caller finds out
which one arrived with a type switch. There is no `any` here and no type switch
to do on it, design.md section 1, so `Token` is a struct with a `kind` on it and
the fields of all six behind that. Which fields a kind uses is not a guess a
reader has to make: each field says, and `kind` is what to branch on.

The six types are still here and still carry Go's fields, because they are what
a caller builds when they are writing rather than reading. `Token(x)` takes any
of them and `start_element` and its five siblings take one back out.

One thing Go has that this does not need. Go's tokens point into the decoder's
buffer, so the bytes under a `CharData` change when the next token is read, and
`CopyToken` exists to escape that. Every token here owns its bytes, so a token
kept across a hundred calls is the token that was read. `copy_token` is here
because Go has it and because a caller porting code will reach for it, and it
is a plain copy.
"""

from core.io import Byte
from core.unicode.utf8 import RUNE_ERROR, decode_rune

from .tables import is_name_first, is_name_rune

comptime START_ELEMENT = 0
"""A `<name>` and its attributes. Go's `StartElement`."""

comptime END_ELEMENT = 1
"""A `</name>`. Go's `EndElement`."""

comptime CHAR_DATA = 2
"""Text between elements, with the entities already expanded. Go's `CharData`.
"""

comptime COMMENT = 3
"""What was between `<!--` and `-->`. Go's `Comment`."""

comptime PROC_INST = 4
"""A `<?target instruction?>`. Go's `ProcInst`."""

comptime DIRECTIVE = 5
"""What was between `<!` and its matching `>`, a doctype most of the time.
Go's `Directive`."""


struct Name(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """An element or attribute name, with the name space it belongs to.
    Go's `Name`.

    `space` is a URL rather than the prefix the document was written with,
    because a prefix means whatever the document said it means and two
    documents can spell the same name space differently. `Decoder.token` does
    that translation and `Decoder.raw_token` does not, which is the whole
    difference between them.
    """

    var space: String
    """The name space URL, or empty. Go's `Space`."""

    var local: String
    """The name itself, with no prefix on it. Go's `Local`."""

    def __init__(out self, space: StringSlice, local: StringSlice):
        """A name in a space. Both parts are copied."""
        self.space = String(space)
        self.local = String(local)

    def __eq__(self, other: Self) -> Bool:
        """Whether both parts match."""
        return self.space == other.space and self.local == other.local

    def __ne__(self, other: Self) -> Bool:
        """Whether either part differs."""
        return not (self == other)

    def write_to[W: Writer](self, mut writer: W):
        """`space:local`, or just `local` when there is no space.

        For a message rather than for a document: this is not the prefix form
        an encoder writes, since the prefix an encoder picks depends on what
        else is in scope.
        """
        if self.space:
            writer.write(self.space, ":")
        writer.write(self.local)


struct Attr(Copyable, Equatable, ImplicitlyCopyable, Movable):
    """One attribute of a start element. Go's `Attr`."""

    var name: Name
    """The attribute name. Go's `Name`."""

    var value: String
    """What was between the quotes, with the entities expanded. Go's `Value`."""

    def __init__(out self, name: Name, value: StringSlice):
        """An attribute with a name and a value."""
        self.name = name
        self.value = String(value)

    def __eq__(self, other: Self) -> Bool:
        """Whether the names and the values both match."""
        return self.name == other.name and self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether either differs."""
        return not (self == other)


struct StartElement(Copyable, Equatable, Movable):
    """An opening tag and its attributes. Go's `StartElement`."""

    var name: Name
    """The element name. Go's `Name`."""

    var attr: List[Attr]
    """The attributes, in the order the document wrote them. Go's `Attr`.

    Including the `xmlns` ones, which is Go's behaviour: they are attributes as
    well as declarations and a caller rewriting a document needs to see them.
    """

    def __init__(out self, name: Name, var attr: List[Attr]):
        """An element with a name and a list of attributes."""
        self.name = name
        self.attr = attr^

    def copy(self) -> Self:
        """A copy. Go's `Copy`.

        Go's makes a fresh attribute slice because its tokens share the
        decoder's memory. This one owns its attributes already, so the copy is
        a copy and nothing more; the module docstring says why the method is
        still here.
        """
        return Self(self.name, self.attr.copy())

    def end(self) -> EndElement:
        """The end element that closes this one. Go's `End`."""
        return EndElement(self.name)

    def __eq__(self, other: Self) -> Bool:
        """Whether the names match and the attributes match in order."""
        if self.name != other.name or len(self.attr) != len(other.attr):
            return False
        for i in range(len(self.attr)):
            if self.attr[i] != other.attr[i]:
                return False
        return True

    def __ne__(self, other: Self) -> Bool:
        """Whether anything differs."""
        return not (self == other)


struct EndElement(Copyable, Equatable, ImplicitlyCopyable, Movable):
    """A closing tag. Go's `EndElement`."""

    var name: Name
    """The element name, matched against the start element. Go's `Name`."""

    def __init__(out self, name: Name):
        """The end of an element."""
        self.name = name

    def __eq__(self, other: Self) -> Bool:
        """Whether the names match."""
        return self.name == other.name

    def __ne__(self, other: Self) -> Bool:
        """Whether they differ."""
        return not (self == other)


struct CharData(Copyable, Equatable, Movable):
    """Text, with the escapes already turned back into characters.
    Go's `CharData`.

    Bytes rather than a `String`, which is Go's choice too, because character
    data is the one place a document can hold anything the character range
    allows and a caller may want it byte for byte. `text` is the way to a
    `String` and says what it refuses.
    """

    var data: List[Byte]
    """The text. Go's `CharData` is these bytes and nothing else."""

    def __init__(out self, var data: List[Byte]):
        """Hold the bytes."""
        self.data = data^

    def __init__(out self, text: StringSlice):
        """Hold a copy of the bytes behind `text`."""
        self.data = List[Byte](text.as_bytes())

    def text(self) raises -> String:
        """The bytes as a `String`.

        Never raises on a token that came out of a decoder, which refuses
        anything that is not UTF-8 while it is reading. It can raise on a
        `CharData` a caller built out of arbitrary bytes.
        """
        return String(from_utf8=Span(self.data))

    def copy(self) -> Self:
        """A copy. Go's `Copy`, and see the module docstring."""
        return Self(self.data.copy())

    def __eq__(self, other: Self) -> Bool:
        """Whether the bytes match."""
        return Span(self.data) == Span(other.data)

    def __ne__(self, other: Self) -> Bool:
        """Whether they differ."""
        return not (self == other)


struct Comment(Copyable, Equatable, Movable):
    """What was between `<!--` and `-->`. Go's `Comment`.

    The markers are not included, and the bytes are exactly what was written:
    a comment is not a place escapes are expanded.
    """

    var data: List[Byte]
    """The comment text."""

    def __init__(out self, var data: List[Byte]):
        """Hold the bytes."""
        self.data = data^

    def __init__(out self, text: StringSlice):
        """Hold a copy of the bytes behind `text`."""
        self.data = List[Byte](text.as_bytes())

    def text(self) raises -> String:
        """The bytes as a `String`, refusing anything that is not UTF-8."""
        return String(from_utf8=Span(self.data))

    def copy(self) -> Self:
        """A copy. Go's `Copy`, and see the module docstring."""
        return Self(self.data.copy())

    def __eq__(self, other: Self) -> Bool:
        """Whether the bytes match."""
        return Span(self.data) == Span(other.data)

    def __ne__(self, other: Self) -> Bool:
        """Whether they differ."""
        return not (self == other)


struct Directive(Copyable, Equatable, Movable):
    """What was between `<!` and its matching `>`. Go's `Directive`.

    Almost always a doctype. Nothing in it is parsed: a document type
    definition can declare entities and pull in external files, and this
    decoder does neither, so the whole declaration arrives as text and the
    caller decides what to do with it. That is Go's decision and it is the one
    that keeps a document from being able to make the parser fetch a URL or
    expand a name into a megabyte of itself.
    """

    var data: List[Byte]
    """The directive text, without the `<!` and the `>`."""

    def __init__(out self, var data: List[Byte]):
        """Hold the bytes."""
        self.data = data^

    def __init__(out self, text: StringSlice):
        """Hold a copy of the bytes behind `text`."""
        self.data = List[Byte](text.as_bytes())

    def text(self) raises -> String:
        """The bytes as a `String`, refusing anything that is not UTF-8."""
        return String(from_utf8=Span(self.data))

    def copy(self) -> Self:
        """A copy. Go's `Copy`, and see the module docstring."""
        return Self(self.data.copy())

    def __eq__(self, other: Self) -> Bool:
        """Whether the bytes match."""
        return Span(self.data) == Span(other.data)

    def __ne__(self, other: Self) -> Bool:
        """Whether they differ."""
        return not (self == other)


struct ProcInst(Copyable, Equatable, Movable):
    """A `<?target instruction?>`. Go's `ProcInst`.

    The XML declaration at the top of a document is one of these, with `xml`
    as the target. Everything else is for whatever program recognises the
    target, and this one neither reads nor validates it.
    """

    var target: String
    """The name after the `<?`. Go's `Target`."""

    var inst: List[Byte]
    """Everything between the target and the `?>`, less the space that
    separates them. Go's `Inst`."""

    def __init__(out self, target: StringSlice, var inst: List[Byte]):
        """A target and its instruction."""
        self.target = String(target)
        self.inst = inst^

    def __init__(out self, target: StringSlice, inst: StringSlice):
        """The same, with the instruction as text."""
        self.target = String(target)
        self.inst = List[Byte](inst.as_bytes())

    def text(self) raises -> String:
        """The instruction as a `String`, refusing anything that is not UTF-8.
        """
        return String(from_utf8=Span(self.inst))

    def copy(self) -> Self:
        """A copy. Go's `Copy`, and see the module docstring."""
        return Self(self.target, self.inst.copy())

    def __eq__(self, other: Self) -> Bool:
        """Whether the targets and the instructions both match."""
        return self.target == other.target and Span(self.inst) == Span(
            other.inst
        )

    def __ne__(self, other: Self) -> Bool:
        """Whether either differs."""
        return not (self == other)


struct Token(Copyable, Equatable, Movable, Writable):
    """Any one of the six. Go's `Token`, which is an empty interface.

    ```mojo
    from core.encoding.xml import CHAR_DATA, START_ELEMENT, Token, new_decoder
    from core.bytes import new_buffer_string

    def main() raises:
        var d = new_decoder(new_buffer_string("<a>hi</a>"))
        var t = d.token()
        if t.kind == START_ELEMENT:
            print(t.name.local)  # a
        if d.token().kind == CHAR_DATA:
            print("text")
    ```

    `kind` says which of the six this is and the fields say the rest. A field
    a kind does not use holds a zero value rather than something stale, so
    reading the wrong one is empty rather than misleading, and the six
    accessors raise instead of returning a token that is not there.
    """

    var kind: Int
    """Which of `START_ELEMENT` and its five siblings this is."""

    var name: Name
    """The element name, for a start element and an end element."""

    var attr: List[Attr]
    """The attributes, for a start element."""

    var target: String
    """The target, for a processing instruction."""

    var data: List[Byte]
    """The bytes, for character data, a comment, a directive, and the
    instruction of a processing instruction."""

    def __init__(out self):
        """A start element with no name, which is what a zero `Token` is.

        Not useful on its own. It exists because a list of tokens has to be
        able to make room before it fills it.
        """
        self.kind = START_ELEMENT
        self.name = Name("", "")
        self.attr = List[Attr]()
        self.target = String()
        self.data = List[Byte]()

    def __init__(out self, var v: StartElement):
        """A start element as a token."""
        self = Self()
        self.name = v.name
        swap(self.attr, v.attr)

    def __init__(out self, v: EndElement):
        """An end element as a token."""
        self = Self()
        self.kind = END_ELEMENT
        self.name = v.name

    def __init__(out self, var v: CharData):
        """Character data as a token."""
        self = Self()
        self.kind = CHAR_DATA
        swap(self.data, v.data)

    def __init__(out self, var v: Comment):
        """A comment as a token."""
        self = Self()
        self.kind = COMMENT
        swap(self.data, v.data)

    def __init__(out self, var v: Directive):
        """A directive as a token."""
        self = Self()
        self.kind = DIRECTIVE
        swap(self.data, v.data)

    def __init__(out self, var v: ProcInst):
        """A processing instruction as a token."""
        self = Self()
        self.kind = PROC_INST
        self.target = v.target
        swap(self.data, v.inst)

    def start_element(self) raises -> StartElement:
        """This as a `StartElement`, or a raise if it is something else."""
        self._must_be(START_ELEMENT, "a start element")
        return StartElement(self.name, self.attr.copy())

    def end_element(self) raises -> EndElement:
        """This as an `EndElement`, or a raise if it is something else."""
        self._must_be(END_ELEMENT, "an end element")
        return EndElement(self.name)

    def char_data(self) raises -> CharData:
        """This as a `CharData`, or a raise if it is something else."""
        self._must_be(CHAR_DATA, "character data")
        return CharData(self.data.copy())

    def comment(self) raises -> Comment:
        """This as a `Comment`, or a raise if it is something else."""
        self._must_be(COMMENT, "a comment")
        return Comment(self.data.copy())

    def directive(self) raises -> Directive:
        """This as a `Directive`, or a raise if it is something else."""
        self._must_be(DIRECTIVE, "a directive")
        return Directive(self.data.copy())

    def proc_inst(self) raises -> ProcInst:
        """This as a `ProcInst`, or a raise if it is something else."""
        self._must_be(PROC_INST, "a processing instruction")
        return ProcInst(self.target, self.data.copy())

    def _must_be(self, kind: Int, wanted: StringSlice) raises:
        """Refuse to hand back a token of the wrong kind.

        Go's type assertion has a two value form that says no quietly. This
        raises, because the accessor was asked for a value and there is not one
        to give, and `kind` is the question a caller should have asked first.
        """
        if self.kind != kind:
            raise Error(
                String("xml: this token is ")
                + _kind_name(self.kind)
                + ", not "
                + String(wanted)
            )

    def text(self) raises -> String:
        """The bytes of this token as a `String`.

        The same thing every one of the six `text` methods does, for a caller
        who has a `Token` in hand and does not want to name its kind first. A
        start element and an end element have no bytes and come back empty.
        """
        return String(from_utf8=Span(self.data))

    def copy(self) -> Self:
        """A copy. Go's `CopyToken`, as a method."""
        var out = Self()
        out.kind = self.kind
        out.name = self.name
        out.attr = self.attr.copy()
        out.target = self.target
        out.data = self.data.copy()
        return out^

    def __eq__(self, other: Self) -> Bool:
        """Whether these are the same kind of token with the same contents."""
        if self.kind != other.kind:
            return False
        if self.name != other.name or self.target != other.target:
            return False
        if Span(self.data) != Span(other.data):
            return False
        if len(self.attr) != len(other.attr):
            return False
        for i in range(len(self.attr)):
            if self.attr[i] != other.attr[i]:
                return False
        return True

    def __ne__(self, other: Self) -> Bool:
        """Whether anything differs."""
        return not (self == other)

    def write_to[W: Writer](self, mut writer: W):
        """The kind and enough of the contents to tell two apart in a message.

        Not a document: an encoder writes those. This is what a failing test or
        a log line wants, so a token holding something that is not UTF-8 prints
        with the replacement character where those bytes were.
        """
        writer.write(_kind_name(self.kind))
        if self.kind == START_ELEMENT:
            writer.write(" <", self.name, ">")
            for i in range(len(self.attr)):
                writer.write(
                    " ", self.attr[i].name, "=", repr(self.attr[i].value)
                )
        elif self.kind == END_ELEMENT:
            writer.write(" </", self.name, ">")
        elif self.kind == PROC_INST:
            writer.write(" ", self.target, " ")
            writer.write(_as_text(Span(self.data)))
        else:
            writer.write(" ")
            writer.write(_as_text(Span(self.data)))


def _as_text[o: Origin](s: Span[Byte, o]) -> String:
    """`s` as a `String`, with anything that is not UTF-8 replaced.

    Go writes `string(b)` all through this package, which takes any bytes and
    puts the replacement character where they were not text. A `String` here
    has to be valid UTF-8, so the substitution has to happen somewhere, and
    `from_utf8_lossy` is the same substitution under another name.

    Used for the parts of a document that become text whatever they hold: a
    name in a failure message, an attribute value, the text of an entity that
    turned out not to be one.
    """
    return String(from_utf8_lossy=s)


def _is_name[o: Origin](s: Span[Byte, o]) -> Bool:
    """Whether `s` is a name a document may use. Go's `isName`.

    The first character has to be a letter, an underscore or a colon, and the
    rest may also be digits, combining marks and extenders. Appendix B of the
    specification says which characters those are and `tables.mojo` is that
    list, generated from Go's copy of it.

    Bytes that are not UTF-8 are not a name, which is checked here rather than
    left to the caller because a name is the one thing this package turns into
    a `String` without replacing anything.
    """
    if len(s) == 0:
        return False
    var decoded = decode_rune(s)
    var r = decoded[0]
    var n = decoded[1]
    if r == RUNE_ERROR and n == 1:
        return False
    if not is_name_first(r):
        return False
    var i = n
    while i < len(s):
        var rest = decode_rune(s[i : len(s)])
        r = rest[0]
        n = rest[1]
        if r == RUNE_ERROR and n == 1:
            return False
        if not is_name_rune(r):
            return False
        i += n
    return True


def _is_name_string(s: StringSlice) -> Bool:
    """`_is_name` over the bytes of `s`. Go's `isNameString`.

    Go keeps the two apart because converting a `string` to a `[]byte` copies
    there. This one borrows, so it is the same call at the same cost and it is
    here because the encoder has names as text and the decoder has them as
    bytes.
    """
    return _is_name(s.as_bytes())


def _kind_name(kind: Int) -> String:
    """What to call a kind in a message."""
    if kind == START_ELEMENT:
        return "a start element"
    if kind == END_ELEMENT:
        return "an end element"
    if kind == CHAR_DATA:
        return "character data"
    if kind == COMMENT:
        return "a comment"
    if kind == PROC_INST:
        return "a processing instruction"
    if kind == DIRECTIVE:
        return "a directive"
    return "not a token"


def copy_token(t: Token) -> Token:
    """A copy of a token. Go's `CopyToken`.

    Go needs this because its tokens borrow the decoder's buffer and stop being
    true as soon as the next one is read. Nothing here borrows anything, so
    this is a plain copy and a caller who never calls it is not making a
    mistake. It is here because Go has it and because a port of Go code should
    not have to work out that it has become unnecessary.
    """
    return t.copy()


trait TokenReader:
    """Anything that hands back one token at a time. Go's `TokenReader`.

    `Decoder` is one. A filter that drops comments or rewrites names is
    another, and writing one is the reason the trait is exported.

    Go's contract has a wrinkle this does not: its `Token` may hand back a
    token and `io.EOF` together, and it says implementations may report the end
    on that call or on the next one. There is one value here, so the end is
    always a raise of `EOF` on its own call, and there is no second way to
    spell it.
    """

    def token(mut self) raises -> Token:
        """The next token, or a raise of `EOF` when there are none left."""
        ...
