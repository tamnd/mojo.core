"""Primality testing. Go's `prime.go`.

Three tests, run in order of what they cost. A table of the primes below sixty
four answers for small numbers outright. Trial division by the primes from
three to fifty three, done as two remainders against their products rather than
fifteen separate divisions, throws out most composites. What is left goes to
Miller-Rabin with as many random bases as the caller asked for, and then to a
Lucas test, and a number that passes both is a Baillie-PSW probable prime.

Baillie-PSW is the part worth knowing about. There is no composite known to
pass it, and it is conjectured that none below 2**64 does, so the answer for
any number that fits in a word is exact even with zero Miller-Rabin rounds. It
is not a proof for larger numbers, and it is not proof against an adversary who
gets to choose the number, which is the same warning Go's documentation gives.

The Jacobi symbol lives here rather than in `int.mojo` even though Go exports it
from `int.go`, because the Lucas test needs it and `int.mojo` needs the Lucas
test. Go's files are not compilation units and can point at each other freely.
Here one of the two has to be underneath the other, and the natural number level
is the one that has no dependency on the signed level. `Int.jacobi` is a call to
this with the signs pulled out.
"""

from core.errors import Report
from core.errors.codes import ErrInvalidArgument
from core.math.rand import PCG

from .arith import _M, Word
from .nat import (
    _add,
    _bit,
    _bit_len,
    _clone,
    _cmp,
    _lsh,
    _one,
    _rsh,
    _set_word,
    _sub,
    _trailing_zero_bits,
    _two,
)
from .natdiv import _mod_w, _rem
from .natexp import _exp_nn, _sqrt
from .natmul import _mul, _sqr
from .natrand import _random

comptime _PRIME_BIT_MASK = UInt64(2891462833508853932)
"""One bit per prime below sixty four, so that `_PRIME_BIT_MASK >> w` answers
for any `w` in range. Go writes the same number as eighteen shifted ones."""

comptime _PRIMES_A = Word(4127218095)
"""Three, five, seven, eleven, thirteen, seventeen, nineteen, twenty three and
thirty seven multiplied together. Go's `primesA`."""

comptime _PRIMES_B = Word(3948078067)
"""Twenty nine, thirty one, forty one, forty three, forty seven and fifty three
multiplied together. Go's `primesB`."""

comptime _PRIMES_AB = _PRIMES_A * _PRIMES_B
"""Both products at once, which fits in one digit at this width and so costs
one division instead of two. Go computes it the same way and masks it, because
the same expression overflows a thirty two bit digit."""

comptime _LUCAS_LIMIT = Word(10000)
"""How far the search for a Lucas parameter goes before giving up. Go panics
here and says the case is widely believed to be impossible."""


def _jacobi[
    o1: ImmOrigin, o2: ImmOrigin
](x_neg: Bool, x: Span[Word, o1], y_neg: Bool, y: Span[Word, o2]) raises -> Int:
    """The Jacobi symbol of `x` over `y`, which is `1`, `-1` or `0`. Go's
    `Jacobi`.

    Both arguments arrive as a sign and a magnitude, because this is below the
    level where a signed integer exists. `y` has to be odd, which Go says by
    panicking and this says by raising `ErrInvalidArgument`.

    The formulation is the one in chapter two of the Yacas book of algorithms:
    reduce, pull out the powers of two and account for each one against the
    denominator modulo eight, then flip the two arguments and account for that
    against both modulo four. It is the Euclidean algorithm with a sign carried
    along beside it, so it runs in the same time.
    """
    if len(y) == 0 or (y[0] & 1) == 0:
        raise Report(
            "big: jacobi needs an odd integer as its second argument"
        ).with_code(ErrInvalidArgument).error()

    var a_neg = x_neg
    var a = _clone(x)
    var b = _clone(y)

    # A negative denominator only matters when the numerator is negative too,
    # and then it flips the answer once.
    var j = -1 if (y_neg and x_neg) else 1

    while True:
        if _cmp(Span(b), Span(_one())) == 0:
            return j
        if len(a) == 0:
            return 0

        # a = a mod b, taken the Euclidean way so that the result is not
        # negative. Go gets this from `Int.Mod`, which is the same correction.
        var reduced = _rem(Span(a), Span(b))
        if a_neg and len(reduced) > 0:
            var lifted = _sub(Span(b), Span(reduced))
            reduced = lifted^
        a = reduced^
        a_neg = False
        if len(a) == 0:
            return 0

        var s = _trailing_zero_bits(Span(a))
        if s & 1 != 0:
            var bmod8 = b[0] & 7
            if bmod8 == 3 or bmod8 == 5:
                j = -j
        var c = _rsh(Span(a), s)

        if (b[0] & 3) == 3 and (c[0] & 3) == 3:
            j = -j
        a = b^
        b = c^


def _probably_prime_miller_rabin[
    o: ImmOrigin
](n: Span[Word, o], reps: Int, force2: Bool) raises -> Bool:
    """Whether `n` survives `reps` rounds of Miller-Rabin. Go's
    `nat.probablyPrimeMillerRabin`.

    Handbook of Applied Cryptography, algorithm 4.24. Writing `n - 1` as an odd
    `q` shifted up by `k`, a prime has to answer either one or `n - 1` to `x**q`
    for every base `x`, or reach `n - 1` by squaring that fewer than `k` times.
    A composite fails for at least three quarters of the bases, so each round
    that passes divides the chance of a wrong answer by four.

    `force2` makes the last round use base two, which is what turns this plus
    the Lucas test into Baillie-PSW.

    The bases are drawn from a generator seeded with the number being tested, so
    the answer is the same on every run. Go seeds its old thirty one bit source
    the same way; the generator here is a PCG, so the bases are different
    numbers drawn from the same distribution.
    """
    var nm1 = _sub(n, Span(_one()))
    var k = _trailing_zero_bits(Span(nm1))
    var q = _rsh(Span(nm1), k)
    var nm3 = _sub(Span(nm1), Span(_two()))
    var nm3_len = _bit_len(Span(nm3))

    var src = PCG(n[0], 0)

    for i in range(reps):
        var x = _two()
        if not (i == reps - 1 and force2):
            var drawn = _random(src, Span(nm3), nm3_len)
            x = _add(Span(drawn), Span(_two()))

        var y = _exp_nn(Span(x), Span(q), n, False)
        if _cmp(Span(y), Span(_one())) == 0 or _cmp(Span(y), Span(nm1)) == 0:
            continue

        var another_base = False
        for _j in range(1, k):
            var squared = _sqr(Span(y))
            y = _rem(Span(squared), n)
            if _cmp(Span(y), Span(nm1)) == 0:
                another_base = True
                break
            if _cmp(Span(y), Span(_one())) == 0:
                return False
        if another_base:
            continue
        return False

    return True


def _probably_prime_lucas[o: ImmOrigin](n: Span[Word, o]) raises -> Bool:
    """Whether `n` survives the almost extra strong Lucas test. Go's
    `nat.probablyPrimeLucas`.

    Baillie and Wagstaff, `Lucas Pseudoprimes`, with the parameter choice
    Baillie calls method C: raise `P` from three until the Jacobi symbol of
    `P*P - 4` over `n` is minus one, keeping `Q` at one. Then compute the Lucas
    sequence `V` at an odd `s` with `n + 1 = s << r`, doubling the subscript
    each step, and check Grantham's conditions on it.

    `V(2k) = V(k)**2 - 2` and `V(2k+1) = V(k)V(k+1) - P` are what make the
    doubling work, so the whole sequence costs one squaring and one
    multiplication per bit of `s`.

    Go panics if the search for `P` passes ten thousand, which nobody has ever
    seen happen; that raises here.
    """
    if len(n) == 0 or _cmp(n, Span(_one())) == 0:
        return False
    if (n[0] & 1) == 0:
        # Two is the only even prime. The caller has already ruled this out;
        # Go keeps the test so the function can be exercised on its own.
        return _cmp(n, Span(_two())) == 0

    var p = Word(3)
    var d = List[Word](length=1, fill=0)
    while True:
        if p > _LUCAS_LIMIT:
            raise Report(
                "big: no Lucas parameter below ten thousand for this number"
            ).with_code(ErrInvalidArgument).error()
        d[0] = p * p - 4
        var j = _jacobi(False, Span(d), False, n)
        if j == -1:
            break
        if j == 0:
            # d is (p-2)(p+2) and shares a factor with n. The search started at
            # p-2 == 1 and has climbed, so the shared factor has to be p+2, and
            # n is prime exactly when it is n itself.
            return len(n) == 1 and n[0] == p + 2
        if p == 40:
            # A perfect square has Jacobi symbol one against every d that does
            # not divide it, so the search would never end. Forty attempts is
            # far past where a non square is expected to stop.
            var root = _sqrt(n)
            var squared = _sqr(Span(root))
            if _cmp(Span(squared), n) == 0:
                return False
        p += 1

    # n + 1 = s << r with s odd. Because the Jacobi symbol came out minus one,
    # this is the exponent Grantham's theorem asks for.
    var s = _add(n, Span(_one()))
    var r = _trailing_zero_bits(Span(s))
    var s_odd = _rsh(Span(s), r)
    s = s_odd^

    var nm2 = _sub(n, Span(_two()))
    var nat_p = _set_word(p)
    var vk = _set_word(2)
    var vk1 = _set_word(p)

    for i in range(_bit_len(Span(s)), -1, -1):
        # Each pass doubles the subscript, and takes it one further when the
        # bit of s at this position is set. Both branches read the old pair and
        # write the new one, so the order inside each branch matters.
        var product = _mul(Span(vk), Span(vk1))
        var lifted = _add(Span(product), n)
        var odd_step = _sub(Span(lifted), Span(nat_p))
        var reduced = _rem(Span(odd_step), n)

        if _bit(Span(s), i) != 0:
            # V(2k+1) = V(k)V(k+1) - P, and V(2k+2) = V(k+1)**2 - 2.
            vk = reduced^
            var squared = _sqr(Span(vk1))
            var shifted = _add(Span(squared), Span(nm2))
            vk1 = _rem(Span(shifted), n)
        else:
            # V(2k+1) is the upper of the pair now, and V(2k) = V(k)**2 - 2.
            vk1 = reduced^
            var squared = _sqr(Span(vk))
            var shifted = _add(Span(squared), Span(nm2))
            vk = _rem(Span(shifted), n)

    # V(s) has to be plus or minus two, and then U(s) has to be zero. Crandall
    # and Pomerance equation 3.13 gives U(k) as the inverse of d times
    # 2V(k+1) - PV(k), and testing that against zero needs no inverse.
    if _cmp(Span(vk), Span(_two())) == 0 or _cmp(Span(vk), Span(nm2)) == 0:
        var left = _mul(Span(vk), Span(nat_p))
        var right = _lsh(Span(vk1), 1)
        var gap = _sub(Span(left), Span(right)) if _cmp(
            Span(left), Span(right)
        ) >= 0 else _sub(Span(right), Span(left))
        var residue = _rem(Span(gap), n)
        if len(residue) == 0:
            return True

    # Otherwise V at s shifted up by some t below r - 1 has to be zero.
    for _t in range(r - 1):
        if len(vk) == 0:
            return True
        if len(vk) == 1 and vk[0] == 2:
            # Two is a fixed point of the doubling, so it can never reach zero.
            return False
        var squared = _sqr(Span(vk))
        # Go writes this as a plain subtraction of two, which underflows if the
        # residue is ever one. Adding n - 2 instead gives the same value modulo
        # n and cannot go below zero.
        var shifted = _add(Span(squared), Span(nm2))
        vk = _rem(Span(shifted), n)

    return False


def _probably_prime[
    o: ImmOrigin
](neg: Bool, x: Span[Word, o], reps: Int) raises -> Bool:
    """Whether `x` is probably prime, with `reps` Miller-Rabin rounds on top of
    Baillie-PSW. Go's `Int.ProbablyPrime`.

    Go panics on a negative `reps`; that raises here.
    """
    if reps < 0:
        raise Report(
            "big: probably_prime needs a count that is not negative"
        ).with_code(ErrInvalidArgument).error()
    if neg or len(x) == 0:
        return False

    var w = x[0]
    if len(x) == 1 and w < 64:
        return (_PRIME_BIT_MASK & (UInt64(1) << w)) != 0

    if (w & 1) == 0:
        return False

    # One division by the product of fifteen small primes, split afterwards,
    # instead of fifteen divisions. Anything sharing a factor with either half
    # is composite.
    var r = _mod_w(x, _PRIMES_AB & _M)
    var ra = r % _PRIMES_A
    var rb = r % _PRIMES_B

    if (
        ra % 3 == 0
        or ra % 5 == 0
        or ra % 7 == 0
        or ra % 11 == 0
        or ra % 13 == 0
        or ra % 17 == 0
        or ra % 19 == 0
        or ra % 23 == 0
        or ra % 37 == 0
        or rb % 29 == 0
        or rb % 31 == 0
        or rb % 41 == 0
        or rb % 43 == 0
        or rb % 47 == 0
        or rb % 53 == 0
    ):
        return False

    if not _probably_prime_miller_rabin(x, reps + 1, True):
        return False
    return _probably_prime_lucas(x)
