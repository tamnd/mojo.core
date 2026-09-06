"""Base32 over a stream, in both directions. Go's `NewEncoder` and `NewDecoder`.

Base32 works in groups of five bytes and eight characters, and a stream does not
arrive in groups of five. Both types here exist to hold the remainder between
calls: the encoder keeps up to four bytes back until a fifth arrives, and the
decoder keeps up to seven characters back until an eighth does.

That is why **an encoder has to be closed**. The last one to four bytes of the
input are still inside it when the last `write` returns, and `close` is what
encodes them and sends the padding. An encoder that is dropped without being
closed writes a truncated document, and no destructor here can save it, because
a destructor cannot raise and a write failure that goes nowhere is worse than
one that arrives late. `bufio.Writer` says the same thing about `flush` and for
the same reason.

The decoder is the one place base32 is fussier than base64. A padded quantum
ends the document, so the decoder remembers that it has seen one, and anything
that arrives afterwards is refused at offset zero rather than decoded. It also
knows how much it needs before it can do anything: a padded encoding needs a
whole group of eight and treats the input running out short of one as
`ErrUnexpectedEOF`, and an unpadded encoding will work with a single character
because a document can end anywhere.
"""

from core.errors import Report, capture, matches, partial
from core.errors.codes import EOF, ErrNoProgress, ErrUnexpectedEOF
from core.errors.value import ErrorValue
from core.io import Byte, Closer, Reader as IoReader, Writer as IoWriter

from .base32 import Encoding, NO_PADDING, _CR, _LF
from .corrupt import _corrupt

comptime _CHUNK = 1024
"""How much an encoder writes at a time, and how much a decoder reads.

Go's two buffers are both this size, and the decoder's output buffer is the 640
bytes that 1024 characters decode to. A round number of quanta either way, so
nothing is split across a chunk boundary for the sake of the buffer.
"""

comptime _DECODED_CHUNK = _CHUNK // 8 * 5
"""What `_CHUNK` characters decode to."""


struct Encoder[W: IoWriter & Deinitable & Movable](Closer, IoWriter, Movable):
    """An encoding over a writer. Go's `NewEncoder`.

    ```mojo
    from core.encoding.base32 import new_encoder, std_encoding
    from core.io import AnyWriter


    def wrap(var dst: AnyWriter, data: Span[UInt8, MutableAnyOrigin]) raises:
        var enc = new_encoder(std_encoding(), dst^)
        _ = enc.write(data)
        enc.close()
    ```

    Not `Copyable`, for the reason `bufio.Writer` is not: two copies over one
    sink would each hold a fragment of a group the other did not, and closing
    them both would write two ends to one document.
    """

    var enc: Encoding
    """The encoding to use. A copy, so the caller may drop theirs."""

    var w: Self.W
    """Where the characters go. Owned, so the call through is direct."""

    var buf: List[Byte]
    """Up to five bytes of input waiting for a group. `nbuf` says how many."""

    var nbuf: Int
    """How many of `buf` are real. Never more than four between calls."""

    var out: List[Byte]
    """Where a group of input is encoded before it is written."""

    var pending: Optional[ErrorValue]
    """The failure this encoder is stuck on, if it has one."""

    def __init__(out self, enc: Encoding, var w: Self.W):
        """Encode into `w` with `enc`. `new_encoder` is Go's name for this."""
        self.enc = enc.copy()
        self.w = w^
        self.buf = List[Byte](length=5, fill=0)
        self.nbuf = 0
        self.out = List[Byte](length=_CHUNK, fill=0)
        self.pending = Optional[ErrorValue]()

    def _check(self) raises:
        """Raise the sticky failure, if there is one, without clearing it."""
        if self.pending:
            raise self.pending.value().error()

    def _hold(mut self, e: Error):
        """Make this encoder stuck, from here to the end of its life."""
        self.pending = Optional[ErrorValue](capture(e))

    def _send(mut self, count: Int, accepted: Int) raises:
        """Write the first `count` bytes of `out`, or get stuck trying.

        `accepted` is how much of the caller's input has been taken so far, and
        it is what goes on `errors.partial` if this fails, because that is the
        number Go's `Write` returns alongside the error.
        """
        try:
            _ = self.w.write(Span(self.out)[0:count])
        except e:
            self._hold(e)
            raise (
                Report("base32.write: writing")
                .wrapping(e)
                .with_count(accepted)
                .error()
            )

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        """Encode `data` and write it. Go's `Write`.

        Returns `len(data)`, which is bytes of input rather than characters of
        output, or raises with the number of input bytes that were accepted on
        `errors.partial`. Accepted means taken from `data`, and up to four of
        those bytes are still inside the encoder waiting for a group; `close`
        is what gets them out.
        """
        self._check()

        var taken = 0

        # The fringe at the front: fill the held group, then send it.
        if self.nbuf > 0:
            while taken < len(data) and self.nbuf < 5:
                self.buf[self.nbuf] = data[taken]
                self.nbuf += 1
                taken += 1
            if self.nbuf < 5:
                return taken
            _ = self.enc.encode(Span(self.out), Span(self.buf)[0:5])
            self._send(8, taken)
            self.nbuf = 0

        # The whole groups in the middle, a chunk of output at a time.
        while len(data) - taken >= 5:
            var room = len(self.out) // 8 * 5
            if room > len(data) - taken:
                room = len(data) - taken
                room -= room % 5
            _ = self.enc.encode(Span(self.out), data[taken : taken + room])
            self._send(room // 5 * 8, taken)
            taken += room

        # The fringe at the back, held for the next call or for `close`.
        var left = len(data) - taken
        for i in range(left):
            self.buf[i] = data[taken + i]
        self.nbuf = left
        return len(data)

    def close(mut self) raises:
        """Encode whatever is held back and write it. Go's `Close`.

        This is the call that writes the padding, so a document is not finished
        until it happens. Writing after it is not defined here any more than it
        is in Go; what is defined is that closing twice writes nothing the
        second time, because the held bytes are gone by then.
        """
        self._check()
        if self.nbuf == 0:
            return
        var held = self.nbuf
        self.nbuf = 0
        _ = self.enc.encode(Span(self.out), Span(self.buf)[0:held])
        self._send(self.enc.encoded_len(held), 0)


def new_encoder[
    W: IoWriter & Deinitable & Movable
](enc: Encoding, var w: W) -> Encoder[W]:
    """An encoder writing `enc` into `w`. Go's `NewEncoder`.

    The caller must `close` it, or the last group and the padding are never
    written. Go says the same in one line of documentation and it is the
    mistake everybody makes once.
    """
    return Encoder[W](enc, w^)


def _decoded[
    o: Origin[mut=True], so: Origin
](
    enc: Encoding,
    dst: Span[Byte, o],
    src: Span[Byte, so],
    mut pending: Optional[ErrorValue],
) -> Tuple[Int, Bool]:
    """Decode `src` into `dst`, and put a failure in `pending` rather than
    raising it.

    The count and Go's `end` flag come back. The bytes decoded before a failure
    are real and are handed to the caller now; the failure is the next call's
    answer, which is the rule `bufio.Reader` follows. A failed decode never
    ends the document, so `end` is false alongside one, matching Go.

    A plain function rather than a method, because every one of the four things
    it touches is a field of the same decoder and a call cannot take the
    decoder and its own fields at once.
    """
    try:
        var n, ended = enc._decode(dst, src)
        return (n, ended)
    except e:
        pending = Optional[ErrorValue](capture(e))
        return (partial(e), False)


def _filtered[
    R: IoReader, o: Origin[mut=True]
](mut r: R, into: Span[Byte, o]) raises -> Int:
    """Read from `r` into `into` with the newlines taken out. Go's
    `newlineFilteringReader`.

    Go has this as a reader wrapped around the caller's, because that is how a
    Go decoder composes one. It is a plain function here because the only thing
    that ever calls it is the decoder below, and a whole type for one private
    caller is a type nobody can use.

    A read that finds nothing but newlines reads again rather than returning
    zero, since zero from a reader that has not ended would be a lie about the
    input having run out.
    """
    while True:
        var got = r.read(into)
        if got == 0:
            raise (
                Report(
                    "base32: the reader returned nothing and did not say why"
                )
                .with_code(ErrNoProgress)
                .error()
            )
        var kept = 0
        for i in range(got):
            var c = into[i]
            if c != _CR and c != _LF:
                if i != kept:
                    into[kept] = c
                kept += 1
        if kept > 0:
            return kept


def _read_encoded[
    R: IoReader, o: Origin[mut=True]
](
    mut r: R,
    into: Span[Byte, o],
    least: Int,
    expects_padding: Bool,
    mut arriving: Optional[ErrorValue],
) -> Int:
    """Read until `least` characters have arrived. Go's `readEncodedData`.

    A short read is not the end of anything, so this asks again until it has
    what a quantum needs or the reader says why it cannot go on. The reason
    goes in `arriving` rather than being raised, because the characters that
    did arrive still have to be decoded first.

    The end of the input part way through a group is `ErrUnexpectedEOF` rather
    than `EOF`, which is Go's rule and the reason a truncated base32 document
    fails loudly instead of decoding to a prefix of itself.
    """
    var n = 0
    while n < least and not arriving:
        try:
            n += _filtered(r, into[n:])
        except e:
            arriving = Optional[ErrorValue](capture(e))

    if arriving:
        var last = arriving.value().error()
        var truncated = n > 0
        # No characters at all, but a group already half held: still truncated,
        # unless the encoding has no padding, where any length is a document.
        if n == 0 and expects_padding and least < 8:
            truncated = True
        if truncated and matches(last, EOF):
            arriving = Optional[ErrorValue](
                capture(
                    Report("base32: the input ended in the middle of a group")
                    .with_code(ErrUnexpectedEOF)
                    .error()
                )
            )
    return n


struct Decoder[R: IoReader & Deinitable & Movable](IoReader, Movable):
    """An encoding over a reader. Go's `NewDecoder`.

    ```mojo
    from core.encoding.base32 import new_decoder, std_encoding
    from core.io import AnyReader, read_all


    def unwrap(var src: AnyReader) raises -> List[UInt8]:
        var dec = new_decoder(std_encoding(), src^)
        return read_all(dec)
    ```

    Carriage returns and line feeds are skipped, which is what lets this read
    the base32 out of a file somebody wrapped at 76 columns.
    """

    var enc: Encoding
    """The encoding to use. A copy, so the caller may drop theirs."""

    var r: Self.R
    """Where the characters come from. Owned, so the call through is direct."""

    var buf: List[Byte]
    """Characters that have arrived and not been decoded. `nbuf` counts them."""

    var nbuf: Int
    """How many of `buf` are real."""

    var out: List[Byte]
    """Decoded bytes that did not fit in the caller's span."""

    var out_start: Int
    """Where the undelivered part of `out` begins."""

    var out_end: Int
    """Where it ends."""

    var end: Bool
    """Whether a padded quantum has closed the document. Go's `d.end`."""

    var pending: Optional[ErrorValue]
    """The failure this decoder is stuck on. Go's `d.err`."""

    var arriving: Optional[ErrorValue]
    """What the reader underneath last said."""

    def __init__(out self, enc: Encoding, var r: Self.R):
        """Decode from `r` with `enc`. `new_decoder` is Go's name for this."""
        self.enc = enc.copy()
        self.r = r^
        self.buf = List[Byte](length=_CHUNK, fill=0)
        self.nbuf = 0
        self.out = List[Byte](length=_DECODED_CHUNK, fill=0)
        self.out_start = 0
        self.out_end = 0
        self.end = False
        self.pending = Optional[ErrorValue]()
        self.arriving = Optional[ErrorValue]()

    def _check(self) raises:
        """Raise the sticky failure, if there is one, without clearing it."""
        if self.pending:
            raise self.pending.value().error()

    def _hold(mut self, e: Error):
        """Make this decoder stuck, from here to the end of its life."""
        self.pending = Optional[ErrorValue](capture(e))

    def _serve[o: Origin[mut=True]](mut self, into: Span[Byte, o]) -> Int:
        """Hand over as much of the undelivered output as `into` will hold."""
        var n = self.out_end - self.out_start
        if n > len(into):
            n = len(into)
        for i in range(n):
            into[i] = self.out[self.out_start + i]
        self.out_start += n
        return n

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """Decode into `into` and return how many bytes arrived. Go's `Read`.

        Bytes never come back with a failure. A group that will not decode
        raises on the call after the one that handed over what came before it,
        which is what `io.Reader` in this library promises and what Go's own
        `bufio` does anyway.

        Characters that arrive after a padded quantum are refused, because the
        padding said the document was over. The offset on that refusal is zero,
        which is Go's, and it means the start of what arrived late rather than
        the start of the input.
        """
        if len(into) == 0:
            return 0
        if self.out_start < self.out_end:
            return self._serve(into)
        self._check()

        while True:
            var want = (len(into) + 4) // 5 * 8
            if want < 8:
                want = 8
            if want > len(self.buf):
                want = len(self.buf)

            # A padded encoding cannot do anything with less than a whole
            # group; an unpadded one can work with a single character.
            var least = 1
            var expects_padding = False
            if self.enc._pad != NO_PADDING:
                least = 8 - self.nbuf
                expects_padding = True

            var fresh = _read_encoded(
                self.r,
                Span(self.buf)[self.nbuf : want],
                least,
                expects_padding,
                self.arriving,
            )
            self.nbuf += fresh
            if self.nbuf < least:
                self._hold(self.arriving.value().error())
                self._check()
            if fresh > 0 and self.end:
                # Characters that arrived after the padding. The ones already
                # held are still owed to the caller, so it is the new arrivals
                # this counts, which is why `fresh` is a number and not a flag.
                self._hold(_corrupt(0, 0))
                self._check()

            # Whole groups only, unless there is no padding to wait for.
            var characters = self.nbuf
            if self.enc._pad != NO_PADDING:
                characters = self.nbuf // 8 * 8

            var served = 0
            if self.enc.decoded_len(self.nbuf) > len(into):
                self.out_start = 0
                var got, ended = _decoded(
                    self.enc,
                    Span(self.out),
                    Span(self.buf)[0:characters],
                    self.pending,
                )
                self.out_end = got
                self.end = ended
                served = self._serve(into)
            else:
                var got, ended = _decoded(
                    self.enc, into, Span(self.buf)[0:characters], self.pending
                )
                served = got
                self.end = ended

            self.nbuf -= characters
            for i in range(self.nbuf):
                self.buf[i] = self.buf[characters + i]

            if served > 0:
                return served
            self._check()
            if self.arriving:
                # Nothing decoded, nothing wrong with the decode, and the
                # reader has already had its last word. That word is the
                # answer.
                self._hold(self.arriving.value().error())
                self._check()
            # A group that spelled no whole byte. Go returns zero here and is
            # read again; this reads again itself, because a read of zero with
            # nothing wrong is not something a reader in this library does.


def new_decoder[
    R: IoReader & Deinitable & Movable
](enc: Encoding, var r: R) -> Decoder[R]:
    """A decoder reading `enc` out of `r`. Go's `NewDecoder`.

    Newlines in the input are skipped wherever they appear, which is the only
    whitespace this or Go's decoder ignores. A space is not a newline and is
    refused like any other byte that is not a symbol.
    """
    return Decoder[R](enc, r^)
