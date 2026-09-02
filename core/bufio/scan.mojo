"""The scanner, and the split functions that drive it. Go's `bufio.Scanner`.

Two things here are not Go's, and both are the point of the file.

## The scanner is a `Cursor`, and there is no `err()`

`core.iter.Cursor` names `bufio.Scanner` as the thing it exists to prevent. Go's
loop is `for s.Scan() { ... }` and it ends early and silently on a read failure;
the check that would have caught it is `s.Err()`, somewhere after the loop,
easily forgotten and impossible for a reader of the code to notice is missing.

So `has_next` is Go's `Scan` with one difference: a clean end of input is
`False`, and anything else comes out as a raise. There is nothing to ask for
afterwards, and nothing to forget.

```mojo
from core.bufio import new_scanner
from core.io import AnyReader


def count_lines(var src: AnyReader) raises -> Int:
    var s = new_scanner(src^)
    var n = 0
    while s.has_next():
        _ = s.next()
        n += 1
    return n
```

## The split function is a trait, not a function pointer

Go's `SplitFunc` is `func(data []byte, atEOF bool) (advance int, token []byte,
err error)`, and the interesting ones in the wild are closures. Neither half of
that survives translation. A function type here has to name concrete types in
every position, origins included, so the `data` argument has no spelling that
does not launder an origin through `core.runtime.box`; and a thin function
pointer has nowhere to keep what a closure captures.

A trait solves both at once, because a trait method may be parametric over the
origin exactly as `io.Reader.read` is, and the receiver is the captured state.
`design.md` section 3 has the general form; this is the first use of it.

The consequence is that the splitter is a type parameter fixed when the scanner
is built. Go's `Split` is a setter that panics if called after the first `Scan`;
here that mistake cannot be written down.

## Tokens are ranges, not slices

`Split` carries indices into the data it was given rather than a subslice, for
the reason in `read.mojo`: a `Span` does not keep its owner still. It also
carries `final` instead of Go's `ErrFinalToken`, which is Go's one place where
an error is not a failure and does not survive being raised. The error channel
here only ever carries failures.
"""

from core.errors import Report, capture, matches, partial
from core.errors.codes import (
    EOF,
    ErrAdvanceTooFar,
    ErrBadReadCount,
    ErrNegativeAdvance,
    ErrNoProgress,
    ErrTooLong,
)
from core.errors.value import ErrorValue
from core.io import Byte, Reader as IoReader
from core.iter import Cursor

from ._rune import RUNE_SELF, _decode_rune, _full_rune

comptime MAX_SCAN_TOKEN_SIZE = 64 * 1024
"""The largest token a scanner will assemble unless told otherwise.

Go's `MaxScanTokenSize`, same number. The ceiling is not an implementation
detail: without one, a stream with no delimiter anywhere in it turns into an
allocation the size of the stream, and that is a denial of service on any input
somebody else controls. `Scanner.buffer` raises it for input that legitimately
needs more.
"""

comptime _START_BUFFER = 4096
"""The first buffer a scanner allocates. Go's `startBufSize`, same number."""

comptime _MAX_EMPTY = 100
"""How many empty tokens in a row are tolerated before calling it a loop.

Go panics here. Nothing in this library panics, so it raises `ErrNoProgress`,
and the condition is the same one: a split function that keeps returning a token
without advancing would spin forever.
"""


@fieldwise_init
struct Split(Copyable, ImplicitlyCopyable, Movable):
    """What a split function decided. Go's three return values, minus the error.

    `start` and `stop` index into the `data` the splitter was handed, and a
    `stop` below zero means there is no token this time. Indices rather than a
    subslice because a span does not keep its owner still, `read.mojo`.

    Build one with the five constructors below rather than by hand. They are
    named for what the scanner does next, which is the thing a split function
    is actually deciding.
    """

    var advance: Int
    """How many bytes of `data` the scanner should consume."""

    var start: Int
    """Where the token begins in `data`."""

    var stop: Int
    """Where it ends. Below zero means there is no token."""

    var final: Bool
    """Stop after this one, token or not. Go's `ErrFinalToken`."""

    @staticmethod
    def more() -> Self:
        """No token yet; read more input and ask again.

        The scanner will not ask again with the same data unless more arrived,
        so this cannot loop.
        """
        return Self(0, 0, -1, False)

    @staticmethod
    def skip(advance: Int) -> Self:
        """No token, but these bytes can go. Leading whitespace, for instance.
        """
        return Self(advance, 0, -1, False)

    @staticmethod
    def token(advance: Int, start: Int, stop: Int) -> Self:
        """A token, and how far to move past it.

        `advance` is usually larger than `stop`, because the delimiter is
        consumed and is not part of the token.
        """
        return Self(advance, start, stop, False)

    @staticmethod
    def last(advance: Int, start: Int, stop: Int) -> Self:
        """A token, and no more after it. Go's `ErrFinalToken` with a token."""
        return Self(advance, start, stop, True)

    @staticmethod
    def stop_here() -> Self:
        """No token and no more input wanted. Go's `ErrFinalToken` with nil.

        Not called `stop`, because that is the name of a field.
        """
        return Self(0, 0, -1, True)

    def has_token(self) -> Bool:
        """Whether this carries a token at all."""
        return self.stop >= 0


trait Splitter:
    """Where a scanner's tokens come from. Go's `bufio.SplitFunc`.

    One method, so an implementation is a function with somewhere to keep its
    state. `mut self` is that somewhere: a splitter that has to remember
    something between calls, which in Go is a closure over a variable, is a
    struct with a field here.

    ```mojo
    from core.bufio import Split, Splitter


    struct Alternating(Splitter, Copyable, Movable):
        \"\"\"Tokens of one byte, then two, to show what state looks like.\"\"\"

        var wide: Bool

        def __init__(out self):
            self.wide = False

        def split[
            o: Origin
        ](mut self, data: Span[UInt8, o], at_eof: Bool) raises -> Split:
            var want = 2 if self.wide else 1
            if len(data) < want:
                if not at_eof or len(data) == 0:
                    return Split.more()
                want = len(data)
            self.wide = not self.wide
            return Split.token(want, 0, want)
    ```

    Once the input has ended, a decision carrying no token ends the scan even
    if bytes are left, which is Go's rule and is the one thing about writing a
    splitter that is easy to get wrong. A splitter with a last token to produce
    has to produce it on the call where `at_eof` is true; `ScanLines` and
    `ScanWords` both have that branch and it is the only reason they do.
    """

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        """Decide what to do with the bytes the scanner is holding.

        `data` is everything the scanner has that it has not consumed, and
        `at_eof` says there will be no more. A splitter that cannot decide asks
        for more with `Split.more()`, and the scanner will not call it again
        with the same bytes unless something arrived, so that is not a loop.

        At end of input with nothing left, return `Split.more()`: the scanner
        reads that as a clean end. Raising is for a malformed stream, and it
        comes out of `has_next` on the caller's side.
        """
        ...


struct ScanBytes(Copyable, Movable, Splitter):
    """One byte per token. Go's `ScanBytes`."""

    def __init__(out self):
        pass

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        if len(data) == 0:
            return Split.more()
        return Split.token(1, 0, 1)


struct ScanRunes(Copyable, Movable, Splitter):
    """One UTF-8 rune per token. Go's `ScanRunes`.

    Go substitutes the three byte encoding of U+FFFD for a byte that is not
    valid UTF-8. A token here is a range of the input, so there is nowhere for
    bytes that are not in the input to come from: the offending byte is the
    token, one per byte, and the advance is the same, so the token stream still
    lines up with Go's. A caller that wants the substitution makes it, which is
    a decode it was going to do anyway.
    """

    def __init__(out self):
        pass

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        if len(data) == 0:
            return Split.more()
        if Int(data[0]) < RUNE_SELF:
            return Split.token(1, 0, 1)

        var r: Int32
        var width: Int
        r, width = _decode_rune(data)
        if width > 1:
            return Split.token(width, 0, width)
        # One byte wide and not ASCII means either a broken encoding or a rune
        # split across the end of what has arrived, and only `_full_rune` can
        # tell those apart.
        if not at_eof and not _full_rune(data):
            return Split.more()
        return Split.token(1, 0, 1)


struct ScanLines(Copyable, Movable, Splitter):
    """One line per token, with the ending stripped. Go's `ScanLines`.

    Both `\\n` and `\\r\\n` end a line and neither appears in the token. A final
    line with no ending is still a line.
    """

    def __init__(out self):
        pass

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        for i in range(len(data)):
            if data[i] == 10:
                var stop = i
                if stop > 0 and data[stop - 1] == 13:
                    stop -= 1
                return Split.token(i + 1, 0, stop)
        if at_eof and len(data) > 0:
            var stop = len(data)
            if data[stop - 1] == 13:
                stop -= 1
            return Split.token(len(data), 0, stop)
        return Split.more()


def _is_space(r: Int32) -> Bool:
    """Go's `bufio.isSpace`, byte for byte.

    Written out rather than taken from a Unicode table because it is a closed
    set of nineteen code points and `core.unicode` is M3. When #19 lands this
    becomes a call and this function goes.
    """
    if r <= 0xFF:
        if r == 32 or (r >= 9 and r <= 13):
            return True
        return r == 0x85 or r == 0xA0
    if r >= 0x2000 and r <= 0x200A:
        return True
    return (
        r == 0x1680
        or r == 0x2028
        or r == 0x2029
        or r == 0x202F
        or r == 0x205F
        or r == 0x3000
    )


struct ScanWords(Copyable, Movable, Splitter):
    """One word per token, whitespace stripped. Go's `ScanWords`.

    Whitespace is the same nineteen code points Go's is, so a word here is a
    word there.
    """

    def __init__(out self):
        pass

    def split[
        o: Origin
    ](mut self, data: Span[Byte, o], at_eof: Bool) raises -> Split:
        var start = 0
        while start < len(data):
            var r: Int32
            var width: Int
            r, width = _decode_rune(data[start:])
            if not _is_space(r):
                break
            start += width

        var i = start
        while i < len(data):
            var r: Int32
            var width: Int
            r, width = _decode_rune(data[i:])
            if _is_space(r):
                return Split.token(i + width, start, i)
            i += width

        if at_eof and len(data) > start:
            return Split.token(len(data), start, len(data))
        # Everything so far was whitespace, so it can go even though there is
        # no token yet. Without this the scanner would rescan it every time.
        return Split.skip(start)


struct Scanner[
    R: IoReader & Deinitable & Movable, S: Splitter & Deinitable & Movable
](Cursor, Movable):
    """Tokens out of a reader. Go's `bufio.Scanner`, as a `Cursor`.

    Not `Copyable`, for the reason `Reader` is not.
    """

    comptime Element = List[Byte]
    """A token, owned. See the module docstring for why it is not a view."""

    var r: Self.R
    """Where the bytes come from."""

    var splitter: Self.S
    """What turns them into tokens. Fixed at construction, see the docstring."""

    var buf: List[Byte]
    """Grows up to `max_token`. Starts empty and is allocated on the first read.
    """

    var start: Int
    """Where the unconsumed bytes begin."""

    var stop: Int
    """Where they end."""

    var max_token: Int
    """The ceiling on one token. `MAX_SCAN_TOKEN_SIZE` unless `buffer` says."""

    var token: List[Byte]
    """The token `has_next` found, waiting for `next`, `bytes` or `text`."""

    var have_token: Bool
    """Whether `token` holds one. Cleared by `next`."""

    var pending: Optional[ErrorValue]
    """A failure or an end of input that the splitter has not been told about yet.
    """

    var done: Bool
    """Whether the scanner has finished, cleanly or otherwise."""

    var scanned: Bool
    """Whether `has_next` has been called, which is what `buffer` refuses after.
    """

    var empties: Int
    """Consecutive empty tokens without progress. See `_MAX_EMPTY`."""

    def __init__(out self, var r: Self.R, var splitter: Self.S):
        self.r = r^
        self.splitter = splitter^
        self.buf = List[Byte]()
        self.start = 0
        self.stop = 0
        self.max_token = MAX_SCAN_TOKEN_SIZE
        self.token = List[Byte]()
        self.have_token = False
        self.pending = Optional[ErrorValue]()
        self.done = False
        self.scanned = False
        self.empties = 0

    def buffer(mut self, size: Int, max: Int) raises:
        """Set the starting buffer size and the ceiling. Go's `Buffer`.

        Go is handed a slice to use, which is a way to reuse an allocation
        across scanners. Ownership here means the scanner would take the list
        and the caller could not have it back, which buys nothing, so this takes
        the size instead of the memory.

        Go panics if this is called after scanning has started. This raises,
        because nothing here panics, and it is still a caller mistake rather
        than a stream problem: the buffer it is about to throw away may hold
        input that has already been read.
        """
        if self.scanned:
            raise (
                Report(
                    "bufio.scanner: buffer after scanning has started"
                ).error()
            )
        var ceiling = max
        if ceiling < size:
            ceiling = size
        if ceiling <= 0:
            ceiling = MAX_SCAN_TOKEN_SIZE
        var want = size
        if want < 0:
            want = 0
        self.buf = List[Byte](length=want, fill=0)
        self.max_token = ceiling
        self.start = 0
        self.stop = 0

    def bytes(self) -> List[Byte]:
        """The token `has_next` found, as bytes. Go's `Bytes`.

        A copy, and empty when there is no token. Go returns a view into the
        buffer here and documents that the next `Scan` overwrites it, which is
        the hazard `read.mojo` explains cannot be caught.
        """
        return self.token.copy()

    def text(self) raises -> String:
        """The token as text. Go's `Text`.

        Raises on a token that is not valid UTF-8, which Go's `Text` cannot do
        because a Go string is bytes. `Reader.read_string` explains the choice;
        `bytes` is the version that never refuses.
        """
        return String(from_utf8=Span(self.token))

    def _hold(mut self, e: Error):
        """Remember a failure until the splitter has been given a last look."""
        self.pending = Optional[ErrorValue](capture(e))

    def _grow(mut self) raises:
        """Make room for more of a token that has not ended yet.

        Doubling, capped at `max_token`, and `ErrTooLong` when the cap is
        already the size. Go does the same and the cap is the whole reason the
        scanner is safe to point at input somebody else wrote.
        """
        if self.start > 0 and (
            self.stop == len(self.buf) or self.start > len(self.buf) // 2
        ):
            for i in range(self.start, self.stop):
                self.buf[i - self.start] = self.buf[i]
            self.stop -= self.start
            self.start = 0
        if self.stop < len(self.buf):
            return

        var want = len(self.buf) * 2
        if want == 0:
            want = _START_BUFFER
        if want > self.max_token:
            want = self.max_token
        if want <= len(self.buf):
            self.done = True
            raise (
                Report("bufio.scanner: token longer than the maximum allowed")
                .with_code(ErrTooLong)
                .with_count(self.stop - self.start)
                .error()
            )

        var bigger = List[Byte](length=want, fill=0)
        for i in range(self.start, self.stop):
            bigger[i - self.start] = self.buf[i]
        self.buf = bigger^
        self.stop -= self.start
        self.start = 0

    def _read_more(mut self) raises:
        """One read into the space after what is held. Failures become `pending`.
        """
        var got: Int
        try:
            got = self.r.read(Span(self.buf)[self.stop :])
        except e:
            self._hold(e)
            return
        if got < 0 or got > len(self.buf) - self.stop:
            self._hold(
                Report(
                    "bufio.scanner: the source read outside the span it was"
                    " given"
                )
                .with_code(ErrBadReadCount)
                .error()
            )
            return
        self.stop += got
        if got == 0:
            self._hold(
                Report(
                    "bufio.scanner: the source returned no bytes and no error"
                )
                .with_code(ErrNoProgress)
                .error()
            )
        else:
            self.empties = 0

    def _apply(mut self, decision: Split) raises:
        """Check what the splitter said and move the window, or raise.

        Go can only check the advance, because its token is a slice and is by
        construction inside the data. Ours is a pair of indices a split function
        chose, so the range is checked too: a splitter with an off by one would
        otherwise hand out bytes from outside the window.
        """
        var window = self.stop - self.start
        if decision.advance < 0:
            raise (
                Report("bufio.scanner: the split function went backwards")
                .with_code(ErrNegativeAdvance)
                .error()
            )
        if decision.advance > window:
            raise (
                Report("bufio.scanner: the split function went past the end")
                .with_code(ErrAdvanceTooFar)
                .error()
            )
        if decision.has_token() and (
            decision.start < 0
            or decision.start > decision.stop
            or decision.stop > window
        ):
            raise (
                Report(
                    "bufio.scanner: the split function returned a token that is"
                    " not inside the data it was given"
                )
                .with_code(ErrAdvanceTooFar)
                .error()
            )
        if decision.has_token():
            var out = List[Byte](capacity=decision.stop - decision.start)
            for i in range(decision.start, decision.stop):
                out.append(self.buf[self.start + i])
            self.token = out^
            self.have_token = True
        self.start += decision.advance

    def has_next(mut self) raises -> Bool:
        """Find the next token. Go's `Scan`, with the failure raised.

        `False` means a clean end of input and keeps meaning it. Everything
        else — a read that failed, a token past the maximum, a split function
        that misbehaved — comes out as a raise, which is the whole difference
        between this and Go and the reason `core.iter.Cursor` exists.

        Calling it twice without a `next` in between is not an error and does
        not advance; the second call answers from the token the first found.
        """
        if self.have_token:
            return True
        if self.done:
            return False
        self.scanned = True

        while True:
            if self.stop > self.start or self.pending:
                var at_eof = Bool(self.pending)
                var decision = self.splitter.split(
                    Span(self.buf)[self.start : self.stop], at_eof
                )
                if decision.final:
                    self.done = True
                    self._apply(decision)
                    return self.have_token
                var moved = decision.advance
                self._apply(decision)
                if self.have_token:
                    if not self.pending or moved > 0:
                        self.empties = 0
                    else:
                        self.empties += 1
                        if self.empties > _MAX_EMPTY:
                            raise (
                                Report(
                                    "bufio.scanner: the split function keeps"
                                    " returning tokens without advancing"
                                )
                                .with_code(ErrNoProgress)
                                .error()
                            )
                    return True

            if self.pending:
                # The splitter has had its look at what is left and wants more,
                # and there is no more. Whatever ended the stream decides
                # whether that is a clean end or a failure.
                self.start = 0
                self.stop = 0
                self.done = True
                var held = self.pending.take()
                self.pending = Optional[ErrorValue]()
                var e = held.error()
                if matches(e, EOF):
                    return False
                raise e

            self._grow()
            self._read_more()

    def next(mut self) raises -> List[Byte]:
        """The token, moved out. `Cursor.next`.

        Calls `has_next` if it has not been called, so a loop that only wants
        tokens can be written with this alone. Raises `EOF` past the end,
        because there is no zero value to return.
        """
        if not self.have_token:
            if not self.has_next():
                raise (
                    Report("bufio.scanner: no more tokens")
                    .with_code(EOF)
                    .error()
                )
        self.have_token = False
        var out = List[Byte]()
        swap(out, self.token)
        return out^


def new_scanner[
    R: IoReader & Deinitable & Movable,
    S: Splitter & Deinitable & Movable = ScanLines,
](var r: R, var splitter: S = ScanLines()) -> Scanner[R, S]:
    """A scanner over `r`, splitting into lines unless told otherwise.

    Go's `NewScanner`, plus the second argument that replaces its `Split`
    setter. `new_scanner(src^)` gives lines; `new_scanner(src^, ScanWords())`
    gives words, and the choice is in the type, so it cannot be changed halfway
    through a scan.
    """
    return Scanner[R, S](r^, splitter^)
