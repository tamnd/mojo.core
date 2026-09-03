"""Shared helpers for the `core.math.big` tests.

Go's tables are written as strings in whatever base is convenient, decimal in
some and hexadecimal with a `0x` prefix in others, and its tests read them with
`SetString(s, 0)` so that the prefix decides. That is what `p` does here, and it
is why nearly every test in this directory starts by turning a string into a
number rather than by building one from digits.

Every file here says `import core.math.big as big` rather than importing the
type by name, because `big.Int` shadows Mojo's own `Int` and a test needs both:
one for the number under test and one for the base, the shift or the bit index
it is passed.
"""

import core.math.big as big


def p(s: String) raises -> big.Int:
    """The number written in `s`, with the base taken from its prefix.

    Go's `new(Int).SetString(s, 0)`. A string that is not a whole number raises
    rather than returning a flag, which in a test is the same thing as failing.
    """
    var z = big.Int()
    z.set_string(s, 0)
    return z^


def pb(s: String, base: Int) raises -> big.Int:
    """The number written in `s` in the given base. Go's `SetString(s, base)`.
    """
    var z = big.Int()
    z.set_string(s, base)
    return z^


def q(s: String) raises -> big.Rat:
    """The rational written in `s`. Go's `new(Rat).SetString(s)`.

    Everything `Rat.set_string` takes, which is the `a/b` form and the floating
    point one. A string that is not a rational raises rather than coming back
    with a flag, which in a test is the same thing as failing.
    """
    var z = big.Rat()
    z.set_string(s)
    return z^


def parses(s: String, base: Int) -> Bool:
    """Whether `s` is a whole number in the given base.

    Go's `SetString` returns a boolean and this library raises, so a test that
    wants the flag asks for it here rather than writing the same `try` block
    thirty times over.
    """
    try:
        var z = big.Int()
        z.set_string(s, base)
        return True
    except:
        return False


def parses_rat(s: String) -> Bool:
    """Whether `s` is a rational number.

    `parses` above, for `Rat` rather than for `Int`.
    """
    try:
        var z = big.Rat()
        z.set_string(s)
        return True
    except:
        return False


def f(s: String) raises -> big.Float:
    """The `Float` written in `s`, at a thousand bits. Go's `makeFloat`.

    Go's helper is `ParseFloat(s, 0, 1000, ToNearestEven)`, and the wide
    precision is the point of it: a table row says what the number is and the
    test that follows sets the precision it actually wants, so no row is
    rounded before the test has looked at it.
    """
    return big.parse_float(s, 0, 1000, big.ToNearestEven)


def alike(x: big.Float, y: big.Float) -> Bool:
    """Whether these are the same number and the same sign. Go's `alike`.

    `cmp` alone reports the two zeros as equal, which is right for arithmetic
    and wrong for a test of which zero came out, so the sign bit is compared
    beside it.
    """
    return x.cmp(y) == 0 and x.signbit() == y.signbit()


def exact_int64(x: big.Float) raises -> Int64:
    """`x` as an `Int64`, refusing one that does not fit. Go's `Float.int64`
    test helper."""
    var v, acc = x.int64()
    if acc != big.Exact:
        raise Error("not an int64: " + x.text(UInt8(ord("g")), 10))
    return v


def exact_uint64(x: big.Float) raises -> UInt64:
    """`x` as a `UInt64`, refusing one that does not fit. Go's `Float.uint64`
    test helper."""
    var v, acc = x.uint64()
    if acc != big.Exact:
        raise Error("not a uint64: " + x.text(UInt8(ord("g")), 10))
    return v
