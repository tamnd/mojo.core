# The part of a generated codec that is the same for every struct: a scanner
# over the input bytes and the handful of writers the encoder calls. This file
# is a template rather than a module. Everything below the BEGIN line is copied
# verbatim into each generated file, and the IMPORT lines above it are merged
# with the imports the generated half needs.
#
# It is copied rather than imported because a generated codec has to work for
# somebody who has this library and nothing else of ours. `core.encoding.json`
# does not exist yet, and when it does the emitter can import its scanner
# instead of copying this, which will show up as a diff in every checked in
# codec and is the point of checking them in.
#
# It is a real Mojo file so that it can be edited with the compiler watching:
# `pixi run codec-selftest` compiles what comes out of it on every run.
#
# IMPORT from core.errors import new
# IMPORT from core.strconv import format_float, format_int, format_uint, parse_float, parse_int, parse_uint
# IMPORT from core.strings import Builder
#
# BEGIN

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
