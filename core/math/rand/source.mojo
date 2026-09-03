"""What a generator has to provide, and the one derivation every reader of it
shares. Go's `rand.Source`.

Go declares `Source` in `rand.go`, next to `Rand`, and there is no reason it
could not be declared there here as well except for one: Mojo has no methods
outside a struct body. Go writes `NormFloat64` and `ExpFloat64` as methods on
`*Rand` in `normal.go` and `exp.go`, and those two files cannot hold a method
of `Rand` here. What they hold instead is a free function over any `Source`,
which means `normal.mojo` needs the trait and `rand.mojo` needs `normal.mojo`.
One of the three files has to hold the trait without importing the other two,
and this is that file.
"""


trait Source:
    """A stream of uniformly distributed 64 bit values. Go's `rand.Source`.

    ```mojo
    from core.math.rand import Source


    def two[S: Source](mut src: S) -> UInt64:
        return src.uint64() ^ src.uint64()
    ```

    One method, and everything else in the package is built on it. `PCG` and
    `ChaCha8` are the two implementations here, and a caller with a generator
    of their own writes this trait and gets the rest.

    Not safe to use from two threads at once, which is Go's rule too. Every
    implementation is a state machine being advanced, and two threads advancing
    it together get repeated values rather than a crash, which is the kind of
    wrong answer nothing later can detect. The top level functions in
    `globals.mojo` are the concurrent safe way in, and they are per thread for
    exactly this reason.
    """

    def uint64(mut self) -> UInt64:
        """The next value, uniform over the whole range of `UInt64`."""
        ...


def _float64[S: Source](mut src: S) -> Float64:
    """One draw as a float64 in `[0, 1)`. Go's `Rand.Float64`.

    Here rather than only on `Rand` because both ziggurats want it and neither
    can be a method. `Rand.float64` is a call to this.

    There are exactly 2**53 float64 values in `[0, 1)`, so the top eleven bits
    are thrown away and the rest is divided by 2**53. That is Go's arithmetic
    and it has to stay Go's arithmetic: the obvious alternative of dividing by
    2**64 rounds to 1.0 for the largest inputs, which is outside the interval
    this promises.
    """
    return Float64(src.uint64() << 11 >> 11) / Float64(1 << 53)
