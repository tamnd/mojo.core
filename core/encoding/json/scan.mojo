"""The state machine every other file here runs on. Go's `scanner`.

One byte at a time, no lookahead, no buffer of its own. `step` is handed the
next byte and answers with an opcode saying what just happened: an
uninteresting byte, the start of a literal, the start or end of an object or an
array, a byte of whitespace that may be dropped, the end of the top level
value, or a failure. That is enough for `valid`, `compact`, `indent` and the
token half of `Decoder` to be four short loops over the same machine rather
than four parsers that have to agree with each other.

Go stores the next state as a function pointer, on the reasoning that it was
ten percent faster than a switch. Here it is a number and the switch is a chain
of comparisons, because a function pointer in a struct is not a shape this
library uses and because the states delegate to each other constantly, which a
number and a loop express directly.

Nesting is capped at ten thousand levels, which is Go's cap and is the one RFC
7159 section 9 says an implementation may set. A few kilobytes of open brackets
is otherwise a stack the size of the input.
"""

from core.errors import Code, Report, capture
from core.errors.codes import ErrJSONSyntax
from core.io import Byte
from core.strconv import quote_rune

comptime _TAB = Byte(9)
comptime _NEWLINE = Byte(10)
comptime _RETURN = Byte(13)
comptime _SPACE = Byte(32)
comptime _QUOTE = Byte(34)
comptime _PLUS = Byte(43)
comptime _COMMA = Byte(44)
comptime _MINUS = Byte(45)
comptime _DOT = Byte(46)
comptime _ZERO = Byte(48)
comptime _ONE = Byte(49)
comptime _NINE = Byte(57)
comptime _COLON = Byte(58)
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
comptime _LOWER_L = Byte(108)
comptime _LOWER_N = Byte(110)
comptime _LOWER_R = Byte(114)
comptime _LOWER_S = Byte(115)
comptime _LOWER_T = Byte(116)
comptime _LOWER_U = Byte(117)
comptime _LBRACE = Byte(123)
comptime _RBRACE = Byte(125)

comptime _SCAN_CONTINUE = 0
"""A byte with nothing to report, such as a byte inside a string."""

comptime _SCAN_BEGIN_LITERAL = 1
"""The first byte of a string, a number, `true`, `false` or `null`.

Where it ends is implied by the next opcode that is not `_SCAN_CONTINUE`, which
is how a number can be recognised without lookahead: `123` is a whole value
only once a byte arrives that cannot continue it.
"""

comptime _SCAN_BEGIN_OBJECT = 2
"""An opening brace."""

comptime _SCAN_OBJECT_KEY = 3
"""The colon after an object key, so the key ended before this byte."""

comptime _SCAN_OBJECT_VALUE = 4
"""The comma after an object value that is not the last one."""

comptime _SCAN_END_OBJECT = 5
"""A closing brace, which also ends the value before it."""

comptime _SCAN_BEGIN_ARRAY = 6
"""An opening bracket."""

comptime _SCAN_ARRAY_VALUE = 7
"""The comma after an array element that is not the last one."""

comptime _SCAN_END_ARRAY = 8
"""A closing bracket, which also ends the value before it."""

comptime _SCAN_SKIP_SPACE = 9
"""Whitespace between values, which anything copying bytes may drop.

The last of the opcodes that mean carry on, which is what lets `compact` test
`v >= _SCAN_SKIP_SPACE` for the byte having no place in the output.
"""

comptime _SCAN_END = 10
"""The top level value ended before this byte, not at it."""

comptime _SCAN_ERROR = 11
"""The input is not JSON. Every later call answers the same."""

comptime MAX_NESTING_DEPTH = 10000
"""How deep the input may nest. Go's `maxNestingDepth`.

Nesting is the one thing in a document that costs more than its own length to
read, since every open bracket has to be remembered until it closes. RFC 7159
section 9 says an implementation may set a limit and this is Go's.
"""

comptime _PARSE_OBJECT_KEY = 0
"""Inside an object, before the colon."""

comptime _PARSE_OBJECT_VALUE = 1
"""Inside an object, after the colon."""

comptime _PARSE_ARRAY_VALUE = 2
"""Inside an array."""

comptime _S_BEGIN_VALUE = 0
comptime _S_BEGIN_VALUE_OR_EMPTY = 1
comptime _S_BEGIN_STRING_OR_EMPTY = 2
comptime _S_BEGIN_STRING = 3
comptime _S_END_VALUE = 4
comptime _S_END_TOP = 5
comptime _S_IN_STRING = 6
comptime _S_IN_STRING_ESC = 7
comptime _S_IN_STRING_ESC_U = 8
comptime _S_IN_STRING_ESC_U1 = 9
comptime _S_IN_STRING_ESC_U12 = 10
comptime _S_IN_STRING_ESC_U123 = 11
comptime _S_NEG = 12
comptime _S_1 = 13
comptime _S_0 = 14
comptime _S_DOT = 15
comptime _S_DOT_0 = 16
comptime _S_E = 17
comptime _S_E_SIGN = 18
comptime _S_E_0 = 19
comptime _S_T = 20
comptime _S_TR = 21
comptime _S_TRU = 22
comptime _S_F = 23
comptime _S_FA = 24
comptime _S_FAL = 25
comptime _S_FALS = 26
comptime _S_N = 27
comptime _S_NU = 28
comptime _S_NUL = 29
comptime _S_ERROR = 30


def _is_space(c: Byte) -> Bool:
    """The four bytes JSON allows between values. Go's `isSpace`."""
    return c <= _SPACE and (
        c == _SPACE or c == _TAB or c == _RETURN or c == _NEWLINE
    )


def _is_digit(c: Byte) -> Bool:
    """A decimal digit."""
    return c >= _ZERO and c <= _NINE


def _is_hex(c: Byte) -> Bool:
    """A hexadecimal digit in either case, for a `\\u` escape."""
    return (
        _is_digit(c)
        or (c >= _LOWER_A and c <= _LOWER_F)
        or (c >= _UPPER_A and c <= _UPPER_F)
    )


def _quote_char(c: Byte) -> String:
    """`c` as a quoted character, for a message. Go's `quoteChar`.

    Go quotes with double quotes and then swaps the outer pair for single ones,
    which leaves a lone quote of either kind wrong, so both are written out
    first. Everything else is what `quote_rune` already produces.
    """
    if c == Byte(ord("'")):
        return String("'\\''")
    if c == _QUOTE:
        return String("'\"'")
    return quote_rune(Int32(Int(c)))


struct SyntaxError(Copyable, Movable, Writable):
    """Where a document stopped being JSON. Go's `SyntaxError`.

    Built from a raised error by `of`, not by hand, so it outlives the `Error`
    it came from. Go's type carries the message and the offset and nothing
    else, and so does this.

    ```mojo
    from core.encoding.json import SyntaxError, valid_or_raise

    def main():
        try:
            valid_or_raise('{"a": tru}'.as_bytes())
        except e:
            var failure = SyntaxError.of(e)
            if failure:
                print(failure.value().offset)  # 10
                print(failure.value().error())
    ```
    """

    var msg: String
    """What went wrong, in Go's words. Go keeps this unexported and reachable
    only through `Error`, and it is a field here because there is nothing to
    hide it behind."""

    var offset: Int
    """How many bytes had been read when it went wrong. Go's `Offset`.

    Counts the byte that failed, so it is a position from one rather than an
    index from zero, and pointing at the character means subtracting one.
    """

    def __init__(out self, msg: String, offset: Int):
        self.msg = msg.copy()
        self.offset = offset

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as a `SyntaxError`, or nothing if it came from somewhere else.

        Go's `err.(*json.SyntaxError)`. Nothing comes back for a failure from
        the underlying reader or for the end of the input, which are the cases
        a type assertion covers by failing.
        """
        var value = capture(e)
        if value.code() != ErrJSONSyntax:
            return None
        var at = value.field("offset")
        if not at:
            return None
        try:
            return Self(value.message(), Int(at.value()))
        except:
            return None

    def error(self) -> String:
        """The message on its own. Go's `Error`, which returns just `msg`."""
        return self.msg.copy()

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.msg)


def _syntax_error(msg: String, offset: Int) -> Error:
    """The raise every failure in this package makes.

    One place, so the message and the offset cannot drift apart and so
    `SyntaxError.of` has one shape to read.
    """
    return (
        Report(msg)
        .with_code(ErrJSONSyntax)
        .with_field("offset", String(offset))
        .error()
    )


struct _Scanner(Copyable, Movable):
    """Go's `scanner`, with the step as a number instead of a function.

    Reset before use, then handed one byte at a time. `bytes` counts what has
    been fed in and is what an offset in a failure is taken from, so a caller
    that feeds bytes has to raise it, which is what Go's own loops do.
    """

    var step: Int
    """Which state the next byte will be read in."""

    var end_top: Bool
    """Whether the top level value has finished."""

    var parse_state: List[Int]
    """What is open, outermost first, one of the three `_PARSE_` values."""

    var err_msg: String
    """The failure, or empty. Go holds an `error` and this holds its two
    halves, because there is no error value to keep."""

    var err_offset: Int
    """Where the failure was, meaningless while `err_msg` is empty."""

    var failed: Bool
    """Whether `err_msg` has been set, since an empty message is a real
    possibility for a failure Go builds with an empty context."""

    var bytes: Int
    """Total bytes fed in. Deliberately not cleared by `reset`, because a
    decoder reading a stream counts across values."""

    def __init__(out self):
        self.step = _S_BEGIN_VALUE
        self.end_top = False
        self.parse_state = List[Int]()
        self.err_msg = String()
        self.err_offset = 0
        self.failed = False
        self.bytes = 0

    def reset(mut self):
        """Ready for another value, keeping the byte count. Go's `reset`."""
        self.step = _S_BEGIN_VALUE
        self.parse_state.clear()
        self.err_msg = String()
        self.err_offset = 0
        self.failed = False
        self.end_top = False

    def error(self) -> Error:
        """The failure as a raise. Only call this after `_SCAN_ERROR`."""
        return _syntax_error(self.err_msg, self.err_offset)

    def _fail(mut self, c: Byte, context: StringSlice) -> Int:
        """Record a failure and go to the state that stays failed."""
        self.step = _S_ERROR
        self.failed = True
        self.err_msg = "invalid character " + _quote_char(c)
        if context.byte_length() != 0:
            self.err_msg += " " + String(context)
        self.err_offset = self.bytes
        return _SCAN_ERROR

    def _push(mut self, c: Byte, state: Int, success: Int) -> Int:
        """Open a composite value, or refuse for being too deep."""
        self.parse_state.append(state)
        if len(self.parse_state) <= MAX_NESTING_DEPTH:
            return success
        return self._fail(c, "exceeded max depth")

    def _pop(mut self):
        """Close a composite value and pick the state that follows it."""
        var n = len(self.parse_state) - 1
        self.parse_state.resize(n, 0)
        if n == 0:
            self.step = _S_END_TOP
            self.end_top = True
        else:
            self.step = _S_END_VALUE

    def eof(mut self) -> Int:
        """Tell the scanner the input has ended. Go's `eof`.

        A number at the end of the input has not been closed by anything, so
        the machine is fed one space to close it, and only then is a document
        that is still open a failure.
        """
        if self.failed:
            return _SCAN_ERROR
        if self.end_top:
            return _SCAN_END
        _ = self.next(_SPACE)
        if self.end_top:
            return _SCAN_END
        if not self.failed:
            self.failed = True
            self.err_msg = String("unexpected end of JSON input")
            self.err_offset = self.bytes
        return _SCAN_ERROR

    def _end_value(mut self, c: Byte) -> Int:
        """Read `c` as the byte after a value, whatever state the machine is in.
        Go's `stateEndValue` called by name.

        `Decoder.token` needs this for one thing. A closing bracket ends the
        value inside it and the value it closes, and the second of those is only
        reported when the byte after it arrives, which a decoder reading a
        stream may have to wait on the network for. Feeding an invented space
        here asks the question without reading anything, and the answer says
        whether the document is finished.

        Setting the state first is what makes it a direct call rather than a
        step: after a closing bracket the state is already this one or the one
        for a finished document, and both give the same answer from here.
        """
        self.step = _S_END_VALUE
        return self.next(c)

    def next(mut self, c: Byte) -> Int:
        """Read one byte and say what it was. Go's `step`.

        Go's states are functions that tail call each other. Here a state that
        would call another sets `state` and goes round again, which is the same
        thing written as a loop, and the loop always ends because no state
        delegates to one that delegates back to it.
        """
        var state = self.step
        while True:
            if state == _S_BEGIN_VALUE_OR_EMPTY:
                if _is_space(c):
                    return _SCAN_SKIP_SPACE
                if c == _RBRACKET:
                    state = _S_END_VALUE
                    continue
                state = _S_BEGIN_VALUE
                continue
            if state == _S_BEGIN_VALUE:
                if _is_space(c):
                    return _SCAN_SKIP_SPACE
                if c == _LBRACE:
                    self.step = _S_BEGIN_STRING_OR_EMPTY
                    return self._push(c, _PARSE_OBJECT_KEY, _SCAN_BEGIN_OBJECT)
                if c == _LBRACKET:
                    self.step = _S_BEGIN_VALUE_OR_EMPTY
                    return self._push(c, _PARSE_ARRAY_VALUE, _SCAN_BEGIN_ARRAY)
                if c == _QUOTE:
                    self.step = _S_IN_STRING
                    return _SCAN_BEGIN_LITERAL
                if c == _MINUS:
                    self.step = _S_NEG
                    return _SCAN_BEGIN_LITERAL
                if c == _ZERO:
                    self.step = _S_0
                    return _SCAN_BEGIN_LITERAL
                if c == _LOWER_T:
                    self.step = _S_T
                    return _SCAN_BEGIN_LITERAL
                if c == _LOWER_F:
                    self.step = _S_F
                    return _SCAN_BEGIN_LITERAL
                if c == _LOWER_N:
                    self.step = _S_N
                    return _SCAN_BEGIN_LITERAL
                if c >= _ONE and c <= _NINE:
                    self.step = _S_1
                    return _SCAN_BEGIN_LITERAL
                return self._fail(c, "looking for beginning of value")
            if state == _S_BEGIN_STRING_OR_EMPTY:
                if _is_space(c):
                    return _SCAN_SKIP_SPACE
                if c == _RBRACE:
                    var n = len(self.parse_state)
                    self.parse_state[n - 1] = _PARSE_OBJECT_VALUE
                    state = _S_END_VALUE
                    continue
                state = _S_BEGIN_STRING
                continue
            if state == _S_BEGIN_STRING:
                if _is_space(c):
                    return _SCAN_SKIP_SPACE
                if c == _QUOTE:
                    self.step = _S_IN_STRING
                    return _SCAN_BEGIN_LITERAL
                return self._fail(
                    c, "looking for beginning of object key string"
                )
            if state == _S_END_VALUE:
                var n = len(self.parse_state)
                if n == 0:
                    self.step = _S_END_TOP
                    self.end_top = True
                    state = _S_END_TOP
                    continue
                if _is_space(c):
                    self.step = _S_END_VALUE
                    return _SCAN_SKIP_SPACE
                var ps = self.parse_state[n - 1]
                if ps == _PARSE_OBJECT_KEY:
                    if c == _COLON:
                        self.parse_state[n - 1] = _PARSE_OBJECT_VALUE
                        self.step = _S_BEGIN_VALUE
                        return _SCAN_OBJECT_KEY
                    return self._fail(c, "after object key")
                if ps == _PARSE_OBJECT_VALUE:
                    if c == _COMMA:
                        self.parse_state[n - 1] = _PARSE_OBJECT_KEY
                        self.step = _S_BEGIN_STRING
                        return _SCAN_OBJECT_VALUE
                    if c == _RBRACE:
                        self._pop()
                        return _SCAN_END_OBJECT
                    return self._fail(c, "after object key:value pair")
                if ps == _PARSE_ARRAY_VALUE:
                    if c == _COMMA:
                        self.step = _S_BEGIN_VALUE
                        return _SCAN_ARRAY_VALUE
                    if c == _RBRACKET:
                        self._pop()
                        return _SCAN_END_ARRAY
                    return self._fail(c, "after array element")
                return self._fail(c, "")
            if state == _S_END_TOP:
                if not _is_space(c):
                    _ = self._fail(c, "after top-level value")
                return _SCAN_END
            if state == _S_IN_STRING:
                if c == _QUOTE:
                    self.step = _S_END_VALUE
                    return _SCAN_CONTINUE
                if c == _BACKSLASH:
                    self.step = _S_IN_STRING_ESC
                    return _SCAN_CONTINUE
                if c < _SPACE:
                    return self._fail(c, "in string literal")
                return _SCAN_CONTINUE
            if state == _S_IN_STRING_ESC:
                if (
                    c == _LOWER_B
                    or c == _LOWER_F
                    or c == _LOWER_N
                    or c == _LOWER_R
                    or c == _LOWER_T
                    or c == _BACKSLASH
                    or c == Byte(47)
                    or c == _QUOTE
                ):
                    self.step = _S_IN_STRING
                    return _SCAN_CONTINUE
                if c == _LOWER_U:
                    self.step = _S_IN_STRING_ESC_U
                    return _SCAN_CONTINUE
                return self._fail(c, "in string escape code")
            if state == _S_IN_STRING_ESC_U:
                if _is_hex(c):
                    self.step = _S_IN_STRING_ESC_U1
                    return _SCAN_CONTINUE
                return self._fail(c, "in \\u hexadecimal character escape")
            if state == _S_IN_STRING_ESC_U1:
                if _is_hex(c):
                    self.step = _S_IN_STRING_ESC_U12
                    return _SCAN_CONTINUE
                return self._fail(c, "in \\u hexadecimal character escape")
            if state == _S_IN_STRING_ESC_U12:
                if _is_hex(c):
                    self.step = _S_IN_STRING_ESC_U123
                    return _SCAN_CONTINUE
                return self._fail(c, "in \\u hexadecimal character escape")
            if state == _S_IN_STRING_ESC_U123:
                if _is_hex(c):
                    self.step = _S_IN_STRING
                    return _SCAN_CONTINUE
                return self._fail(c, "in \\u hexadecimal character escape")
            if state == _S_NEG:
                if c == _ZERO:
                    self.step = _S_0
                    return _SCAN_CONTINUE
                if c >= _ONE and c <= _NINE:
                    self.step = _S_1
                    return _SCAN_CONTINUE
                return self._fail(c, "in numeric literal")
            if state == _S_1:
                if _is_digit(c):
                    self.step = _S_1
                    return _SCAN_CONTINUE
                state = _S_0
                continue
            if state == _S_0:
                if c == _DOT:
                    self.step = _S_DOT
                    return _SCAN_CONTINUE
                if c == _LOWER_E or c == _UPPER_E:
                    self.step = _S_E
                    return _SCAN_CONTINUE
                state = _S_END_VALUE
                continue
            if state == _S_DOT:
                if _is_digit(c):
                    self.step = _S_DOT_0
                    return _SCAN_CONTINUE
                return self._fail(c, "after decimal point in numeric literal")
            if state == _S_DOT_0:
                if _is_digit(c):
                    return _SCAN_CONTINUE
                if c == _LOWER_E or c == _UPPER_E:
                    self.step = _S_E
                    return _SCAN_CONTINUE
                state = _S_END_VALUE
                continue
            if state == _S_E:
                if c == _PLUS or c == _MINUS:
                    self.step = _S_E_SIGN
                    return _SCAN_CONTINUE
                state = _S_E_SIGN
                continue
            if state == _S_E_SIGN:
                if _is_digit(c):
                    self.step = _S_E_0
                    return _SCAN_CONTINUE
                return self._fail(c, "in exponent of numeric literal")
            if state == _S_E_0:
                if _is_digit(c):
                    return _SCAN_CONTINUE
                state = _S_END_VALUE
                continue
            if state == _S_T:
                if c == _LOWER_R:
                    self.step = _S_TR
                    return _SCAN_CONTINUE
                return self._fail(c, "in literal true (expecting 'r')")
            if state == _S_TR:
                if c == _LOWER_U:
                    self.step = _S_TRU
                    return _SCAN_CONTINUE
                return self._fail(c, "in literal true (expecting 'u')")
            if state == _S_TRU:
                if c == _LOWER_E:
                    self.step = _S_END_VALUE
                    return _SCAN_CONTINUE
                return self._fail(c, "in literal true (expecting 'e')")
            if state == _S_F:
                if c == _LOWER_A:
                    self.step = _S_FA
                    return _SCAN_CONTINUE
                return self._fail(c, "in literal false (expecting 'a')")
            if state == _S_FA:
                if c == _LOWER_L:
                    self.step = _S_FAL
                    return _SCAN_CONTINUE
                return self._fail(c, "in literal false (expecting 'l')")
            if state == _S_FAL:
                if c == _LOWER_S:
                    self.step = _S_FALS
                    return _SCAN_CONTINUE
                return self._fail(c, "in literal false (expecting 's')")
            if state == _S_FALS:
                if c == _LOWER_E:
                    self.step = _S_END_VALUE
                    return _SCAN_CONTINUE
                return self._fail(c, "in literal false (expecting 'e')")
            if state == _S_N:
                if c == _LOWER_U:
                    self.step = _S_NU
                    return _SCAN_CONTINUE
                return self._fail(c, "in literal null (expecting 'u')")
            if state == _S_NU:
                if c == _LOWER_L:
                    self.step = _S_NUL
                    return _SCAN_CONTINUE
                return self._fail(c, "in literal null (expecting 'l')")
            if state == _S_NUL:
                if c == _LOWER_L:
                    self.step = _S_END_VALUE
                    return _SCAN_CONTINUE
                return self._fail(c, "in literal null (expecting 'l')")
            return _SCAN_ERROR


def _check_valid[o: Origin](data: Span[Byte, o], mut scan: _Scanner) -> Bool:
    """Run `scan` over the whole of `data`. Go's `checkValid`.

    False leaves the failure on the scanner, where `error` builds the raise.
    """
    scan.reset()
    for i in range(len(data)):
        scan.bytes += 1
        if scan.next(data[i]) == _SCAN_ERROR:
            return False
    return scan.eof() != _SCAN_ERROR


def valid[o: Origin](data: Span[Byte, o]) -> Bool:
    """Whether `data` is one JSON value and nothing else. Go's `Valid`.

    ```mojo
    from core.encoding.json import valid

    def main():
        print(valid('{"a": [1, 2]}'.as_bytes()))  # True
        print(valid("{} {}".as_bytes()))  # False
    ```

    Whitespace around the value is allowed and a second value after it is not,
    which is what makes this a check of a whole document rather than of a
    prefix. Nothing is decoded, so this costs one pass and no allocation beyond
    the depth stack.
    """
    var scan = _Scanner()
    return _check_valid(data, scan)


def valid_or_raise[o: Origin](data: Span[Byte, o]) raises:
    """Like `valid`, but says where it went wrong.

    Go has no such function and reaches the same message through `Unmarshal`,
    which is a heavier call to make for a question about the bytes. The raise
    carries `ErrJSONSyntax` and the offset, so `SyntaxError.of` reads both.
    """
    var scan = _Scanner()
    if not _check_valid(data, scan):
        raise scan.error()
