"""Ascii85 over a stream, in both directions. Go's `NewEncoder` and
`NewDecoder`.

Ascii85 works in groups of four bytes and a stream does not arrive in groups of
four, so both types here exist to hold the remainder between calls. The encoder
keeps up to three bytes back until a fourth arrives; the decoder keeps whatever
characters have not made a whole group.

That is why **an encoder has to be closed**. The last one to three bytes of the
input are still inside it when the last `write` returns, and `close` is what
writes the short group that spells them. An encoder that is dropped without
being closed writes a truncated document, and no destructor here can save it,
because a destructor cannot raise and a write failure that goes nowhere is
worse than one that arrives late.
"""

from core.errors import Report, capture
from core.errors.codes import ErrNoProgress
from core.errors.value import ErrorValue
from core.io import Byte, Closer, Reader as IoReader, Writer as IoWriter

from .ascii85 import _SPACE, decode, encode

comptime _CHUNK = 1024
"""How much an encoder writes at a time, and how much a decoder reads.

Go's three buffers are all this size. It is not a multiple of five, so a group
can straddle the end of the output buffer; the encoder works in whole groups of
input instead, which is the same rule from the other side.
"""


struct Encoder[W: IoWriter & Deinitable & Movable](Closer, IoWriter, Movable):
    """Ascii85 over a writer. Go's `NewEncoder`.

    ```mojo
    from core.encoding.ascii85 import new_encoder
    from core.io import AnyWriter


    def wrap(var dst: AnyWriter, data: Span[UInt8, MutableAnyOrigin]) raises:
        var enc = new_encoder(dst^)
        _ = enc.write(data)
        enc.close()
    ```

    Not `Copyable`, for the reason `bufio.Writer` is not: two copies over one
    sink would each hold a fragment of a group the other did not, and closing
    them both would write two ends to one document.
    """

    var w: Self.W
    """Where the characters go. Owned, so the call through is direct."""

    var buf: List[Byte]
    """Up to four bytes of input waiting for a group. `nbuf` says how many."""

    var nbuf: Int
    """How many of `buf` are real. Never more than three between calls."""

    var out: List[Byte]
    """Where a run of groups is encoded before it is written."""

    var pending: Optional[ErrorValue]
    """The failure this encoder is stuck on, if it has one."""

    def __init__(out self, var w: Self.W):
        """Encode into `w`. `new_encoder` is Go's name for this."""
        self.w = w^
        self.buf = List[Byte](length=4, fill=0)
        self.nbuf = 0
        self.out = List[Byte](length=_CHUNK, fill=0)
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
                Report("ascii85.write: writing")
                .wrapping(e)
                .with_count(accepted)
                .error()
            )

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        """Encode `data` and write it. Go's `Write`.

        Returns `len(data)`, which is bytes of input rather than characters of
        output, or raises with the number of input bytes that were accepted on
        `errors.partial`. Up to three of the accepted bytes are still inside
        the encoder waiting for a group; `close` is what gets them out.
        """
        self._check()

        var taken = 0

        # The fringe at the front: fill the held group, then send it.
        if self.nbuf > 0:
            while taken < len(data) and self.nbuf < 4:
                self.buf[self.nbuf] = data[taken]
                self.nbuf += 1
                taken += 1
            if self.nbuf < 4:
                return taken
            var wrote = encode(Span(self.out), Span(self.buf)[0:4])
            self._send(wrote, taken)
            self.nbuf = 0

        # The whole groups in the middle, a chunk of output at a time.
        while len(data) - taken >= 4:
            var room = len(self.out) // 5 * 4
            if room > len(data) - taken:
                room = len(data) - taken
                room -= room % 4
            var wrote = encode(Span(self.out), data[taken : taken + room])
            self._send(wrote, taken)
            taken += room

        # The fringe at the back, held for the next call or for `close`.
        var left = len(data) - taken
        for i in range(left):
            self.buf[i] = data[taken + i]
        self.nbuf = left
        return len(data)

    def close(mut self) raises:
        """Encode whatever is held back and write it. Go's `Close`.

        This is the call that writes the last short group, so a document is not
        finished until it happens. Writing after it is not defined here any
        more than it is in Go; what is defined is that closing twice writes
        nothing the second time, because the held bytes are gone by then.
        """
        self._check()
        if self.nbuf == 0:
            return
        var held = self.nbuf
        self.nbuf = 0
        var wrote = encode(Span(self.out), Span(self.buf)[0:held])
        self._send(wrote, 0)


def new_encoder[W: IoWriter & Deinitable & Movable](var w: W) -> Encoder[W]:
    """An encoder writing ascii85 into `w`. Go's `NewEncoder`.

    The caller must `close` it, or the last group is never written. Go says the
    same in one line of documentation and it is the mistake everybody makes
    once.

    Neither the `<~` at the front nor the `~>` at the end is written. Those
    belong to PostScript and PDF rather than to the encoding, and a caller that
    wants them writes them either side of this.
    """
    return Encoder[W](w^)


struct Decoder[R: IoReader & Deinitable & Movable](IoReader, Movable):
    """Ascii85 over a reader. Go's `NewDecoder`.

    ```mojo
    from core.encoding.ascii85 import new_decoder
    from core.io import AnyReader, read_all


    def unwrap(var src: AnyReader) raises -> List[UInt8]:
        var dec = new_decoder(src^)
        return read_all(dec)
    ```

    Space and control characters are skipped wherever they appear, so a
    document wrapped at any width reads back. The `<~` and `~>` fence is not
    understood and its characters are not in the alphabet, so a caller that has
    one strips it before this sees it.
    """

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

    var pending: Optional[ErrorValue]
    """The failure this decoder is stuck on. Go's `d.err`."""

    var arriving: Optional[ErrorValue]
    """What the reader underneath last said. Go's `d.readErr`."""

    def __init__(out self, var r: Self.R):
        """Decode from `r`. `new_decoder` is Go's name for this."""
        self.r = r^
        self.buf = List[Byte](length=_CHUNK, fill=0)
        self.nbuf = 0
        self.out = List[Byte](length=_CHUNK, fill=0)
        self.out_start = 0
        self.out_end = 0
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

    def _squeeze(mut self):
        """Drop the space and control characters. Go does this inline.

        Only reached when a whole buffer of input decoded to nothing, which
        means it is nearly all whitespace. Without this the buffer would stay
        full of characters that are not data and the decoder would never make
        room to read the ones that are.
        """
        var kept = 0
        for i in range(self.nbuf):
            if self.buf[i] > _SPACE:
                self.buf[kept] = self.buf[i]
                kept += 1
        self.nbuf = kept

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """Decode into `into` and return how many bytes arrived. Go's `Read`.

        Bytes never come back with a failure. A group that will not decode
        raises on the call after the one that handed over what came before it,
        which is what `io.Reader` in this library promises and what Go's
        version manages here anyway, since its `Decode` reports nothing decoded
        when it refuses.

        The last group is only completed once the reader has ended, which is
        what `flush` means to `decode` and why the decoder holds a short group
        rather than guessing at it.
        """
        if len(into) == 0:
            return 0
        self._check()

        while True:
            if self.out_start < self.out_end:
                return self._serve(into)

            if self.nbuf > 0:
                var ndst = 0
                var nsrc = 0
                try:
                    ndst, nsrc = decode(
                        Span(self.out),
                        Span(self.buf)[0 : self.nbuf],
                        Bool(self.arriving),
                    )
                except e:
                    self._hold(e)
                    self._check()

                if ndst > 0:
                    self.out_start = 0
                    self.out_end = ndst
                    self.nbuf -= nsrc
                    for i in range(self.nbuf):
                        self.buf[i] = self.buf[nsrc + i]
                    continue
                self._squeeze()

            # Nothing held and nothing decoded. Whatever the reader last said
            # is the answer now.
            if self.arriving:
                self._hold(self.arriving.value().error())
                self._check()

            var got = 0
            try:
                got = self.r.read(Span(self.buf)[self.nbuf :])
            except e:
                self.arriving = Optional[ErrorValue](capture(e))
            self.nbuf += got

            if got == 0 and not self.arriving:
                self.arriving = Optional[ErrorValue](
                    capture(
                        Report(
                            "ascii85: the reader returned nothing and did not"
                            " say why"
                        )
                        .with_code(ErrNoProgress)
                        .error()
                    )
                )


def new_decoder[R: IoReader & Deinitable & Movable](var r: R) -> Decoder[R]:
    """A decoder reading ascii85 out of `r`. Go's `NewDecoder`.

    Space and control characters in the input are skipped, which is more than
    the base64 and base32 decoders skip: those two take out carriage returns
    and line feeds and refuse everything else. Ascii85 can afford it because
    its alphabet starts at `!`, so nothing below a space means anything.
    """
    return Decoder[R](r^)
