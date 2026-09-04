"""Division the way Go writes it, for the places where the sign matters.

Mojo's `//` and `%` are Python's: the quotient rounds towards negative infinity
and the remainder takes the sign of the divisor, so `-7 // 2` is -4 and `-7 % 2`
is 1. Go's `/` and `%` are C's: the quotient rounds towards zero and the
remainder takes the sign of the dividend, so the same two expressions are -3
and -1.

Neither is wrong and they only disagree on a negative operand, which is exactly
where this package lives. A duration is signed, an instant before 1970 has a
negative Unix second, and rounding towards zero is what `truncate` promises in
words. So Go's two operators are spelled out here as functions, and the rule
followed in the rest of the package is that a value which cannot be negative
may use the operator and everything else has to say which division it means.

The calendar arithmetic in `calendar.mojo` is the interesting case of "cannot
be negative". It shifts the epoch back to the year -292277022400 precisely so
that every intermediate value is positive and the two divisions agree, which is
a trick worth knowing about before reaching for these functions there.
"""


def _quo(a: Int, b: Int) -> Int:
    """`a / b` as Go computes it, rounding towards zero.

    Division by zero is the caller's problem, the same as it is in Go and the
    same as it is for the operator this stands in for.
    """
    var q = a // b
    if q < 0 and q * b != a:
        # The floor went one step too far, which can only happen when the
        # answer is negative and the division was not exact.
        q += 1
    return q


def _rem(a: Int, b: Int) -> Int:
    """`a % b` as Go computes it, taking the sign of `a`.

    Defined from `_quo` rather than from `%` so that the two cannot drift apart:
    the pair has to satisfy `_quo(a, b) * b + _rem(a, b) == a` for the callers
    here, which take the quotient and the remainder from the same division and
    put them back together.
    """
    return a - _quo(a, b) * b
