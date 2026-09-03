"""Elementary mathematics on complex numbers. Go's `math/cmplx`.

Twenty seven functions.

```mojo
from std.complex import ComplexFloat64

from core.math.cmplx import abs, polar, sqrt

var z = ComplexFloat64(3.0, 4.0)
print(abs(z))                        # 5.0
var r, theta = polar(z)
print(r, theta)                      # 5.0 0.9272952180016122
var root = sqrt(ComplexFloat64(-1.0, 0.0))
print(root.re, root.im)              # 0.0 1.0
```

The number type is `std.complex.ComplexFloat64`, which is Mojo's, so a value
from this package is the same value the rest of the language already works
with. What that type does not have is any of these functions: it carries the
four arithmetic operators, a conjugate, a norm and nothing else, so all
twenty seven are ported rather than wrapped.

Two of the three it does have are not the ones Go uses either. `norm()` is the
square root of the sum of two squares, which overflows at `(1e308, 1e308)`
where the answer is 1.4e308 and underflows to zero at `(1e-320, 1e-320)` where
the answer is 1.4e-320; `abs` here is a hypotenuse and is right at both. And
`/` is the naive formula, which overflows in the same way. That one does not
come up, because Go's `math/cmplx` never divides one complex number by
another.

The ports are Cephes by way of Go, and the special case switches in front of
them are C99 Annex G. Those switches are most of the source and all of the
difficulty: the answers there turn on the sign of a zero, on an infinity
beside a not a number counting as an infinity rather than as a not a number,
and on which side of a branch cut an argument arrived from. Go's own tables
for all of it are in `tests/generated/cmplx.mojo`, including the pairs of
points either side of every branch cut.

`polar` returns Go's two values as a tuple that unpacks, the way
`core.math.frexp` does: `var r, theta = polar(x)`.

Nothing here raises, as nothing in `core.math` does. Every input has an answer
once the infinities and the not a numbers are answers.
"""

from .abs import abs, conj, phase, polar, rect
from .asin import acos, acosh, asin, asinh, atan, atanh
from .exp import exp, log, log10, pow, sqrt
from .ieee import inf, is_inf, is_nan, nan
from .trig import cos, cosh, cot, sin, sinh, tan, tanh
