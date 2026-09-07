"""Reading a stream one token at a time. Go's `Decoder`, the token half.

A document arrives as a flat sequence: the four brackets, and the strings,
numbers, booleans and nulls between them. Commas and colons are not tokens,
because they carry no information a caller does not already have from the
brackets and the counting, and Go elides them for the same reason.

The decoder holds its own buffer and reads ahead of what has been asked for,
which is what makes a stream of values on one connection work: the bytes after
a value stay in the buffer and the next call starts where the last one stopped.
`input_offset` is the position between the token just handed back and the one
after it, so a caller logging a failure can name a byte in the original stream
rather than a byte in some buffer nobody else can see.

Two things guard the token path that Go does not guard. `max_depth` refuses a
document that nests deeper than ten thousand, because the token path keeps a
stack of open brackets and Go lets that stack grow to the size of the input, so
a file of nothing but `[` costs Go memory and costs this a refusal. And every
token owns its bytes rather than pointing into the buffer, so a token kept
across a hundred calls is still the token that was read.

What is not here yet is `Decode`, which reads a value into a variable of the
caller's type. Go does that by inspecting the type while the program runs and
there is no such inspection here, design.md section 1, so it arrives as
generated code with issue #33.
"""

from core.errors import Report, matches
from core.errors.codes import EOF, ErrUnexpectedEOF
from core.io import Byte, Reader as IoReader
from core.iter import Cursor
from core.unicode.utf8 import RUNE_ERROR, RUNE_SELF, append_rune, decode_rune

from .number import Number
from .scan import (
    _BACKSLASH,
    _LBRACE,
    _LBRACKET,
    _LOWER_A,
    _LOWER_B,
    _LOWER_F,
    _LOWER_N,
    _LOWER_R,
    _LOWER_T,
    _LOWER_U,
    _NEWLINE,
    _NINE,
    _QUOTE,
    _RBRACE,
    _RBRACKET,
    _RETURN,
    _SCAN_END,
    _SCAN_END_ARRAY,
    _SCAN_END_OBJECT,
    _SCAN_ERROR,
    _SPACE,
    _Scanner,
    _TAB,
    _UPPER_A,
    _UPPER_F,
    _ZERO,
    _COLON,
    _COMMA,
    _is_space,
    _quote_char,
    _syntax_error,
    MAX_NESTING_DEPTH,
)
from .token import (
    ARRAY_CLOSE,
    ARRAY_OPEN,
    OBJECT_CLOSE,
    OBJECT_OPEN,
    Token,
)

comptime _MIN_READ = 512
"""The smallest read the decoder will ask its source for. Go's `minRead`.

Each refill asks for at least this and at most the size of what it already
holds, so the buffer doubles rather than creeping up by a constant and a large
document costs a logarithmic number of reads instead of a linear one.
"""

comptime _TOP_VALUE = 0
"""Before the first value, and between two values in a stream."""

comptime _ARRAY_START = 1
"""Just after a `[`, where a value or a `]` may come."""

comptime _ARRAY_VALUE = 2
"""Just after a comma in an array, where a value has to come."""

comptime _ARRAY_COMMA = 3
"""Just after an array element, where a comma or a `]` may come."""

comptime _OBJECT_START = 4
"""Just after a `{`, where a key or a `}` may come."""

comptime _OBJECT_KEY = 5
"""Just after a comma in an object, where a key has to come."""

comptime _OBJECT_COLON = 6
"""Just after a key, where the colon has to come."""

comptime _OBJECT_VALUE = 7
"""Just after the colon, where a value has to come."""

comptime _OBJECT_COMMA = 8
"""Just after a value in an object, where a comma or a `}` may come."""

comptime _SURR1 = Int32(0xD800)
"""The first code point that is a leading surrogate."""

comptime _SURR2 = Int32(0xDC00)
"""The first code point that is a trailing surrogate."""

comptime _SURR3 = Int32(0xE000)
"""The first code point past the surrogates."""

comptime _SURR_SELF = Int32(0x10000)
"""The first code point that has to be written as a surrogate pair."""


def _is_surrogate(r: Int32) -> Bool:
    """Whether `r` is half of a pair. Go's `utf16.IsSurrogate`.

    Written out rather than imported, because `core.unicode.utf16` is not
    ported yet and these three lines are the whole of what this file needs from
    it.
    """
    return _SURR1 <= r and r < _SURR3


def _decode_surrogate_pair(r1: Int32, r2: Int32) -> Int32:
    """The code point `r1` and `r2` spell together, or `RUNE_ERROR`.
    Go's `utf16.DecodeRune`.

    A leading surrogate with nothing valid after it is not an error a document
    can be refused for, because `\\ud800` on its own is six characters a
    document is allowed to contain. It becomes the replacement character, which
    is what Go does and what every other decoder does.
    """
    if _SURR1 <= r1 and r1 < _SURR2 and _SURR2 <= r2 and r2 < _SURR3:
        return ((r1 - _SURR1) << 10) | ((r2 - _SURR2) + _SURR_SELF)
    return RUNE_ERROR


def _getu4[o: Origin](s: Span[Byte, o]) -> Int32:
    """The code point a `\\uXXXX` escape at the front of `s` names, or -1.
    Go's `getu4`.

    Minus one for anything that is not six bytes starting with a backslash and
    a `u` and ending in four hex digits, which is how the caller tells a real
    escape from a backslash that happens to be followed by a `u`.
    """
    if len(s) < 6 or s[0] != _BACKSLASH or s[1] != _LOWER_U:
        return -1
    var r = Int32(0)
    for i in range(2, 6):
        var c = s[i]
        var v: Int32
        if c >= _ZERO and c <= _NINE:
            v = Int32(Int(c - _ZERO))
        elif c >= _LOWER_A and c <= _LOWER_F:
            v = Int32(Int(c - _LOWER_A) + 10)
        elif c >= _UPPER_A and c <= _UPPER_F:
            v = Int32(Int(c - _UPPER_A) + 10)
        else:
            return -1
        r = r * 16 + v
    return r


def _unquote[o: Origin](quoted: Span[Byte, o]) -> String:
    """The characters a quoted string literal stands for. Go's `unquoteBytes`.

    Go's returns a second value saying whether the literal was well formed, and
    this one does not, because the only bytes that ever reach here are bytes the
    scanner has already accepted as a string. The two shapes Go refuses, a bare
    control character and an unescaped quote, cannot arrive: the scanner refuses
    the first and the second is where the literal ended.

    Anything that is not UTF-8 becomes the replacement character, which is Go's
    behaviour and is why a string is where this library stops caring what a
    document holds: the structure was already checked, and the text is coerced
    rather than refused.
    """
    var s = quoted[1 : len(quoted) - 1]
    var out = List[Byte](capacity=len(s))
    var r = 0
    while r < len(s):
        var c = s[r]
        if c == _BACKSLASH:
            r += 1
            if r >= len(s):
                break
            var e = s[r]
            if e == _LOWER_U:
                r -= 1
                var rr = _getu4(s[r : len(s)])
                if rr < 0:
                    break
                r += 6
                if _is_surrogate(rr):
                    var paired = _decode_surrogate_pair(
                        rr, _getu4(s[r : len(s)])
                    )
                    if paired != RUNE_ERROR:
                        r += 6
                        _ = append_rune(out, paired)
                        continue
                    rr = RUNE_ERROR
                _ = append_rune(out, rr)
                continue
            r += 1
            if e == _LOWER_B:
                out.append(Byte(8))
            elif e == _LOWER_F:
                out.append(Byte(12))
            elif e == _LOWER_N:
                out.append(_NEWLINE)
            elif e == _LOWER_R:
                out.append(_RETURN)
            elif e == _LOWER_T:
                out.append(_TAB)
            else:
                out.append(e)
        elif c < Byte(RUNE_SELF):
            out.append(c)
            r += 1
        else:
            var decoded = decode_rune(s[r : len(s)])
            r += decoded[1]
            _ = append_rune(out, decoded[0])
    return String(from_utf8_lossy=Span(out))


def _non_space[o: Origin](b: Span[Byte, o]) -> Bool:
    """Whether `b` holds anything that is not whitespace. Go's `nonSpace`.

    Asked when the input ends in the middle of a value, to tell a stream that
    finished cleanly from one that was cut off.
    """
    for i in range(len(b)):
        if not _is_space(b[i]):
            return True
    return False


struct Decoder[R: IoReader & Deinitable & Movable](Movable):
    """A reader over one stream of JSON values. Go's `Decoder`.

    ```mojo
    from core.encoding.json import new_decoder
    from core.io import Reader


    def keys[R: Reader & Deinitable & Movable](
        var src: R,
    ) raises -> List[String]:
        var d = new_decoder(src^)
        _ = d.token()
        var names = List[String]()
        while d.more():
            names.append(d.token().as_string())
            _ = d.token()
        return names^
    ```

    More than one value may follow another in the stream, with or without
    whitespace between them, which is what makes this the way to read a log of
    JSON lines. `token` walks straight from the end of one value into the start
    of the next.

    Not `Copyable`. Two decoders over one source would each read bytes the other
    needed, and the buffer only makes sense with one owner.
    """

    var max_depth: Int
    """How deep brackets may nest before `token` refuses. Go has no counterpart
    on this path.

    Ten thousand unless changed, which is the cap Go's scanner applies to
    `Valid` and `Unmarshal` and does not apply to its token path. Nesting is the
    one thing in a document that costs more than its own length to read, since
    every open bracket has to be remembered until it closes, so a file of a
    hundred million `[` is a stack the size of the file. RFC 7159 section 9 says
    an implementation may set a limit and this is where it is set.
    """

    var r: Self.R
    """The source. Owned, so the call is direct and there is no interface to
    dispatch through."""

    var _buf: List[Byte]
    """What has been read and not yet handed back.

    Grows as needed and is slid down when the front of it has been consumed,
    which is Go's arrangement: one buffer for the whole stream rather than one
    per value.
    """

    var _scanp: Int
    """Where the unread bytes start in `_buf`."""

    var _scanned: Int64
    """How many bytes were dropped off the front of `_buf` by earlier slides.

    Added to `_scanp` to give `input_offset`, so an offset means a position in
    the stream rather than a position in the buffer.
    """

    var _scan: _Scanner
    """The state machine, reset before each value."""

    var _err: Optional[Error]
    """The failure this decoder is stuck on, if any.

    Once set it stays set, so every later call reports the same thing rather
    than trying to carry on from a position it does not understand. Only a
    failure that ends the stream lives here: a token that is merely in the wrong
    place raises without sticking, which is Go's split too, because the caller
    can look at `input_offset`, decide the document is theirs to fix, and read
    on.
    """

    var _token_state: Int
    """Where in a value the token path currently is, one of the nine
    `_TOP_VALUE` and its siblings."""

    var _token_stack: List[Int]
    """The states to go back to, one per open bracket."""

    def __init__(out self, var r: Self.R):
        """A decoder over `r`, reading nothing yet."""
        self.max_depth = MAX_NESTING_DEPTH
        self.r = r^
        self._buf = List[Byte]()
        self._scanp = 0
        self._scanned = 0
        self._scan = _Scanner()
        self._err = None
        self._token_state = _TOP_VALUE
        self._token_stack = List[Int]()

    def input_offset(self) -> Int64:
        """Where the decoder is in the stream. Go's `InputOffset`.

        The end of the token just handed back and the start of the one after
        it, counted in bytes from the first byte the source ever produced.
        """
        return self._scanned + Int64(self._scanp)

    def buffered(self) -> List[Byte]:
        """The bytes read from the source and not yet handed back. Go's
        `Buffered`.

        Go returns a reader over the decoder's own buffer, which stops being
        valid at the next call. This returns a copy, so it is still the bytes
        that were there when it was asked and holding onto it costs nothing but
        its own size. The deviations page has the row.

        Used for the case Go documents it for: a protocol where a JSON header is
        followed by bytes that are not JSON, and the reader has already swallowed
        some of them.
        """
        return List[Byte](Span(self._buf)[self._scanp : len(self._buf)])

    def more(mut self) -> Bool:
        """Whether the array or object being read has another element.
        Go's `More`.

        False at the end of the input and false at a closing bracket, which is
        the loop condition for reading an array of unknown length. It reads
        ahead to answer and reports nothing about a stream that has gone wrong,
        so a loop written on it alone ends quietly on a malformed document;
        `tokens` is the way to have that raise instead.
        """
        try:
            var c = self._peek()
            return c != _RBRACKET and c != _RBRACE
        except:
            return False

    def token(mut self) raises -> Token:
        """The next token. Go's `Token`.

        Raises `EOF` at the end of the stream, which Go reports as a nil token
        alongside `io.EOF` and which is the one place a Go caller has to check
        the error before the value.

        The brackets it hands back are properly nested and matched. A `]` where
        a `}` belongs, a comma where a value belongs, or a value where a key
        belongs is a raise naming the byte and where it was, so a caller reading
        a stream of tokens never has to check the shape themselves.
        """
        if self._err:
            raise self._err.value()
        while True:
            var c = self._peek()
            if c == _LBRACKET:
                if not self._value_allowed():
                    raise self._token_error(c)
                self._open(c)
                self._token_state = _ARRAY_START
                return Token(ARRAY_OPEN)
            if c == _RBRACKET:
                if (
                    self._token_state != _ARRAY_START
                    and self._token_state != _ARRAY_COMMA
                ):
                    raise self._token_error(c)
                self._close()
                return Token(ARRAY_CLOSE)
            if c == _LBRACE:
                if not self._value_allowed():
                    raise self._token_error(c)
                self._open(c)
                self._token_state = _OBJECT_START
                return Token(OBJECT_OPEN)
            if c == _RBRACE:
                if (
                    self._token_state != _OBJECT_START
                    and self._token_state != _OBJECT_COMMA
                ):
                    raise self._token_error(c)
                self._close()
                return Token(OBJECT_CLOSE)
            if c == _COLON:
                if self._token_state != _OBJECT_COLON:
                    raise self._token_error(c)
                self._scanp += 1
                self._token_state = _OBJECT_VALUE
                continue
            if c == _COMMA:
                if self._token_state == _ARRAY_COMMA:
                    self._scanp += 1
                    self._token_state = _ARRAY_VALUE
                    continue
                if self._token_state == _OBJECT_COMMA:
                    self._scanp += 1
                    self._token_state = _OBJECT_KEY
                    continue
                raise self._token_error(c)
            if c == _QUOTE and (
                self._token_state == _OBJECT_START
                or self._token_state == _OBJECT_KEY
            ):
                var key = self._read_literal()
                self._token_state = _OBJECT_COLON
                return key^
            if not self._value_allowed():
                raise self._token_error(c)
            var value = self._read_literal()
            self._value_end()
            return value^

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

    def _open(mut self, c: Byte) raises:
        """Consume an opening bracket and remember what it interrupted.

        The one place `max_depth` is checked, and the message is the scanner's
        word for word, so a document refused for depth reads the same whether it
        was `valid` or `token` that refused it.
        """
        if len(self._token_stack) >= self.max_depth:
            raise self._stuck(
                _syntax_error(
                    "invalid character "
                    + _quote_char(c)
                    + " exceeded max depth",
                    Int(self.input_offset()),
                )
            )
        self._scanp += 1
        self._token_stack.append(self._token_state)

    def _close(mut self):
        """Consume a closing bracket and go back to what it interrupted."""
        self._scanp += 1
        var n = len(self._token_stack) - 1
        self._token_state = self._token_stack[n]
        self._token_stack.resize(n, 0)
        self._value_end()

    def _value_allowed(self) -> Bool:
        """Whether a value may start here. Go's `tokenValueAllowed`."""
        return (
            self._token_state == _TOP_VALUE
            or self._token_state == _ARRAY_START
            or self._token_state == _ARRAY_VALUE
            or self._token_state == _OBJECT_VALUE
        )

    def _value_end(mut self):
        """Move past a value that has just been read. Go's `tokenValueEnd`."""
        if (
            self._token_state == _ARRAY_START
            or self._token_state == _ARRAY_VALUE
        ):
            self._token_state = _ARRAY_COMMA
        elif self._token_state == _OBJECT_VALUE:
            self._token_state = _OBJECT_COMMA

    def _token_error(mut self, c: Byte) -> Error:
        """A byte in the wrong place, with what was expected instead.
        Go's `tokenError`.

        Not sticky. Go leaves the decoder usable after one of these and so does
        this, because the caller knows where the failure was and may decide the
        rest of the stream is still worth reading.
        """
        var context = String()
        if (
            self._token_state == _TOP_VALUE
            or self._token_state == _ARRAY_START
            or self._token_state == _ARRAY_VALUE
            or self._token_state == _OBJECT_VALUE
        ):
            context = " looking for beginning of value"
        elif self._token_state == _ARRAY_COMMA:
            context = " after array element"
        elif self._token_state == _OBJECT_KEY:
            context = " looking for beginning of object key string"
        elif self._token_state == _OBJECT_COLON:
            context = " after object key"
        elif self._token_state == _OBJECT_COMMA:
            context = " after object key:value pair"
        return _syntax_error(
            "invalid character " + _quote_char(c) + context,
            Int(self.input_offset()),
        )

    def _read_literal(mut self) raises -> Token:
        """The next string, number, boolean or null, read whole.

        Go reads it into an `any` through `Decode` and finds out what it was
        from the type it ended up with. There is no `any` here, so the first
        byte says which of the four it is, which the scanner has already proved
        is the only one it can be.
        """
        var n = self._read_value()
        var start = self._scanp
        self._scanp += n
        var first = self._buf[start]
        if first == _QUOTE:
            return Token(_unquote(Span(self._buf)[start : start + n]))
        if first == _LOWER_T:
            return Token(True)
        if first == _LOWER_F:
            return Token(False)
        if first == _LOWER_N:
            return Token()
        return Token(
            Number(String(from_utf8_lossy=Span(self._buf)[start : start + n]))
        )

    def _read_value(mut self) raises -> Int:
        """How many bytes the next whole value takes. Go's `readValue`.

        Reads from the source until the scanner says the value has ended, so
        the bytes of one value are all in the buffer at once and the caller can
        look at them together. The value starts at `_scanp`, which `_peek` has
        already moved past any whitespace.
        """
        self._scan.reset()
        var scanp = self._scanp
        var ended = False
        while True:
            while scanp < len(self._buf):
                var c = self._buf[scanp]
                self._scan.bytes += 1
                var op = self._scan.next(c)
                if op == _SCAN_END:
                    # The end is reported one byte late, so the count has to go
                    # back one for the next value to start where this one
                    # stopped.
                    self._scan.bytes -= 1
                    return scanp - self._scanp
                if op == _SCAN_END_OBJECT or op == _SCAN_END_ARRAY:
                    # A closing bracket may also have ended the top level value,
                    # and the byte that would say so may not have been sent yet.
                    # An invented space asks without reading.
                    if self._scan._end_value(_SPACE) == _SCAN_END:
                        scanp += 1
                        return scanp - self._scanp
                elif op == _SCAN_ERROR:
                    raise self._stuck(self._scan.error())
                scanp += 1
            if ended:
                if self._scan.next(_SPACE) == _SCAN_END:
                    return scanp - self._scanp
                if _non_space(Span(self._buf)):
                    raise self._stuck(
                        Report("json: unexpected end of JSON input")
                        .with_code(ErrUnexpectedEOF)
                        .error()
                    )
                raise self._stuck(
                    Report("json: end of input").with_code(EOF).error()
                )
            var held = scanp - self._scanp
            ended = not self._refill()
            scanp = self._scanp + held

    def _peek(mut self) raises -> Byte:
        """The next byte that is not whitespace, without consuming it.
        Go's `peek`.

        Moves `_scanp` onto it, so the whitespace before a token is never seen
        again and an offset taken afterwards names the token rather than the
        space in front of it.
        """
        while True:
            for i in range(self._scanp, len(self._buf)):
                var c = self._buf[i]
                if _is_space(c):
                    continue
                self._scanp = i
                return c
            if not self._refill():
                raise Report("json: end of input").with_code(EOF).error()

    def _refill(mut self) raises -> Bool:
        """Read more from the source. False when there is no more. Go's
        `refill`.

        Slides the consumed bytes off the front first, so a stream of a million
        small values is read through a buffer the size of the largest one rather
        than the size of the stream.
        """
        if self._scanp > 0:
            self._scanned += Int64(self._scanp)
            var kept = len(self._buf) - self._scanp
            for i in range(kept):
                self._buf[i] = self._buf[self._scanp + i]
            self._buf.resize(kept, 0)
            self._scanp = 0
        var have = len(self._buf)
        var room = _MIN_READ if have < _MIN_READ else have
        self._buf.resize(have + room, 0)
        var got: Int
        try:
            got = self.r.read(Span(self._buf)[have : have + room])
        except e:
            self._buf.resize(have, 0)
            if matches(e, EOF):
                return False
            raise self._stuck(e)
        self._buf.resize(have + got, 0)
        return got > 0

    def _stuck(mut self, var e: Error) -> Error:
        """Remember `e` as the failure and hand it back to be raised.

        Every failure that ends the stream goes through here, so there is no way
        to report one and leave the decoder willing to carry on from a position
        it does not understand.
        """
        self._err = e.copy()
        return e^


struct Tokens[R: IoReader & Deinitable & Movable, o: MutOrigin](
    Cursor, Movable
):
    """A cursor over the tokens left in a decoder. Go has no counterpart.

    ```mojo
    from core.encoding.json import NUMBER, new_decoder
    from core.io import Reader


    def numbers[R: Reader & Deinitable & Movable](var src: R) raises -> Int:
        var d = new_decoder(src^)
        var tokens = d.tokens()
        var found = 0
        while tokens.has_next():
            if tokens.next().kind == NUMBER:
                found += 1
        return found
    ```

    It holds a pointer at the decoder rather than the decoder itself, the same
    arrangement `sort.Reverse` has and for the same reason: a copy would be read
    to the end and the caller's decoder would be left where it was.

    A malformed document raises out of whichever of the two calls found it, so a
    loop that ignores failures does not compile and one that catches them says
    which token it was on.
    """

    comptime Element = Token

    var inner: Pointer[Decoder[Self.R], Self.o]
    """The decoder being walked. Nothing is copied and nothing is owned."""

    var pending: Optional[Token]
    """The token `has_next` read in order to answer, waiting for `next`."""

    var done: Bool
    """Whether the end of the stream has been reached.

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

        There is no way to know a stream has another token without reading one.
        The end of the input is not a failure and is the answer `False`;
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
                Report("json: read past the last token").with_code(EOF).error()
            )
        var got = self.pending.take()
        return got^


def new_decoder[R: IoReader & Deinitable & Movable](var r: R) -> Decoder[R]:
    """A decoder over `r`. Go's `NewDecoder`.

    Go takes an `io.Reader` interface and this takes the concrete type, so every
    read is a direct call. `core.io.AnyReader` is the way to hold one of several
    sources in the same variable.

    The decoder buffers, and it reads past the end of a value on purpose. A
    caller who needs the bytes it read ahead of asks `buffered` for them.
    """
    return Decoder[R](r^)
