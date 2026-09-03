"""Pseudo random numbers. Go's `math/rand/v2`.

```mojo
from core.math.rand import int_n, new, new_pcg

# The default source: no seed, no state to carry, safe from any thread.
print(int_n(6) + 1)

# A source of your own: reproducible, and one thread at a time.
var r = new(new_pcg(1, 2))
print(r.int_n(6) + 1)
```

**Not for anything that has to be unguessable.** Both generators here are
deterministic functions of their seed, and the whole state of either is
recoverable from a memory dump. A key, a session token or a password reset link
comes from the operating system, not from this. Go says the same thing at the
top of its package and it means it.

## What is here

`Source` is the whole interface a generator has to provide: one uniform 64 bit
value. `PCG` and `ChaCha8` implement it. `PCG` is 128 bits of state and about
as fast as arithmetic gets; `ChaCha8` is the ChaCha stream cipher with eight
rounds, much harder to predict and not much slower, and it is what Go's own
runtime uses.

`Rand` wraps a `Source` and is where everything else comes from: integers in a
range without bias, floats in `[0, 1)`, permutations, shuffles, and the normal
and exponential distributions. `Zipf` is a fourth distribution, built on a
`Rand` rather than on a `Source`.

The top level functions are the same set again with no generator to supply.
They draw from a `ChaCha8` seeded from the operating system, one per thread, so
they need no lock and no seeding and are safe to call from anywhere. They are
also the only part of the package that is not reproducible.

## This is `math/rand/v2`

Named `core.math.rand` without the version, because there is no version one
here to tell it apart from. Go's original `math/rand` is a different and worse
package: its top level functions share one locked generator, its `Int31n` and
friends have a bias correction that costs a division, and `Seed` made the whole
program's randomness a global. None of that is worth porting.

## What differs from Go

Six things, and `docs/deviations.md` has the rows.

**A `Rand` owns its `Source` and a `Zipf` owns its `Rand`.** Go holds pointers
and shares. Sharing a generator between two things that both advance it is the
mistake neither language can check for, and Mojo can decline to allow it.

**Every panic is a raise.** A bound that is not positive, a zero to
`uint64_n`, a negative count to `shuffle` or `perm`, and a `new_zipf` with
parameters that describe no distribution, which Go answers with a nil pointer.

**`ChaCha8.unmarshal_binary` checks what Go indexes by.** Go reads the
`readbuf:` length byte and the block position out of the encoding and uses both
without looking at them, so three shapes of untrusted input panic there and a
fourth restores a generator that skips forward in the stream. All four are
refused here with `ErrInvalidEncoding`, and the receiver is left alone.

**`n` raises on a `DType` that is not integral.** Go constrains the type
parameter, so `rand.N(1.5)` does not compile. Section 10 of `docs/design.md` is
why that check cannot be a compile error here. It is a `comptime if` and folds
away for every integer type.

**`shuffle` takes its swap as a compile time parameter.** So the exchange is
inlined rather than called through a pointer, the same choice `core.sort` made.

**`ChaCha8.read` does not declare `core.io.Reader`.** It has that signature
exactly, so wrapping one as a reader is a wrapper and nothing more, but
declaring the conformance would put `core.io` underneath this package and Go's
`math/rand/v2` does not import `io`.

## Why this package is `unsafe`

Only `globals.mojo` is, and only because Mojo has no global mutable state: the
per thread generator lives in the C slot in `core/errors/shim`, is allocated
with `malloc`, and is seeded through a raw `getentropy`. Nothing a caller of
`Rand`, `PCG`, `ChaCha8` or `Zipf` touches goes near any of it.
"""

from .chacha8 import ChaCha8, new_chacha8
from .globals import (
    exp_float64,
    float32,
    float64,
    int,
    int32,
    int32_n,
    int64,
    int64_n,
    int_n,
    n,
    norm_float64,
    perm,
    shuffle,
    uint,
    uint32,
    uint32_n,
    uint64,
    uint64_n,
    uint_n,
)
from .pcg import PCG, new_pcg
from .rand import Rand, new
from .source import Source
from .zipf import Zipf, new_zipf
