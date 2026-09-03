"""Arithmetic on vectors of words. Go's `arith.go`.

Every number in this package is a little endian vector of `Word`, and this file
is the dozen loops that run over one. A multiple precision add is a single pass
carrying one bit from each limb into the next, a multiple precision multiply is
that pass with a product added in, and a shift is that pass reading two limbs
to write one. Nothing above this file touches a limb directly.

Go writes the loops here in terms of `math/bits` and then replaces most of them
with assembly on the architectures it has assembly for. This library has no
assembly, so what is written here is what runs, and `core.math.bits` is where
the carry and the double width product come from.

The one shape that does not survive the port is Go's aliasing. Go's `addVV(z,
x, y)` is happy to be called as `addVV(z, z, y)`, because a Go slice is a
pointer and the language has nothing to say about two of them meeting. Mojo
refuses two spans over one list in the same call, so every loop Go calls both
ways appears here twice: `_add_vv` for the three operand form and
`_add_vv_into` for the accumulate. The pair costs a few lines and buys back the
in place path Go's callers depend on, which matters most in the division loop,
where the running remainder is read and written in the same statement.
"""

from core.math.bits import add64, leading_zeros64, mul64, sub64

comptime Word = UInt64
"""One digit of a multiple precision number. Go's `Word`.

Go defines it as `uint` and derives the width from `bits.UintSize`, so the same
source builds a 32 bit and a 64 bit library. Every platform this library builds
for is 64 bit, `docs/platforms.md` is the list, so this is `UInt64` and the
width below is written down rather than computed. A number is a `List[Word]`
holding the digits smallest first.
"""

comptime _W = 64
"""Bits in a `Word`. Go's `_W`."""

comptime _S = 8
"""Bytes in a `Word`. Go's `_S`."""

comptime _M = Word.MAX
"""A `Word` with every bit set. Go's `_M`, which it writes as `_B - 1`."""

comptime _MojoInt = Int
"""Mojo's own `Int`, under a name the rest of the package can still reach.

Go's `math/big` exports a type called `Int`, and this package exports one too,
because a port that renamed it would make every line of Go's documentation
wrong. Declaring `struct Int` in `int.mojo` shadows the builtin for the whole of
that file, and `rat.mojo` and `float.mojo` import it and lose the builtin as
well. Those files spell the machine sized integer `_MojoInt`, and this is where
the name is bound, in a file that has no `Int` of its own to shadow it.
"""


def _mul_ww(x: Word, y: Word) -> Tuple[Word, Word]:
    """The whole product of two words, high half first. Go's `mulWW`."""
    return mul64(x, y)


def _mul_add_www(x: Word, y: Word, c: Word) -> Tuple[Word, Word]:
    """`x * y + c` as a double width value, high half first. Go's `mulAddWWW_g`.

    The addition cannot overflow the pair: the largest product of two words is
    two words minus twice the largest word, so there is always room for one
    more word on top.
    """
    var hi, lo = mul64(x, y)
    var sum, carry = add64(lo, c, 0)
    return (hi + carry, sum)


def _nlz(x: Word) -> Word:
    """How many zero bits sit above the highest set bit. Go's `nlz`.

    The count comes back as a `Word` rather than as an `Int` because almost
    every caller uses it as a shift amount, and Mojo will not shift a `UInt64`
    by an `Int`.
    """
    return Word(leading_zeros64(x))


def _add_vv[
    o0: MutOrigin, o1: ImmOrigin, o2: ImmOrigin
](z: Span[Word, o0], x: Span[Word, o1], y: Span[Word, o2]) -> Word:
    """`z = x + y`, returning the carry out of the top. Go's `addVV_g`.

    All three have to be the same length, and `z` has to be a different vector
    from both of the others. `_add_vv_into` is the one to call when it is not.
    """
    var c = Word(0)
    for i in range(len(z)):
        var zi, cc = add64(x[i], y[i], c)
        z[i] = zi
        c = cc
    return c


def _add_vv_into[
    o0: MutOrigin, o1: ImmOrigin
](z: Span[Word, o0], y: Span[Word, o1]) -> Word:
    """`z += y`, returning the carry out of the top.

    Go spells this `addVV(z, z, y)`. Both have to be the same length.
    """
    var c = Word(0)
    for i in range(len(z)):
        var zi, cc = add64(z[i], y[i], c)
        z[i] = zi
        c = cc
    return c


def _sub_vv[
    o0: MutOrigin, o1: ImmOrigin, o2: ImmOrigin
](z: Span[Word, o0], x: Span[Word, o1], y: Span[Word, o2]) -> Word:
    """`z = x - y`, returning the borrow out of the top. Go's `subVV_g`."""
    var c = Word(0)
    for i in range(len(z)):
        var zi, cc = sub64(x[i], y[i], c)
        z[i] = zi
        c = cc
    return c


def _sub_vv_into[
    o0: MutOrigin, o1: ImmOrigin
](z: Span[Word, o0], y: Span[Word, o1]) -> Word:
    """`z -= y`, returning the borrow out of the top.

    Go spells this `subVV(z, z, y)`, and the division loop is where it earns
    its place: the running remainder is the vector being read and written.
    """
    var c = Word(0)
    for i in range(len(z)):
        var zi, cc = sub64(z[i], y[i], c)
        z[i] = zi
        c = cc
    return c


def _add_vw[
    o0: MutOrigin, o1: ImmOrigin
](z: Span[Word, o0], x: Span[Word, o1], y: Word) -> Word:
    """`z = x + y` for a single word `y`, returning the carry. Go's `addVW`.

    With an empty `z` the carry is `y` itself, which is what Go returns and
    what the callers that trim a leading zero rely on.
    """
    var c = y
    for i in range(len(z)):
        var zi, cc = add64(x[i], c, 0)
        z[i] = zi
        c = cc
    return c


def _add_vw_into[o0: MutOrigin](z: Span[Word, o0], y: Word) -> Word:
    """`z += y` for a single word `y`, returning the carry.

    This is the version Go hand writes and links out of the package, because
    the carry almost always dies in the first limb and the loop can stop as
    soon as one limb does not wrap. That early exit is the whole point of
    having a word sized add at all, so it is kept here.
    """
    if len(z) == 0:
        return y
    var zi, cc = add64(z[0], y, 0)
    z[0] = zi
    if cc == 0:
        return 0
    for i in range(1, len(z)):
        var xi = z[i]
        if xi != _M:
            z[i] = xi + 1
            return 0
        z[i] = 0
    return 1


def _sub_vw[
    o0: MutOrigin, o1: ImmOrigin
](z: Span[Word, o0], x: Span[Word, o1], y: Word) -> Word:
    """`z = x - y` for a single word `y`, returning the borrow. Go's `subVW`."""
    var c = y
    for i in range(len(z)):
        var zi, cc = sub64(x[i], c, 0)
        z[i] = zi
        c = cc
    return c


def _sub_vw_into[o0: MutOrigin](z: Span[Word, o0], y: Word) -> Word:
    """`z -= y` for a single word `y`, returning the borrow.

    The mirror of `_add_vw_into`, stopping at the first limb that does not
    borrow.
    """
    if len(z) == 0:
        return y
    var zi, cc = sub64(z[0], y, 0)
    z[0] = zi
    if cc == 0:
        return 0
    for i in range(1, len(z)):
        var xi = z[i]
        if xi != 0:
            z[i] = xi - 1
            return 0
        z[i] = _M
    return 1


def _lsh_vu[
    o0: MutOrigin, o1: ImmOrigin
](z: Span[Word, o0], x: Span[Word, o1], s: Word) -> Word:
    """`z = x << s` for `s` under a word, returning the bits shifted off the
    top. Go's `lshVU_g`.

    Both have to be the same length. The shift runs downwards so that a caller
    shifting a vector into a longer one reads each limb before the limb above
    it is overwritten.
    """
    if s == 0:
        for i in range(len(z)):
            z[i] = x[i]
        return 0
    if len(z) == 0:
        return 0
    var sl = s & Word(_W - 1)
    var sr = (Word(_W) - sl) & Word(_W - 1)
    var c = x[len(z) - 1] >> sr
    for i in range(len(z) - 1, 0, -1):
        z[i] = (x[i] << sl) | (x[i - 1] >> sr)
    z[0] = x[0] << sl
    return c


def _rsh_vu[
    o0: MutOrigin, o1: ImmOrigin
](z: Span[Word, o0], x: Span[Word, o1], s: Word) -> Word:
    """`z = x >> s` for `s` under a word, returning the bits shifted off the
    bottom. Go's `rshVU_g`.

    Both have to be the same length, and the loop runs upwards for the reason
    `_lsh_vu`'s runs downwards.
    """
    if s == 0:
        for i in range(len(z)):
            z[i] = x[i]
        return 0
    if len(z) == 0:
        return 0
    var sr = s & Word(_W - 1)
    var sl = (Word(_W) - sr) & Word(_W - 1)
    var c = x[0] << sl
    for i in range(1, len(z)):
        z[i - 1] = (x[i - 1] >> sr) | (x[i] << sl)
    z[len(z) - 1] = x[len(z) - 1] >> sr
    return c


def _lsh_vu_into[o0: MutOrigin](z: Span[Word, o0], s: Word) -> Word:
    """`z <<= s` for `s` under a word, returning the bits shifted off the top.

    Go spells this `lshVU(z, z, s)`, and the squaring loop calls it that way to
    double the products it has collected below the diagonal.
    """
    if s == 0 or len(z) == 0:
        return 0
    var sl = s & Word(_W - 1)
    var sr = (Word(_W) - sl) & Word(_W - 1)
    var c = z[len(z) - 1] >> sr
    for i in range(len(z) - 1, 0, -1):
        z[i] = (z[i] << sl) | (z[i - 1] >> sr)
    z[0] = z[0] << sl
    return c


def _rsh_vu_into[o0: MutOrigin](z: Span[Word, o0], s: Word) -> Word:
    """`z >>= s` for `s` under a word, returning the bits shifted off the
    bottom.

    Go spells this `rshVU(z, z, s)`, and the division loop calls it that way to
    undo the scaling of the remainder.
    """
    if s == 0 or len(z) == 0:
        return 0
    var sr = s & Word(_W - 1)
    var sl = (Word(_W) - sr) & Word(_W - 1)
    var c = z[0] << sl
    for i in range(1, len(z)):
        z[i - 1] = (z[i - 1] >> sr) | (z[i] << sl)
    z[len(z) - 1] = z[len(z) - 1] >> sr
    return c


def _mul_add_vww[
    o0: MutOrigin, o1: ImmOrigin
](z: Span[Word, o0], x: Span[Word, o1], y: Word, r: Word) -> Word:
    """`z = x * y + r` for a single word `y`, returning the carry out of the
    top. Go's `mulAddVWW_g`.

    Both vectors have to be the same length. The carry is a whole word here
    rather than a bit, because a product contributes to the limb above it.
    """
    var c = r
    for i in range(len(z)):
        var hi, lo = _mul_add_www(x[i], y, c)
        c = hi
        z[i] = lo
    return c


def _add_mul_vvww_into[
    o0: MutOrigin, o1: ImmOrigin
](z: Span[Word, o0], y: Span[Word, o1], m: Word, a: Word) -> Word:
    """`z += y * m + a`, returning the carry out of the top. Go's
    `addMulVVWW_g` called with `z` for its own `x`.

    This is the inner loop of every multiplication in the package and of the
    Montgomery reduction, so it is the loop worth reading twice. Each step
    forms one full product, adds the limb already in `z` and the carry from the
    step below, and leaves the top half as the carry into the step above.
    """
    var c = a
    for i in range(len(z)):
        var z1, z0 = _mul_add_www(y[i], m, z[i])
        var lo, cc = add64(z0, c, 0)
        z[i] = lo
        c = cc + z1
    return c


def _add_to[o0: MutOrigin, o1: ImmOrigin](z: Span[Word, o0], x: Span[Word, o1]):
    """`z += x` where `x` may be shorter than `z`. Go's `addTo`.

    The carry out of the overlap is pushed up through the rest of `z`, and a
    carry out of the whole of `z` is dropped, because every caller has already
    made `z` long enough for the answer.
    """
    var n = len(x)
    if n == 0:
        return
    var c = _add_vv_into(z[0:n], x)
    if c != 0 and n < len(z):
        _ = _add_vw_into(z[n:], c)


def _div_ww(x1: Word, x0: Word, y: Word, m: Word) -> Tuple[Word, Word]:
    """`(x1, x0) / y` and its remainder, given `m` from `_reciprocal_word(y)`.
    Go's `divWW`.

    `x1` has to be below `y`, so the quotient fits in one word. The point of
    the reciprocal is that this never divides: it multiplies by an approximate
    inverse, which lands within two of the answer, and then corrects. Hardware
    division of a double width dividend is slow enough on every processor here
    that the multiply and the two corrections win, which is why Go's division
    loop precomputes `m` once per divisor and passes it down.
    """
    var s = _nlz(y)
    var a1 = x1
    var a0 = x0
    var d = y
    if s != 0:
        a1 = (a1 << s) | (a0 >> (Word(_W) - s))
        a0 <<= s
        d <<= s

    # The first term of the three term sum in Go's derivation. The other two
    # are each below one, so this is low by at most two.
    var t1, t0 = mul64(m, a1)
    var _unused, c = add64(t0, a0, 0)
    var q, _carry = add64(t1, a1, c)

    var dq1, dq0 = mul64(d, q)
    var r0, b = sub64(a0, dq0, 0)
    var r1, _b2 = sub64(a1, dq1, b)

    # The remainder computed above is below `_B + d`, so `r1` is 0 or 1. A one
    # there says the quotient was low by at least one; the test after it
    # catches a quotient low by one more.
    if r1 != 0:
        q += 1
        r0 -= d
    if r0 >= d:
        q += 1
        r0 -= d
    return (q, r0 >> s)


def _reciprocal_word(d1: Word) -> Word:
    """`(_B * _B - 1) / u - _B` where `u` is `d1` shifted up to fill a word.
    Go's `reciprocalWord`.

    The one place in the package that divides in hardware, once per divisor
    rather than once per limb. Go reaches for `bits.Div` here, which raises on
    a quotient that does not fit; this does the same division in `UInt128`
    instead, because the numerator is below `u << _W` by construction and so
    the failure `bits.Div` reports cannot happen, and a raise nothing can
    trigger would spread through every caller of the division loop.
    """
    var u = UInt128(d1 << _nlz(d1))
    var num = ((UInt128(_M) - u) << UInt128(_W)) | UInt128(_M)
    return Word((num // u).cast[DType.uint64]())
