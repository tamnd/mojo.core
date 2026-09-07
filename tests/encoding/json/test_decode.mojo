"""`Decoder`, one token at a time.

Go's `TestDecodeInStream` is the table this starts from. Half its rows call
`Decode` between tokens, which needs a type to read into and so waits for issue
33; the other half are token streams and they are all here, along with Go's own
rule that `More` is true before every token except a closing bracket.

After the table comes one behaviour at a time: where the offsets land, what is
left buffered, what a document that stops in the middle raises, and what
`_unquote` makes of the escapes a scanner lets through.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.bytes import new_buffer_string
from core.encoding.json import (
    ARRAY_CLOSE,
    ARRAY_OPEN,
    BOOL,
    DELIM,
    Delim,
    NULL,
    NUMBER,
    Number,
    OBJECT_CLOSE,
    OBJECT_OPEN,
    STRING,
    SyntaxError,
    Token,
    new_decoder,
)
from core.encoding.json.decode import _unquote
from core.errors import Report, matches
from core.errors.codes import EOF, ErrUnexpectedEOF
from core.io import Byte, Reader


struct OneByte(Copyable, Movable, Reader):
    """A source that hands back one byte a call. Go's `iotest.OneByteReader`.

    The decoder buffers, so a document that arrives whole is read in a single
    call and the refill loop never runs twice. This makes it run once per byte,
    which is the arrangement a socket produces and the one that catches a
    decoder holding a position across a buffer that moved underneath it.
    """

    var data: List[Byte]
    """The bytes left to hand out, including the ones already handed out."""

    var pos: Int
    """How many have been handed out."""

    def __init__(out self, s: String):
        """A source over `s`'s bytes."""
        self.data = List[Byte](s.as_bytes())
        self.pos = 0

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        if self.pos >= len(self.data):
            raise Report("fixture: end of input").with_code(EOF).error()
        if len(into) == 0:
            return 0
        into[0] = self.data[self.pos]
        self.pos += 1
        return 1


def _show(t: Token) -> String:
    """A token in one word, so a whole stream fits on one line.

    A number keeps a `#` and a string keeps its quotes, because `1` and `"1"`
    are two different tokens and a row that wrote them the same way would pass
    whichever one arrived.
    """
    if t.kind == DELIM:
        return t.delim.string()
    if t.kind == BOOL:
        return String("true") if t.boolean else String("false")
    if t.kind == NUMBER:
        return "#" + t.number.string()
    if t.kind == STRING:
        return '"' + t.text + '"'
    return String("null")


def _stream(text: StringSlice) raises -> String:
    """Every token in `text`, space separated, with `more` checked before each.

    Go's harness expects `More` to be true before every token except `]` and
    `}`, and asserting it here rather than in a test of its own means every row
    of the table covers it.
    """
    var d = new_decoder(new_buffer_string(String(text)))
    var seen = String()
    while True:
        var had_more = d.more()
        var got = Token()
        try:
            got = d.token()
        except e:
            if matches(e, EOF):
                if had_more:
                    raise Error(
                        "more() was true at the end of " + repr(String(text))
                    )
                break
            raise e
        var closing = t_is_close(got)
        if had_more == closing:
            raise Error(
                "more() was "
                + String(had_more)
                + " before "
                + _show(got)
                + " in "
                + repr(String(text))
            )
        if seen.byte_length() != 0:
            seen += " "
        seen += _show(got)
    return seen^


def t_is_close(t: Token) -> Bool:
    """Whether `t` is one of the two brackets `more` answers `False` before."""
    if t.kind != DELIM:
        return False
    return t.delim == ARRAY_CLOSE or t.delim == OBJECT_CLOSE


def _fails(text: StringSlice, msg: StringSlice, offset: Int) raises:
    """Read `text` until something raises, and check it raised that.

    Go's harness stops at the first failure and compares the whole
    `SyntaxError`, message and offset together, which is what this does.
    """
    var d = new_decoder(new_buffer_string(String(text)))
    for _ in range(64):
        try:
            _ = d.token()
        except e:
            var failure = SyntaxError.of(e)
            if not failure:
                raise Error(
                    "wrong kind of failure for "
                    + repr(String(text))
                    + ": "
                    + String(e)
                )
            assert_equal(failure.value().error(), String(msg))
            assert_equal(failure.value().offset, offset)
            return
    raise Error("accepted " + repr(String(text)))


def _unq(literal: StringSlice) raises -> String:
    """What a quoted string literal, quotes and all, stands for."""
    return _unquote(literal.as_bytes())


def test_gos_streaming_token_rows() raises:
    """The eight rows of Go's `TestDecodeInStream` that only read tokens."""
    assert_equal(_stream("10"), "#10")
    assert_equal(_stream(" [10] "), "[ #10 ]")
    assert_equal(_stream(' [false,10,"b"] '), '[ false #10 "b" ]')
    assert_equal(_stream('{ "a": 1 }'), '{ "a" #1 }')
    assert_equal(_stream('{"a": 1, "b":"3"}'), '{ "a" #1 "b" "3" }')
    assert_equal(_stream(' [{"a": 1},{"a": 2}] '), '[ { "a" #1 } { "a" #2 } ]')
    assert_equal(_stream('{"obj": {"a": 1}}'), '{ "obj" { "a" #1 } }')
    assert_equal(_stream('{"obj": [{"a": 1}]}'), '{ "obj" [ { "a" #1 } ] }')


def test_gos_three_failing_rows() raises:
    """The three rows of Go's table that fail without needing `Decode`.

    The two offsets that are not zero come from the scanner, which counts from
    the start of the value rather than the start of the stream. Go has the same
    split and the same numbers.
    """
    _fails('{ "\\a" }', "invalid character 'a' in string escape code", 3)
    _fails(" \\a", "invalid character '\\\\' looking for beginning of value", 1)
    _fails(",", "invalid character ',' looking for beginning of value", 0)


def test_the_five_kinds_all_arrive() raises:
    """One document holding one of each."""
    var d = new_decoder(new_buffer_string('[null, true, 7, "s"]'))
    assert_equal(d.token().as_delim(), ARRAY_OPEN)
    assert_true(d.token().is_null())
    assert_true(d.token().as_bool())
    assert_equal(d.token().as_number(), Number("7"))
    assert_equal(d.token().as_string(), "s")
    assert_equal(d.token().as_delim(), ARRAY_CLOSE)


def test_a_number_keeps_what_the_document_wrote() raises:
    """No float ever gets in the way.

    `1e400` is the row that matters: it is a number a document may hold and no
    float can, so a decoder that converted here would have to fail on it.
    """
    assert_equal(_stream("[1, 1.0, 1e400, -0]"), "[ #1 #1.0 #1e400 #-0 ]")


def test_an_accessor_of_the_wrong_kind_raises() raises:
    """Asking a string for its number says both what was asked and what is
    there."""
    var t = Token("s")
    var said = String()
    try:
        _ = t.as_number()
    except e:
        said = String(e)
    assert_equal(said, "json: token is a string, not a number")


def test_a_delimiter_reads_as_its_bracket() raises:
    """The four constants, and what they print as."""
    assert_equal(String(ARRAY_OPEN), "[")
    assert_equal(String(ARRAY_CLOSE), "]")
    assert_equal(String(OBJECT_OPEN), "{")
    assert_equal(String(OBJECT_CLOSE), "}")
    assert_equal(Delim(Byte(ord("["))), ARRAY_OPEN)
    assert_true(ARRAY_OPEN != OBJECT_OPEN)


def test_a_token_writes_as_a_message() raises:
    """`write_to` is for a message, so a string loses its quotes."""
    assert_equal(String(Token("a b")), "a b")
    assert_equal(String(Token(True)), "true")
    assert_equal(String(Token(False)), "false")
    assert_equal(String(Token(Number("1e9"))), "1e9")
    assert_equal(String(Token()), "null")


def test_tokens_of_the_same_kind_compare_by_value() raises:
    """And two kinds never compare equal, whatever they hold."""
    assert_equal(Token("a"), Token("a"))
    assert_true(Token("a") != Token("b"))
    assert_equal(Token(Number("1")), Token(Number("1")))
    assert_true(Token(Number("1")) != Token(Number("1.0")))
    assert_equal(Token(), Token())
    assert_true(Token(True) != Token())


def test_input_offset_names_a_byte_of_the_stream() raises:
    """The end of the token just handed back, counted from the first byte in."""
    var d = new_decoder(new_buffer_string('{"a": 1}'))
    assert_equal(Int(d.input_offset()), 0)
    _ = d.token()
    assert_equal(Int(d.input_offset()), 1)
    _ = d.token()
    assert_equal(Int(d.input_offset()), 4)
    _ = d.token()
    assert_equal(Int(d.input_offset()), 7)
    _ = d.token()
    assert_equal(Int(d.input_offset()), 8)


def test_an_offset_survives_the_buffer_sliding() raises:
    """A refill drops the front of the buffer, and the count does not restart.

    The document is longer than one read from this source by a wide margin, so
    the buffer is slid many times before the last token arrives.
    """
    var text = '{"' + "a" * 600 + '": 1}'
    var d = new_decoder(OneByte(text))
    _ = d.token()
    assert_equal(Int(d.input_offset()), 1)
    assert_equal(d.token().as_string(), "a" * 600)
    assert_equal(Int(d.input_offset()), 603)
    assert_equal(d.token().as_number(), Number("1"))
    assert_equal(Int(d.input_offset()), 606)
    assert_equal(d.token().as_delim(), OBJECT_CLOSE)
    assert_equal(Int(d.input_offset()), 607)


def test_one_byte_at_a_time_reads_the_same_document() raises:
    """A source that never fills the buffer in one call.

    Nesting, a key that crosses several refills and a value after the closing
    bracket, so the refill loop runs in each of the places it can.
    """
    var text = '{"' + "k" * 700 + '": [1, {"b": null}], "t": true} 9'
    var d = new_decoder(OneByte(text))
    var seen = String()
    while True:
        try:
            var got = d.token()
            seen += _show(got)
        except e:
            if matches(e, EOF):
                break
            raise e
    assert_equal(seen, '{"' + "k" * 700 + '"[#1{"b"null}]"t"true}#9')


def test_buffered_is_what_was_read_past_the_end() raises:
    """Go's case: a JSON header followed by bytes that are not JSON."""
    var d = new_decoder(new_buffer_string('{"a": 1}the rest'))
    for _ in range(4):
        _ = d.token()
    assert_equal(String(from_utf8_lossy=Span(d.buffered())), "the rest")


def test_buffered_is_a_copy() raises:
    """Holding onto it costs its own size and nothing else.

    Go hands back a reader over the decoder's own buffer, which the next call
    moves. This is the row the deviations page names.
    """
    var d = new_decoder(new_buffer_string("1 2"))
    _ = d.token()
    var held = d.buffered()
    _ = d.token()
    assert_equal(String(from_utf8_lossy=Span(held)), " 2")


def test_more_is_false_at_the_end_and_at_a_closing_bracket() raises:
    """The loop condition for reading an array of unknown length."""
    var d = new_decoder(new_buffer_string("[]"))
    assert_true(d.more())
    _ = d.token()
    assert_false(d.more())
    _ = d.token()
    assert_false(d.more())


def test_more_is_false_on_an_empty_stream() raises:
    """Nothing to read is not something to raise about."""
    var d = new_decoder(new_buffer_string("   "))
    assert_false(d.more())


def test_a_stream_holds_more_than_one_value() raises:
    """With whitespace between them, and without."""
    assert_equal(_stream("1 2 3"), "#1 #2 #3")
    assert_equal(_stream('{"a":1}{"b":2}'), '{ "a" #1 } { "b" #2 }')
    assert_equal(_stream("[1][2]"), "[ #1 ] [ #2 ]")


def test_the_end_of_the_stream_raises_eof() raises:
    """And says so with the code, not with a null token."""
    var d = new_decoder(new_buffer_string("1"))
    _ = d.token()
    var said = Error()
    try:
        _ = d.token()
    except e:
        said = e.copy()
    assert_true(matches(said, EOF))
    assert_equal(String(said), "json: end of input")


def test_a_document_cut_off_mid_value_is_unexpected_eof() raises:
    """And the decoder stays stuck on it.

    The string never closes, so the scanner is still inside a value when the
    source runs out, which is the one case that tells a stream that finished
    from one that was cut.
    """
    var d = new_decoder(new_buffer_string('["ab'))
    _ = d.token()
    var said = Error()
    try:
        _ = d.token()
    except e:
        said = e.copy()
    assert_true(matches(said, ErrUnexpectedEOF))
    assert_equal(String(said), "json: unexpected end of JSON input")
    var again = Error()
    try:
        _ = d.token()
    except e:
        again = e.copy()
    assert_equal(String(again), String(said))


def test_a_bracket_in_the_wrong_place_raises() raises:
    """The nesting is checked, so a caller reading tokens never checks it.

    The bracket that comes straight after an opening brace says only what the
    byte was, with none of the context the other states carry. Go's `tokenError`
    has no case for that state either, and the two agree row for row.
    """
    _fails("[}", "invalid character '}' looking for beginning of value", 1)
    _fails("{]", "invalid character ']'", 1)
    _fails('{"a": 1]', "invalid character ']' after object key:value pair", 7)
    _fails("[1,]", "invalid character ']' looking for beginning of value", 3)
    _fails(
        '{"a": 1, ]',
        "invalid character ']' looking for beginning of object key string",
        9,
    )


def test_a_key_that_is_not_a_string_raises() raises:
    """An object key is a string or it is a failure."""
    _fails("{1: 2}", "invalid character '1'", 1)
    _fails(
        '{"a": 1, 2: 3}',
        "invalid character '2' looking for beginning of object key string",
        9,
    )
    _fails('{"a" 1}', "invalid character '1' after object key", 5)


def test_a_token_error_leaves_the_decoder_usable() raises:
    """Not sticky, which is Go's split too.

    The caller knows where the failure was, may decide the document is theirs
    to fix, and the bytes are still there to look at.
    """
    var d = new_decoder(new_buffer_string('{"a" 1}'))
    _ = d.token()
    _ = d.token()
    try:
        _ = d.token()
    except:
        pass
    assert_equal(Int(d.input_offset()), 5)
    assert_equal(String(from_utf8_lossy=Span(d.buffered())), "1}")


def test_max_depth_refuses_a_document_that_nests_too_far() raises:
    """Go leaves the token path uncapped and this does not.

    The message is the scanner's word for word, so a document refused for depth
    reads the same whether it was `valid` or `token` that refused it.
    """
    var d = new_decoder(new_buffer_string("[[[[1]]]]"))
    d.max_depth = 3
    for _ in range(3):
        assert_equal(d.token().as_delim(), ARRAY_OPEN)
    var said = Error()
    try:
        _ = d.token()
    except e:
        said = e.copy()
    var failure = SyntaxError.of(said)
    assert_true(Bool(failure))
    assert_equal(
        failure.value().error(), "invalid character '[' exceeded max depth"
    )
    assert_equal(failure.value().offset, 3)


def test_max_depth_is_sticky() raises:
    """A document too deep to read does not become readable on the next call."""
    var d = new_decoder(new_buffer_string("[[[[1]]]]"))
    d.max_depth = 2
    _ = d.token()
    _ = d.token()
    var first = String()
    try:
        _ = d.token()
    except e:
        first = String(e)
    var second = String()
    try:
        _ = d.token()
    except e:
        second = String(e)
    assert_equal(second, first)


def test_max_depth_allows_exactly_its_own_number() raises:
    """Off by one in either direction would show here."""
    var d = new_decoder(new_buffer_string("[[[1]]]"))
    d.max_depth = 3
    assert_equal(_show(d.token()), "[")
    assert_equal(_show(d.token()), "[")
    assert_equal(_show(d.token()), "[")
    assert_equal(_show(d.token()), "#1")


def test_tokens_is_a_cursor() raises:
    """The whole stream, with a failure raising rather than ending the loop."""
    var d = new_decoder(new_buffer_string('[1, {"a": null}]'))
    var seen = String()
    var cursor = d.tokens()
    while cursor.has_next():
        seen += _show(cursor.next())
    assert_equal(seen, '[#1{"a"null}]')


def test_a_cursor_raises_on_a_document_that_stops() raises:
    """Which is the whole reason it exists.

    A loop written on `token` and a comparison against `EOF` ends quietly here
    unless the comparison is right; this one cannot.
    """
    var d = new_decoder(new_buffer_string('["ab'))
    var cursor = d.tokens()
    assert_true(cursor.has_next())
    _ = cursor.next()
    var said = Error()
    try:
        _ = cursor.has_next()
    except e:
        said = e.copy()
    assert_true(matches(said, ErrUnexpectedEOF))


def test_a_cursor_is_done_once_and_stays_done() raises:
    """The first of the trait's three rules."""
    var d = new_decoder(new_buffer_string("1"))
    var cursor = d.tokens()
    assert_true(cursor.has_next())
    assert_equal(_show(cursor.next()), "#1")
    assert_false(cursor.has_next())
    assert_false(cursor.has_next())
    var said = Error()
    try:
        _ = cursor.next()
    except e:
        said = e.copy()
    assert_true(matches(said, EOF))


def test_the_decoder_is_usable_after_a_cursor() raises:
    """Taking a few tokens through a cursor and reading the rest by hand."""
    var d = new_decoder(new_buffer_string("[1, 2, 3]"))
    var taken = String()
    var cursor = d.tokens()
    taken += _show(cursor.next())
    taken += _show(cursor.next())
    assert_equal(taken, "[#1")
    assert_equal(_show(d.token()), "#2")


def test_escapes_come_back_as_characters() raises:
    """The seven two character escapes, all in one string."""
    assert_equal(_unq('"\\n"'), "\n")
    assert_equal(_unq('"\\t"'), "\t")
    assert_equal(_unq('"\\r"'), "\r")
    assert_equal(_unq('"\\b"'), chr(8))
    assert_equal(_unq('"\\f"'), chr(12))
    assert_equal(_unq('"\\\\"'), "\\")
    assert_equal(_unq('"\\/"'), "/")
    assert_equal(_unq('"\\""'), '"')


def test_a_hex_escape_comes_back_as_its_code_point() raises:
    """Below and above the one byte boundary, and the null character."""
    assert_equal(_unq('"\\u0041"'), "A")
    assert_equal(_unq('"\\u00e9"'), "é")
    assert_equal(_unq('"\\u20ac"'), "€")
    assert_equal(_unq('"\\u0000"'), chr(0))
    assert_equal(_unq('"\\uFFFD"'), chr(0xFFFD))


def test_a_surrogate_pair_comes_back_as_one_character() raises:
    """Which is the only way a document can write a code point above the basic
    plane as an escape."""
    assert_equal(_unq('"\\ud83d\\ude00"'), chr(0x1F600))
    assert_equal(_unq('"\\uD834\\uDD1E"'), chr(0x1D11E))
    assert_equal(_unq('"a\\ud83d\\ude00b"'), "a" + chr(0x1F600) + "b")


def test_a_surrogate_on_its_own_becomes_the_replacement() raises:
    """Six characters a document is allowed to contain and no code point
    matches, so this is coerced rather than refused, as Go and everything else
    does."""
    assert_equal(_unq('"\\ud800"'), chr(0xFFFD))
    assert_equal(_unq('"\\udc00"'), chr(0xFFFD))
    assert_equal(_unq('"\\ud800a"'), chr(0xFFFD) + "a")
    assert_equal(_unq('"\\ud800\\ud800"'), chr(0xFFFD) + chr(0xFFFD))
    assert_equal(_unq('"\\ud800\\u0041"'), chr(0xFFFD) + "A")


def test_bytes_that_are_not_utf8_become_the_replacement() raises:
    """A string is where this stops caring what a document holds.

    The structure was already checked by the scanner, and the text is coerced.
    Written as bytes because a Mojo `String` cannot hold a lone continuation
    byte at all.
    """
    var quote = Byte(ord('"'))
    var lone: List[Byte] = [quote, Byte(0x80), quote]
    assert_equal(_unquote(Span(lone)), chr(0xFFFD))
    var cut: List[Byte] = [quote, Byte(0xE2), Byte(0x82), quote]
    assert_equal(_unquote(Span(cut)), chr(0xFFFD) + chr(0xFFFD))
    var good: List[Byte] = [quote, Byte(0xE2), Byte(0x82), Byte(0xAC), quote]
    assert_equal(_unquote(Span(good)), "€")


def test_an_empty_string_unquotes_to_nothing() raises:
    """The shortest literal the scanner can produce."""
    assert_equal(_unq('""'), "")


def test_a_string_token_owns_its_bytes() raises:
    """A token kept across a hundred calls is the token that was read."""
    var d = new_decoder(OneByte('["first", "second", "third"]'))
    _ = d.token()
    var held = d.token()
    for _ in range(3):
        _ = d.token()
    assert_equal(held.as_string(), "first")
