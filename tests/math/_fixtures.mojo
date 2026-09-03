"""The four comparisons Go's `math` tests are written in terms of.

Go's `all_test.go` opens with `tolerance`, `close`, `veryclose`, `soclose` and
`alike`, and every test in the package is a loop whose body is one of them.
They are here rather than in one test file because there are ten test files in
this directory and all ten want them.

`tolerance` is relative to the expected value and not to the computed one,
which is Go's choice and matters: an answer of zero against an expected value
of 1e-300 is a failure at any tolerance, and the other way round it would pass.
`close` is 1e-14, about forty five parts in the last place of a float64, and
`veryclose` is 4e-16, about two. Which of the two a given function gets is Go's
judgement about how much error the function is allowed to accumulate, and that
judgement is copied along with the numbers.

`alike` is the exact one, used wherever the answer is a special value rather
than a computed one. It is not `==`: it calls two not a numbers alike, which
`==` does not, and it separates the two zeros, which `==` does not either.
Nearly every special case table in Go turns on one of those two differences.

The `assert_*` wrappers exist so that a failure names the input. A bare
`assert_true(close(got, want))` over a table of ten inputs says only that one
of the ten was wrong.

Where Go writes a plain `!=`, meaning it expects the answer to be correctly
rounded and will accept nothing else, these tests use `assert_alike`. It is the
same comparison on everything either of them is ever handed, and it also
catches a zero coming back with the wrong sign.
"""

from std.testing import assert_true

from core.math import abs, is_nan, signbit


def tolerance(a: Float64, b: Float64, e: Float64) -> Bool:
    """Whether `a` is within a relative `e` of the expected value `b`.

    `a == b` first, because `e * b` underflows to zero for a subnormal `b` and
    two values that are bit for bit the same should match whatever the
    tolerance does.
    """
    if a == b:
        return True
    var d = abs(a - b)
    var scaled = e
    if b != 0:
        scaled = abs(e * b)
    return d < scaled


def close(a: Float64, b: Float64) -> Bool:
    """Within 1e-14 of the expected value `b`. About forty five ulp."""
    return tolerance(a, b, 1e-14)


def veryclose(a: Float64, b: Float64) -> Bool:
    """Within 4e-16 of the expected value `b`. About two ulp."""
    return tolerance(a, b, 4e-16)


def soclose(a: Float64, b: Float64, e: Float64) -> Bool:
    """Within a tolerance the caller picks. Go's name for it."""
    return tolerance(a, b, e)


def alike(a: Float64, b: Float64) -> Bool:
    """Whether `a` and `b` are the same value, counting the special ones.

    Two not a numbers are alike, though they are not equal. Positive and
    negative zero are equal but not alike. Everything else is `==`.
    """
    if is_nan(a) and is_nan(b):
        return True
    if a == b:
        return signbit(a) == signbit(b)
    return False


def assert_alike(got: Float64, want: Float64, what: String) raises:
    """`alike`, as an assertion that says what was asked and what came back."""
    assert_true(
        alike(got, want), what + " = " + String(got) + ", want " + String(want)
    )


def assert_close(got: Float64, want: Float64, what: String) raises:
    """`close`, as an assertion."""
    assert_true(
        close(got, want), what + " = " + String(got) + ", want " + String(want)
    )


def assert_veryclose(got: Float64, want: Float64, what: String) raises:
    """`veryclose`, as an assertion."""
    assert_true(
        veryclose(got, want),
        what + " = " + String(got) + ", want " + String(want),
    )


def assert_soclose(
    got: Float64, want: Float64, e: Float64, what: String
) raises:
    """`soclose`, as an assertion."""
    assert_true(
        soclose(got, want, e),
        what + " = " + String(got) + ", want " + String(want),
    )
