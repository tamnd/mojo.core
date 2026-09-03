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

# A third is a third, and stays one however it was written.
var third = big.new_rat(7, 21)
print(third.rat_string())        # 1/3
print(third.float_string(5))     # 0.33333

# Two hundred bits of the square root of two.
var two = big.Float()
two.set_prec(200)
two.set_int64(2)
print(two.sqrt().text(UInt8(ord("g")), 30))
# 1.41421356237309504880168872421
```

Numbers here are as large as memory allows. `Int` is a signed integer, `Rat` is
a quotient of two of them, and `Float` is a floating point number carried to
whatever precision was asked for.

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

`Rat` is the whole of Go's `Rat`: the four arithmetic operations, comparison,
the sign, the absolute value, the negation and the inverse, the numerator and
the denominator, conversion to and from `Float32` and `Float64` with a flag
saying whether the answer is exact, the number of decimal digits it needs and
whether that is all of them, printing as a fraction or at a fixed precision,
reading either form back out of text, and gob and text codecs. A `Rat` is always
in lowest terms and its denominator is always one or more, so two values that
are equal as numbers are equal digit for digit.

`Float` is the whole of Go's `Float`: a precision from two bits to `MaxPrec`,
six rounding modes, the four arithmetic operations and the square root, an
accuracy after every one of them saying which way the answer was rounded, the
signed zeros and infinities, comparison, the mantissa and the exponent as
separate values, conversion to and from `Float32`, `Float64`, `Int`, `Rat` and
the machine integers with a flag saying whether the answer is exact, eight text
formats including the shortest string that reads back as the same number,
reading any of them back, and gob and text codecs.

An operation is correctly rounded: the answer is the true result rounded once,
under the mode asked for, not the true result approached by a sequence of
roundings. `tests/math/big/test_floatarith.mojo` checks that against a second,
much slower implementation that shares no code with this one.

`Word` is the digit the magnitude is built out of, sixty four bits wide here,
and `Int.bits` and `Int.set_bits` are the two methods that speak in them.

`Accuracy` and `RoundingMode` belong to `Float`. `Accuracy` appears on `Int` and
`Rat` too, because their conversions to a machine float report one.

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

**A `Float`'s precision and mode come from its operands.** Go keeps both on the
destination, so `new(Float).SetPrec(p).SetMode(m).Add(x, y)` is how either is
chosen. With no destination, `x.add(y)` works at the wider of the two
precisions and rounds by `x`'s mode, which is what Go's `new(Float).Add(x, y)`
does, and `x.add(y, p)` names the precision. To choose a mode, copy the left
operand and set it: `var z = x.copy(); z.set_mode(big.ToZero)`. `copy` keeps the
source's precision and mode where `set` rounds to the receiver's, which is Go's
distinction between `Copy` and `Set`.

**Values, not pointers.** Go's methods all take `*Int` and `*Rat` and its
documentation warns that shallow copies are not supported. A number here is the
number, `b = a.copy()` is a second number, and there is nothing to share by
accident. `Rat.num` and `Rat.denom` return copies for the same reason `bits`
does.

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

`Float` raises with the `ErrNaN` code where Go panics with an `ErrNaN` value:
two infinities of opposite signs added, two of the same sign subtracted, a zero
times an infinity, a zero over a zero, an infinity over an infinity, the square
root of a negative number, and a NaN handed to `set_float64` or `new_float`.
`ErrNaN` is a code here rather than a struct, because that is what errors are in
this library, so there is no `Error` method to put the message behind. Go's own
documentation calls that panic a value carrying an error, which is a raise
written the long way round.
`Float.int` and `Float.rat` raise for an infinity, where Go returns a nil and an
accuracy, and a negative precision raises because Go's is unsigned and has no
such case to answer.

`Rat` adds a zero denominator, the inverse of zero and a division by zero to the
panics, all with `ErrDivideByZero`, and `set_float64` of a NaN or an infinity to
the nils, with `ErrInvalidArgument`. `set_string` and `unmarshal_text` raise with
`ErrSyntax` where Go returns a false, and they leave the receiver as it was
rather than as something undefined.

**`Rat`'s denominator is a one from the start.** Go leaves the zero value's
empty and reads an empty one as a one, which costs it two helpers and half of
`norm`. Nothing here behaves differently, because Go normalises at the first
assignment. The one visible trace is the gob encoding of a `Rat` nobody has
assigned to, which Go writes with an empty denominator and this writes with a
one; both sides read both forms.

**`Rat.float64` and `float32` say a number under the smallest subnormal is not
exact.** Go reports `1/(1<<2000)` as an exact zero, because the step that loses
bits stops at the bottom of the subnormal range and the check after it is for an
infinity alone. A zero does not represent that number, so the flag here says so.

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

from core.errors.codes import ErrNaN

from .arith import Word
from .float import (
    Float,
    MaxExp,
    MaxPrec,
    MinExp,
    new_float,
    parse_float,
)
from .int import Int, jacobi, new_int
from .natconv import MaxBase
from .rat import new_rat, Rat
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
