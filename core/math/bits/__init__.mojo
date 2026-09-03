"""Bit counting and wide arithmetic. Go's `math/bits`.

Fifty symbols in two halves. `count.mojo` and `reverse.mojo` are the questions
about one number: how many bits are set, where the highest and lowest of them
are, and the same number with its bits or its bytes turned around.
`arith.mojo` is the arithmetic a multiple precision integer is built from: a
sum with its carry, a difference with its borrow, a product that keeps both
halves, and a division whose dividend is twice as wide as its divisor.

```mojo
from core.math.bits import leading_zeros64, mul64, ones_count64

print(ones_count64(UInt64(0b1011)))       # 3
print(leading_zeros64(UInt64(1)))         # 63
var hi, lo = mul64(UInt64(1) << 63, UInt64(2))
print(hi, lo)                             # 1 0
```

Go writes every one of these by hand, out of byte tables and mask ladders and
Knuth's algorithm D, because the Go compiler intrinsifies some of them on some
architectures and the written version is what the rest fall back to. Mojo has
`std.bit` for the counting and `UInt128` for the arithmetic, so this package is
mostly one line per function. That is not a shortcut around Go's work, it is
Go's work already done by the compiler, and the tests take Go's own tables to
show the answers are the same on every input Go checks.

The only functions that can fail are `div`, `div32`, `div64`, `rem`, `rem32`
and `rem64`. Go panics on a zero divisor and on a quotient too wide to return;
those raise `ErrDivideByZero` and `ErrOverflow` here, because a package at the
bottom of the tier list is not the one that gets to end the process.

This package depends on `core.errors` and nothing else, which keeps it under
`core.math` and under `core.math.big`, the caller the arithmetic half exists
for.
"""

from .arith import (
    add,
    add32,
    add64,
    div,
    div32,
    div64,
    mul,
    mul32,
    mul64,
    rem,
    rem32,
    rem64,
    sub,
    sub32,
    sub64,
)
from .count import (
    UINT_SIZE,
    leading_zeros,
    leading_zeros8,
    leading_zeros16,
    leading_zeros32,
    leading_zeros64,
    len,
    len8,
    len16,
    len32,
    len64,
    ones_count,
    ones_count8,
    ones_count16,
    ones_count32,
    ones_count64,
    trailing_zeros,
    trailing_zeros8,
    trailing_zeros16,
    trailing_zeros32,
    trailing_zeros64,
)
from .reverse import (
    reverse,
    reverse8,
    reverse16,
    reverse32,
    reverse64,
    reverse_bytes,
    reverse_bytes16,
    reverse_bytes32,
    reverse_bytes64,
    rotate_left,
    rotate_left8,
    rotate_left16,
    rotate_left32,
    rotate_left64,
)
