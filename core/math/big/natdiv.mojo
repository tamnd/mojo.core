"""Division of natural numbers. Go's `natdiv.go`.

Long division, digit by digit, exactly as it is taught, with the digits being
sixty four bits wide instead of ten values wide. Two things make that work at
this width.

The first is guessing. A digit of the quotient is guessed from the top two
digits of the running remainder and the top digit of the divisor, which is one
division of a double width value by a single one, and the guess is never more
than two too large. Refining it against the second digit of the divisor brings
that down to one too large, and the correction after the subtraction catches
the rest.

The second is scaling. The guess is only that good when the top digit of the
divisor has its high bit set, so both sides are shifted up until it does before
the loop starts and the remainder is shifted back down at the end. The quotient
is unaffected, because multiplying both sides of a division by the same power
of two does not change it.

Go has a second algorithm, `divRecursive`, which splits the problem in half
above forty digits of divisor and is asymptotically better because the halves
multiply with Karatsuba. It is not here. It is written entirely in terms of
overlapping subsections of one vector being read and written by the same call,
which is the shape this port cannot express, and it changes no answer, only how
long a very large division takes. `docs/deviations.md` records it.
"""

from core.errors import Report
from core.errors.codes import ErrDivideByZero

from .arith import (
    _M,
    _add_vv_into,
    _div_ww,
    _lsh_vu,
    _mul_add_vww,
    _mul_ww,
    _nlz,
    _reciprocal_word,
    _rsh_vu_into,
    _sub_vv_into,
    Word,
)
from .nat import _clone, _cmp, _norm, _set_word, _zero


struct _QuoRem(Movable):
    """A quotient and a remainder together.

    Go returns the pair, and Mojo cannot unpack a tuple whose members are lists
    into two variables, so the pair is a value with two names.
    """

    var q: List[Word]
    """The quotient."""

    var r: List[Word]
    """The remainder."""

    def __init__(out self, var q: List[Word], var r: List[Word]):
        """Take ownership of both."""
        self.q = q^
        self.r = r^

    def take_q(deinit self) -> List[Word]:
        """The quotient, moved out, with the remainder thrown away.

        Moving one field out of a value is only allowed from a method that
        consumes the whole value, so a caller that wants one half and not the
        other says so here rather than writing `both.q^`.
        """
        return self.q^

    def take_r(deinit self) -> List[Word]:
        """The remainder, moved out, with the quotient thrown away."""
        return self.r^

    def unpack(deinit self, mut q: List[Word], mut r: List[Word]):
        """Move both halves out into two lists the caller already has.

        A tuple of two lists cannot be unpacked into two names without copying
        both, so a caller that wants the quotient and the remainder declares
        them first and this fills them in.
        """
        q = self.q^
        r = self.r^


struct _QuoRemW(Movable):
    """A quotient and a single digit remainder, from dividing by one digit."""

    var q: List[Word]
    """The quotient."""

    var r: Word
    """The remainder, which is below the one digit divisor."""

    def __init__(out self, var q: List[Word], r: Word):
        """Take ownership of the quotient."""
        self.q = q^
        self.r = r

    def take_q(deinit self) -> List[Word]:
        """The quotient, moved out, with the remainder thrown away."""
        return self.q^


def _divide_by_zero() -> Error:
    """Go panics with this message; here it is an error with a code on it."""
    return Report("big: division by zero").with_code(ErrDivideByZero).error()


def _div_wvw[
    o: ImmOrigin
](mut z: List[Word], xn: Word, x: Span[Word, o], y: Word) -> Word:
    """Fill `z` with `(xn:x) / y` and return the remainder. Go's `divWVW`.

    `z` and `x` have to be the same length, and `xn` has to be below `y`, which
    is what keeps every digit of the quotient inside one word. The reciprocal
    is computed once and every digit after that is a multiply.
    """
    var r = xn
    if len(x) == 1:
        var wide = (UInt128(r) << UInt128(64)) | UInt128(x[0])
        var d = UInt128(y)
        z[0] = Word((wide // d).cast[DType.uint64]())
        return Word((wide % d).cast[DType.uint64]())
    var rec = _reciprocal_word(y)
    for i in range(len(z) - 1, -1, -1):
        var q, rr = _div_ww(r, x[i], y, rec)
        z[i] = q
        r = rr
    return r


def _div_w[o: ImmOrigin](x: Span[Word, o], y: Word) raises -> _QuoRemW:
    """`x / y` and `x % y` for a single digit `y`. Go's `nat.divW`."""
    var m = len(x)
    if y == 0:
        raise _divide_by_zero()
    if y == 1:
        return _QuoRemW(_clone(x), 0)
    if m == 0:
        return _QuoRemW(_zero(), 0)

    var z = List[Word](length=m, fill=0)
    var r = _div_wvw(z, 0, x, y)
    return _QuoRemW(_norm(z^), r)


def _mod_w[o: ImmOrigin](x: Span[Word, o], d: Word) raises -> Word:
    """`x % d` for a single digit `d`. Go's `nat.modW`.

    The quotient is computed and thrown away, which is what Go does too and
    what the comment in Go's source has wanted to fix since 2010.
    """
    if d == 0:
        raise _divide_by_zero()
    if len(x) == 0:
        return 0
    var q = List[Word](length=len(x), fill=0)
    return _div_wvw(q, 0, x, d)


def _greater_than(x1: Word, x2: Word, y1: Word, y2: Word) -> Bool:
    """Whether the two digit number `x1:x2` is above `y1:y2`. Go's
    `greaterThan`.

    The high digit is first here, which is the opposite of the order the rest
    of the package stores digits in. Go's comment says the same and calls it a
    thing to fix.
    """
    return x1 > y1 or (x1 == y1 and x2 > y2)


def _div_basic[
    o: ImmOrigin
](mut q: List[Word], mut u: List[Word], v: Span[Word, o]):
    """Long division, leaving the quotient in `q` and the remainder in `u`. Go's
    `nat.divBasic`.

    `v` has to have at least two digits with the top bit of the top one set,
    `u` has to be one digit longer than the answer needs, and `q` has to be
    long enough for the quotient. `_div_large` is what arranges all three.
    """
    var n = len(v)
    var m = len(u) - n

    var qhatv = List[Word](length=n + 1, fill=0)

    var vn1 = v[n - 1]
    var rec = _reciprocal_word(vn1)

    # Invented leading zero for the first pass. Afterwards this is u[j+n].
    var ujn = Word(0)

    for j in range(m, -1, -1):
        # The two digit guess. When the top digits are equal the quotient digit
        # is the largest one there is, which is where Go starts.
        var qhat = _M

        if ujn != vn1:
            var qh, rhat = _div_ww(ujn, u[j + n - 1], vn1, rec)
            qhat = qh
            var vn2 = v[n - 2]
            var x1, x2 = _mul_ww(qhat, vn2)
            var ujn2 = u[j + n - 2]
            while _greater_than(x1, x2, rhat, ujn2):
                qhat -= 1
                var previous = rhat
                rhat += vn1
                # An overflowing remainder puts the three digit comparison out
                # of reach, so the guess is as refined as it is going to get.
                if rhat < previous:
                    break
                var a, b = _mul_ww(qhat, vn2)
                x1 = a
                x2 = b

        qhatv[n] = _mul_add_vww(Span(qhatv)[0:n], v, qhat, 0)
        var qhl = len(qhatv)
        if j + qhl > len(u) and qhatv[n] == 0:
            qhl -= 1

        # Take the guess away from this section of the running remainder. A
        # borrow out of it says the guess was one too large after all, so the
        # divisor goes back in and the digit comes down by one.
        var c = _sub_vv_into(Span(u)[j : j + qhl], Span(qhatv)[0:qhl])
        if c != 0:
            var back = _add_vv_into(Span(u)[j : j + n], v)
            # When n == qhl the borrow above and this carry cancel, so u[j+n]
            # is already right and touching it would be wrong.
            if n < qhl:
                u[j + n] += back
            qhat -= 1

        ujn = u[j + n - 1]

        # The caller may know the top digit is zero and not have left room.
        if j == m and m == len(q) and qhat == 0:
            continue
        q[j] = qhat


def _div_large[
    o1: ImmOrigin, o2: ImmOrigin
](u_in: Span[Word, o1], v_in: Span[Word, o2]) -> _QuoRem:
    """`u_in / v_in` and its remainder, for a divisor of two digits or more.
    Go's `nat.divLarge`.

    The caller has to have checked that `v_in` has at least two digits and that
    `u_in` is at least as long as it is.
    """
    var n = len(v_in)
    var m = len(u_in) - n

    # Scale both sides until the top bit of the divisor is set.
    var shift = _nlz(v_in[n - 1])
    var v = List[Word](length=n, fill=0)
    var u = List[Word](length=len(u_in) + 1, fill=0)
    if shift == 0:
        for i in range(n):
            v[i] = v_in[i]
        for i in range(len(u_in)):
            u[i] = u_in[i]
    else:
        _ = _lsh_vu(Span(v), v_in, shift)
        u[len(u_in)] = _lsh_vu(Span(u)[0 : len(u_in)], u_in, shift)

    var q = List[Word](length=m + 1, fill=0)
    _div_basic(q, u, Span(v))
    var quotient = _norm(q^)

    if shift != 0:
        _ = _rsh_vu_into(Span(u), shift)
    var remainder = _norm(u^)

    return _QuoRem(quotient^, remainder^)


def _div[
    o1: ImmOrigin, o2: ImmOrigin
](u: Span[Word, o1], v: Span[Word, o2]) raises -> _QuoRem:
    """`u / v` and `u % v`. Go's `nat.div`.

    Raises `ErrDivideByZero` for a zero divisor, where Go panics.
    """
    if len(v) == 0:
        raise _divide_by_zero()

    if len(v) == 1:
        var one = _div_w(u, v[0])
        var r = _set_word(one.r)
        return _QuoRem(one^.take_q(), r^)

    if _cmp(u, v) < 0:
        return _QuoRem(_zero(), _clone(u))

    return _div_large(u, v)


def _rem[
    o1: ImmOrigin, o2: ImmOrigin
](u: Span[Word, o1], v: Span[Word, o2]) raises -> List[Word]:
    """`u % v`. Go's `nat.rem`, which exists to say the quotient is not wanted.
    """
    var both = _div(u, v)
    return both^.take_r()
