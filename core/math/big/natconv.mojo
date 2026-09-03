"""Text conversion for natural numbers. Go's `natconv.go`.

Reading and writing a number in a base that is not two is where a big number
package spends a surprising amount of its time, so neither direction here works
one digit at a time. Both work a word at a time: the largest power of the base
that fits in a word is found once, and then reading multiplies by that power
and adds a whole group of digits, and writing divides by it and peels a whole
group off the remainder.

Writing a large number has a second gear as well. Dividing the whole number by
one word repeatedly is quadratic, so above a few words the number is split in
half first, by dividing by a tabulated power of the base close to its square
root, and each half is converted on its own. Go builds that table once per
process and caches it behind a mutex; there is no global mutable state in Mojo
at all, so the table here is built per conversion and thrown away, which costs
a few multiplications on the way in and saves the locking on every call.

Go takes an `io.ByteScanner` for reading and unreads the byte that ends the
number. This takes the bytes and gives back how many of them it used, which is
the same information without needing a reader that can go backwards.
"""

from core.errors import Report
from core.errors.codes import ErrBase, ErrSyntax
from core.math import log2

from .arith import _M, _mul_add_vww, _W, Word
from .nat import _bit_len, _clone, _cmp, _norm, _rsh, _set_word, _zero
from .natdiv import _div, _div_w
from .natmul import _mul, _mul_add_ww, _sqr

comptime _MAX_BASE = 62
"""The largest base these accept, being ten digits and two alphabets. Go's
`MaxBase`."""

comptime MaxBase = _MAX_BASE
"""The largest base `Int.text`, `Int.set_string` and their siblings accept.
Go's `MaxBase`.

Ten digits, then `a` to `z` for ten to thirty five, then `A` to `Z` for thirty
six to sixty one. Go spells it as that sum rather than as sixty two, and the
private name above is what the rest of this package uses so that the constant
and the code that enforces it move together.
"""

comptime _MAX_BASE_SMALL = 36
"""The largest base in which case does not matter. Go's `maxBaseSmall`.

Below and including this, `a` and `A` are both ten. Above it the lower case
letters are ten to thirty five and the upper case ones are thirty six to sixty
one, so a base sixty two number is case sensitive and a base thirty six one is
not.
"""

comptime _LEAF_SIZE = 8
"""Words below which a number is converted by repeated division by one word
rather than being split in half first. Go's `leafSize`, which Go's comment says
it measured at eight and sixteen on two different processors."""

comptime _DIGIT_0 = UInt8(ord("0"))
comptime _DIGIT_9 = UInt8(ord("9"))
comptime _LOWER_A = UInt8(ord("a"))
comptime _LOWER_Z = UInt8(ord("z"))
comptime _UPPER_A = UInt8(ord("A"))
comptime _UPPER_Z = UInt8(ord("Z"))
comptime _PERIOD = UInt8(ord("."))
comptime _UNDERSCORE = UInt8(ord("_"))
comptime _MINUS = UInt8(ord("-"))

comptime _PREV_OTHER = 0
"""The character before this one was not a digit and not a separator."""

comptime _PREV_DIGIT = 1
"""The character before this one was a digit, so a separator may follow it."""

comptime _PREV_SEPARATOR = 2
"""The character before this one was a separator, so a digit has to follow."""


def _digit(v: Word) -> UInt8:
    """The character for the digit value `v`, which has to be below the base.

    Go indexes a string constant. The three ranges are spelled out here because
    a string constant would have to be indexed by byte anyway and this says
    which range each answer comes from.
    """
    if v < 10:
        return _DIGIT_0 + UInt8(v)
    if v < Word(_MAX_BASE_SMALL):
        return _LOWER_A + UInt8(v - 10)
    return _UPPER_A + UInt8(v - Word(_MAX_BASE_SMALL))


def _max_pow(b: Word) -> Tuple[Word, Int]:
    """The largest power of `b` that fits in a word, and its exponent. Go's
    `maxPow`.

    For base ten in a sixty four bit word this is ten to the nineteenth and
    nineteen, which is to say nineteen decimal digits go into one word.
    """
    var p = b
    var n = 1
    var limit = _M // b
    while p <= limit:
        p *= b
        n += 1
    return (p, n)


def _pow_word(x_in: Word, n_in: Int) -> Word:
    """`x` to the power `n` in one word, wrapping if it does not fit. Go's
    `pow`.

    Every caller has already established from `_max_pow` that the answer fits.
    """
    var p = Word(1)
    var x = x_in
    var n = n_in
    while n > 0:
        if n & 1 != 0:
            p *= x
        x *= x
        n >>= 1
    return p


def _pow_nat(x: Word, n_in: Int) -> List[Word]:
    """`x` to the power `n` as a natural number. Go's `nat.expWW`.

    Go routes this through the general modular exponentiation. This is the same
    square and multiply loop written out, because the general one is a great
    deal of machinery for a base that is one word and an exponent that is at
    most a few dozen.
    """
    var z = _set_word(1)
    var base = _set_word(x)
    var n = n_in
    while n > 0:
        if n & 1 != 0:
            var product = _mul(Span(z), Span(base))
            z = product^
        var squared = _sqr(Span(base))
        base = squared^
        n >>= 1
    return z^


struct _Divisor(Movable):
    """One entry of the table of powers of the base used to split a large
    number in half. Go's `divisor`."""

    var bbb: List[Word]
    """The divisor itself, a power of the conversion base."""

    var nbits: Int
    """Its bit length, which is roughly the base two logarithm of it."""

    var ndigits: Int
    """How many digits of the output base it accounts for."""

    def __init__(out self, var bbb: List[Word], nbits: Int, ndigits: Int):
        """Take ownership of the divisor."""
        self.bbb = bbb^
        self.nbits = nbits
        self.ndigits = ndigits


def _divisors(m: Int, b: Word, ndigits: Int, bb: Word) -> List[_Divisor]:
    """Successive squares of `bb` to the power of the leaf size, for splitting a
    number of `m` words. Go's `divisors`.

    Empty when the number is small enough to convert without splitting, which
    is what tells the converter to go straight to its iterative loop.
    """
    var table = List[_Divisor]()
    if m <= _LEAF_SIZE:
        return table^

    # Enough entries that the largest is around the square root of the number.
    var k = 1
    var words = _LEAF_SIZE
    while words < m >> 1 and k < 64:
        k += 1
        words <<= 1

    for i in range(k):
        var bbb = _pow_nat(bb, _LEAF_SIZE) if i == 0 else _sqr(
            Span(table[i - 1].bbb)
        )
        var nd = ndigits * _LEAF_SIZE if i == 0 else 2 * table[i - 1].ndigits

        # Squaring leaves room at the top of the last word more often than not,
        # so multiply by the base while that room lasts. Every digit bought
        # here is a digit the divisions below do not have to produce.
        while True:
            var larger = List[Word](length=len(bbb), fill=0)
            var carry = _mul_add_vww(Span(larger), Span(bbb), b, 0)
            if carry != 0:
                break
            bbb = larger^
            nd += 1

        var nbits = _bit_len(Span(bbb))
        table.append(_Divisor(bbb^, nbits, nd))

    return table^


def _convert_words[
    so: MutOrigin, to: ImmOrigin
](
    var q: List[Word],
    s: Span[UInt8, so],
    lo: Int,
    hi_in: Int,
    b: Word,
    ndigits: Int,
    bb: Word,
    table: Span[_Divisor, to],
    nt: Int,
) raises:
    """Write `q` in base `b` into `s[lo:hi_in]`, right justified and padded with
    leading zeros. Go's `nat.convertWords`.

    Go passes shorter and shorter subsections of the output as it recurses.
    This passes the whole of it with the bounds beside it, which says the same
    thing and keeps every call to one span of the buffer.
    """
    var hi = hi_in
    var index = nt - 1

    while nt > 0 and len(q) > _LEAF_SIZE:
        # Pick the tabulated divisor closest to the square root of what is
        # left, without going over it.
        var max_length = _bit_len(Span(q))
        var min_length = max_length >> 1
        while index > 0 and table[index - 1].nbits > min_length:
            index -= 1
        if (
            table[index].nbits >= max_length
            and _cmp(Span(table[index].bbb), Span(q)) >= 0
        ):
            index -= 1
            if index < 0:
                raise Report(
                    "big: internal inconsistency in text conversion"
                ).with_code(ErrSyntax).error()

        var both = _div(Span(q), Span(table[index].bbb))
        var upper = List[Word]()
        var lower = List[Word]()
        both^.unpack(upper, lower)
        q = upper^

        # The low half accounts for exactly the digits this divisor covers, so
        # it goes in the top of the buffer and the high half keeps the rest.
        var h = hi - table[index].ndigits
        _convert_words(lower^, s, h, hi, b, ndigits, bb, table, index)
        hi = h

    # What is left is small enough to peel a word of digits off at a time.
    var i = hi
    while len(q) > 0:
        var one = _div_w(Span(q), bb)
        var r = one.r
        q = one^.take_q()
        for _j in range(ndigits):
            if i <= lo:
                break
            i -= 1
            s[i] = _digit(r % b)
            r //= b

    while i > lo:
        i -= 1
        s[i] = _DIGIT_0


def _itoa[
    o: ImmOrigin
](x: Span[Word, o], neg: Bool, base: Int) raises -> List[UInt8]:
    """`x` in the given base, with a minus in front when `neg` and `x` is not
    zero. Go's `nat.itoa`.

    Go panics on a base outside two to sixty two. This raises `ErrBase`.
    """
    if base < 2 or base > _MAX_BASE:
        raise Report(String("big: invalid number base ", base)).with_code(
            ErrBase
        ).error()

    if len(x) == 0:
        var zero = List[UInt8](length=1, fill=_DIGIT_0)
        return zero^

    # One byte per digit, from the bit length over the bits per digit, and one
    # more because that division rounds down.
    var room = Int(Float64(_bit_len(x)) / log2(Float64(base))) + 1
    if neg:
        room += 1
    var s = List[UInt8](length=room, fill=0)
    var i = room

    var b = Word(base)
    if b & (b - 1) == 0:
        # A power of two, so a digit is a fixed run of bits and no division is
        # needed. The words are walked in order and the digits come out of the
        # bottom, which means a digit straddling two words has to be finished
        # with bits from the word above it.
        var shift = UInt(0)
        var t = b
        while t > 1:
            t >>= 1
            shift += 1
        var mask = Word((1 << shift) - 1)
        var w = x[0]
        var nbits = UInt(_W)

        for k in range(1, len(x)):
            while nbits >= shift:
                i -= 1
                s[i] = _digit(w & mask)
                w >>= Word(shift)
                nbits -= shift

            if nbits == 0:
                w = x[k]
                nbits = UInt(_W)
            else:
                w |= x[k] << Word(nbits)
                i -= 1
                s[i] = _digit(w & mask)
                w = x[k] >> Word(shift - nbits)
                nbits = UInt(_W) - (shift - nbits)

        # The top word, whose leading zeros are not digits of the answer.
        while w != 0:
            i -= 1
            s[i] = _digit(w & mask)
            w >>= Word(shift)
    else:
        var bb, ndigits = _max_pow(b)
        var table = _divisors(len(x), b, ndigits, bb)
        var q = _clone(x)
        _convert_words(
            q^, Span(s), 0, room, b, ndigits, bb, Span(table), len(table)
        )

        # That padded to the full width of the buffer, and `x` is not zero, so
        # there is a digit to stop at.
        i = 0
        while s[i] == _DIGIT_0:
            i += 1

    if neg:
        i -= 1
        s[i] = _MINUS

    var out = List[UInt8](capacity=room - i)
    for k in range(i, room):
        out.append(s[k])
    return out^


def _utoa[o: ImmOrigin](x: Span[Word, o], base: Int) raises -> List[UInt8]:
    """`x` in the given base with no sign. Go's `nat.utoa`."""
    return _itoa(x, False, base)


struct _Scan(Movable):
    """What reading a number off the front of some bytes produced."""

    var value: List[Word]
    """The number itself."""

    var base: Int
    """The base it turned out to be in, which is only interesting when the
    caller asked for base zero and a prefix decided it."""

    var count: Int
    """How many digits were read, not counting a base prefix. Negative when a
    fraction was allowed and a period appeared, in which case the value of the
    number is `value` times `base` to the power of `count`."""

    var used: Int
    """How many bytes were consumed. The caller is the one that knows whether
    the bytes after that are allowed to be there.

    Go has no equivalent, because Go unreads the byte that ended the number
    and leaves the reader positioned there. `read` would be the obvious name
    and it is a Mojo argument convention, so this is `used`."""

    def __init__(
        out self, var value: List[Word], base: Int, count: Int, used: Int
    ):
        """Take ownership of the number."""
        self.value = value^
        self.base = base
        self.count = count
        self.used = used

    def take_value(deinit self) -> List[Word]:
        """The number, moved out."""
        return self.value^


def _scan[
    o: ImmOrigin
](src: Span[UInt8, o], base: Int, frac_ok_in: Bool) raises -> _Scan:
    """Read the longest number at the front of `src`. Go's `nat.scan`.

    A base of zero means the prefix decides: `0b` for two, `0o` or a bare `0`
    for eight, `0x` for sixteen, and ten otherwise. Underscores may separate
    digits only when the base is zero, which is Go's rule for its own source
    and for every number it parses out of text.

    Go panics on a base that is neither zero nor in range, and returns its two
    syntax problems as errors. All three raise here.
    """
    var frac_ok = frac_ok_in
    var base_ok = (
        base == 0
        or (not frac_ok and 2 <= base and base <= _MAX_BASE)
        or (frac_ok and (base == 2 or base == 8 or base == 10 or base == 16))
    )
    if not base_ok:
        raise Report(String("big: invalid number base ", base)).with_code(
            ErrBase
        ).error()

    var prev = _PREV_OTHER
    var inval_sep = False

    var pos = 0
    var ch = UInt8(0)
    var have = pos < len(src)
    if have:
        ch = src[pos]
        pos += 1

    var b = base
    var prefix = UInt8(0)
    var count = 0

    if base == 0:
        b = 10
        if have and ch == _DIGIT_0:
            prev = _PREV_DIGIT
            count = 1
            have = pos < len(src)
            if have:
                ch = src[pos]
                pos += 1
            if have:
                if ch == UInt8(ord("b")) or ch == UInt8(ord("B")):
                    b = 2
                    prefix = UInt8(ord("b"))
                elif ch == UInt8(ord("o")) or ch == UInt8(ord("O")):
                    b = 8
                    prefix = UInt8(ord("o"))
                elif ch == UInt8(ord("x")) or ch == UInt8(ord("X")):
                    b = 16
                    prefix = UInt8(ord("x"))
                elif not frac_ok:
                    b = 8
                    prefix = _DIGIT_0
                if prefix != 0:
                    count = 0
                    if prefix != _DIGIT_0:
                        have = pos < len(src)
                        if have:
                            ch = src[pos]
                            pos += 1

    # Digits are collected a group at a time. For bases that pack whole into a
    # word the groups are appended and the whole thing is reversed at the end,
    # and for the rest each group multiplies what came before it.
    var z = List[Word]()
    var b1 = Word(b)
    var bn = Word(0)
    var n = _W
    if b == 4:
        n = _W // 2
    elif b == 16:
        n = _W // 4
    elif b != 2:
        var p, k = _max_pow(b1)
        bn = p
        n = k

    var di = Word(0)
    var i = 0
    var dp = -1

    while have:
        if ch == _PERIOD and frac_ok:
            frac_ok = False
            if prev == _PREV_SEPARATOR:
                inval_sep = True
            prev = _PREV_OTHER
            dp = count
        elif ch == _UNDERSCORE and base == 0:
            if prev != _PREV_DIGIT:
                inval_sep = True
            prev = _PREV_SEPARATOR
        else:
            var d1 = Word(_MAX_BASE + 1)
            if _DIGIT_0 <= ch and ch <= _DIGIT_9:
                d1 = Word(ch - _DIGIT_0)
            elif _LOWER_A <= ch and ch <= _LOWER_Z:
                d1 = Word(ch - _LOWER_A) + 10
            elif _UPPER_A <= ch and ch <= _UPPER_Z:
                if b <= _MAX_BASE_SMALL:
                    d1 = Word(ch - _UPPER_A) + 10
                else:
                    d1 = Word(ch - _UPPER_A) + Word(_MAX_BASE_SMALL)

            if d1 >= b1:
                # Not part of the number. Leave it for the caller.
                pos -= 1
                break

            prev = _PREV_DIGIT
            count += 1

            di = di * b1 + d1
            i += 1

            if i == n:
                if bn == 0:
                    z.append(di)
                else:
                    var grown = _mul_add_ww(Span(z), bn, di)
                    z = grown^
                di = 0
                i = 0

        have = pos < len(src)
        if have:
            ch = src[pos]
            pos += 1

    if inval_sep or prev == _PREV_SEPARATOR:
        raise Report("big: '_' must separate successive digits").with_code(
            ErrSyntax
        ).error()

    if count == 0:
        if prefix == _DIGIT_0:
            # Only the octal prefix was there, so the number is a decimal zero.
            return _Scan(_zero(), 10, 1, pos)
        raise Report("big: number has no digits").with_code(ErrSyntax).error()

    if bn == 0:
        if i > 0:
            # The last group is short, so it is left justified here and the
            # whole number is shifted back down after the reverse.
            z.append(di * _pow_word(b1, n - i))
        var reversed = List[Word](capacity=len(z))
        for k in range(len(z) - 1, -1, -1):
            reversed.append(z[k])
        z = _norm(reversed^)
        if i > 0:
            var shifted = _rsh(Span(z), (n - i) * (_W // n))
            z = shifted^
    elif i > 0:
        var grown = _mul_add_ww(Span(z), _pow_word(b1, i), di)
        z = grown^

    if dp >= 0:
        count = dp - count

    return _Scan(z^, b, count, pos)
