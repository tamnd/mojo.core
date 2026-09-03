"""Elementary mathematics on float64. Go's `math`.

Ninety seven symbols: thirty constants and sixty seven functions.

```mojo
from core.math import PI, hypot, lgamma, sqrt

print(sqrt(2.0))                  # 1.4142135623730951
print(hypot(3.0, 4.0))            # 5.0
var value, sign = lgamma(-2.5)
print(value, sign)                # -0.05624371649767405 -1
```

Everything here is float64. Go's `math` is too, and where Go has a float32
version it says so in the name, as `Nextafter32` does. A version of this
package parametric over the width is a thing Mojo could express and Go's API is
not, so it is not what this is.

About half of these functions are the system library's, reached through
`std.math`. Go writes its own because the Go runtime does not link a C library
and cannot call one cheaply if it did; the results are transcriptions of
FDLIBM, which is the same code that ended up inside the libm Mojo already
links. Copying it a third time would add a place for a bug to live and take
nothing away from any of the other two.

The other half is ported, for one of three reasons, and the docstring on each
function says which.

Some are ported because `std.math` is not accurate enough to pass Go's tests.
Mojo's is a throughput first library and its exponentials trade digits for
speed: measured against libm over Go's own inputs, `std.math.erf` is off by
a hundred and seventy million parts in the last place, `pow` by ten million,
`log` by two million. Go's tolerances are forty five parts and two. `exp`,
`exp2`, `log`, `log1p`, `pow`, `erf`, `erfc`, `cosh` and `gamma` are ported
for this reason, and Go's own test tables are what says they are close enough
now.

Some are ported because `std.math` gives the wrong answer at a special value.
`std.math.sinh` is a not a number at negative infinity, `std.math.tanh` is one
at a not a number. Those two are ported whole; `j0`, `j1`, `y0` and `y1` keep
the system library for the arithmetic and answer the special cases in front of
it.

Nine are ported because there is nothing to call: `erfinv` and `erfcinv`,
which are a rational approximation out of a statistics paper, `jn` and `yn`,
which are Bessel recurrences, `ilogb`, `pow10`, `round`, `round_to_even` and
the sign half of `lgamma`.

The one place the shape of the API changes is where Go returns two values.
Go's `Frexp`, `Lgamma`, `Modf` and `Sincos` return a pair, and so do these, as
a tuple that unpacks: `var frac, exp = frexp(x)`. `Lgamma`'s second value in C
is a global that the call sets as a side effect, which Go replaced with a
return value and this replaces the same way.

Nothing in this package raises. Go's `math` has no error return and no panic in
it, because every input has an answer once the not a numbers and the infinities
are answers, and this keeps that.

The one thing that could not be carried across is that a subnormal float
literal is zero in Mojo, so `SMALLEST_NONZERO_FLOAT32` and
`SMALLEST_NONZERO_FLOAT64` are built out of their bit patterns.
docs/deviations.md has the row.
"""

from .bessel import j0, j1, jn, y0, y1, yn
from .ieee import (
    abs,
    copysign,
    float32bits,
    float32frombits,
    float64bits,
    float64frombits,
    inf,
    is_inf,
    is_nan,
    nan,
    signbit,
)
from .const import (
    E,
    LN2,
    LN10,
    LOG2E,
    LOG10E,
    MAX_FLOAT32,
    MAX_FLOAT64,
    MAX_INT,
    MAX_INT8,
    MAX_INT16,
    MAX_INT32,
    MAX_INT64,
    MAX_UINT,
    MAX_UINT8,
    MAX_UINT16,
    MAX_UINT32,
    MAX_UINT64,
    MIN_INT,
    MIN_INT8,
    MIN_INT16,
    MIN_INT32,
    MIN_INT64,
    PHI,
    PI,
    SMALLEST_NONZERO_FLOAT32,
    SMALLEST_NONZERO_FLOAT64,
    SQRT2,
    SQRT_E,
    SQRT_PHI,
    SQRT_PI,
)
from .arith import (
    cbrt,
    fma,
    frexp,
    hypot,
    ldexp,
    nextafter,
    nextafter32,
    remainder,
    sqrt,
)
from .erf import erf, erfc, erfcinv, erfinv
from .exp import exp, exp2, expm1, pow, pow10
from .log import ilogb, log, log1p, log2, log10, logb
from .floor import (
    ceil,
    dim,
    floor,
    max,
    min,
    mod,
    modf,
    round,
    round_to_even,
    trunc,
)
from .gamma import gamma, lgamma
from .trig import (
    acos,
    acosh,
    asin,
    asinh,
    atan,
    atan2,
    atanh,
    cos,
    cosh,
    sin,
    sincos,
    sinh,
    tan,
    tanh,
)
