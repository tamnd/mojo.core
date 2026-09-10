"""Reading a DEFLATE stream. Go's `inflate.go`.

A DEFLATE stream is a sequence of blocks and a bit stream that does not care
where the bytes end. A block is either stored, in which case it carries its own
length and its bytes go through as they are, or it is Huffman coded, in which
case it is a run of symbols that are either a literal byte or a backward copy
out of the window in `dict.mojo`. A coded block uses either the fixed code that
RFC 1951 section 3.2.6 writes out, or a code the block describes for itself
first, in a third Huffman code that describes the other two.

Every failure in here is `CorruptInputError`, carrying how far the reader had
got. That is the only honest number a bit stream can report, and it is what Go
reports too.

## The step is a number

Go stores what to do next as a `func(*decompressor)` on the struct and calls
through it. A function pointer in a struct is not a shape this library uses,
design.md section 1, so the step is a small integer and `_advance` is a
dispatch on it. That is the arrangement `core.encoding.json` already uses for
its scanner and for the same reason. Go's `stepState` comes across unchanged as
`step_state`, because it says which half of a Huffman block was interrupted and
a number was already the right shape for that.

## The reader has to have read_byte

Go's `NewReader` takes any `io.Reader` and wraps one that is not also an
`io.ByteReader` in a `bufio.Reader`, and its own documentation warns that the
wrapper "may read more data than necessary". Here the bound is on the
signature: `new_reader` takes a reader that already has `read_byte`, which is
exactly Go's exported `Reader` interface, and a caller holding a plain reader
wraps it in `bufio.new_reader` themselves. The reason is that the over reading
is not a detail. `gzip` and `zlib` both have a checksum to read after the last
block, and they can only find it if the decompressor left it alone, so both
have to hand a buffered reader in either way. Making that visible in the type
is the difference between a caller knowing where their bytes went and finding
out later. `docs/deviations.md` has the row.
"""

from core.errors import ErrorValue, Report, capture, matches, partial
from core.errors.codes import EOF, ErrUnexpectedEOF
from core.io import (
    Byte,
    ByteReader as IoByteReader,
    Closer as IoCloser,
    Reader as IoReader,
    read_full,
)
from core.math.bits import reverse8

from .corrupt import _corrupt, _internal
from .dict import _DictDecoder
from .huffman import (
    _CHUNK_BITS,
    _COUNT_MASK,
    _HuffmanDecoder,
    _MAX_NUM_DIST,
    _MAX_NUM_LIT,
    _NUM_CHUNKS,
    _NUM_CODES,
    _VALUE_SHIFT,
    _fixed_decoder,
)

comptime _MAX_MATCH_OFFSET = 1 << 15
"""How far back a copy may reach, which is the window size. RFC 1951 section
3.2.5 caps a distance at 32768 and this is that number. Go keeps it in
`deflate.go`, where the writer needs it too."""

comptime _END_BLOCK_MARKER = 256
"""The literal code that ends a Huffman block. Every block has one."""

comptime _STEP_NEXT_BLOCK = 0
"""Read a block header. Go's `nextBlock`."""

comptime _STEP_HUFFMAN_BLOCK = 1
"""Decode symbols. Go's `huffmanBlock`."""

comptime _STEP_COPY_DATA = 2
"""Move the bytes of a stored block. Go's `copyData`."""

comptime _STATE_INIT = 0
"""A Huffman block resumes at the next symbol."""

comptime _STATE_DICT = 1
"""A Huffman block resumes in the middle of a backward copy."""

comptime _CODE_ORDER: InlineArray[Int, 19] = [
    16,
    17,
    18,
    0,
    8,
    7,
    9,
    6,
    10,
    5,
    11,
    4,
    12,
    3,
    13,
    2,
    14,
    1,
    15,
]
"""The order the code length code's own lengths arrive in. RFC 1951 section
3.2.7 puts the rarely used lengths last so a short table can stop early."""


trait Reader(IoByteReader, IoReader):
    """A source a decompressor can read from. Go's `flate.Reader`.

    Both halves are needed and for different reasons. The bit stream is pulled
    one byte at a time, which is `read_byte`, and a stored block is moved in
    one go, which is `read`. Go's interface is these two and nothing else, and
    so is this.
    """

    pass


def _no_eof(e: Error) raises -> Error:
    """`EOF` in the middle of a block is `ErrUnexpectedEOF`. Go's `noEOF`.

    A stream that stops between blocks has still stopped early, because a
    DEFLATE stream ends with a block that says it is the last one and nothing
    else ends it. So every end of input inside the decompressor is unexpected.
    """
    if matches(e, EOF):
        return (
            Report("flate: the stream ended part way through")
            .with_code(ErrUnexpectedEOF)
            .error()
        )
    return e


struct Decompressor[R: Reader & Deinitable & Movable](
    IoCloser, IoReader, Movable
):
    """A DEFLATE stream, read as the bytes it stands for.

    Go's `decompressor`, which it keeps unexported and hands back as an
    `io.ReadCloser`. It is named here because a return type has to be named.

    ```mojo
    from core.compress.flate import Reader, new_reader
    from core.io import Byte, read_all


    def inflate[R: Reader & Deinitable & Movable](var src: R) raises -> List[Byte]:
        var r = new_reader(src^)
        return read_all(r)
    ```

    The stream ends with `EOF` after the block that says it is the last one,
    and anything after that block is left in the reader untouched, which is
    what lets `gzip` find its checksum.
    """

    var r: Self.R
    """Where the compressed bytes come from. Owned, so the call through is
    direct."""

    var roffset: Int64
    """How many bytes have been pulled out of `r`. This is the offset a
    `CorruptInputError` reports."""

    var b: UInt32
    """The bit buffer, filled from the bottom. Go's `f.b`."""

    var nb: Int
    """How many bits of `b` are real. Go's `f.nb`."""

    var h1: _HuffmanDecoder
    """The literal and length code of a dynamic block, and the code length
    code while one is being read."""

    var h2: _HuffmanDecoder
    """The distance code of a dynamic block."""

    var fixed: _HuffmanDecoder
    """The literal and length code every fixed block uses. Go keeps one per
    process behind a `sync.Once`; this is one per decompressor, because shared
    mutable state costs more to reason about than a few hundred stores."""

    var use_fixed: Bool
    """Whether the block being decoded uses `fixed` rather than `h1`. Go
    points `f.hl` at one or the other."""

    var no_dist: Bool
    """Whether the block has no distance code of its own, which means the five
    bit fixed distance encoding. Go leaves `f.hd` nil."""

    var bits: List[Int]
    """Code lengths for the literal and distance codes, read as one run."""

    var codebits: List[Int]
    """Code lengths for the code length code."""

    var dict: _DictDecoder
    """The window of already emitted bytes."""

    var buf: List[Byte]
    """Four bytes, for the length and its complement at the head of a stored
    block."""

    var step: Int
    """What `_advance` does next. One of the `_STEP_` constants."""

    var step_state: Int
    """Where in a Huffman block to resume. One of the `_STATE_`
    constants."""

    var final: Bool
    """Whether the block being decoded said it was the last one."""

    var pending: Optional[ErrorValue]
    """The failure this decompressor is stuck on, `EOF` included. Go's
    `f.err`."""

    var to_read_start: Int
    """Start of the range of `dict.hist` waiting to go to the caller."""

    var to_read_end: Int
    """End of it. Go's `f.toRead` is a slice; this is the same thing without a
    borrow that has to outlive the call that made it."""

    var copy_len: Int
    """Bytes still to move, in a stored block or a backward copy."""

    var copy_dist: Int
    """How far back the backward copy in progress reaches."""

    def __init__[o: Origin](out self, var r: Self.R, dict: Span[Byte, o]):
        """Read `r` as DEFLATE, with `dict` already emitted.

        `new_reader` and `new_reader_dict` are Go's names for this.
        """
        self.r = r^
        self.roffset = 0
        self.b = 0
        self.nb = 0
        self.h1 = _HuffmanDecoder()
        self.h2 = _HuffmanDecoder()
        self.fixed = _fixed_decoder()
        self.use_fixed = False
        self.no_dist = False
        self.bits = List[Int](length=_MAX_NUM_LIT + _MAX_NUM_DIST, fill=0)
        self.codebits = List[Int](length=_NUM_CODES, fill=0)
        self.dict = _DictDecoder()
        self.buf = List[Byte](length=4, fill=0)
        self.step = _STEP_NEXT_BLOCK
        self.step_state = _STATE_INIT
        self.final = False
        self.pending = Optional[ErrorValue]()
        self.to_read_start = 0
        self.to_read_end = 0
        self.copy_len = 0
        self.copy_dist = 0
        self.dict.reset(_MAX_MATCH_OFFSET, dict)

    def reset[o: Origin](mut self, var r: Self.R, dict: Span[Byte, o]):
        """Start over on a new stream. Go's `Reset` on the same value.

        Everything is dropped except the buffers, which are the point: reading
        many small streams through one decompressor allocates the window and
        the two code length arrays once rather than once each.
        """
        self.r = r^
        self.roffset = 0
        self.b = 0
        self.nb = 0
        self.h1 = _HuffmanDecoder()
        self.h2 = _HuffmanDecoder()
        self.use_fixed = False
        self.no_dist = False
        self.step = _STEP_NEXT_BLOCK
        self.step_state = _STATE_INIT
        self.final = False
        self.pending = Optional[ErrorValue]()
        self.to_read_start = 0
        self.to_read_end = 0
        self.copy_len = 0
        self.copy_dist = 0
        self.dict.reset(_MAX_MATCH_OFFSET, dict)

    def _hold(mut self, e: Error):
        """Make this decompressor stuck, from here to the end of its life."""
        if not self.pending:
            self.pending = Optional[ErrorValue](capture(e))

    def _check(self) raises:
        """Raise the sticky failure, if there is one, without clearing it."""
        if self.pending:
            raise self.pending.value().error()

    def _more_bits(mut self) raises:
        """Pull one byte into the bit buffer. Go's `moreBits`."""
        var c: Byte
        try:
            c = self.r.read_byte()
        except e:
            var bad = _no_eof(e)
            raise bad
        self.roffset += 1
        self.b |= UInt32(c) << UInt32(self.nb)
        self.nb += 8

    def _need(mut self, count: Int) raises:
        """Make sure the bit buffer holds at least `count` bits."""
        while self.nb < count:
            self._more_bits()

    def _take(mut self, count: Int) -> UInt32:
        """Consume `count` bits off the bottom of the buffer.

        Invariant: `count <= nb`, which `_need` is how you get.
        """
        var v = self.b & UInt32((1 << count) - 1)
        self.b >>= UInt32(count & 31)
        self.nb -= count
        return v

    def _huff_sym(mut self, fixed: Bool, literal: Bool) raises -> Int:
        """Read one symbol. Go's `huffSym`.

        `fixed` picks the fixed literal code and `literal` picks between `h1`
        and `h2`, which is Go's `f.hl` and `f.hd` written as two bits rather
        than as two pointers. There is no way to hold a reference to one of
        three fields in a local here, so the three lookups below are spelled
        out; the alternative was copying a table of five hundred entries per
        symbol.

        An empty code and a degenerate one both leave a zero entry where the
        lookup lands, so the `n == 0` test below is what refuses them, which
        is Go's arrangement as well.
        """
        var n: Int
        if fixed:
            n = self.fixed.min
        elif literal:
            n = self.h1.min
        else:
            n = self.h2.min
        while True:
            while self.nb < n:
                self._more_bits()
            var index = Int(self.b) & (_NUM_CHUNKS - 1)
            var chunk: UInt32
            if fixed:
                chunk = self.fixed.chunks[index]
            elif literal:
                chunk = self.h1.chunks[index]
            else:
                chunk = self.h2.chunks[index]
            n = Int(chunk & _COUNT_MASK)
            if n > _CHUNK_BITS:
                var row = Int(chunk >> _VALUE_SHIFT)
                if fixed:
                    var off = Int(
                        (self.b >> UInt32(_CHUNK_BITS)) & self.fixed.link_mask
                    )
                    chunk = self.fixed.links[row][off]
                elif literal:
                    var off = Int(
                        (self.b >> UInt32(_CHUNK_BITS)) & self.h1.link_mask
                    )
                    chunk = self.h1.links[row][off]
                else:
                    var off = Int(
                        (self.b >> UInt32(_CHUNK_BITS)) & self.h2.link_mask
                    )
                    chunk = self.h2.links[row][off]
                n = Int(chunk & _COUNT_MASK)
            if n <= self.nb:
                if n == 0:
                    raise _corrupt(self.roffset)
                self.b >>= UInt32(n & 31)
                self.nb -= n
                return Int(chunk >> _VALUE_SHIFT)

    def _next_block(mut self) raises:
        """Read a block header and start on the block. Go's `nextBlock`."""
        self._need(3)
        self.final = (self.b & 1) == 1
        self.b >>= 1
        var kind = Int(self.b & 3)
        self.b >>= 2
        self.nb -= 3
        if kind == 0:
            self._data_block()
        elif kind == 1:
            self.use_fixed = True
            self.no_dist = True
            self._huffman_block()
        elif kind == 2:
            self._read_huffman()
            self.use_fixed = False
            self.no_dist = False
            self._huffman_block()
        else:
            # Three is reserved and RFC 1951 never assigned it.
            raise _corrupt(self.roffset)

    def _read_huffman(mut self) raises:
        """Read the two code tables a dynamic block describes. Go's
        `readHuffman`.

        Three counts first, then the lengths of the code length code in the
        order `_CODE_ORDER` gives, then the lengths of the literal code and the
        distance code as one run through that third code.
        """
        self._need(14)
        var nlit = Int(self.b & 0x1F) + 257
        if nlit > _MAX_NUM_LIT:
            raise _corrupt(self.roffset)
        self.b >>= 5
        var ndist = Int(self.b & 0x1F) + 1
        if ndist > _MAX_NUM_DIST:
            raise _corrupt(self.roffset)
        self.b >>= 5
        var nclen = Int(self.b & 0xF) + 4
        # _NUM_CODES is 19 and nclen is at most 19, so it is always valid.
        self.b >>= 4
        self.nb -= 14

        var order = materialize[_CODE_ORDER]()
        for i in range(nclen):
            self._need(3)
            self.codebits[order[i]] = Int(self._take(3))
        for i in range(nclen, _NUM_CODES):
            self.codebits[order[i]] = 0
        if not self.h1.build(Span(self.codebits)):
            raise _corrupt(self.roffset)

        var total = nlit + ndist
        var i = 0
        while i < total:
            var x = self._huff_sym(False, True)
            if x < 16:
                self.bits[i] = x
                i += 1
                continue
            var rep: Int
            var extra: Int
            var value: Int
            if x == 16:
                rep = 3
                extra = 2
                if i == 0:
                    raise _corrupt(self.roffset)
                value = self.bits[i - 1]
            elif x == 17:
                rep = 3
                extra = 3
                value = 0
            elif x == 18:
                rep = 11
                extra = 7
                value = 0
            else:
                # The code length code has nineteen symbols and the three
                # above are the only ones over fifteen, so this is a bug here
                # rather than a bad stream. Go says the same in the same
                # place.
                raise _internal("unexpected length code")
            self._need(extra)
            rep += Int(self._take(extra))
            if i + rep > total:
                raise _corrupt(self.roffset)
            for _ in range(rep):
                self.bits[i] = value
                i += 1

        if not self.h1.build(Span(self.bits)[0:nlit]):
            raise _corrupt(self.roffset)
        if not self.h2.build(Span(self.bits)[nlit : nlit + ndist]):
            raise _corrupt(self.roffset)

        # Every block ends with the end of block marker, so no symbol can be
        # shorter than that marker's code. Raising the minimum to it means a
        # lookup never pulls in bits the stream does not have, which is what
        # keeps the decompressor from reading past the end of the last block.
        if self.h1.min < self.bits[_END_BLOCK_MARKER]:
            self.h1.min = self.bits[_END_BLOCK_MARKER]

    def _huffman_block(mut self) raises:
        """Decode symbols until the block ends or the window fills. Go's
        `huffmanBlock`.

        Go writes this with two labels and a `goto` between them. The two
        labels are the two values of `step_state`, so the same shape is a loop
        with a flag here, and the returns that Go makes to hand the window
        over are the same returns.
        """
        var copying = self.step_state == _STATE_DICT
        while True:
            if not copying:
                var v = self._huff_sym(self.use_fixed, True)
                var length: Int
                var extra: Int
                if v < 256:
                    self.dict.write_byte(Byte(v))
                    if self.dict.avail_write() == 0:
                        self._flush()
                        self.step = _STEP_HUFFMAN_BLOCK
                        self.step_state = _STATE_INIT
                        return
                    continue
                elif v == 256:
                    self._finish_block()
                    return
                elif v < 265:
                    length = v - (257 - 3)
                    extra = 0
                elif v < 269:
                    length = v * 2 - (265 * 2 - 11)
                    extra = 1
                elif v < 273:
                    length = v * 4 - (269 * 4 - 19)
                    extra = 2
                elif v < 277:
                    length = v * 8 - (273 * 8 - 35)
                    extra = 3
                elif v < 281:
                    length = v * 16 - (277 * 16 - 67)
                    extra = 4
                elif v < 285:
                    length = v * 32 - (281 * 32 - 131)
                    extra = 5
                elif v < _MAX_NUM_LIT:
                    length = 258
                    extra = 0
                else:
                    raise _corrupt(self.roffset)
                if extra > 0:
                    self._need(extra)
                    length += Int(self._take(extra))

                var dist: Int
                if self.no_dist:
                    # Fixed blocks write a distance as five bits, most
                    # significant first, which is the one place DEFLATE does
                    # not write a number backwards.
                    self._need(5)
                    dist = Int(reverse8(UInt8((self.b & 0x1F) << 3)))
                    self.b >>= 5
                    self.nb -= 5
                else:
                    dist = self._huff_sym(False, False)

                if dist < 4:
                    dist += 1
                elif dist < _MAX_NUM_DIST:
                    var nb = (dist - 2) >> 1
                    var bonus = (dist & 1) << nb
                    self._need(nb)
                    bonus |= Int(self._take(nb))
                    dist = (1 << (nb + 1)) + 1 + bonus
                else:
                    # Codes 30 and 31 are the two RFC 1951 section 3.2.5 says
                    # never appear.
                    raise _corrupt(self.roffset)

                # The length is not checked, because an encoder is allowed to
                # be prescient: a copy may run past what has been written and
                # read the bytes it is itself producing.
                if dist > self.dict.hist_size():
                    raise _corrupt(self.roffset)

                self.copy_len = length
                self.copy_dist = dist
                copying = True

            var moved = self.dict.try_write_copy(self.copy_dist, self.copy_len)
            if moved == 0:
                moved = self.dict.write_copy(self.copy_dist, self.copy_len)
            self.copy_len -= moved
            if self.dict.avail_write() == 0 or self.copy_len > 0:
                self._flush()
                self.step = _STEP_HUFFMAN_BLOCK
                self.step_state = _STATE_DICT
                return
            copying = False

    def _data_block(mut self) raises:
        """Start a stored block. Go's `dataBlock`.

        The header is a length and its ones complement, and the bits left over
        from the block header are dropped, which is what makes a stored block
        start on a byte boundary.
        """
        self.nb = 0
        self.b = 0
        var got = 0
        try:
            got = read_full(self.r, Span(self.buf)[0:4])
        except e:
            self.roffset += Int64(partial(e))
            var bad = _no_eof(e)
            raise bad
        self.roffset += Int64(got)
        var n = Int(self.buf[0]) | (Int(self.buf[1]) << 8)
        var nn = Int(self.buf[2]) | (Int(self.buf[3]) << 8)
        if UInt16(nn) != UInt16(~n & 0xFFFF):
            raise _corrupt(self.roffset)
        if n == 0:
            self._flush()
            self._finish_block()
            return
        self.copy_len = n
        self._copy_data()

    def _copy_data(mut self) raises:
        """Move the bytes of a stored block into the window. Go's `copyData`."""
        var room = self.dict.avail_write()
        var want = self.copy_len
        if want > room:
            want = room
        var start = self.dict.wr_pos
        var got = 0
        try:
            got = read_full(self.r, Span(self.dict.hist)[start : start + want])
        except e:
            got = partial(e)
            self.roffset += Int64(got)
            self.copy_len -= got
            self.dict.write_mark(got)
            var bad = _no_eof(e)
            raise bad
        self.roffset += Int64(got)
        self.copy_len -= got
        self.dict.write_mark(got)

        if self.dict.avail_write() == 0 or self.copy_len > 0:
            self._flush()
            self.step = _STEP_COPY_DATA
            return
        self._finish_block()

    def _finish_block(mut self) raises:
        """End a block, and the stream with it if it was the last one."""
        if self.final:
            if self.dict.avail_read() > 0:
                self._flush()
            self._hold(Report("flate: end of stream").with_code(EOF).error())
        self.step = _STEP_NEXT_BLOCK

    def _flush(mut self):
        """Hand the window's unread part to the caller's next `read`."""
        var ready = self.dict.read_flush()
        self.to_read_start = ready[0]
        self.to_read_end = ready[1]

    def _advance(mut self):
        """One step of the machine, with any failure made sticky.

        Go assigns to `f.err` at each of the two dozen places that can fail;
        the same places raise here and this is the one catch, so a step body
        reads as a straight line and no site can forget to record what went
        wrong.
        """
        try:
            if self.step == _STEP_NEXT_BLOCK:
                self._next_block()
            elif self.step == _STEP_HUFFMAN_BLOCK:
                self._huffman_block()
            else:
                self._copy_data()
        except e:
            self._hold(e)

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """Decompress into `into` and return how many bytes arrived.

        `EOF` comes after the block that said it was the last one, and any
        bytes after it stay in the reader underneath. Bytes never come back
        with a failure: a stream that goes bad after producing output raises on
        the call after the one that handed the output over, which is what
        `core.io.Reader` promises.
        """
        if len(into) == 0:
            return 0
        while True:
            if self.to_read_start < self.to_read_end:
                var n = self.to_read_end - self.to_read_start
                if n > len(into):
                    n = len(into)
                for i in range(n):
                    into[i] = self.dict.hist[self.to_read_start + i]
                self.to_read_start += n
                return n
            self._check()
            self._advance()
            if self.pending and self.to_read_start == self.to_read_end:
                # Whatever the window still holds is good output that arrived
                # before the failure, so it goes out before the raise does.
                self._flush()

    def close(mut self) raises:
        """The end of the stream. Go's `Close`.

        An orderly end raises nothing. Anything else raises what the
        decompressor is stuck on, which is Go returning `f.err`. Nothing is
        released, because nothing was acquired: this exists so that a
        decompressor can stand in for Go's `io.ReadCloser`.
        """
        if not self.pending:
            return
        var e = self.pending.value().error()
        if matches(e, EOF):
            return
        raise e


def new_reader[R: Reader & Deinitable & Movable](var r: R) -> Decompressor[R]:
    """Read `r` as a DEFLATE stream. Go's `NewReader`.

    ```mojo
    from core.compress.flate import Reader, new_reader
    from core.io import Byte, read_all


    def inflate[R: Reader & Deinitable & Movable](var src: R) raises -> List[Byte]:
        var r = new_reader(src^)
        return read_all(r)
    ```

    The stream ends at the block that says it is the last one and everything
    after that block is left in `r`. Go's version takes any `io.Reader` and
    buffers one that cannot hand over a single byte; here that wrapping is the
    caller's, so that a caller who needs the bytes after the stream knows where
    they went. See the module docstring.
    """
    var none = List[Byte]()
    return Decompressor(r^, Span(none))


def new_reader_dict[
    R: Reader & Deinitable & Movable, o: Origin
](var r: R, dict: Span[Byte, o]) -> Decompressor[R]:
    """`new_reader` with a preset dictionary. Go's `NewReaderDict`.

    The stream is read as though `dict` had already been emitted, so its very
    first command may copy out of it. This is how a stream written by
    `new_writer_dict` is read back, and the two dictionaries have to be the
    same or the output is quietly wrong rather than refused, which is a
    property of DEFLATE and not of this.
    """
    return Decompressor(r^, dict)
