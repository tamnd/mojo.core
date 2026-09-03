"""The PCG generator, with 128 bits of state. Go's `rand.PCG`.

A 128 bit linear congruential generator whose output is scrambled by DXSM,
"double xorshift multiply". The state advance is the same one every LCG has,
`state = state * mul + inc`, done in two 64 bit halves because there is no
single instruction for it; the scrambling is what stops the low bits of an LCG
from being as predictable as they otherwise are.

```mojo
from core.math.rand import PCG, new_pcg

var p = new_pcg(1, 2)
print(p.uint64())  # 14179336015798290704
```

Cheaper than `ChaCha8` and much weaker. The whole state is 128 bits and it is
recoverable from a handful of outputs by anybody who wants to, so this is for
simulation and for reproducible test input and never for anything a person
would want to guess. `ChaCha8` is the one to reach for when that matters and it
is not much slower.

Marshalling is twenty bytes: the four ASCII bytes `pcg:` and then the two state
words, high first, each big endian. Nothing about that is negotiable, since
those bytes are what a state written by Go reads back as here.
"""

from core.errors import Report
from core.errors.codes import ErrInvalidEncoding
from core.math.bits import add64, mul64

from .byteorder import _append_str, _be_append_uint64, _be_uint64, _has_prefix
from .source import Source

comptime _MUL_HI = UInt64(2549297995355413924)
"""The top half of the 128 bit multiplier."""

comptime _MUL_LO = UInt64(4865540595714422341)
"""The bottom half of the 128 bit multiplier."""

comptime _INC_HI = UInt64(6364136223846793005)
"""The top half of the 128 bit increment."""

comptime _INC_LO = UInt64(1442695040888963407)
"""The bottom half of the 128 bit increment."""

comptime _CHEAP_MUL = UInt64(0xDA942042E4DD58B5)
"""The 64 bit multiplier in the output scrambler."""

comptime _MARSHAL_SIZE = 20
"""How long a marshalled `PCG` is: four bytes of tag and two state words."""


struct PCG(Copyable, Movable, Source):
    """A PCG generator with 128 bits of internal state. Go's `rand.PCG`.

    A default constructed `PCG` behaves as `new_pcg(0, 0)`, which is Go's rule
    for its zero value. That is a usable generator rather than a broken one:
    an LCG with a non zero increment leaves a zero state immediately.

    Copyable, and a copy is an independent generator that produces the same
    values as the original will. That is the point of a reproducible generator
    and it is also the way to get two of them out of step by accident, so copy
    deliberately.
    """

    var hi: UInt64
    """The top half of the state."""

    var lo: UInt64
    """The bottom half of the state."""

    def __init__(out self):
        """The zero generator, which is `new_pcg(0, 0)`."""
        self.hi = 0
        self.lo = 0

    def __init__(out self, seed1: UInt64, seed2: UInt64):
        """A generator seeded with these two words."""
        self.hi = seed1
        self.lo = seed2

    def seed(mut self, seed1: UInt64, seed2: UInt64):
        """Reset to behave as `new_pcg(seed1, seed2)` does."""
        self.hi = seed1
        self.lo = seed2

    def _next(mut self) -> Tuple[UInt64, UInt64]:
        """Advance the state and return it, high half first.

        `state = state * mul + inc` in 128 bits. The product needs three 64 bit
        multiplies rather than four, because the top half of the multiplier
        times the top half of the state falls entirely off the top.

        Numpy multiplies by a 64 bit constant here instead. Go declines that
        and so does this: a multiplier with no high bits weakens the effect of
        the low bits of the state on the high bits of the product, and it saves
        one multiply out of three.
        """
        var hi, lo = mul64(self.lo, _MUL_LO)
        hi += self.hi * _MUL_LO + self.lo * _MUL_HI
        var sum_lo, carry = add64(lo, _INC_LO, 0)
        var sum_hi, _ = add64(hi, _INC_HI, carry)
        self.lo = sum_lo
        self.hi = sum_hi
        return (sum_hi, sum_lo)

    def uint64(mut self) -> UInt64:
        """The next value, uniform over the whole range of `UInt64`.

        DXSM: shift the high half down onto itself twice with a multiply
        between, then multiply by the low half forced odd. An odd multiplier is
        invertible modulo 2**64, which is what keeps the scrambler from losing
        any of the state it was given.
        """
        var hi, lo = self._next()
        hi ^= hi >> 32
        hi *= _CHEAP_MUL
        hi ^= hi >> 48
        hi *= lo | 1
        return hi

    def append_binary(self, mut dst: List[UInt8]) -> Int:
        """Append the marshalled state to `dst` and return how many bytes that
        took, which is always twenty.

        Go returns a slice and an error that is always nil. The count is what
        the rest of this library appends with, and the error is not carried
        because there is nothing that could produce one.
        """
        var start = len(dst)
        _append_str(dst, "pcg:")
        _be_append_uint64(dst, self.hi)
        _be_append_uint64(dst, self.lo)
        return len(dst) - start

    def marshal_binary(self) -> List[UInt8]:
        """The marshalled state, twenty bytes of it."""
        var out = List[UInt8](capacity=_MARSHAL_SIZE)
        _ = self.append_binary(out)
        return out^

    def unmarshal_binary[o: ImmOrigin](mut self, data: Span[UInt8, o]) raises:
        """Restore the state from `data`, or raise `ErrInvalidEncoding`.

        Nothing is written to `self` unless the whole input is accepted, so a
        generator that refuses an encoding is still the generator it was.
        """
        if len(data) != _MARSHAL_SIZE or not _has_prefix(data, "pcg:"):
            raise (
                Report("rand: invalid PCG encoding")
                .with_code(ErrInvalidEncoding)
                .error()
            )
        self.hi = _be_uint64(data[4:])
        self.lo = _be_uint64(data[12:])


def new_pcg(seed1: UInt64, seed2: UInt64) -> PCG:
    """A `PCG` seeded with these two words. Go's `rand.NewPCG`.

    Go returns a pointer because its `Rand` holds one and the generator has to
    be shared with it. This returns a value and `Rand` owns what it is given,
    which is `deviations.md`'s row for this package.
    """
    return PCG(seed1, seed2)
