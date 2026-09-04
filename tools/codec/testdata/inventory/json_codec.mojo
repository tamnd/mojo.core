"""JSON for Item, Sparse, Summary and Vendor, generated from the structs themselves.

Written by `tools/codec` out of the fields and struct tags of the
`inventory` package. Do not edit it: change the struct or its tags and
run the generator again. It is checked in so that it can be read, reviewed and
built without running anything, and regenerating it has to produce this file
byte for byte.

Each struct has two entry points:

```mojo
var text = marshal_json(item)
var back: Item = unmarshal_json_item(text.as_bytes())
```

The encoder is overloaded on its argument, so every struct here has one called
`marshal_json`. The decoder is told apart from the others only by the type it
produces, which Mojo will not overload on, so its name carries the struct.

A key in the document that no field matches is skipped, the way Go skips one.
A field that is not in the document is an error, because Mojo has no zero value
to leave it at. `Optional` is how a field says it may be absent.

The scanner below the imports is a copy rather than an import. A generated
codec has to build for somebody who has this library and nothing else of ours,
and `core.encoding.json` does not exist yet.
"""

from core.errors import new
from core.strconv import (
    format_float,
    format_int,
    format_uint,
    parse_float,
    parse_int,
    parse_uint,
)
from core.strings import Builder

from .items import Item, Sparse
from .summaries import Summary
from .vendors import Vendor


comptime _TAB = Byte(9)
comptime _NEWLINE = Byte(10)
comptime _RETURN = Byte(13)
comptime _SPACE = Byte(32)
comptime _QUOTE = Byte(34)
comptime _AMPERSAND = Byte(38)
comptime _COMMA = Byte(44)
comptime _MINUS = Byte(45)
comptime _DOT = Byte(46)
comptime _SLASH = Byte(47)
comptime _ZERO = Byte(48)
comptime _NINE = Byte(57)
comptime _COLON = Byte(58)
comptime _LESS = Byte(60)
comptime _GREATER = Byte(62)
comptime _UPPER_A = Byte(65)
comptime _UPPER_E = Byte(69)
comptime _UPPER_F = Byte(70)
comptime _LBRACKET = Byte(91)
comptime _BACKSLASH = Byte(92)
comptime _RBRACKET = Byte(93)
comptime _LOWER_A = Byte(97)
comptime _LOWER_B = Byte(98)
comptime _LOWER_E = Byte(101)
comptime _LOWER_F = Byte(102)
comptime _LOWER_N = Byte(110)
comptime _LOWER_R = Byte(114)
comptime _LOWER_T = Byte(116)
comptime _LOWER_U = Byte(117)
comptime _LBRACE = Byte(123)
comptime _RBRACE = Byte(125)

comptime _HEX = "0123456789abcdef"

comptime _MAX_DEPTH = 10000
"""How deep the input is allowed to nest, which is Go's `maxNestingDepth`.

Nesting is what turns a small input into a large stack. Both the generated
decoders and `skip_value` count their depth against this, so a megabyte of
open brackets is a raise rather than a crash.
"""

comptime _REPLACEMENT = 0xFFFD
"""What an escape that is not a character turns into, which is Go's answer too.

A lone surrogate half is well formed JSON and is not a character, and Go's
decoder writes U+FFFD for it rather than refusing the document. Refusing would
be defensible; differing from Go quietly would not be.
"""


def _byte_name(c: Byte) -> String:
    """One byte as it should read in an error message."""
    if c >= _SPACE and c < Byte(127):
        return "'" + chr(Int(c)) + "'"
    return "byte " + String(Int(c))


def _write_rune(mut out: List[Byte], r: Int):
    """One code point onto the end of `out` as UTF-8."""
    if r < 0x80:
        out.append(Byte(r))
    elif r < 0x800:
        out.append(Byte(0xC0 | (r >> 6)))
        out.append(Byte(0x80 | (r & 0x3F)))
    elif r < 0x10000:
        out.append(Byte(0xE0 | (r >> 12)))
        out.append(Byte(0x80 | ((r >> 6) & 0x3F)))
        out.append(Byte(0x80 | (r & 0x3F)))
    else:
        out.append(Byte(0xF0 | (r >> 18)))
        out.append(Byte(0x80 | ((r >> 12) & 0x3F)))
        out.append(Byte(0x80 | ((r >> 6) & 0x3F)))
        out.append(Byte(0x80 | (r & 0x3F)))


struct _Scanner[o: ImmOrigin](Movable):
    """The input, a position in it, and how deeply nested that position is.

    Every generated decoder walks one of these. The methods are the JSON
    grammar and nothing above it: reading a value into a field is the generated
    code's job, and knowing that `[` starts an array is this one's.
    """

    var data: Span[Byte, Self.o]
    var pos: Int
    var depth: Int

    def __init__(out self, data: Span[Byte, Self.o]):
        self.data = data
        self.pos = 0
        self.depth = 0

    def fail(self, what: String) -> Error:
        """An error naming the byte it happened at.

        Offsets rather than lines and columns, because the offset is what a
        caller can slice the input with and counting lines costs a pass over
        everything read so far.
        """
        return new("json: at byte " + String(self.pos) + ": " + what)

    def enter(mut self) raises:
        """Go one level deeper into the input, or refuse to."""
        self.depth += 1
        if self.depth > _MAX_DEPTH:
            raise self.fail("nested more than " + String(_MAX_DEPTH) + " deep")

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
            raise self.fail("the input ended in the middle of a value")
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
            raise self.fail("expected " + _byte_name(c))

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
        raise self.fail("expected true or false")

    def _hex4(mut self) raises -> Int:
        """The four hexadecimal digits of a `\\u` escape."""
        if self.pos + 4 > len(self.data):
            raise self.fail("a \\u escape ran off the end of the input")
        var r = 0
        for i in range(4):
            var c = self.data[self.pos + i]
            if c >= _ZERO and c <= _NINE:
                r = r * 16 + Int(c - _ZERO)
            elif c >= _LOWER_A and c <= _LOWER_F:
                r = r * 16 + Int(c - _LOWER_A) + 10
            elif c >= _UPPER_A and c <= _UPPER_F:
                r = r * 16 + Int(c - _UPPER_A) + 10
            else:
                raise self.fail("a \\u escape is not four hexadecimal digits")
        self.pos += 4
        return r

    def _escape(mut self, mut out: List[Byte]) raises:
        """One escape sequence, the backslash already taken."""
        if self.pos >= len(self.data):
            raise self.fail("the input ended in the middle of an escape")
        var c = self.data[self.pos]
        self.pos += 1
        if c == _QUOTE or c == _BACKSLASH or c == _SLASH:
            out.append(c)
        elif c == _LOWER_B:
            out.append(Byte(8))
        elif c == _LOWER_F:
            out.append(Byte(12))
        elif c == _LOWER_N:
            out.append(_NEWLINE)
        elif c == _LOWER_R:
            out.append(_RETURN)
        elif c == _LOWER_T:
            out.append(_TAB)
        elif c == _LOWER_U:
            var r = self._hex4()
            if r >= 0xD800 and r <= 0xDBFF:
                # A high surrogate, which is half of a character. Its low half
                # has to be the next escape or there is no character here.
                var saved = self.pos
                var another = (
                    self.pos + 1 < len(self.data)
                    and self.data[self.pos] == _BACKSLASH
                    and self.data[self.pos + 1] == _LOWER_U
                )
                if another:
                    self.pos += 2
                    var low = self._hex4()
                    if low >= 0xDC00 and low <= 0xDFFF:
                        var whole = (
                            0x10000 + ((r - 0xD800) << 10) + (low - 0xDC00)
                        )
                        _write_rune(out, whole)
                        return
                    self.pos = saved
                _write_rune(out, _REPLACEMENT)
            elif r >= 0xDC00 and r <= 0xDFFF:
                _write_rune(out, _REPLACEMENT)
            else:
                _write_rune(out, r)
        else:
            raise self.fail("\\" + _byte_name(c) + " is not an escape")

    def read_string(mut self) raises -> String:
        """One JSON string, with its escapes resolved."""
        self.expect(_QUOTE)
        var out = List[Byte]()
        while True:
            if self.pos >= len(self.data):
                raise self.fail("the input ended in the middle of a string")
            var c = self.data[self.pos]
            if c == _QUOTE:
                self.pos += 1
                break
            if c == _BACKSLASH:
                self.pos += 1
                self._escape(out)
                continue
            if c < _SPACE:
                raise self.fail(
                    "a string holds " + _byte_name(c) + " unescaped"
                )
            out.append(c)
            self.pos += 1
        return String(from_utf8=Span(out))

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

    def read_number(mut self, whole: Bool) raises -> String:
        """The text of one JSON number.

        The grammar is JSON's and not Go's, so `01`, `.5`, `1.` and `+1` are
        all refused here rather than accepted and then read by a parser that is
        more generous than the format. With `whole` set a fraction or an
        exponent is refused too, which is what makes a `1.5` in an integer
        field an error instead of a silent 1.
        """
        self.skip_space()
        var start = self.pos
        _ = self.accept(_MINUS)
        var first = self.pos
        var lead = self._digits()
        if lead == 0:
            raise self.fail("expected a number")
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
                self.data[self.pos] == _MINUS or self.data[self.pos] == Byte(43)
            ):
                self.pos += 1
            if self._digits() == 0:
                raise self.fail("a number has nothing after its exponent")
            fraction = True
        if whole and fraction:
            self.pos = start
            raise self.fail("expected a whole number")
        return String(from_utf8=Span(self.data[start : self.pos]))

    def read_signed(mut self, bits: Int) raises -> Int64:
        """A whole number that fits in `bits` bits, sign included."""
        return parse_int(self.read_number(True), 10, bits)

    def read_unsigned(mut self, bits: Int) raises -> UInt64:
        """A whole number that fits in `bits` bits and is not negative."""
        return parse_uint(self.read_number(True), 10, bits)

    def read_float(mut self, bits: Int) raises -> Float64:
        """A number, read as a float of `bits` bits."""
        return parse_float(self.read_number(False), bits)

    def skip_value(mut self) raises:
        """Step over one whole value, whatever it is.

        This is what a key the struct does not have costs: the value is walked
        for its shape and thrown away. Go ignores unknown keys the same way,
        and a decoder that refused them could not read a document written by a
        newer version of the program that wrote it.
        """
        var c = self.peek()
        if c == _QUOTE:
            _ = self.read_string()
        elif c == _LBRACE:
            self.enter()
            self.pos += 1
            if not self.accept(_RBRACE):
                while True:
                    _ = self.read_string()
                    self.expect(_COLON)
                    self.skip_value()
                    if self.accept(_COMMA):
                        continue
                    break
                self.expect(_RBRACE)
            self.leave()
        elif c == _LBRACKET:
            self.enter()
            self.pos += 1
            if not self.accept(_RBRACKET):
                while True:
                    self.skip_value()
                    if self.accept(_COMMA):
                        continue
                    break
                self.expect(_RBRACKET)
            self.leave()
        elif c == _LOWER_T or c == _LOWER_F:
            _ = self.read_bool()
        elif c == _LOWER_N:
            if not self.accept_null():
                raise self.fail("expected a value")
        else:
            _ = self.read_number(False)

    def end(mut self) raises:
        """Check that the value just read was the whole input."""
        self.skip_space()
        if self.pos != len(self.data):
            raise self.fail("there is more input after the end of the value")


def _missing(struct_name: StaticString, key: String) -> Error:
    """What a decoder raises when a key it needs was not in the document.

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


def _write_escape(c: Byte, mut out: Builder) raises:
    """One byte that cannot appear in a JSON string as itself."""
    out.write_byte(_BACKSLASH)
    out.write_byte(_LOWER_U)
    out.write_byte(_ZERO)
    out.write_byte(_ZERO)
    var digits = _HEX.as_bytes()
    out.write_byte(digits[Int(c >> 4)])
    out.write_byte(digits[Int(c & 0xF)])


def _write_string[o: ImmOrigin](s: StringSlice[o], mut out: Builder) raises:
    """One string as a quoted JSON string.

    The escaping is Go's `encoding/json` and not the JSON grammar's minimum:
    `<`, `>` and `&` go out as escapes so that the result can be embedded in an
    HTML page without closing a script tag, and U+2028 and U+2029 go out as
    escapes because they are line terminators to a JavaScript parser and are
    not to a JSON one. Matching Go matters more here than terse output, since
    the two are going to be compared byte for byte.
    """
    out.write_byte(_QUOTE)
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
                _ = out.write(data[start:i])
            if c == _QUOTE or c == _BACKSLASH:
                out.write_byte(_BACKSLASH)
                out.write_byte(c)
            elif c == _NEWLINE:
                out.write_byte(_BACKSLASH)
                out.write_byte(_LOWER_N)
            elif c == _RETURN:
                out.write_byte(_BACKSLASH)
                out.write_byte(_LOWER_R)
            elif c == _TAB:
                out.write_byte(_BACKSLASH)
                out.write_byte(_LOWER_T)
            else:
                _write_escape(c, out)
            i += 1
            start = i
            continue
        # U+2028 and U+2029, which are E2 80 A8 and E2 80 A9 in UTF-8.
        if (
            c == Byte(0xE2)
            and i + 2 < len(data)
            and data[i + 1] == Byte(0x80)
            and (data[i + 2] == Byte(0xA8) or data[i + 2] == Byte(0xA9))
        ):
            if start < i:
                _ = out.write(data[start:i])
            _ = out.write_string("\\u202")
            out.write_byte(_HEX.as_bytes()[Int(data[i + 2] - Byte(0xA0))])
            i += 3
            start = i
            continue
        i += 1
    if start < len(data):
        _ = out.write(data[start:])
    out.write_byte(_QUOTE)


def _write_bool(b: Bool, mut out: Builder) raises:
    """`true` or `false`."""
    _ = out.write_string("true" if b else "false")


def _write_signed(i: Int64, mut out: Builder) raises:
    """A signed number."""
    _ = out.write_string(format_int(i, 10))


def _write_unsigned(i: UInt64, mut out: Builder) raises:
    """An unsigned number."""
    _ = out.write_string(format_uint(i, 10))


def _write_float(f: Float64, bits: Int, mut out: Builder) raises:
    """A number, formatted the way Go's `encoding/json` formats one.

    Shortest round trip digits, with the exponent form only outside the range
    where the plain one is readable, and the exponent itself written without a
    leading zero. Go does the last of those by hand after formatting and so
    does this, for the same reason: nobody else spells it that way.
    """
    # Infinity times zero is not a number and neither is a number that already
    # was not one, which is both of the cases JSON cannot hold in one test.
    if f * 0.0 != 0.0:
        raise new("json: " + String(f) + " has no JSON representation")
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
            _ = out.write(b[: n - 2])
            out.write_byte(b[n - 1])
            return
    _ = out.write_string(text)


# ----------------------------------------------------------------------------
# inventory.items.Item
# ----------------------------------------------------------------------------


def marshal_json(value: Item) raises -> String:
    """`value` as a JSON object."""
    var out = Builder()
    _encode_item(value, out)
    return out.string()


def _encode_item(value: Item, mut out: Builder) raises:
    """One object onto the end of `out`, for a field or for the whole value."""
    out.write_byte(_LBRACE)
    _ = out.write_string('"name":')
    _write_string(value.name, out)
    out.write_byte(_COMMA)
    _ = out.write_string('"id":')
    _write_signed(Int64(value.sku), out)
    out.write_byte(_COMMA)
    _ = out.write_string('"weight":')
    _write_float(Float64(value.weight), 32, out)
    out.write_byte(_COMMA)
    _ = out.write_string('"code":')
    _write_unsigned(UInt64(value.code), out)
    out.write_byte(_COMMA)
    _ = out.write_string('"vendor":')
    _encode_vendor(value.vendor, out)
    out.write_byte(_COMMA)
    _ = out.write_string('"alternates":')
    out.write_byte(_LBRACKET)
    var first2 = True
    for item1 in value.alternates:
        if not first2:
            out.write_byte(_COMMA)
        first2 = False
        _encode_vendor(item1, out)
    out.write_byte(_RBRACKET)
    out.write_byte(_COMMA)
    _ = out.write_string('"sizes":')
    out.write_byte(_LBRACE)
    var keys3 = List[String]()
    for entry4 in value.sizes.items():
        keys3.append(entry4.key)
    sort(keys3)
    var first6 = True
    for key5 in keys3:
        if not first6:
            out.write_byte(_COMMA)
        first6 = False
        _write_string(key5, out)
        out.write_byte(_COLON)
        _write_signed(Int64(value.sizes[key5]), out)
    out.write_byte(_RBRACE)
    if len(value.tags) != 0:
        out.write_byte(_COMMA)
        _ = out.write_string('"tags":')
        out.write_byte(_LBRACKET)
        var first8 = True
        for item7 in value.tags:
            if not first8:
                out.write_byte(_COMMA)
            first8 = False
            _write_string(item7, out)
        out.write_byte(_RBRACKET)
    if value.count:
        out.write_byte(_COMMA)
        _ = out.write_string('"count":')
        _write_signed(Int64(value.count.value()), out)
    out.write_byte(_COMMA)
    _ = out.write_string('"note":')
    if value.note:
        _write_string(value.note.value(), out)
    else:
        _ = out.write_string("null")
    out.write_byte(_RBRACE)


def unmarshal_json_item(out result: Item, data: Span[Byte, _]) raises:
    """The whole of `data` as one `Item`."""
    var sc = _Scanner(data)
    result = _decode_item(sc)
    sc.end()


def _decode_item(out result: Item, mut sc: _Scanner[_]) raises:
    """One object out of `sc`, wherever in the document it is."""
    var v_name = Optional[String]()
    var v_sku = Optional[Int64]()
    var v_weight = Optional[Float32]()
    var v_code = Optional[UInt8]()
    var v_vendor = Optional[Vendor]()
    var v_alternates = List[Vendor]()
    var v_sizes = Dict[String, Int64]()
    var v_tags = List[String]()
    var v_count = Optional[Int]()
    var v_note = Optional[String]()
    sc.enter()
    sc.expect(_LBRACE)
    if not sc.accept(_RBRACE):
        while True:
            var key = sc.read_string()
            sc.expect(_COLON)
            if key == "name":
                v_name = sc.read_string()
            elif key == "id":
                v_sku = Int64(sc.read_signed(64))
            elif key == "weight":
                v_weight = Float32(sc.read_float(32))
            elif key == "code":
                v_code = UInt8(sc.read_unsigned(8))
            elif key == "vendor":
                v_vendor = _decode_vendor(sc)
            elif key == "alternates":
                var held1 = List[Vendor]()
                sc.enter()
                sc.expect(_LBRACKET)
                if not sc.accept(_RBRACKET):
                    while True:
                        var item2 = _decode_vendor(sc)
                        held1.append(item2^)
                        if sc.accept(_COMMA):
                            continue
                        break
                    sc.expect(_RBRACKET)
                sc.leave()
                v_alternates = held1^
            elif key == "sizes":
                var held3 = Dict[String, Int64]()
                sc.enter()
                sc.expect(_LBRACE)
                if not sc.accept(_RBRACE):
                    while True:
                        var key4 = sc.read_string()
                        sc.expect(_COLON)
                        var held5 = Int64(sc.read_signed(64))
                        held3[key4^] = held5
                        if sc.accept(_COMMA):
                            continue
                        break
                    sc.expect(_RBRACE)
                sc.leave()
                v_sizes = held3^
            elif key == "tags":
                var held6 = List[String]()
                sc.enter()
                sc.expect(_LBRACKET)
                if not sc.accept(_RBRACKET):
                    while True:
                        var item7 = sc.read_string()
                        held6.append(item7^)
                        if sc.accept(_COMMA):
                            continue
                        break
                    sc.expect(_RBRACKET)
                sc.leave()
                v_tags = held6^
            elif key == "count":
                var held8 = Optional[Int]()
                if not sc.accept_null():
                    var held9 = Int(sc.read_signed(0))
                    held8 = held9
                v_count = held8^
            elif key == "note":
                var held10 = Optional[String]()
                if not sc.accept_null():
                    var held11 = sc.read_string()
                    held10 = held11^
                v_note = held10^
            else:
                sc.skip_value()
            if sc.accept(_COMMA):
                continue
            break
        sc.expect(_RBRACE)
    sc.leave()
    if not v_name:
        raise _missing("Item", "name")
    if not v_sku:
        raise _missing("Item", "id")
    if not v_weight:
        raise _missing("Item", "weight")
    if not v_code:
        raise _missing("Item", "code")
    if not v_vendor:
        raise _missing("Item", "vendor")
    result = Item(
        v_name.take(),
        v_sku.take(),
        v_weight.take(),
        v_code.take(),
        v_vendor.take(),
        v_alternates^,
        v_sizes^,
        v_tags^,
        v_count^,
        v_note^,
    )


# ----------------------------------------------------------------------------
# inventory.items.Sparse
# ----------------------------------------------------------------------------


def marshal_json(value: Sparse) raises -> String:
    """`value` as a JSON object."""
    var out = Builder()
    _encode_sparse(value, out)
    return out.string()


def _encode_sparse(value: Sparse, mut out: Builder) raises:
    """One object onto the end of `out`, for a field or for the whole value."""
    out.write_byte(_LBRACE)
    var wrote = False
    if value.first:
        _ = out.write_string('"first":')
        _write_signed(Int64(value.first.value()), out)
        wrote = True
    if len(value.rest) != 0:
        if wrote:
            out.write_byte(_COMMA)
        _ = out.write_string('"rest":')
        out.write_byte(_LBRACKET)
        var first2 = True
        for item1 in value.rest:
            if not first2:
                out.write_byte(_COMMA)
            first2 = False
            _write_string(item1, out)
        out.write_byte(_RBRACKET)
        wrote = True
    if wrote:
        out.write_byte(_COMMA)
    _ = out.write_string('"last":')
    _write_string(value.last, out)
    out.write_byte(_RBRACE)


def unmarshal_json_sparse(out result: Sparse, data: Span[Byte, _]) raises:
    """The whole of `data` as one `Sparse`."""
    var sc = _Scanner(data)
    result = _decode_sparse(sc)
    sc.end()


def _decode_sparse(out result: Sparse, mut sc: _Scanner[_]) raises:
    """One object out of `sc`, wherever in the document it is."""
    var v_first = Optional[Int]()
    var v_rest = List[String]()
    var v_last = Optional[String]()
    sc.enter()
    sc.expect(_LBRACE)
    if not sc.accept(_RBRACE):
        while True:
            var key = sc.read_string()
            sc.expect(_COLON)
            if key == "first":
                var held1 = Optional[Int]()
                if not sc.accept_null():
                    var held2 = Int(sc.read_signed(0))
                    held1 = held2
                v_first = held1^
            elif key == "rest":
                var held3 = List[String]()
                sc.enter()
                sc.expect(_LBRACKET)
                if not sc.accept(_RBRACKET):
                    while True:
                        var item4 = sc.read_string()
                        held3.append(item4^)
                        if sc.accept(_COMMA):
                            continue
                        break
                    sc.expect(_RBRACKET)
                sc.leave()
                v_rest = held3^
            elif key == "last":
                v_last = sc.read_string()
            else:
                sc.skip_value()
            if sc.accept(_COMMA):
                continue
            break
        sc.expect(_RBRACE)
    sc.leave()
    if not v_last:
        raise _missing("Sparse", "last")
    result = Sparse(v_first^, v_rest^, v_last.take())


# ----------------------------------------------------------------------------
# inventory.summaries.Summary
# ----------------------------------------------------------------------------


def marshal_json(value: Summary) raises -> String:
    """`value` as a JSON object."""
    var out = Builder()
    _encode_summary(value, out)
    return out.string()


def _encode_summary(value: Summary, mut out: Builder) raises:
    """One object onto the end of `out`, for a field or for the whole value."""
    out.write_byte(_LBRACE)
    _ = out.write_string('"label":')
    _write_string(value.label, out)
    out.write_byte(_COMMA)
    _ = out.write_string('"takings":')
    _write_float(Float64(value.takings), 64, out)
    out.write_byte(_RBRACE)


# Summary has a field tagged `-`, which the document does not carry,
# so there is nothing to construct one from and it encodes only.


# ----------------------------------------------------------------------------
# inventory.vendors.Vendor
# ----------------------------------------------------------------------------


def marshal_json(value: Vendor) raises -> String:
    """`value` as a JSON object."""
    var out = Builder()
    _encode_vendor(value, out)
    return out.string()


def _encode_vendor(value: Vendor, mut out: Builder) raises:
    """One object onto the end of `out`, for a field or for the whole value."""
    out.write_byte(_LBRACE)
    _ = out.write_string('"name":')
    _write_string(value.name, out)
    out.write_byte(_COMMA)
    _ = out.write_string('"rating":')
    _write_float(Float64(value.rating), 64, out)
    out.write_byte(_COMMA)
    _ = out.write_string('"active":')
    _write_bool(value.active, out)
    out.write_byte(_RBRACE)


def unmarshal_json_vendor(out result: Vendor, data: Span[Byte, _]) raises:
    """The whole of `data` as one `Vendor`."""
    var sc = _Scanner(data)
    result = _decode_vendor(sc)
    sc.end()


def _decode_vendor(out result: Vendor, mut sc: _Scanner[_]) raises:
    """One object out of `sc`, wherever in the document it is."""
    var v_name = Optional[String]()
    var v_rating = Optional[Float64]()
    var v_active = Optional[Bool]()
    sc.enter()
    sc.expect(_LBRACE)
    if not sc.accept(_RBRACE):
        while True:
            var key = sc.read_string()
            sc.expect(_COLON)
            if key == "name":
                v_name = sc.read_string()
            elif key == "rating":
                v_rating = Float64(sc.read_float(64))
            elif key == "active":
                v_active = sc.read_bool()
            else:
                sc.skip_value()
            if sc.accept(_COMMA):
                continue
            break
        sc.expect(_RBRACE)
    sc.leave()
    if not v_name:
        raise _missing("Vendor", "name")
    if not v_rating:
        raise _missing("Vendor", "rating")
    if not v_active:
        raise _missing("Vendor", "active")
    result = Vendor(v_name.take(), v_rating.take(), v_active.take())
