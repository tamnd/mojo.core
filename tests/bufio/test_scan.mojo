"""The scanner and its splitters. Go's `bufio/scan_test.go`.

Issue #14 names two things this file has to prove: that a scanner hitting its
token limit says so, and that one over a reader returning short reads still
produces the same tokens. Both are here, and the second is why every splitter
is exercised over `OneByte` as well as over `Fixed` — a scanner that only
called its splitter once per read would produce the right tokens over a source
that hands over everything at once and mangle them over one that dribbles.

The rest is the two departures from Go. The scanner is a `core.iter.Cursor`, so
a read failure comes out of `has_next` rather than being left in an `Err()`
nobody checks — `test_a_read_failure_comes_out_of_the_loop` is the one that
would have been silent in Go. And the split function is a trait, so a stateful
splitter is a struct with a field: `Alternating` is here to show that compiles
and works, because the whole erasure design in this milestone turns on it.
"""

from std.testing import assert_equal, assert_true

from core.bufio import (
    MAX_SCAN_TOKEN_SIZE,
    ScanBytes,
    ScanLines,
    ScanRunes,
    ScanWords,
    Scanner,
    Split,
    Splitter,
    new_scanner,
)
from core.errors import matches
from core.errors.codes import (
    EOF,
    ErrAdvanceTooFar,
    ErrNegativeAdvance,
    ErrNoProgress,
    ErrTooLong,
)
from core.io import Byte

from tests.bufio._fixtures import (
    Broken,
    Fixed,
    Half,
    OneByte,
    as_bytes,
    as_text,
)


def lines_of[
    S: Splitter & Deinitable & Movable
](var s: Scanner[Fixed, S]) raises -> List[String]:
    """Every token a scanner produces, as text, for readable assertions."""
    var out = List[String]()
    while s.has_next():
        out.append(as_text(s.next()))
    return out^


def dribbled[
    S: Splitter & Deinitable & Movable
](var s: Scanner[OneByte, S]) raises -> List[String]:
    """The same, over a source that hands over one byte at a time."""
    var out = List[String]()
    while s.has_next():
        out.append(as_text(s.next()))
    return out^


def assert_tokens(got: List[String], want: List[String]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def strings(*items: String) -> List[String]:
    var out = List[String]()
    for item in items:
        out.append(item)
    return out^


# Lines.


def test_lines_are_the_default() raises:
    assert_tokens(
        lines_of(new_scanner(Fixed("one\ntwo\nthree\n"))),
        strings("one", "two", "three"),
    )


def test_a_final_line_without_an_ending_is_still_a_line() raises:
    assert_tokens(
        lines_of(new_scanner(Fixed("one\ntwo"))), strings("one", "two")
    )


def test_a_trailing_newline_does_not_make_an_empty_last_line() raises:
    assert_tokens(lines_of(new_scanner(Fixed("one\n"))), strings("one"))


def test_empty_lines_are_tokens() raises:
    assert_tokens(lines_of(new_scanner(Fixed("\n\na\n"))), strings("", "", "a"))


def test_carriage_returns_are_stripped() raises:
    assert_tokens(
        lines_of(new_scanner(Fixed("one\r\ntwo\r\n"))), strings("one", "two")
    )


def test_a_lone_carriage_return_at_the_end_is_stripped() raises:
    """Go's `dropCR` runs on the final unterminated line too."""
    assert_tokens(lines_of(new_scanner(Fixed("one\r"))), strings("one"))


def test_empty_input_has_no_tokens() raises:
    var s = new_scanner(Fixed(""))
    assert_true(not s.has_next())


def test_has_next_keeps_saying_no() raises:
    """`Cursor`'s rule: `False` is a clean end and it stays that way."""
    var s = new_scanner(Fixed("a\n"))
    assert_true(s.has_next())
    _ = s.next()
    assert_true(not s.has_next())
    assert_true(not s.has_next())


def test_lines_over_a_one_byte_reader() raises:
    assert_tokens(
        dribbled(new_scanner(OneByte("one\ntwo\nthree"))),
        strings("one", "two", "three"),
    )


def test_lines_over_a_half_reader() raises:
    var s = new_scanner(Half("one\ntwo\nthree"))
    var out = List[String]()
    while s.has_next():
        out.append(as_text(s.next()))
    assert_tokens(out, strings("one", "two", "three"))


# The other splitters.


def test_words() raises:
    assert_tokens(
        lines_of(new_scanner(Fixed("  hello   world\n\tagain  "), ScanWords())),
        strings("hello", "world", "again"),
    )


def test_a_last_word_with_no_whitespace_after_it() raises:
    """The branch every splitter needs and the one easiest to leave out: a
    token that exists only because the input ended. Both inputs above end in
    whitespace, which is the shape that never reaches it."""
    assert_tokens(
        lines_of(new_scanner(Fixed("hello world"), ScanWords())),
        strings("hello", "world"),
    )


def test_words_of_only_whitespace() raises:
    var s = new_scanner(Fixed("   \n\t  "), ScanWords())
    assert_true(not s.has_next())


def test_words_over_a_one_byte_reader() raises:
    assert_tokens(
        dribbled(new_scanner(OneByte("  hello   world  "), ScanWords())),
        strings("hello", "world"),
    )


def test_bytes() raises:
    assert_tokens(
        lines_of(new_scanner(Fixed("abc"), ScanBytes())),
        strings("a", "b", "c"),
    )


def test_runes() raises:
    assert_tokens(
        lines_of(new_scanner(Fixed("a¢€𐍈"), ScanRunes())),
        strings("a", "¢", "€", "𐍈"),
    )


def test_runes_over_a_one_byte_reader() raises:
    """A rune arrives a byte at a time, so a splitter that decoded whatever had
    turned up would report replacement characters here."""
    assert_tokens(
        dribbled(new_scanner(OneByte("a¢€𐍈"), ScanRunes())),
        strings("a", "¢", "€", "𐍈"),
    )


def test_runes_on_invalid_input_take_one_byte_each() raises:
    """The documented deviation: Go substitutes U+FFFD and this hands over the
    offending byte, one token per byte, so the stream still lines up."""
    var raw = List[Byte]()
    raw.append(Byte(0xFF))
    raw.append(Byte(0xFE))
    raw.append(Byte(ord("z")))
    var s = new_scanner(Fixed(raw^), ScanRunes())
    var count = 0
    var last = List[Byte]()
    while s.has_next():
        last = s.next()
        count += 1
    assert_equal(count, 3)
    assert_equal(len(last), 1)
    assert_equal(last[0], Byte(ord("z")))


# The token limit, which is what makes this safe to point at hostile input.


def test_a_token_past_the_maximum_is_refused() raises:
    var s = new_scanner(Fixed("0123456789abcdefghijklmnopqrstuvwxyz"))
    s.buffer(8, 16)
    var raised = False
    try:
        _ = s.has_next()
    except e:
        raised = True
        assert_true(matches(e, ErrTooLong))
    assert_true(raised)


def test_a_token_that_fits_with_its_delimiter_is_allowed() raises:
    """Fifteen bytes and a newline in a sixteen byte ceiling. The delimiter has
    to fit too, because the buffer holds it before the splitter drops it, which
    is Go's behaviour and is the off by one worth pinning."""
    var s = new_scanner(Fixed("0123456789abcde\nrest\n"))
    s.buffer(8, 16)
    assert_true(s.has_next())
    assert_equal(as_text(s.next()), "0123456789abcde")


def test_the_limit_is_reached_over_a_one_byte_reader_too() raises:
    """The buffer grows a read at a time here rather than in one jump, which is
    where an off by one in the growth would show."""
    var s = new_scanner(OneByte("0123456789abcdefghijklmnopqrstuvwxyz"))
    s.buffer(8, 16)
    var raised = False
    try:
        _ = s.has_next()
    except e:
        raised = True
        assert_true(matches(e, ErrTooLong))
    assert_true(raised)


def test_the_default_maximum_is_gos() raises:
    assert_equal(MAX_SCAN_TOKEN_SIZE, 64 * 1024)


def test_buffer_after_scanning_has_started_is_refused() raises:
    """Go panics here. Nothing in this library panics, and the mistake is the
    same one: the buffer being thrown away may hold input already read."""
    var s = new_scanner(Fixed("a\nb\n"))
    _ = s.has_next()
    var raised = False
    try:
        s.buffer(64, 128)
    except e:
        raised = True
    assert_true(raised)


# Failures, which is where this differs from Go most.


def test_a_read_failure_comes_out_of_the_loop() raises:
    """The whole reason `Cursor` exists. In Go this loop ends looking exactly
    like a clean end of file and the reason is in an `Err()` nobody calls."""
    var s = new_scanner(Broken("one\ntwo\n"))
    assert_equal(as_text(s.next()), "one")
    assert_equal(as_text(s.next()), "two")
    var raised = False
    try:
        _ = s.has_next()
    except e:
        raised = True
        assert_true(not matches(e, EOF))
    assert_true(raised)


def test_next_past_the_end_raises() raises:
    """There is no zero value to return, so this is `EOF` rather than empty."""
    var s = new_scanner(Fixed("a\n"))
    _ = s.next()
    var raised = False
    try:
        _ = s.next()
    except e:
        raised = True
        assert_true(matches(e, EOF))
    assert_true(raised)


def test_next_alone_is_a_usable_loop() raises:
    """`next` calls `has_next` when it has to, so a caller that wants tokens
    and nothing else does not have to write both."""
    var s = new_scanner(Fixed("a\nb\n"))
    assert_equal(as_text(s.next()), "a")
    assert_equal(as_text(s.next()), "b")


def test_has_next_twice_does_not_advance() raises:
    var s = new_scanner(Fixed("a\nb\n"))
    assert_true(s.has_next())
    assert_true(s.has_next())
    assert_equal(as_text(s.next()), "a")


def test_bytes_and_text_see_the_same_token() raises:
    var s = new_scanner(Fixed("héllo\n"))
    assert_true(s.has_next())
    assert_equal(s.text(), "héllo")
    assert_equal(len(s.bytes()), 6)
    # And they are copies, so asking twice is the same answer.
    assert_equal(s.text(), "héllo")


# Splitters written by hand, which is what the trait is for.


struct Alternating(Copyable, Movable, Splitter):
    """Tokens of one byte, then two, then one, and so on.

    The alternation is a field. In Go this is a closure over a local; here the
    receiver is the captured state and there is no second mechanism, which is
    the pattern `design.md` section 3 settles for the whole library.
    """

    var wide: Bool

    def __init__(out self):
        self.wide = False

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        var want = 2 if self.wide else 1
        if len(data) < want:
            if not at_eof or len(data) == 0:
                return Split.more()
            want = len(data)
        self.wide = not self.wide
        return Split.token(want, 0, want)


def test_a_stateful_splitter_keeps_its_state() raises:
    assert_tokens(
        lines_of(new_scanner(Fixed("abcdef"), Alternating())),
        strings("a", "bc", "d", "ef"),
    )


def test_a_stateful_splitter_over_a_one_byte_reader() raises:
    """The splitter is asked again every time a byte arrives, so one that
    changed its state on a call that produced no token would drift here."""
    assert_tokens(
        dribbled(new_scanner(OneByte("abcdef"), Alternating())),
        strings("a", "bc", "d", "ef"),
    )


struct SkipsForever(Copyable, Movable, Splitter):
    """Consumes a byte at a time and never produces a token."""

    def __init__(out self):
        pass

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        if len(data) == 0:
            return Split.more()
        return Split.skip(1)


def test_a_split_with_no_token_once_the_input_has_ended_finishes() raises:
    """Go's rule, and it is subtler than it looks: once the input has ended, a
    decision carrying no token ends the scan even though bytes are left. A
    splitter with a final token to produce has to produce it on the call where
    `at_eof` is true, which is what `ScanLines` and `ScanWords` both do."""
    var s = new_scanner(Fixed("abcdef"), SkipsForever())
    assert_true(not s.has_next())


struct FirstTwo(Copyable, Movable, Splitter):
    """Two tokens and then stop, using `final` in place of `ErrFinalToken`."""

    var seen: Int

    def __init__(out self):
        self.seen = 0

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        if len(data) == 0:
            return Split.more()
        self.seen += 1
        if self.seen == 2:
            return Split.last(1, 0, 1)
        return Split.token(1, 0, 1)


def test_a_final_token_ends_the_scan() raises:
    """Go's `ErrFinalToken`, without an error that is not a failure."""
    assert_tokens(
        lines_of(new_scanner(Fixed("abcdef"), FirstTwo())), strings("a", "b")
    )


struct StopAtOnce(Copyable, Movable, Splitter):
    """Stops without a token. Go's `ErrFinalToken` with a nil token."""

    def __init__(out self):
        pass

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        return Split.stop_here()


def test_stopping_without_a_token_is_a_clean_end() raises:
    var s = new_scanner(Fixed("abcdef"), StopAtOnce())
    assert_true(not s.has_next())


struct Backwards(Copyable, Movable, Splitter):
    """Returns a negative advance, which no splitter may do."""

    def __init__(out self):
        pass

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        return Split(-1, 0, -1, False)


def test_a_negative_advance_is_caught() raises:
    var s = new_scanner(Fixed("abcdef"), Backwards())
    var raised = False
    try:
        _ = s.has_next()
    except e:
        raised = True
        assert_true(matches(e, ErrNegativeAdvance))
    assert_true(raised)


struct TooFar(Copyable, Movable, Splitter):
    """Advances past the end of what it was shown."""

    def __init__(out self):
        pass

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        return Split(len(data) + 1, 0, -1, False)


def test_an_advance_past_the_end_is_caught() raises:
    var s = new_scanner(Fixed("abcdef"), TooFar())
    var raised = False
    try:
        _ = s.has_next()
    except e:
        raised = True
        assert_true(matches(e, ErrAdvanceTooFar))
    assert_true(raised)


struct OutsideToken(Copyable, Movable, Splitter):
    """Returns a token range that is not inside the data it was given.

    Go cannot make this mistake, because its token is a subslice by
    construction. Ours is a pair of indices a split function chose, so the
    scanner checks them, and this is the test that the check is real.
    """

    def __init__(out self):
        pass

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        return Split(1, 0, len(data) + 4, False)


def test_a_token_outside_the_data_is_caught() raises:
    var s = new_scanner(Fixed("abcdef"), OutsideToken())
    var raised = False
    try:
        _ = s.has_next()
    except e:
        raised = True
        assert_true(matches(e, ErrAdvanceTooFar))
    assert_true(raised)


struct Stuck(Copyable, Movable, Splitter):
    """An empty token forever, without ever advancing. Go's `maxConsecutive`."""

    def __init__(out self):
        pass

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        return Split(0, 0, 0, False)


def test_a_splitter_that_never_advances_is_stopped() raises:
    """Only once the input has ended, which is the only point at which not
    advancing is provably not progress. Go panics; this raises."""
    var s = new_scanner(Fixed(""), Stuck())
    var raised = False
    var rounds = 0
    try:
        while rounds < 500:
            if not s.has_next():
                break
            _ = s.next()
            rounds += 1
    except e:
        raised = True
        assert_true(matches(e, ErrNoProgress))
    assert_true(raised)
    assert_true(rounds < 500)


struct Raising(Copyable, Movable, Splitter):
    """A splitter that refuses the input, which is what raising is for."""

    def __init__(out self):
        pass

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        raise Error("splitter: this stream is malformed")


def test_a_splitter_that_raises_stops_the_scan() raises:
    var s = new_scanner(Fixed("abcdef"), Raising())
    var raised = False
    try:
        _ = s.has_next()
    except e:
        raised = True
    assert_true(raised)
