"""Hex over a stream, in both directions. Go's `NewEncoder` and `NewDecoder`.

The encoder holds nothing back, because one byte is two characters and there is
no group to complete, so it has no `close` and Go's returns a plain `io.Writer`
rather than a `WriteCloser`. That makes it the only stream encoder in this
directory that a caller cannot get wrong by forgetting to finish it.

The decoder does hold something back, because two characters are one byte and a
read can end between them. A pair split across two reads is joined; a pair split
by the end of the input is `ErrUnexpectedEOF` rather than the `ErrLength` the
whole string form raises, since a stream that stopped early may simply not have
finished arriving. Go draws the same line and says so in the same place.
"""

from core.errors import Report, capture, matches, partial
from core.errors.codes import EOF, ErrNoProgress, ErrUnexpectedEOF
from core.errors.value import ErrorValue
from core.io import Byte, Reader as IoReader, Writer as IoWriter

from .hex import _NOT_HEX, _unhex, decode, encode
from .invalid import _invalid

comptime _BUFFER = 1024
"""How many characters an encoder writes at a time and a decoder reads.

Go's two buffers are both this size. It is even, which is all a hex buffer has
to be for no pair to be split across a chunk boundary for the sake of the
buffer.
"""


struct Encoder[W: IoWriter & Deinitable & Movable](IoWriter, Movable):
    """Hex over a writer. Go's `NewEncoder`.

    ```mojo
    from core.encoding.hex import new_encoder
    from core.io import AnyWriter


    def spell(var dst: AnyWriter, data: Span[UInt8, MutableAnyOrigin]) raises:
        var enc = new_encoder(dst^)
        _ = enc.write(data)
    ```

    Nothing is held back between calls, so there is nothing to close. Not
    `Copyable` all the same, for the reason `bufio.Writer` is not: two of these
    over one sink is two writers over one sink, which is the caller's problem
    to have chosen rather than one to be handed quietly.
    """

    var w: Self.W
    """Where the characters go. Owned, so the call through is direct."""

    var out: List[Byte]
    """Where a chunk of input is encoded before it is written."""

    var pending: Optional[ErrorValue]
    """The failure this encoder is stuck on, if it has one."""

    def __init__(out self, var w: Self.W):
        """Encode into `w`. `new_encoder` is Go's name for this."""
        self.w = w^
        self.out = List[Byte](length=_BUFFER, fill=0)
        self.pending = Optional[ErrorValue]()

    def _check(self) raises:
        """Raise the sticky failure, if there is one, without clearing it."""
        if self.pending:
            raise self.pending.value().error()

    def _send(mut self, count: Int, accepted: Int) raises:
        """Write the first `count` characters of `out`, or get stuck trying.

        `accepted` is how much of the caller's input has been taken so far, and
        it is what goes on `errors.partial`, because that is the number Go's
        `Write` returns alongside the error.
        """
        try:
            _ = self.w.write(Span(self.out)[0:count])
        except e:
            self.pending = Optional[ErrorValue](capture(e))
            raise (
                Report("hex.write: writing")
                .wrapping(e)
                .with_count(accepted)
                .error()
            )

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        """Encode `data` and write it. Go's `Write`.

        Returns `len(data)`, which is bytes of input rather than characters of
        output, or raises with the number of input bytes that were accepted on
        `errors.partial`. Accepted means written, since nothing is buffered.
        """
        self._check()
        var taken = 0
        while taken < len(data):
            var chunk = _BUFFER // 2
            if chunk > len(data) - taken:
                chunk = len(data) - taken
            var wrote = encode(Span(self.out), data[taken : taken + chunk])
            self._send(wrote, taken)
            taken += chunk
        return taken


def new_encoder[W: IoWriter & Deinitable & Movable](var w: W) -> Encoder[W]:
    """An encoder writing lowercase hex into `w`. Go's `NewEncoder`.

    Nothing to close. Every byte handed to `write` is two characters written
    before it returns.
    """
    return Encoder[W](w^)


struct Decoder[R: IoReader & Deinitable & Movable](IoReader, Movable):
    """Hex over a reader. Go's `NewDecoder`.

    ```mojo
    from core.encoding.hex import new_decoder
    from core.io import AnyReader, read_all


    def unspell(var src: AnyReader) raises -> List[UInt8]:
        var dec = new_decoder(src^)
        return read_all(dec)
    ```

    Either case of letter is accepted and nothing else is, not even a newline,
    which is what tells this apart from the base64 and base32 decoders. Hex has
    no wrapping convention of its own, so a line break in the input is a
    character that is not a hex digit.
    """

    var r: Self.R
    """Where the characters come from. Owned, so the call through is direct."""

    var buf: List[Byte]
    """Characters that have arrived. `start` and `end` say which are real."""

    var start: Int
    """Where the undecoded characters begin. Go reslices `in` instead."""

    var end: Int
    """Where they stop."""

    var pending: Optional[ErrorValue]
    """The failure this decoder is stuck on. Go's `d.err`."""

    var arriving: Optional[ErrorValue]
    """What the reader underneath last said. Go's `d.readErr`."""

    def __init__(out self, var r: Self.R):
        """Decode from `r`. `new_decoder` is Go's name for this."""
        self.r = r^
        self.buf = List[Byte](length=_BUFFER, fill=0)
        self.start = 0
        self.end = 0
        self.pending = Optional[ErrorValue]()
        self.arriving = Optional[ErrorValue]()

    def _check(self) raises:
        """Raise the sticky failure, if there is one, without clearing it."""
        if self.pending:
            raise self.pending.value().error()

    def _hold(mut self, e: Error):
        """Make this decoder stuck, from here to the end of its life."""
        self.pending = Optional[ErrorValue](capture(e))

    def _fill(mut self) raises:
        """Read more characters, with the odd one from last time kept.

        The leftover is at most one character, so moving it to the front is a
        single assignment rather than a copy, and it leaves the whole buffer
        for the read. Go does the same with a `copy` of zero or one bytes.
        """
        if self.end > self.start:
            self.buf[0] = self.buf[self.start]
            self.end -= self.start
        else:
            self.end = 0
        self.start = 0

        var got = 0
        try:
            got = self.r.read(Span(self.buf)[self.end :])
        except e:
            self.arriving = Optional[ErrorValue](capture(e))
        self.end += got

        if got == 0 and not self.arriving:
            self.arriving = Optional[ErrorValue](
                capture(
                    Report(
                        "hex: the reader returned nothing and did not say why"
                    )
                    .with_code(ErrNoProgress)
                    .error()
                )
            )

        # The input ran out between the two characters of a pair. Go reports
        # the invalid character if the odd one out is not a hex digit, since
        # that is the problem the caller can act on, and `ErrUnexpectedEOF`
        # otherwise. `ErrLength`, which the whole string form raises, is not
        # used here: a stream that stopped early is a different fact from a
        # string that was written down wrong.
        if self.arriving and (self.end - self.start) % 2 != 0:
            if matches(self.arriving.value().error(), EOF):
                var last = self.buf[self.end - 1]
                if _unhex(last) == _NOT_HEX:
                    self.arriving = Optional[ErrorValue](
                        capture(_invalid(last, 0))
                    )
                else:
                    self.arriving = Optional[ErrorValue](
                        capture(
                            Report(
                                "hex: the input ended in the middle of a pair"
                            )
                            .with_code(ErrUnexpectedEOF)
                            .error()
                        )
                    )

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """Decode into `into` and return how many bytes arrived. Go's `Read`.

        Bytes never come back with a failure. A pair that will not decode
        raises on the call after the one that handed over what came before it,
        which is what `io.Reader` in this library promises. Go returns the two
        together here and the callers of it, `io.Copy` among them, then have to
        remember to keep the bytes.
        """
        if len(into) == 0:
            return 0
        self._check()

        while True:
            if self.end - self.start < 2 and not self.arriving:
                self._fill()

            var pairs = (self.end - self.start) // 2
            if pairs > len(into):
                pairs = len(into)

            var served = 0
            if pairs > 0:
                try:
                    served = decode(
                        into[0:pairs],
                        Span(self.buf)[self.start : self.start + pairs * 2],
                    )
                    self.start += served * 2
                except e:
                    served = partial(e)
                    # The rest of the buffer is not worth keeping: whatever
                    # comes after a character that is not hex is not something
                    # this decoder will ever agree to read.
                    self.start = 0
                    self.end = 0
                    self._hold(e)

            if served > 0:
                return served
            self._check()
            if self.arriving:
                self._hold(self.arriving.value().error())
                self._check()


def new_decoder[R: IoReader & Deinitable & Movable](var r: R) -> Decoder[R]:
    """A decoder reading hex out of `r`. Go's `NewDecoder`.

    The input has to be an even number of hex digits and nothing else. An odd
    number raises `ErrUnexpectedEOF` at the end, rather than the `ErrLength`
    that `decode` raises, which is Go's split and is documented on both.
    """
    return Decoder[R](r^)
