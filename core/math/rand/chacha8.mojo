"""The ChaCha8 generator. Go's `rand.ChaCha8`, and the `internal/chacha8rand`
state machine it is built on.

ChaCha8 is ChaCha with eight rounds instead of twenty, run as a generator
rather than as a cipher: a 32 byte seed is the key, the nonce is zero, and the
output is the keystream. It is strong enough that recovering the seed from the
output is not something anybody knows how to do, and it is fast enough that Go
made it the generator behind every unseeded random number in the runtime.

```mojo
from core.math.rand import new_chacha8

var seed = InlineArray[UInt8, 32](fill=0)
var c = new_chacha8(seed)
print(c.uint64() != 0)  # True
```

**This is still not a cryptographic random number generator.** The construction
is a cryptographic one and the state is recoverable from a memory dump, which
is the difference. Use the operating system's generator for a key.

Three details of the construction are worth knowing before reading the code.

**The blocks are interlaced.** One call to the block function computes four
ChaCha8 blocks at once, laid out so that a machine with four wide vector
registers computes them in parallel with no shuffling. Go says outright that
this fixes the output order forever, and it fixes it here too: the words come
out four blocks at a time in column order, not one block after another.

**It reseeds itself.** After twelve of the sixteen counter values, the last
four words of the buffer become the next seed and the counter goes back to
zero. Those four words are never handed out, which is why a refill at that
point yields twenty eight values rather than thirty two. The point is that a
memory dump gives up the recent past and not the whole history.

**The marshalled form is the seed and a position, not the buffer.** Forty eight
bytes: the tag `chacha8:`, a big endian count of values used since the last
reseed, and the four seed words little endian. Restoring recomputes the buffer.
When a `read` has left part of a value unconsumed, `readbuf:` and those bytes
go in front of that, which is the only variable length part of the encoding.
"""

from core.errors import Report
from core.errors.codes import ErrInvalidEncoding
from core.math.bits import rotate_left32

from .byteorder import (
    _append_str,
    _be_append_uint64,
    _be_uint64,
    _has_prefix,
    _le_append_uint64,
    _le_uint64,
)
from .source import Source

comptime _CTR_INC = UInt32(4)
"""How far the counter moves between block calls, which is four blocks."""

comptime _CTR_MAX = UInt32(16)
"""The counter value that triggers a reseed."""

comptime _CHUNK = UInt32(32)
"""How many 64 bit values one block call produces."""

comptime _RESEED = UInt32(4)
"""How many words of a buffer are held back to seed the next one."""

comptime _STATE_TAG = "chacha8:"
"""What a marshalled state starts with."""

comptime _READ_TAG = "readbuf:"
"""What a marshalled state starts with when a partial value is pending."""

comptime _STATE_SIZE = 48
"""How long the state part of a marshalled `ChaCha8` is."""

comptime _MAX_USED = UInt64((_CTR_MAX // _CTR_INC) * _CHUNK - _RESEED)
"""The largest position a marshalled state can claim, which is 124.

Sixteen counter values in steps of four is four block calls, thirty two values
each, less the four the last of them holds back to reseed with.
"""


def _block(
    seed: InlineArray[UInt64, 4],
    mut buf: InlineArray[UInt64, 32],
    counter: UInt32,
):
    """Four ChaCha8 blocks into `buf`. Go's `block_generic`.

    The working state is sixteen rows of four lanes, one lane per block, which
    is the interlaced layout the module docstring describes. Rows zero to three
    are the ChaCha constants, four to eleven are the seed, twelve is the
    counter and thirteen to fifteen are zero.

    Only rows four to eleven are added back to what they started as. The other
    eight rows started as constants and a counter, so there is no entropy in
    them to preserve and Go skips the addition. Skipping it is part of the
    output, not an optimisation that could be undone.

    Go swaps the halves of every word afterwards on a big endian machine, so
    that reading the pairs of 32 bit lanes as 64 bit values gives the same
    answer everywhere. Every platform this library supports is little endian,
    so that branch is not ported. Packing the pairs at the end here is the
    little endian read written out.
    """
    var lanes = InlineArray[UInt32, 64](fill=0)
    for col in range(4):
        lanes[0 * 4 + col] = 0x61707865
        lanes[1 * 4 + col] = 0x3320646E
        lanes[2 * 4 + col] = 0x79622D32
        lanes[3 * 4 + col] = 0x6B206574
        for word in range(4):
            lanes[(4 + 2 * word) * 4 + col] = UInt32(seed[word] & 0xFFFFFFFF)
            lanes[(5 + 2 * word) * 4 + col] = UInt32(seed[word] >> 32)
        lanes[12 * 4 + col] = counter + UInt32(col)
        lanes[13 * 4 + col] = 0
        lanes[14 * 4 + col] = 0
        lanes[15 * 4 + col] = 0

    var x = InlineArray[UInt32, 16](fill=0)

    @parameter
    def qr(a: Int, b: Int, c: Int, d: Int):
        """One quarter round, in place on the working state."""
        x[a] += x[b]
        x[d] = rotate_left32(x[d] ^ x[a], 16)
        x[c] += x[d]
        x[b] = rotate_left32(x[b] ^ x[c], 12)
        x[a] += x[b]
        x[d] = rotate_left32(x[d] ^ x[a], 8)
        x[c] += x[d]
        x[b] = rotate_left32(x[b] ^ x[c], 7)

    for col in range(4):
        for row in range(16):
            x[row] = lanes[row * 4 + col]

        # Four iterations of eight quarter rounds is eight rounds: four down
        # the columns of the ChaCha matrix and four along its diagonals.
        for _ in range(4):
            qr(0, 4, 8, 12)
            qr(1, 5, 9, 13)
            qr(2, 6, 10, 14)
            qr(3, 7, 11, 15)
            qr(0, 5, 10, 15)
            qr(1, 6, 11, 12)
            qr(2, 7, 8, 13)
            qr(3, 4, 9, 14)

        for row in range(16):
            if row >= 4 and row < 12:
                lanes[row * 4 + col] += x[row]
            else:
                lanes[row * 4 + col] = x[row]

    for word in range(32):
        buf[word] = UInt64(lanes[2 * word]) | (
            UInt64(lanes[2 * word + 1]) << 32
        )


struct _State(Copyable, Movable):
    """The generator itself. Go's `chacha8rand.State`.

    Separate from `ChaCha8` because Go keeps it separate: the runtime uses this
    and does not want the marshalling or the byte oriented read that the public
    type adds. Keeping the split makes the two files line up with Go's.
    """

    var buf: InlineArray[UInt64, 32]
    """The values not yet handed out, plus the four held back to reseed with."""

    var seed: InlineArray[UInt64, 4]
    """The key the current run of blocks is computed from."""

    var i: UInt32
    """How far into `buf` the next value is."""

    var n: UInt32
    """How much of `buf` may be handed out, which is 28 before a reseed."""

    var c: UInt32
    """The block counter, in steps of four up to sixteen."""

    def __init__(out self):
        """A state with nothing in it. Every use seeds it before reading."""
        self.buf = InlineArray[UInt64, 32](fill=0)
        self.seed = InlineArray[UInt64, 4](fill=0)
        self.i = 0
        self.n = 0
        self.c = 0

    def next(mut self) -> Tuple[UInt64, Bool]:
        """The next value, and whether there was one.

        False means the buffer is spent and the caller has to `refill` and ask
        again. That is Go's shape and it exists so the fast path is a bounds
        check and an increment with no branch into the block function.
        """
        var at = self.i
        if at >= self.n:
            return (UInt64(0), False)
        self.i = at + 1
        return (self.buf[Int(at & 31)], True)

    def init_bytes(mut self, seed: InlineArray[UInt8, 32]):
        """Seed from 32 bytes, read as four little endian words. Go's `Init`."""
        var words = InlineArray[UInt64, 4](fill=0)
        for word in range(4):
            var v = UInt64(0)
            for k in reversed(range(8)):
                v = (v << 8) | UInt64(seed[word * 8 + k])
            words[word] = v
        self.init64(words)

    def init64(mut self, seed: InlineArray[UInt64, 4]):
        """Seed from four words and compute the first block. Go's `Init64`."""
        self.seed = seed.copy()
        _block(seed, self.buf, 0)
        self.c = 0
        self.i = 0
        self.n = _CHUNK

    def refill(mut self):
        """Compute the next block, reseeding first if the counter has run out.

        Go does the reseed immediately before the block rather than immediately
        after the one that produced the words, so that a marshalled state is
        the seed and a position and nothing else. The cost is that a memory
        dump gives up the values since the last reseed, which Go weighs against
        an encoding four times the size and takes.
        """
        self.c += _CTR_INC
        if self.c == _CTR_MAX:
            var back = Int(_CHUNK - _RESEED)
            for k in range(Int(_RESEED)):
                self.seed[k] = self.buf[back + k]
            self.c = 0
        var seed = self.seed.copy()
        _block(seed, self.buf, self.c)
        self.i = 0
        self.n = _CHUNK
        if self.c == _CTR_MAX - _CTR_INC:
            self.n = _CHUNK - _RESEED


def _marshal_state(s: _State, mut dst: List[UInt8]):
    """Append the 48 byte encoding of `s`. Go's `chacha8rand.Marshal`."""
    _append_str(dst, _STATE_TAG)
    _be_append_uint64(dst, UInt64((s.c // _CTR_INC) * _CHUNK + s.i))
    for k in range(4):
        _le_append_uint64(dst, s.seed[k])


def _unmarshal_state[o: ImmOrigin](mut s: _State, data: Span[UInt8, o]) raises:
    """Restore `s` from its encoding. Go's `chacha8rand.Unmarshal`.

    The position is checked against `_MAX_USED` before anything is written,
    because a position past the end of a buffer would leave a state whose `i`
    is beyond its `n` and which therefore refills on the first read, quietly
    skipping to a different place in the stream.
    """
    if len(data) != _STATE_SIZE or not _has_prefix(data, _STATE_TAG):
        raise (
            Report("rand: invalid ChaCha8 encoding")
            .with_code(ErrInvalidEncoding)
            .error()
        )
    var used = _be_uint64(data[8:])
    if used > _MAX_USED:
        raise (
            Report("rand: invalid ChaCha8 encoding")
            .with_code(ErrInvalidEncoding)
            .error()
        )
    for k in range(4):
        s.seed[k] = _le_uint64(data[(2 + k) * 8 :])
    s.c = _CTR_INC * (UInt32(used) // _CHUNK)
    var seed = s.seed.copy()
    _block(seed, s.buf, s.c)
    s.i = UInt32(used) % _CHUNK
    s.n = _CHUNK
    if s.c == _CTR_MAX - _CTR_INC:
        s.n = _CHUNK - _RESEED


struct ChaCha8(Copyable, Movable, Source):
    """A ChaCha8 based generator. Go's `rand.ChaCha8`.

    Seeded with 32 bytes, and every seed is as good as every other, so a caller
    with only a number to hand can put it in the first eight bytes and leave
    the rest zero.

    Copyable, and a copy produces the same values the original will. See `PCG`
    for what that is good for and what it costs.
    """

    var state: _State
    """The generator."""

    var read_buf: InlineArray[UInt8, 8]
    """The last value drawn by `read`, when part of it is still owed."""

    var read_len: Int
    """How many bytes at the end of `read_buf` are still owed. Zero to eight."""

    def __init__(out self, seed: InlineArray[UInt8, 32]):
        """A generator seeded with these 32 bytes."""
        self.state = _State()
        self.read_buf = InlineArray[UInt8, 8](fill=0)
        self.read_len = 0
        self.state.init_bytes(seed)

    def seed(mut self, seed: InlineArray[UInt8, 32]):
        """Reset to behave as `new_chacha8(seed)` does.

        The pending `read` bytes go too. They belong to the old stream and
        handing them out after a reseed would put values from before the reset
        into the output of the generator after it.
        """
        self.state.init_bytes(seed)
        self.read_buf = InlineArray[UInt8, 8](fill=0)
        self.read_len = 0

    def uint64(mut self) -> UInt64:
        """The next value, uniform over the whole range of `UInt64`."""
        while True:
            var value, ok = self.state.next()
            if ok:
                return value
            self.state.refill()

    def read[o: MutOrigin](mut self, into: Span[UInt8, o]) raises -> Int:
        """Fill `into` with bytes and return how many, which is always all of
        them.

        This has `core.io.Reader`'s signature, including the `raises` it never
        uses, so that wrapping one of these as a reader later needs no change
        here. It does not declare that conformance, because doing so would put
        `core.io` under `core.math.rand` and Go's `math/rand/v2` does not
        import `io`.

        Interleaving this with `uint64` leaves the order the bits come out in
        unspecified, and this may hand out bits drawn before the last `uint64`.
        That is Go's wording and Go's behaviour: a read that does not end on an
        eight byte boundary keeps the rest of the value it drew, and `uint64`
        does not look at it.
        """
        var want = len(into)
        var at = 0
        var moved = 0

        if self.read_len > 0:
            var take = min(want, self.read_len)
            var from_ = 8 - self.read_len
            for k in range(take):
                into[k] = self.read_buf[from_ + k]
            self.read_len -= take
            at = take
            moved = take

        while want - at >= 8:
            var value = self.uint64()
            for k in range(8):
                into[at + k] = UInt8((value >> UInt64(8 * k)) & 0xFF)
            at += 8
            moved += 8

        var rest = want - at
        if rest > 0:
            var value = self.uint64()
            for k in range(8):
                self.read_buf[k] = UInt8((value >> UInt64(8 * k)) & 0xFF)
            for k in range(rest):
                into[at + k] = self.read_buf[k]
            moved += rest
            self.read_len = 8 - rest

        return moved

    def append_binary(self, mut dst: List[UInt8]) -> Int:
        """Append the marshalled state to `dst` and return how many bytes that
        took.

        Forty eight bytes normally, and up to fifty seven when a `read` left
        part of a value owed.
        """
        var start = len(dst)
        if self.read_len > 0:
            _append_str(dst, _READ_TAG)
            dst.append(UInt8(self.read_len))
            for k in range(self.read_len):
                dst.append(self.read_buf[8 - self.read_len + k])
        _marshal_state(self.state, dst)
        return len(dst) - start

    def marshal_binary(self) -> List[UInt8]:
        """The marshalled state."""
        var out = List[UInt8](capacity=64)
        _ = self.append_binary(out)
        return out^

    def unmarshal_binary[o: ImmOrigin](mut self, data: Span[UInt8, o]) raises:
        """Restore the state from `data`, or raise `ErrInvalidEncoding`.

        A `readbuf:` section is optional and its absence leaves any bytes this
        generator already owed where they are, which is Go's behaviour.

        Go's version indexes `readBuf[8-len(buf):]` without checking the length
        byte, so an encoding claiming nine or more pending bytes panics with a
        slice bounds failure. Here that length is checked and the encoding is
        refused, because this decodes whatever a caller was given and a panic
        on malformed input is a denial of service rather than a bug report.
        """
        var rest = data
        if _has_prefix(data, _READ_TAG):
            var body = data[_READ_TAG.byte_length() :]
            if len(body) == 0 or len(body) < 1 + Int(body[0]) or body[0] > 8:
                raise (
                    Report("rand: invalid ChaCha8 read buffer encoding")
                    .with_code(ErrInvalidEncoding)
                    .error()
                )
            var count = Int(body[0])
            for k in range(count):
                self.read_buf[8 - count + k] = body[1 + k]
            self.read_len = count
            rest = body[1 + count :]
        _unmarshal_state(self.state, rest)


def new_chacha8(seed: InlineArray[UInt8, 32]) -> ChaCha8:
    """A `ChaCha8` seeded with these 32 bytes. Go's `rand.NewChaCha8`.

    Named `new_chacha8` rather than the `new_cha_cha8` the naming rules would
    derive, through an entry in `tools/parity/renames.toml`. The rules split a
    camel case name before every capital that starts a word and `ChaCha8` has
    two of them, which is right for `NewZipf` and wrong here.
    """
    return ChaCha8(seed)
