"""Arbitrary precision arithmetic. Go's `math/big`.

```mojo
import core.math.big as big

# Fifty factorial, which is nowhere near fitting in a machine integer.
var f = big.new_int(1)
for i in range(1, 51):
    f = f.mul(big.new_int(Int64(i)))
print(f.string())
# 30414093201713378043612608166064768844377641568960512000000000000

# A number is prime often enough to be worth asking.
var p = big.Int()
p.set_string("170141183460469231731687303715884105727", 10)
print(p.probably_prime(20))  # True
```

Numbers here are as large as memory allows. `Int` is a signed integer; `Rat`
and `Float` are Go's rational and floating point types and are not written yet.

Import the package rather than the type, as above and as Go does. `Int` here
shadows Mojo's own `Int`, and most code that reaches for a big number wants a
machine one in the same breath, for a base or a shift or a bit index.

## What is here

`Int` is the whole of Go's `Int`: the four arithmetic operations in both the
truncating and the Euclidean flavours, the bit operations over an infinite two's
complement picture of the number, shifts, powers with and without a modulus,
the greatest common divisor with Bezout coefficients, modular inverses and
square roots, integer square roots, primality testing, conversion to and from
text in every base up to `MaxBase`, and conversion to and from bytes, gob, text
and JSON.

`Word` is the digit the magnitude is built out of, sixty four bits wide here,
and `Int.bits` and `Int.set_bits` are the two methods that speak in them.

`Accuracy` and `RoundingMode` belong to `Float`, and `Accuracy` is here early
because `Int.float64` reports one.

`jacobi` is the Jacobi symbol, which is a free function in Go as well because
it is symmetric enough that neither argument is the obvious receiver.

`Int.must_set_string` is not Go's and is the one addition. Go writes a constant
at package level and drops the boolean; there is no package level here and
`set_string` raises, so a written down modulus would otherwise make the file
holding it a raising one. It aborts, so it is for a literal only, and the
linter refuses it on anything else.

## What differs from Go

**No destination argument.** Go writes `z.Add(x, y)`, filling `z` and returning
it, so that a caller can reuse an allocation and can accumulate with
`z.Add(z, y)`. Mojo will not let one value arrive as both the mutable receiver
and a borrowed argument, so that spelling cannot exist. Every operation is a
method on its first operand and returns a new value: `x.add(y)`. Methods that
take no `Int` at all, such as `set_int64`, stay setters, because there is
nothing there to alias.

**Values, not pointers.** Go's methods all take `*Int` and its documentation
warns that shallow copies are not supported. An `Int` here is the number, `b =
a.copy()` is a second number, and there is nothing to share by accident.

**Multiple results come back through arguments.** `quo_rem`, `div_mod` and
`gcd_ext` have more than one answer. A tuple would need `Int` to be implicitly
copyable, which a type holding a list cannot be, so the extra answers are
written through `mut` arguments the caller already holds and the main one is
returned.

**Three method names are Mojo keywords.** `And`, `Or` and `Not` are `__and__`,
`__or__` and `__invert__`, and `Xor` follows them to `__xor__`. `AndNot` keeps
its name as `and_not`.

**Every panic is a raise, and so is every nil.** Division by zero, a negative
bit index, a bit that is not zero or one, the square root of a negative number,
a base outside two to `MaxBase`, an even modulus for the Jacobi symbol, a
negative round count for `probably_prime` and a `fill_bytes` buffer too small
to hold the number all raise where Go ends the process.
So do the three cases where Go returns a nil `Int`: no modular inverse, no
modular square root, and a negative power of a number with no inverse.

**`bits` and `set_bits` copy.** Go hands out and takes in the number's own
backing array and documents the sharing. A view of storage a value owns is the
one thing this library does not hand out anywhere, because the owner can move.

**`Int.rand` takes any source.** Go's takes a `*rand.Rand`. This takes anything
implementing `core.math.rand.Source`, which a `Rand` is, and so are `PCG` and
`ChaCha8` on their own. The digits it draws differ from Go's for the same seed:
Go builds each one from two thirty two bit draws because its old generator was
that wide, and `core.math.rand` is `math/rand/v2`, whose sources are already
sixty four bits.

`docs/deviations.md` has the rows for all of these.

## Speed

The multiplication is schoolbook below a threshold and Karatsuba above it, with
a squaring path of its own, and the division is Knuth's algorithm D with a
reciprocal cached across the digits. Go has two more algorithms this does not:
`divRecursive`, which helps only on divisors of several thousand digits, and
`karatsubaSqr`. Both are on the list rather than in the package.

This is not a constant time library, and Go says the same about its own. The
running time of nearly everything here depends on the values, so a program that
must not leak a secret through timing wants a different tool.
"""

from .arith import Word
from .int import Int, jacobi, new_int
from .natconv import MaxBase
from .rounding import (
    Above,
    Accuracy,
    AwayFromZero,
    Below,
    Exact,
    RoundingMode,
    ToNearestAway,
    ToNearestEven,
    ToNegativeInf,
    ToPositiveInf,
    ToZero,
)
