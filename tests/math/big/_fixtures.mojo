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
