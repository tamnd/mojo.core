"""The constants. Go's `math` const blocks.

Thirty of them: eleven irrational numbers, four floating point limits and
fifteen integer limits.

The irrational ones are written to sixty digits, as Go writes them, and the
compiler keeps the nearest float64 to what is written. Go can afford sixty
digits because its untyped constants are arbitrary precision until they are
used; here the digits past the seventeenth are decoration, but they are the
same decoration Go has and a reader comparing the two files should not have to
work out whether a difference in the fortieth digit means anything.

The two smallest values are built from bits rather than written as decimals.
`4.9406564584124654e-324` in a Mojo source file is `0.0` by the time it is a
`Float64`, because a float literal is flushed to zero when it is subnormal, and
the smallest nonzero float of a width is subnormal by definition. That is a
language deviation and docs/deviations.md carries it.

The integer limits are on Mojo's types already, `Int8.MAX` and the rest, and
these are here because Go's names are part of the contract. Go's are untyped
constants usable as any numeric type; these have the type their name says.
"""

from std.memory import bitcast


comptime E = 2.71828182845904523536028747135266249775724709369995957496696763
"""Euler's number, the base of the natural logarithm."""

comptime PI = 3.14159265358979323846264338327950288419716939937510582097494459
"""Pi."""

comptime PHI = 1.61803398874989484820458683436563811772030917980576286213544862
"""The golden ratio."""

comptime SQRT2 = 1.41421356237309504880168872420969807856967187537694807317667974
"""The square root of two."""

comptime SQRT_E = 1.64872127070012814684865078781416357165377610071014801157507931
"""The square root of Euler's number."""

comptime SQRT_PI = 1.77245385090551602729816748334114518279754945612238712821380779
"""The square root of pi."""

comptime SQRT_PHI = 1.27201964951406896425242246173749149171560804184009624861664038
"""The square root of the golden ratio."""

comptime LN2 = 0.693147180559945309417232121458176568075500134360255254120680009
"""The natural logarithm of two."""

comptime LOG2E = 1.44269504088896340735992468100189213742664595415298593413544940
"""The base two logarithm of Euler's number, one over `LN2`.

Go writes this as `1 / Ln2`, which it can do because its untyped constants stay
at arbitrary precision until they are used, so the division happens before any
rounding. A comptime value in Mojo behaves the same way and the division would
have worked here as well. It is written out because a float64 division does
round twice, and for `LOG10E` below that costs an ulp; writing both out means
the value does not depend on which context the expression is read in.
"""

comptime LN10 = 2.30258509299404568401799145468436420760110148862877297603332790
"""The natural logarithm of ten."""

comptime LOG10E = 0.43429448190325182765112891891660508229439700580366656611445378
"""The base ten logarithm of Euler's number, one over `LN10`.

Written out rather than divided, for the reason `LOG2E` above gives. This is
the one where it matters: `1 / LN10` between two float64s is
0x3FDBCB7B1526E50D and the correctly rounded value is 0x3FDBCB7B1526E50E.
"""


comptime MAX_FLOAT32 = Float32(3.40282346638528859811704183484516925440e38)
"""The largest finite float32.

Not `Float32.MAX`, which in Mojo is positive infinity rather than the largest
finite value. Go's `MaxFloat32` is the largest finite one and so is this.
"""

comptime SMALLEST_NONZERO_FLOAT32 = bitcast[DType.float32](UInt32(1))
"""The smallest positive float32, about 1.401298464324817e-45.

Written as the bit pattern it is because a float literal this small is flushed
to zero on its way into a `Float32`. One bit set, in the lowest place of the
fraction, which is what the smallest subnormal is.
"""

comptime MAX_FLOAT64 = 1.79769313486231570814527423731704356798070e308
"""The largest finite float64.

Not `Float64.MAX`, for the reason `MAX_FLOAT32` above gives.
"""

comptime SMALLEST_NONZERO_FLOAT64 = bitcast[DType.float64](UInt64(1))
"""The smallest positive float64, about 4.9406564584124654e-324.

Written as bits for the same reason `SMALLEST_NONZERO_FLOAT32` is.
"""


comptime MAX_INT = Int.MAX
"""The largest `Int`. 64 bits on every platform this library builds for."""

comptime MIN_INT = Int.MIN
"""The smallest `Int`."""

comptime MAX_INT8 = Int8.MAX
"""127."""

comptime MIN_INT8 = Int8.MIN
"""-128."""

comptime MAX_INT16 = Int16.MAX
"""32767."""

comptime MIN_INT16 = Int16.MIN
"""-32768."""

comptime MAX_INT32 = Int32.MAX
"""2147483647."""

comptime MIN_INT32 = Int32.MIN
"""-2147483648."""

comptime MAX_INT64 = Int64.MAX
"""9223372036854775807."""

comptime MIN_INT64 = Int64.MIN
"""-9223372036854775808."""

comptime MAX_UINT = UInt.MAX
"""The largest `UInt`."""

comptime MAX_UINT8 = UInt8.MAX
"""255."""

comptime MAX_UINT16 = UInt16.MAX
"""65535."""

comptime MAX_UINT32 = UInt32.MAX
"""4294967295."""

comptime MAX_UINT64 = UInt64.MAX
"""18446744073709551615."""
