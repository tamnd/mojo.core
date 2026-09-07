"""The five things a token stream is made of, and the one type that holds any of
them.

Go says `type Token any` and lists six Go types a token may turn out to be, and
a caller finds out which one arrived with a type switch. There is no `any` here
and no type switch to do on it, design.md section 1, so `Token` is a struct with
a `kind` on it and the fields of all five behind that. Which fields a kind uses
is not a guess a reader has to make: each field says, and `kind` is what to
branch on.

Five rather than Go's six, because Go's list counts a number twice: a number
arrives as a `float64` normally and as a `Number` after `UseNumber`, which is
one thing decided by a switch on the decoder rather than by the document. Every
number here is a `Number`, and a caller who wanted a float asks the `Number` for
one and finds out there whether it fits. `1e400` is a number a document may hold
and no float can, so a decoder that hands back floats by default is a decoder
that loses documents, and Go's own answer to that is the method this makes the
only path.
"""

from core.io import Byte

from .number import Number
from .scan import _LBRACE, _LBRACKET, _RBRACE, _RBRACKET

comptime DELIM = 0
"""One of the four brackets. Go's `Delim`."""

comptime BOOL = 1
"""`true` or `false`. Go's `bool`."""

comptime NUMBER = 2
"""A number, kept as the document wrote it. Go's `Number`."""

comptime STRING = 3
"""A string, with the escapes already turned back into characters. Go's
`string`."""

comptime NULL = 4
"""`null`. Go's `nil`, which is the one token Go cannot tell from a failure
without checking the error first."""


struct Delim(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """One of `[`, `]`, `{` and `}`. Go's `Delim`.

    ```mojo
    from core.encoding.json import ARRAY_OPEN, Delim
    from core.io import Byte


    def main() raises:
        print(Delim(Byte(ord("["))) == ARRAY_OPEN)  # True
        print(String(ARRAY_OPEN))  # [
    ```

    Go makes this a `rune`, so `Delim('\\u00e9')` is a value its type allows and
    its decoder never produces. A byte here, because the four brackets are the
    whole of what a delimiter can ever be and the wider type buys nothing.
    """

    var char: Byte
    """The bracket itself. One of four values, always."""

    def __init__(out self, char: Byte):
        """A delimiter for `char`. Nothing checks that it is one of the four,
        which is Go's position too: the decoder only ever builds the four, and a
        caller building a fifth has written a value nothing will match."""
        self.char = char

    def __eq__(self, other: Self) -> Bool:
        """Whether they are the same bracket."""
        return self.char == other.char

    def __ne__(self, other: Self) -> Bool:
        """Whether they differ."""
        return self.char != other.char

    def string(self) -> String:
        """The bracket as a one character string. Go's `String`."""
        return chr(Int(self.char))

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.string())


comptime ARRAY_OPEN = Delim(_LBRACKET)
"""The `[` that opens an array."""

comptime ARRAY_CLOSE = Delim(_RBRACKET)
"""The `]` that closes one."""

comptime OBJECT_OPEN = Delim(_LBRACE)
"""The `{` that opens an object."""

comptime OBJECT_CLOSE = Delim(_RBRACE)
"""The `}` that closes one."""


struct Token(Copyable, Equatable, Movable, Writable):
    """Any one of the five. Go's `Token`, which is an empty interface.

    ```mojo
    from core.encoding.json import DELIM, STRING, new_decoder
    from core.io import Reader


    def opens_an_object[R: Reader & Deinitable & Movable](
        var src: R,
    ) raises -> Bool:
        var d = new_decoder(src^)
        var t = d.token()
        if t.kind != DELIM or t.delim.string() != "{":
            return False
        return d.token().kind == STRING
    ```

    `kind` says which of the five this is and the fields say the rest. A field a
    kind does not use holds a zero value rather than something stale, so reading
    the wrong one is empty rather than misleading, and the four accessors raise
    instead of handing back a value that is not there.

    Every token owns its bytes. Nothing here points into the decoder's buffer,
    so a token kept across a hundred calls is the token that was read.
    """

    var kind: Int
    """Which of `DELIM`, `BOOL`, `NUMBER`, `STRING` and `NULL` this is."""

    var delim: Delim
    """The bracket, for a delimiter."""

    var boolean: Bool
    """The value, for `true` and `false`."""

    var number: Number
    """The number as the document wrote it, for a number."""

    var text: String
    """The characters, with the escapes already expanded, for a string.

    Both an object key and a string value arrive this way, and nothing on the
    token says which it was: that is what the surrounding delimiters and the
    caller's own counting say, exactly as in Go.
    """

    def __init__(out self):
        """A `null`, which is what a zero `Token` is.

        Not useful on its own. It exists because a list of tokens has to be able
        to make room before it fills it.
        """
        self.kind = NULL
        self.delim = ARRAY_OPEN
        self.boolean = False
        self.number = Number("")
        self.text = String()

    def __init__(out self, v: Delim):
        """A delimiter as a token."""
        self = Self()
        self.kind = DELIM
        self.delim = v

    def __init__(out self, v: Bool):
        """A boolean as a token."""
        self = Self()
        self.kind = BOOL
        self.boolean = v

    def __init__(out self, v: Number):
        """A number as a token."""
        self = Self()
        self.kind = NUMBER
        self.number = v.copy()

    def __init__(out self, v: StringSlice):
        """A string as a token. The bytes are copied."""
        self = Self()
        self.kind = STRING
        self.text = String(v)

    def as_delim(self) raises -> Delim:
        """The bracket, or a raise if this is something else."""
        self._must_be(DELIM, "a delimiter")
        return self.delim

    def as_bool(self) raises -> Bool:
        """The boolean, or a raise if this is something else."""
        self._must_be(BOOL, "a boolean")
        return self.boolean

    def as_number(self) raises -> Number:
        """The number, or a raise if this is something else."""
        self._must_be(NUMBER, "a number")
        return self.number.copy()

    def as_string(self) raises -> String:
        """The string, or a raise if this is something else."""
        self._must_be(STRING, "a string")
        return self.text.copy()

    def is_null(self) -> Bool:
        """Whether this is `null`.

        A question rather than an accessor, because there is nothing to hand
        back. Go's equivalent is comparing a `Token` against `nil`, which is
        also how Go reports the end of the stream, so a Go caller has to check
        the error first and a caller here does not.
        """
        return self.kind == NULL

    def _must_be(self, kind: Int, wanted: StringSlice) raises:
        """Refuse to hand back a token of the wrong kind.

        Go's type assertion has a two value form that says no quietly. This one
        raises, and the message names both what was asked for and what is
        actually here, because the two together are what tells a reader which of
        the two is wrong.
        """
        if self.kind != kind:
            raise Error(
                "json: token is "
                + _describe(self.kind)
                + ", not "
                + String(wanted)
            )

    def __eq__(self, other: Self) -> Bool:
        """Whether they are the same kind holding the same value.

        A number compares as text, which is what `Number` does and why: `1.0`
        and `1` are the same number and were not written the same way, and a
        token stream is about what a document says.
        """
        if self.kind != other.kind:
            return False
        if self.kind == DELIM:
            return self.delim == other.delim
        if self.kind == BOOL:
            return self.boolean == other.boolean
        if self.kind == NUMBER:
            return self.number == other.number
        if self.kind == STRING:
            return self.text == other.text
        return True

    def __ne__(self, other: Self) -> Bool:
        """Whether anything differs."""
        return not (self == other)

    def write_to[W: Writer](self, mut writer: W):
        """The token as it would read in a message.

        For a message rather than for a document. A string is written as its
        characters with no quotes and no escaping, so this is not a JSON
        encoding and nothing should assemble a document out of it.
        """
        if self.kind == DELIM:
            writer.write(self.delim)
        elif self.kind == BOOL:
            writer.write("true" if self.boolean else "false")
        elif self.kind == NUMBER:
            writer.write(self.number)
        elif self.kind == STRING:
            writer.write(self.text)
        else:
            writer.write("null")


def _describe(kind: Int) -> String:
    """What a kind is called in a message."""
    if kind == DELIM:
        return String("a delimiter")
    if kind == BOOL:
        return String("a boolean")
    if kind == NUMBER:
        return String("a number")
    if kind == STRING:
        return String("a string")
    return String("null")
