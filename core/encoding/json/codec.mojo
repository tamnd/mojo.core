"""The half of a generated codec that is the same for every struct.

`tools/codec` writes one encoder and one decoder for every struct whose
docstring says `codec:"json"`, out of the fields and the struct tags. Every one
of them needs the same three things: a position in the input, the JSON grammar
below the level of which field is which, and the handful of writers that put a
string or a number on the end of some bytes. Those are here.

They were copied into each generated file until this package existed to hold
them, because a generated codec has to work for somebody who has this library
and nothing else of ours, and there was nothing here to import. Now there is,
so a program with twenty codecs in it carries one copy of this rather than
twenty, and a generated decoder reads exactly the documents `parse` reads
rather than the documents a second implementation of the same grammar happens
to read.

Nothing here is Go's. Go's `encoding/json` does this work by reflection while
the program runs, so there is no function in it a generated decoder would call
and no name of Go's for any of this. What a caller of this library writes is
still `marshal_json(value)` and `unmarshal_json_item(bytes)`, which the
generator wrote; these are what those two are made of.

`ValueScanner` is not the scanner `valid` and `compact` run on. That one is a
state machine fed one byte at a time, which is what makes it work over a
stream, and this one holds the whole document and walks it, which is what makes
a decoder that assigns straight into a field possible. They agree on the
grammar because the parts where agreeing is difficult, the text of a string and
the shape of a number, are the same code.
"""

from core.errors import Report, new
from core.io import Byte
from core.strconv import (
    format_float,
    format_int,
    format_uint,
    parse_float,
    parse_int,
    parse_uint,
)

from .document import _unquote_strict
from .errors import _type_error, _unsupported_value
from .raw import RawMessage
from .scan import (
    MAX_NESTING_DEPTH,
    _BACKSLASH,
    _COLON,
    _COMMA,
    _DOT,
    _LBRACE,
    _LBRACKET,
    _LOWER_A,
    _LOWER_B,
    _LOWER_E,
    _LOWER_F,
    _LOWER_N,
    _LOWER_R,
    _LOWER_T,
    _LOWER_U,
    _MINUS,
    _NEWLINE,
    _NINE,
    _PLUS,
    _QUOTE,
    _RBRACE,
    _RBRACKET,
    _RETURN,
    _SPACE,
    _TAB,
    _UPPER_E,
    _ZERO,
    _is_hex,
    _quote_char,
    _syntax_error,
)

comptime _HEX = "0123456789abcdef"
"""The digits a `\\u` escape is written with, in lower case, which is Go's."""

comptime _SLASH = Byte(47)
comptime _LESS = Byte(60)
comptime _GREATER = Byte(62)
comptime _AMPERSAND = Byte(38)
comptime _E2 = Byte(0xE2)
comptime _80 = Byte(0x80)
comptime _A8 = Byte(0xA8)


struct ValueScanner[o: ImmOrigin](Movable):
    """The input, a position in it, and how deeply nested that position is.

    Every generated decoder walks one of these. The methods are the JSON
    grammar and nothing above it: reading a value into a field is the generated
    code's job, and knowing that `[` starts an array is this one's.

    ```mojo
    from core.encoding.json import ValueScanner

    def main():
        var sc = ValueScanner('{"a":1}'.as_bytes())
        sc.expect(Byte(ord("{")))
        print(sc.read_string())  # a
        sc.expect(Byte(ord(":")))
        print(sc.read_signed(64))  # 1
    ```
    """

    var data: Span[Byte, Self.o]
    """The whole document. A decoder is handed all of it at once, which is what
    lets a field be assigned where it is found rather than buffered."""

    var pos: Int
    """How many bytes have been read."""

    var depth: Int
    """How many brackets are open, counted against `MAX_NESTING_DEPTH`."""

    var disallow_unknown: Bool
    """Whether a key no field matches is an error rather than something to step
    over. Go's `Decoder.DisallowUnknownFields`, carried down to where the
    decision is made.

    Off unless asked for, which is Go's default and is the only default a
    format that has to survive the other end being upgraded can have.
    """

    var struct_name: String
    """The struct being read, or empty. What goes on an `UnmarshalTypeError`.

    Go keeps the same two on its decoder, as `errorContext`, and for the same
    reason: the call that finds the disagreement is several levels below the
    one that knows whose field it is.
    """

    var field: String
    """The key being read, or empty. The other half of `struct_name`."""

    def __init__(
        out self, data: Span[Byte, Self.o], disallow_unknown: Bool = False
    ):
        self.data = data
        self.pos = 0
        self.depth = 0
        self.disallow_unknown = disallow_unknown
        self.struct_name = String()
        self.field = String()

    def at_field(mut self, struct_name: StaticString, key: String):
        """Say whose field is about to be read.

        Generated code calls this once per key, so a value that will not go
        into the field it arrived for names the field rather than only the
        type. A nested struct overwrites both and does not put them back,
        which is right rather than sloppy: the innermost call is the one that
        failed, and the loop above it sets them again before its next read.
        """
        self.struct_name = String(struct_name)
        self.field = key.copy()

    def fail(self, what: String) -> Error:
        """A refusal naming the byte it happened at.

        The same shape every other refusal in this package makes, so
        `SyntaxError.of` reads a generated decoder's failure as readily as it
        reads one from `valid`. Offsets rather than lines and columns, because
        the offset is what a caller can slice the input with and counting lines
        costs a pass over everything read so far.
        """
        return _syntax_error(what, self.pos + 1)

    def fail_type(self, what: String, type: String) -> Error:
        """A refusal saying the document held one thing and the field is
        another.

        Not a syntax error, and it does not carry `ErrJSONSyntax`, because the
        document is well formed JSON and the disagreement is about what the
        reader expected rather than about the bytes. Go draws the same line:
        its scanner never sees this and its decoder never calls it a syntax
        error.
        """
        return _type_error(
            what, type, self.pos + 1, self.struct_name, self.field
        )

    def _value_kind(mut self) raises -> String:
        """What the next value is, named the way Go names it in a type error.

        Empty means the bytes are not the start of any value, and the caller
        turns that into a syntax error, because a document that is not JSON is
        refused for being that rather than for disagreeing with a field.

        One byte says which of the six a value is for four of them, since JSON
        gave every kind a different first character. The two that need more
        are the ones a byte can only start: `tru` is a broken document and not
        a bool, and a minus with nothing after it is not a number. Both are
        looked at in full and neither is read, so the caller's position is
        where it was.
        """
        var c = self.peek()
        if c == _QUOTE:
            return "string"
        if c == _LBRACE:
            return "object"
        if c == _LBRACKET:
            return "array"
        if c == _LOWER_T:
            return "bool" if self._spelled("true") else String()
        if c == _LOWER_F:
            return "bool" if self._spelled("false") else String()
        if c == _LOWER_N:
            return "null" if self._spelled("null") else String()
        if c >= _ZERO and c <= _NINE:
            return "number"
        if c == _MINUS and self.pos + 1 < len(self.data):
            var next = self.data[self.pos + 1]
            if next >= _ZERO and next <= _NINE:
                return "number"
        return String()

    def _spelled(mut self, word: StaticString) -> Bool:
        """Whether `word` is written out in full at the position, reading
        nothing."""
        var here = self.pos
        var found = self._word(word)
        self.pos = here
        return found

    def enter(mut self) raises:
        """Go one level deeper into the input, or refuse to."""
        self.depth += 1
        if self.depth > MAX_NESTING_DEPTH:
            raise self.fail(
                "exceeded max depth of " + String(MAX_NESTING_DEPTH)
            )

    def leave(mut self):
        """Come back out of a level."""
        self.depth -= 1

    def skip_space(mut self):
        """Step over the four bytes JSON calls whitespace."""
        while self.pos < len(self.data):
            var c = self.data[self.pos]
            if c != _SPACE and c != _TAB and c != _NEWLINE and c != _RETURN:
                return
            self.pos += 1

    def peek(mut self) raises -> Byte:
        """The next byte that is not whitespace, without consuming it."""
        self.skip_space()
        if self.pos >= len(self.data):
            raise self.fail("unexpected end of JSON input")
        return self.data[self.pos]

    def accept(mut self, c: Byte) raises -> Bool:
        """Take `c` if it is next, and say whether it was."""
        self.skip_space()
        if self.pos < len(self.data) and self.data[self.pos] == c:
            self.pos += 1
            return True
        return False

    def expect(mut self, c: Byte) raises:
        """Take `c`, or raise saying it was wanted."""
        if not self.accept(c):
            raise self.fail("expected " + _quote_char(c))

    def _word(mut self, word: StaticString) -> Bool:
        """Take a bare word such as `null` if it is next, whitespace already
        skipped by the caller."""
        var want = word.as_bytes()
        if self.pos + len(want) > len(self.data):
            return False
        for i in range(len(want)):
            if self.data[self.pos + i] != want[i]:
                return False
        self.pos += len(want)
        return True

    def accept_null(mut self) raises -> Bool:
        """Take `null` if it is next, and say whether it was."""
        self.skip_space()
        return self._word("null")

    def read_bool(mut self) raises -> Bool:
        """`true` or `false`."""
        self.skip_space()
        if self._word("true"):
            return True
        if self._word("false"):
            return False
        var kind = self._value_kind()
        if kind == "":
            raise self.fail("expected true or false")
        raise self.fail_type(kind, "Bool")

    def _skip_escape(mut self) raises:
        """Step over one escape sequence, the backslash not yet taken.

        The escape is only checked here, not resolved. What it stands for is
        `_unquote_strict`'s answer, and that function is written for a literal
        somebody has already agreed is one, so this is where an escape that is
        not an escape has to be refused.
        """
        if self.pos + 1 >= len(self.data):
            raise self.fail("unexpected end of JSON input")
        var esc = self.data[self.pos + 1]
        if esc == _LOWER_U:
            if self.pos + 6 > len(self.data):
                raise self.fail("unexpected end of JSON input")
            for i in range(2, 6):
                var digit = self.data[self.pos + i]
                if not _is_hex(digit):
                    self.pos += i
                    raise self.fail(
                        "invalid character "
                        + _quote_char(digit)
                        + " in \\u escape"
                    )
            self.pos += 6
            return
        if (
            esc != _QUOTE
            and esc != _BACKSLASH
            and esc != _SLASH
            and esc != _LOWER_B
            and esc != _LOWER_F
            and esc != _LOWER_N
            and esc != _LOWER_R
            and esc != _LOWER_T
        ):
            self.pos += 1
            raise self.fail(
                "invalid character " + _quote_char(esc) + " in string escape"
            )
        self.pos += 2

    def read_key(mut self) raises -> String:
        """One string that is an object's key.

        The same bytes `read_string` reads and a different refusal for
        something else being there, which is Go's split as well: a key that is
        not a string is a document that is not JSON, and a value that is not a
        string is a document that disagrees with the struct. Go says `looking
        for beginning of object key string` for the first and raises an
        `UnmarshalTypeError` for the second.
        """
        self.skip_space()
        if self.pos >= len(self.data) or self.data[self.pos] != _QUOTE:
            raise self.fail("expected a string")
        return self._quoted()

    def read_string(mut self) raises -> String:
        """One JSON string, with its escapes resolved.

        Refuses a string holding bytes that are not UTF-8 and an escape naming
        half of a surrogate pair with no other half, which is what `parse`
        does and is not what Go does. A Mojo `String` says it is UTF-8, so
        Go's U+FFFD in place of either would be a silent edit of somebody's
        data rather than a representation of it. `docs/deviations.md` has the
        row.
        """
        self.skip_space()
        if self.pos >= len(self.data) or self.data[self.pos] != _QUOTE:
            var kind = self._value_kind()
            if kind == "":
                raise self.fail("expected a string")
            raise self.fail_type(kind, "String")
        return self._quoted()

    def _quoted(mut self) raises -> String:
        """One JSON string from its opening quote, which the caller has
        already found."""
        var start = self.pos
        self.pos += 1
        while True:
            if self.pos >= len(self.data):
                raise self.fail("unexpected end of JSON input")
            var c = self.data[self.pos]
            if c == _BACKSLASH:
                self._skip_escape()
                continue
            if c == _QUOTE:
                self.pos += 1
                break
            if c < _SPACE:
                raise self.fail(
                    "invalid character " + _quote_char(c) + " in string literal"
                )
            self.pos += 1
        return _unquote_strict(self.data[start : self.pos], start)

    def _digits(mut self) raises -> Int:
        """Run over one or more decimal digits and say how many."""
        var seen = 0
        while self.pos < len(self.data):
            var c = self.data[self.pos]
            if c < _ZERO or c > _NINE:
                break
            self.pos += 1
            seen += 1
        return seen

    def read_number(
        mut self, whole: Bool, type: String = String()
    ) raises -> String:
        """The text of one JSON number.

        The grammar is JSON's and not Go's, so `01`, `.5`, `1.` and `+1` are
        all refused here rather than accepted and then read by a parser that is
        more generous than the format. With `whole` set a fraction or an
        exponent is refused too, which is what makes a `1.5` in an integer
        field an error instead of a silent 1.

        `type` is the name of what the number is being read into, and naming it
        is what turns a value of the wrong kind from a complaint about the
        bytes into an `UnmarshalTypeError`. Left empty, which is what a caller
        reading a number for its own sake does, every refusal is a syntax
        error, since there is no field for the document to disagree with.
        """
        self.skip_space()
        var start = self.pos
        _ = self.accept(_MINUS)
        var first = self.pos
        var lead = self._digits()
        if lead == 0:
            self.pos = start
            if type == "":
                raise self.fail("expected a number")
            var kind = self._value_kind()
            if kind == "":
                raise self.fail("expected a number")
            raise self.fail_type(kind, type)
        if lead > 1 and self.data[first] == _ZERO:
            raise self.fail("a number has a leading zero")
        var fraction = False
        if self.pos < len(self.data) and self.data[self.pos] == _DOT:
            self.pos += 1
            if self._digits() == 0:
                raise self.fail("a number has nothing after its point")
            fraction = True
        if self.pos < len(self.data) and (
            self.data[self.pos] == _LOWER_E or self.data[self.pos] == _UPPER_E
        ):
            self.pos += 1
            if self.pos < len(self.data) and (
                self.data[self.pos] == _MINUS or self.data[self.pos] == _PLUS
            ):
                self.pos += 1
            if self._digits() == 0:
                raise self.fail("a number has nothing after its exponent")
            fraction = True
        var text = String(from_utf8=Span(self.data[start : self.pos]))
        if whole and fraction:
            self.pos = start
            if type == "":
                raise self.fail("expected a whole number")
            raise self.fail_type("number " + text, type)
        return text^

    def _fitted(
        mut self, type: String, whole: Bool
    ) raises -> Tuple[String, Int]:
        """The text of one number and where it started, for a read that has to
        say what it could not fit it into."""
        self.skip_space()
        var start = self.pos
        var text = self.read_number(whole, type)
        return (text^, start)

    def read_signed(mut self, bits: Int) raises -> Int64:
        """A whole number that fits in `bits` bits, sign included."""
        var type = "Int" + String(bits)
        var read = self._fitted(type, True)
        try:
            return parse_int(read[0], 10, bits)
        except:
            self.pos = read[1]
            raise self.fail_type("number " + read[0], type)

    def read_unsigned(mut self, bits: Int) raises -> UInt64:
        """A whole number that fits in `bits` bits and is not negative."""
        var type = "UInt" + String(bits)
        var read = self._fitted(type, True)
        try:
            return parse_uint(read[0], 10, bits)
        except:
            self.pos = read[1]
            raise self.fail_type("number " + read[0], type)

    def read_float(mut self, bits: Int) raises -> Float64:
        """A number, read as a float of `bits` bits."""
        var type = "Float" + String(bits)
        var read = self._fitted(type, False)
        try:
            return parse_float(read[0], bits)
        except:
            self.pos = read[1]
            raise self.fail_type("number " + read[0], type)

    def skip_value(mut self) raises:
        """Step over one whole value, whatever it is.

        This is what a key the struct does not have costs: the value is walked
        for its shape and thrown away. Go ignores unknown keys the same way,
        and a decoder that refused them could not read a document written by a
        newer version of the program that wrote it.

        The nesting is a list of the brackets still open rather than a call per
        level, which is the one place in this package where the shape of the
        code is decided by the machine underneath it. `MAX_NESTING_DEPTH` is
        ten thousand, a thread here gets eight megabytes of stack, and a frame
        holding the locals of a call that reads a string or a number does not
        fit ten thousand times over. A document of nothing but brackets has to
        come back as the refusal `enter` makes and not as a dead process, and
        that is a promise about every input rather than about the ones a
        compiler happens to leave room for.
        """
        var closing = List[Byte]()
        while True:
            var c = self.peek()
            if c == _LBRACE or c == _LBRACKET:
                self.enter()
                self.pos += 1
                closing.append(_RBRACE if c == _LBRACE else _RBRACKET)
                if not self.accept(closing[len(closing) - 1]):
                    if c == _LBRACE:
                        _ = self.read_key()
                        self.expect(_COLON)
                    # A member goes next, so start again rather than looking
                    # for what follows a value that has not been read yet.
                    continue
                self.leave()
                _ = closing.pop()
            elif c == _QUOTE:
                _ = self.read_string()
            elif c == _LOWER_T or c == _LOWER_F:
                _ = self.read_bool()
            elif c == _LOWER_N:
                if not self.accept_null():
                    raise self.fail("expected a value")
            else:
                _ = self.read_number(False)

            # One value is done. It may have been the last member of any
            # number of the brackets still open, so close them until one has
            # another member in it.
            while len(closing) > 0:
                var closer = closing[len(closing) - 1]
                if self.accept(_COMMA):
                    if closer == _RBRACE:
                        _ = self.read_key()
                        self.expect(_COLON)
                    break
                self.expect(closer)
                self.leave()
                _ = closing.pop()
            if len(closing) == 0:
                return

    def read_raw(mut self) raises -> RawMessage:
        """One whole value, kept as the bytes it was written with.

        What a `RawMessage` field turns into, and the way a document decides
        its own shape: the bytes are walked far enough to know where the value
        ends and are not read for what they mean, so a payload whose type is
        named by a field beside it can be read a second time once that field
        has been.
        """
        self.skip_space()
        var start = self.pos
        self.skip_value()
        return RawMessage(self.data[start : self.pos])

    def unknown_key(mut self, key: String) raises:
        """A key no field matched, stepped over or refused.

        Which of the two is `disallow_unknown`, and the message is Go's word
        for word so that a program moved off Go reads the same failure. It is
        not a syntax error and does not carry `ErrJSONSyntax`, because the
        document is well formed JSON and the disagreement is about what the
        reader expected rather than about the bytes. The offset is on it all
        the same, naming the value the key introduced, because the scanner
        knows where it is and Go's decoder does not.
        """
        if not self.disallow_unknown:
            self.skip_value()
            return
        raise (
            Report('json: unknown field "' + key + '"')
            .with_field("offset", String(self.pos + 1))
            .error()
        )

    def end(mut self) raises:
        """Check that the value just read was the whole input."""
        self.skip_space()
        if self.pos != len(self.data):
            raise self.fail("invalid character after top-level value")


def missing_key(struct_name: StaticString, key: String) -> Error:
    """What a generated decoder raises when a key it needs was not there.

    Go leaves a missing field at its zero value. Mojo has no zero value to
    leave it at, so a field that is not `Optional` and not in the document is
    an error rather than a guess. An `Optional` field is the way to say that a
    key may be absent.
    """
    return new(
        "json: "
        + String(struct_name)
        + ': the document has no "'
        + key
        + '" key'
    )


def _append_escape(mut dst: List[Byte], c: Byte):
    """One byte that cannot appear in a JSON string as itself."""
    var digits = _HEX.as_bytes()
    dst.append(_BACKSLASH)
    dst.append(_LOWER_U)
    dst.append(_ZERO)
    dst.append(_ZERO)
    dst.append(digits[Int(c >> 4)])
    dst.append(digits[Int(c & 0xF)])


def append_string[o: ImmOrigin](mut dst: List[Byte], s: StringSlice[o]):
    """One string onto the end of `dst` as a quoted JSON string.

    The escaping is Go's `encoding/json` and not the JSON grammar's minimum:
    `<`, `>` and `&` go out as escapes so that the result can be embedded in an
    HTML page without closing a script tag, and U+2028 and U+2029 go out as
    escapes because they are line terminators to a JavaScript parser and are
    not to a JSON one. Matching Go matters more here than terse output, since
    the two are going to be compared byte for byte.

    `Value.write_to` makes the other choice and escapes only what RFC 8259
    requires, because a document that arrived in UTF-8 should leave in UTF-8.
    The difference is Go's: `Marshal` escapes and `Compact` does not.
    """
    dst.append(_QUOTE)
    var data = s.as_bytes()
    var start = 0
    var i = 0
    while i < len(data):
        var c = data[i]
        if c < Byte(0x80):
            if (
                c >= _SPACE
                and c != _QUOTE
                and c != _BACKSLASH
                and c != _LESS
                and c != _GREATER
                and c != _AMPERSAND
            ):
                i += 1
                continue
            if start < i:
                dst.extend(data[start:i])
            if c == _QUOTE or c == _BACKSLASH:
                dst.append(_BACKSLASH)
                dst.append(c)
            elif c == _NEWLINE:
                dst.append(_BACKSLASH)
                dst.append(_LOWER_N)
            elif c == _RETURN:
                dst.append(_BACKSLASH)
                dst.append(_LOWER_R)
            elif c == _TAB:
                dst.append(_BACKSLASH)
                dst.append(_LOWER_T)
            else:
                _append_escape(dst, c)
            i += 1
            start = i
            continue
        # U+2028 and U+2029, which are E2 80 A8 and E2 80 A9 in UTF-8.
        if (
            c == _E2
            and i + 2 < len(data)
            and data[i + 1] == _80
            and (data[i + 2] & ~Byte(1)) == _A8
        ):
            if start < i:
                dst.extend(data[start:i])
            dst.extend("\\u202".as_bytes())
            dst.append(_HEX.as_bytes()[Int(data[i + 2] & 0xF)])
            i += 3
            start = i
            continue
        i += 1
    if start < len(data):
        dst.extend(data[start:])
    dst.append(_QUOTE)


def append_raw(mut dst: List[Byte], m: RawMessage):
    """A value that is already JSON, written through unchanged.

    The whitespace inside it goes out as it came in, which is the point: a raw
    message is the bytes somebody sent, and reformatting them would mean a
    payload signed by whoever wrote it no longer verifies.
    """
    if len(m.bytes) == 0:
        dst.extend("null".as_bytes())
        return
    dst.extend(Span(m.bytes))


def append_bool(mut dst: List[Byte], b: Bool):
    """`true` or `false`."""
    dst.extend(("true" if b else "false").as_bytes())


def append_signed(mut dst: List[Byte], i: Int64) raises:
    """A signed number."""
    dst.extend(format_int(i, 10).as_bytes())


def append_unsigned(mut dst: List[Byte], i: UInt64) raises:
    """An unsigned number."""
    dst.extend(format_uint(i, 10).as_bytes())


def append_float(mut dst: List[Byte], f: Float64, bits: Int) raises:
    """A number, formatted the way Go's `encoding/json` formats one.

    Shortest round trip digits, with the exponent form only outside the range
    where the plain one is readable, and the exponent itself written without a
    leading zero. Go does the last of those by hand after formatting and so
    does this, for the same reason: nobody else spells it that way.

    Raises an `UnsupportedValueError` for a float that is infinite or is not a
    number, in Go's words, since JSON has no way to spell either.
    """
    # Infinity times zero is not a number and neither is a number that already
    # was not one, which is both of the cases JSON cannot hold in one test.
    if f * 0.0 != 0.0:
        if f != f:
            raise _unsupported_value("NaN")
        raise _unsupported_value("+Inf" if f > 0 else "-Inf")
    var magnitude = f if f >= 0 else -f
    var form = _LOWER_F
    if magnitude != 0.0 and (magnitude < 1e-6 or magnitude >= 1e21):
        form = _LOWER_E
    var text = format_float(f, form, -1, bits)
    if form == _LOWER_E:
        var b = text.as_bytes()
        var n = len(b)
        if (
            n >= 4
            and b[n - 4] == _LOWER_E
            and b[n - 3] == _MINUS
            and b[n - 2] == _ZERO
        ):
            dst.extend(b[: n - 2])
            dst.append(b[n - 1])
            return
    dst.extend(text.as_bytes())
