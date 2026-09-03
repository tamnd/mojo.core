"""A generator, and everything worth asking one for. Go's `rand.Rand`.

`Rand` turns a `Source`, which knows only how to produce a uniform 64 bit
value, into integers in a range, floats in the unit interval, permutations,
shuffles and two named distributions. Every one of those is a small piece of
arithmetic on top of the same single call, and every one of them is written the
way Go writes it, because a different derivation is a different stream.

```mojo
from core.math.rand import new, new_pcg

var r = new(new_pcg(1, 2))
print(r.int_n(6) + 1)  # a die roll
```

Two things here are not Go's.

**A `Rand` owns its `Source`.** Go holds a `Source` interface value, which is a
pointer to somebody else's generator, so the same generator can be shared
between a `Rand`, a `Zipf` and the caller. Sharing a mutable generator is
exactly what neither language can check, and Mojo can decline it, so `Rand[S]`
holds an `S` by value. It is also why the calls through to the source are
direct rather than dynamic. `core.bufio` and `core.io`'s `limit` made the same
trade for the same reasons.

**Every function that Go panics from raises instead.** Go panics on a bound
that is not positive, on a `uint64_n` of zero and on a negative count to
`shuffle`. All of those are programmer error rather than bad input, which is
Go's argument for panicking, and it is still not this library's call to end the
process. See `docs/deviations.md`.

Go's `uint32n` and the `is32bit` branch that selects it are not ported. They
exist so that a 32 bit machine produces the same stream a 64 bit one does
without doing 64 bit division; every platform this library supports is 64 bit,
so the branch is dead and porting it would mean porting code no test here can
reach.
"""

from core.errors import Report
from core.errors.codes import ErrInvalidArgument
from core.math.bits import mul64

from .exp import _exp_float64
from .normal import _norm_float64
from .source import Source, _float64


struct Rand[S: Source & Deinitable & Movable](Movable, Source):
    """A source of random numbers. Go's `rand.Rand`.

    Not safe to use from two threads at once, which is Go's rule as well. The
    top level functions in this package are, and they are per thread rather
    than locked.
    """

    var src: Self.S
    """The generator underneath. Owned, not borrowed. See the module docstring.
    """

    def __init__(out self, var src: Self.S):
        """Wrap `src`, taking ownership of it."""
        self.src = src^

    def uint64(mut self) -> UInt64:
        """A value uniform over the whole range of `UInt64`."""
        return self.src.uint64()

    def int64(mut self) -> Int64:
        """A non negative 63 bit value."""
        return Int64(self.src.uint64() & ~(UInt64(1) << 63))

    def uint32(mut self) -> UInt32:
        """A value uniform over the whole range of `UInt32`.

        The top half of a draw rather than the bottom. Every generator here is
        strongest in its high bits and a linear congruential one is weakest in
        its low bits, so the half that is thrown away is chosen rather than
        arbitrary.
        """
        return UInt32(self.src.uint64() >> 32)

    def int32(mut self) -> Int32:
        """A non negative 31 bit value."""
        return Int32(self.src.uint64() >> 33)

    def int(mut self) -> Int:
        """A non negative value, with the sign bit cleared."""
        return Int(self.src.uint64() << 1 >> 1)

    def uint(mut self) -> UInt:
        """A value uniform over the whole range of `UInt`."""
        return UInt(self.src.uint64())

    def _uint64n(mut self, n: UInt64) -> UInt64:
        """A value in `[0, n)`, with no check that `n` is not zero.

        A power of two is a mask, which is exact and needs one draw.

        Everything else is Lemire's method. Multiply a draw by `n` and keep the
        top half: that scales `[0, 2**64)` down to `[0, n)`, and it is biased,
        because 2**64 outcomes cannot be shared equally between `n` buckets
        unless `n` divides it. The bias is in the first `2**64 % n` products,
        so the sample is thrown away and redrawn when the bottom half of the
        product lands there, which restores exact uniformity.

        The threshold costs a 64 bit division, which is the most expensive
        instruction in the function, and it is only needed when the low half is
        already below `n`. That is why the division is inside the `if` and not
        above it: for a typical `n` it never runs at all.
        """
        if n & (n - 1) == 0:
            return self.src.uint64() & (n - 1)

        var hi, lo = mul64(self.src.uint64(), n)
        if lo < n:
            # 2**64 % n, written so it fits in 64 bits. Go spells this `-n % n`
            # and relies on unsigned negation wrapping; the subtraction from
            # zero is the same value said out loud.
            var thresh = (UInt64(0) - n) % n
            while lo < thresh:
                hi, lo = mul64(self.src.uint64(), n)
        return hi

    def uint64_n(mut self, n: UInt64) raises -> UInt64:
        """A value in `[0, n)`. Raises `ErrInvalidArgument` when `n` is zero."""
        if n == 0:
            raise (
                Report("rand: invalid argument to uint64_n")
                .with_code(ErrInvalidArgument)
                .error()
            )
        return self._uint64n(n)

    def int64_n(mut self, n: Int64) raises -> Int64:
        """A value in `[0, n)`. Raises `ErrInvalidArgument` unless `n > 0`."""
        if n <= 0:
            raise (
                Report("rand: invalid argument to int64_n")
                .with_code(ErrInvalidArgument)
                .error()
            )
        return Int64(self._uint64n(UInt64(n)))

    def uint32_n(mut self, n: UInt32) raises -> UInt32:
        """A value in `[0, n)`. Raises `ErrInvalidArgument` when `n` is zero."""
        if n == 0:
            raise (
                Report("rand: invalid argument to uint32_n")
                .with_code(ErrInvalidArgument)
                .error()
            )
        return UInt32(self._uint64n(UInt64(n)))

    def int32_n(mut self, n: Int32) raises -> Int32:
        """A value in `[0, n)`. Raises `ErrInvalidArgument` unless `n > 0`."""
        if n <= 0:
            raise (
                Report("rand: invalid argument to int32_n")
                .with_code(ErrInvalidArgument)
                .error()
            )
        return Int32(self._uint64n(UInt64(Int(n))))

    def int_n(mut self, n: Int) raises -> Int:
        """A value in `[0, n)`. Raises `ErrInvalidArgument` unless `n > 0`."""
        if n <= 0:
            raise (
                Report("rand: invalid argument to int_n")
                .with_code(ErrInvalidArgument)
                .error()
            )
        return Int(self._uint64n(UInt64(n)))

    def uint_n(mut self, n: UInt) raises -> UInt:
        """A value in `[0, n)`. Raises `ErrInvalidArgument` when `n` is zero."""
        if n == 0:
            raise (
                Report("rand: invalid argument to uint_n")
                .with_code(ErrInvalidArgument)
                .error()
            )
        return UInt(self._uint64n(UInt64(n)))

    def float64(mut self) -> Float64:
        """A value in `[0.0, 1.0)`."""
        return _float64(self.src)

    def float32(mut self) -> Float32:
        """A value in `[0.0, 1.0)`.

        There are exactly 2**24 float32 values in `[0, 1)`, so this keeps 24
        bits of a `uint32` draw rather than the 53 bits `float64` keeps.
        """
        return Float32(self.uint32() << 8 >> 8) / Float32(1 << 24)

    def norm_float64(mut self) -> Float64:
        """A value from the standard normal distribution, mean 0, deviation 1.

        For a different normal distribution, scale and shift the result:
        `sample = r.norm_float64() * deviation + mean`.
        """
        return _norm_float64(self.src)

    def exp_float64(mut self) -> Float64:
        """A value from the exponential distribution with rate 1, so mean 1.

        For a different rate, divide: `sample = r.exp_float64() / rate`.
        """
        return _exp_float64(self.src)

    def shuffle[
        swap: def(Int, Int) capturing[_] -> None
    ](mut self, n: Int) raises:
        """Put `n` things in a random order by exchanging pairs of them.

        `swap(i, j)` exchanges the elements at those two indices, and this
        never calls it with an index outside `[0, n)`. Raises
        `ErrInvalidArgument` when `n` is negative.

        Go takes the swap as an ordinary function value. It is a compile time
        parameter here, so the exchange is inlined into the loop rather than
        called through a pointer, which is the same choice `core.sort` made.
        The cost is that the function has to be known where `shuffle` is
        called, which rules out choosing between two of them at run time; a
        caller who needs that writes the branch inside one swap.

        Fisher and Yates, walking down. Shuffling more than 2**31 things is not
        something any generator here can do meaningfully, since 2**31 factorial
        is beyond astronomically more permutations than 128 or 256 bits of
        state can select between, but the signature takes an `Int` and so does
        this.
        """
        if n < 0:
            raise (
                Report("rand: invalid argument to shuffle")
                .with_code(ErrInvalidArgument)
                .error()
            )
        for i in reversed(range(1, n)):
            swap(i, Int(self._uint64n(UInt64(i + 1))))

    def perm(mut self, n: Int) raises -> List[Int]:
        """A random permutation of `0` through `n - 1`.

        Raises `ErrInvalidArgument` when `n` is negative, which is where Go
        panics in `make`.
        """
        if n < 0:
            raise (
                Report("rand: invalid argument to perm")
                .with_code(ErrInvalidArgument)
                .error()
            )
        var p = List[Int](capacity=n)
        for i in range(n):
            p.append(i)

        @parameter
        def swap(i: Int, j: Int):
            var held = p[i]
            p[i] = p[j]
            p[j] = held

        self.shuffle[swap](n)
        return p^


def new[S: Source & Deinitable & Movable](var src: S) -> Rand[S]:
    """A `Rand` reading from `src`. Go's `rand.New`.

    Takes ownership of `src`. Go takes an interface value and shares it; see
    the module docstring for why this does not.
    """
    return Rand(src^)
