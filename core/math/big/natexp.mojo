"""Exponentiation and square root of natural numbers. Go has these in
`nat.go`; they are here because `nat.mojo` is long enough already.

Raising a number to a power is done by squaring. Walking the exponent from the
top bit down, squaring at every bit and multiplying by the base at every one
bit, costs a squaring per bit rather than a multiplication per unit, which is
the difference between a calculation that finishes and one that does not.

Modular exponentiation, which is what public key cryptography is made of, adds
a reduction after every step, and a division per squaring is far more expensive
than the squaring. So there are three faster paths, picked by the shape of the
modulus, and all three avoid dividing in the loop:

  - An odd modulus goes to Montgomery multiplication, which replaces the
    division with a multiplication and a shift by working in a representation
    where reduction is cheap.
  - A modulus that is a power of two needs no reduction at all, only a mask, so
    that path is a plain windowed exponentiation with a truncation.
  - Anything else is an odd number times a power of two, so it is split into
    one of each of the above and the two answers are put back together with the
    Chinese remainder theorem.

Go's versions pass a destination in to be reused, and swap two buffers back and
forth so that the loop allocates nothing. Every function here returns a new
value instead, for the reason given at the top of `nat.mojo`, which means this
allocates once per squaring where Go allocates once per call. That is the cost
of the aliasing rule and it is the thing to come back to if these ever need to
be fast.
"""

from core.errors import Report
from core.errors.codes import ErrInvalidArgument
from core.math.bits import sub64

from .arith import _add_mul_vvww_into, _M, _nlz, _W, Word
from .nat import (
    _add,
    _bit_len,
    _clone,
    _cmp,
    _is_pow2,
    _lsh,
    _norm,
    _one,
    _rsh,
    _set_word,
    _sub,
    _sub_mod_2n,
    _trailing_zero_bits,
    _trunc,
    _two,
    _zero,
)
from .natdiv import _div, _rem
from .natmul import _mul, _sqr

comptime _WINDOW = 4
"""Bits of the exponent consumed at a time by the windowed loops. Go's `n` in
`expNNWindowed` and `expNNMontgomery`, which is four in both."""


def _montgomery[
    o1: ImmOrigin, o2: ImmOrigin, o3: ImmOrigin
](
    x: Span[Word, o1], y: Span[Word, o2], m: Span[Word, o3], k: Word, n: Int
) raises -> List[Word]:
    """Montgomery multiplication of `x` and `y` modulo `m`. Go's
    `nat.montgomery`.

    All three have to be exactly `n` words long, and `x` and `y` have to be
    already reduced. `k` is the negated inverse of the bottom word of `m` modulo
    a word, which is what makes each step's correction a single multiplication.

    This is Gueron's almost Montgomery multiplication: the answer is below two
    to the power of `n` words, which is what the loop needs of it, but it is not
    necessarily below `m`. The caller converts out of this representation at the
    end and reduces once there.

    The answer keeps its full `n` words, leading zeros and all, because every
    caller feeds it straight back in and the length is part of the contract.
    """
    if len(x) != n or len(y) != n or len(m) != n:
        raise Report("big: mismatched montgomery number lengths").with_code(
            ErrInvalidArgument
        ).error()

    var z = List[Word](length=2 * n, fill=0)
    var c = Word(0)
    for i in range(n):
        var d = y[i]
        var c2 = _add_mul_vvww_into(Span(z)[i : n + i], x, d, 0)
        var t = z[i] * k
        var c3 = _add_mul_vvww_into(Span(z)[i : n + i], m, t, 0)
        var cx = c + c2
        var cy = cx + c3
        z[n + i] = cy
        c = 1 if (cx < c2 or cy < c3) else 0

    var out = List[Word](length=n, fill=0)
    if c != 0:
        var borrow = Word(0)
        for i in range(n):
            var d, b = sub64(z[n + i], m[i], borrow)
            out[i] = d
            borrow = b
    else:
        for i in range(n):
            out[i] = z[n + i]
    return out^


def _inverse_mod_2n[
    o: ImmOrigin
](x: Span[Word, o], n: Int) raises -> List[Word]:
    """The inverse of the odd number `x` modulo two to the power `n`.

    Go asks its general modular inverse for this, which is Lehmer's greatest
    common divisor and lives up in `Int`. A power of two modulus does not need
    any of that: an inverse correct to one bit is correct to two after one
    Newton step, four after the next, and so on, so a dozen multiplications
    reach any width. The answer is the same one Go's returns, because an
    inverse modulo two to the power `n` is unique below that power.

    `x` has to be odd, which every caller has checked by construction.
    """
    var u = _one()
    var k = 1
    while k < n:
        k *= 2
        var width = k if k < n else n
        # u = u * (2 - x*u), which doubles the number of correct bits.
        var t = _mul(x, Span(u))
        var d = _sub_mod_2n(Span(_two()), Span(t), width)
        var p = _mul(Span(u), Span(d))
        u = _trunc(Span(p), width)
    return _trunc(Span(u), n)


def _exp_nn[
    o1: ImmOrigin, o2: ImmOrigin, o3: ImmOrigin
](
    x: Span[Word, o1], y: Span[Word, o2], m: Span[Word, o3], slow: Bool
) raises -> List[Word]:
    """`x` to the power `y`, modulo `m` when `m` is not empty. Go's `nat.expNN`.

    `slow` asks for the plain square and multiply loop rather than one of the
    fast modular paths, which is what the tests use to check the fast paths
    against something simple.
    """
    # x**y mod 1 == 0.
    if len(m) == 1 and m[0] == 1:
        return _zero()

    # x**0 == 1.
    if len(y) == 0:
        return _set_word(1)

    # 0**y == 0 for y above zero.
    if len(x) == 0:
        return _zero()

    # 1**y == 1.
    if len(x) == 1 and x[0] == 1:
        return _set_word(1)

    # x**1 == x, reduced when there is a modulus.
    if len(y) == 1 and y[0] == 1:
        if len(m) == 0:
            return _clone(x)
        return _rem(x, m)

    if len(m) != 0 and len(y) > 1 and not slow:
        if m[0] & 1 == 1:
            return _exp_nn_montgomery(x, y, m)
        var log_m, is_pow2 = _is_pow2(m)
        if is_pow2:
            return _exp_nn_windowed(x, y, log_m)
        return _exp_nn_montgomery_even(x, y, m)

    # Square and multiply, from the top bit of the exponent down. The first
    # word is entered part way in, at its top set bit, because everything above
    # that bit is zero and squaring one is a waste.
    var z = _clone(x)
    var v = y[len(y) - 1]
    var shift = Int(_nlz(v)) + 1
    v = 0 if shift == _W else v << Word(shift)
    var mask = Word(1) << Word(_W - 1)

    var w = _W - shift
    for _j in range(w):
        var squared = _sqr(Span(z))
        z = squared^
        if v & mask != 0:
            var product = _mul(Span(z), x)
            z = product^
        if len(m) != 0:
            var reduced = _rem(Span(z), m)
            z = reduced^
        v <<= 1

    for i in range(len(y) - 2, -1, -1):
        v = y[i]
        for _j in range(_W):
            var squared = _sqr(Span(z))
            z = squared^
            if v & mask != 0:
                var product = _mul(Span(z), x)
                z = product^
            if len(m) != 0:
                var reduced = _rem(Span(z), m)
                z = reduced^
            v <<= 1

    return _norm(z^)


def _exp_nn_montgomery_even[
    o1: ImmOrigin, o2: ImmOrigin, o3: ImmOrigin
](x: Span[Word, o1], y: Span[Word, o2], m: Span[Word, o3]) raises -> List[Word]:
    """`x` to the power `y` modulo an even `m` that is not a power of two. Go's
    `nat.expNNMontgomeryEven`.

    Every such modulus is a power of two times an odd number, and those two are
    coprime, so the answer modulo each of them determines the answer modulo the
    product. Each half goes to the path that suits it and the two come back
    together with

        z = z2 + m2 * ((z1 - z2) * m2 inverse mod m1)

    which needs one inverse, and an easy one, because `m1` is a power of two.
    """
    var n = _trailing_zero_bits(m)
    var m1 = _lsh(Span(_one()), n)
    var m2 = _rsh(m, n)

    var z1 = _exp_nn(x, y, Span(m1), False)
    var z2 = _exp_nn(x, y, Span(m2), False)

    var difference = _sub_mod_2n(Span(z1), Span(z2), n)
    var m2inv = _inverse_mod_2n(Span(m2), n)
    var scaled = _mul(Span(difference), Span(m2inv))
    var p = _trunc(Span(scaled), n)

    var lifted = _mul(Span(p), Span(m2))
    return _add(Span(z2), Span(lifted))


def _exp_nn_windowed[
    o1: ImmOrigin, o2: ImmOrigin
](x: Span[Word, o1], y: Span[Word, o2], log_m: Int) raises -> List[Word]:
    """`x` to the power `y` modulo two to the power `log_m`. Go's
    `nat.expNNWindowed`.

    No reduction is needed for this modulus, only a truncation, so the loop is
    the plain windowed one: the sixteen powers of `x` from zero to fifteen are
    computed once, and then each four bits of the exponent cost four squarings
    and one multiplication instead of four of each.

    `y` has to be longer than one word, which is the only way this gets called.
    """
    if len(y) <= 1:
        raise Report("big: misuse of windowed exponentiation").with_code(
            ErrInvalidArgument
        ).error()

    if x[0] & 1 == 0:
        # The exponent is above `log_m` because it is more than a word long, so
        # an even base raises to a multiple of the modulus.
        return _zero()
    if log_m == 1:
        return _set_word(1)

    var powers = List[List[Word]](capacity=1 << _WINDOW)
    powers.append(_one())
    powers.append(_trunc(x, log_m))
    for i in range(2, 1 << _WINDOW, 2):
        var squared = _sqr(Span(powers[i // 2]))
        powers.append(_trunc(Span(squared), log_m))
        var stepped = _mul(Span(powers[i]), x)
        powers.append(_trunc(Span(stepped), log_m))

    # The multiplicative group modulo two to the power `log_m` has order two to
    # the power `log_m - 1`, so everything above that in the exponent may be
    # thrown away. Rather than shortening `y`, the walk starts at the word the
    # remaining bits are in and masks that word.
    var i = len(y) - 1
    var mtop = (log_m - 2) // _W
    var mmask = _M
    var mbits = (log_m - 1) & (_W - 1)
    if mbits != 0:
        mmask = (Word(1) << Word(mbits)) - 1
    if i > mtop:
        i = mtop

    var advance = False
    var z = _set_word(1)
    while i >= 0:
        var yi = y[i]
        if i == mtop:
            yi &= mmask
        var j = 0
        while j < _W:
            if advance:
                for _s in range(_WINDOW):
                    var squared = _sqr(Span(z))
                    z = _trunc(Span(squared), log_m)

            var product = _mul(
                Span(z), Span(powers[Int(yi >> Word(_W - _WINDOW))])
            )
            z = _trunc(Span(product), log_m)

            yi <<= _WINDOW
            advance = True
            j += _WINDOW
        i -= 1

    return _norm(z^)


def _exp_nn_montgomery[
    o1: ImmOrigin, o2: ImmOrigin, o3: ImmOrigin
](x_in: Span[Word, o1], y: Span[Word, o2], m: Span[Word, o3]) raises -> List[
    Word
]:
    """`x` to the power `y` modulo an odd `m`. Go's `nat.expNNMontgomery`.

    The same four bit window as `_exp_nn_windowed`, with every multiplication
    done in Montgomery representation so that the reduction after it is a
    shift. Getting into that representation costs one division, to find two to
    the power of twice the modulus width modulo `m`, and getting out of it
    costs one more multiplication.
    """
    var nw = len(m)

    # `x` has to be exactly as long as `m`. It does not have to be below it.
    var x = _clone(x_in)
    if len(x) > nw:
        x = _rem(Span(x), m)
    if len(x) < nw:
        var padded = List[Word](length=nw, fill=0)
        for i in range(len(x)):
            padded[i] = x[i]
        x = padded^

    # k0 = -m**-1 mod 2**_W, by Newton's iteration on the bottom word alone.
    # Dumas, "On Newton-Raphson Iteration for Multiplicative Inverses Modulo
    # Prime Powers".
    var k0 = Word(2) - m[0]
    var t = m[0] - 1
    var i = 1
    while i < _W:
        t *= t
        k0 *= t + 1
        i <<= 1
    k0 = Word(0) - k0

    # RR = 2**(2*_W*len(m)) mod m, the factor that moves a number into
    # Montgomery representation.
    var shifted = _lsh(Span(_one()), 2 * nw * _W)
    var rr = _rem(Span(shifted), m)
    if len(rr) < nw:
        var padded = List[Word](length=nw, fill=0)
        for k in range(len(rr)):
            padded[k] = rr[k]
        rr = padded^

    var one = List[Word](length=nw, fill=0)
    one[0] = 1

    var powers = List[List[Word]](capacity=1 << _WINDOW)
    powers.append(_montgomery(Span(one), Span(rr), m, k0, nw))
    powers.append(_montgomery(Span(x), Span(rr), m, k0, nw))
    for k in range(2, 1 << _WINDOW):
        powers.append(
            _montgomery(Span(powers[k - 1]), Span(powers[1]), m, k0, nw)
        )

    var z = _clone(Span(powers[0]))

    for k in range(len(y) - 1, -1, -1):
        var yi = y[k]
        var j = 0
        while j < _W:
            if k != len(y) - 1 or j != 0:
                for _s in range(_WINDOW):
                    var squared = _montgomery(Span(z), Span(z), m, k0, nw)
                    z = squared^
            var stepped = _montgomery(
                Span(z), Span(powers[Int(yi >> Word(_W - _WINDOW))]), m, k0, nw
            )
            z = stepped^
            yi <<= _WINDOW
            j += _WINDOW

    # Back out of Montgomery representation.
    var out = _montgomery(Span(z), Span(one), m, k0, nw)

    # Almost Montgomery multiplication can leave one multiple of the modulus
    # behind. Go's issue 13907 is the bug report that added this.
    if _cmp(Span(out), m) >= 0:
        var reduced = _sub(Span(out), m)
        out = reduced^
        if _cmp(Span(out), m) >= 0:
            var divided = _rem(Span(out), m)
            out = divided^

    return _norm(out^)


def _sqrt[o: ImmOrigin](x: Span[Word, o]) raises -> List[Word]:
    """The integer square root of `x`, rounded down. Go's `nat.sqrt`.

    Newton's method on the integers, from a starting point known to be too
    large. Brent and Zimmermann, `Modern Computer Arithmetic`, algorithm 1.13.
    Each step roughly doubles the number of correct digits, and the sequence
    decreases until it reaches the answer, so the first step that does not
    decrease is the one to stop at. For an `x` one below a perfect square the
    sequence then oscillates between the answer and one above it, which is why
    the test is on the step and not on the value.
    """
    if _cmp(x, Span(_one())) <= 0:
        return _clone(x)

    var z1 = _lsh(Span(_one()), (_bit_len(x) + 1) // 2)
    while True:
        var both = _div(x, Span(z1))
        var z2 = both^.take_q()
        var summed = _add(Span(z2), Span(z1))
        z2 = summed^
        var halved = _rsh(Span(z2), 1)
        z2 = halved^
        if _cmp(Span(z2), Span(z1)) >= 0:
            return z1^
        z1 = z2^
