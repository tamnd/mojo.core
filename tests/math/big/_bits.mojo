"""A second, slower way to write a floating point number. Go's `bits_test.go`.

A `Bits` value is a list of exponents, and the number it stands for is the sum
of two to each of them: `[0, 1]` is three and `[-1]` is a half. Order does not
matter and a repeat is an addition, so `[0, 0]` is also two.

The point of it is that adding, multiplying and rounding are trivial in this
form and share no code at all with `core.math.big`. Adding is concatenating two
lists, multiplying is every pairwise sum of exponents, and both are exact
however long the lists get. A test can therefore work an answer out here and
compare, rather than comparing the package against a table somebody typed in.

Go writes the operations as methods on a named slice type. There is no named
list type here, so they are free functions over `List[Int]` with a `bits_`
prefix, which keeps them out of the way of the many other things in these tests
called `add` and `mul`.
"""

from core.strconv import format_int
import core.math.big as big
from core.math.big.rounding import RoundingMode


def bits_add(x: List[Int], y: List[Int]) -> List[Int]:
    """`x + y`. Go's `Bits.add`, which is a concatenation.

    Two to the `a` plus two to the `b` is a sum of two powers whichever `a` and
    `b` are, so nothing has to be worked out.
    """
    var z = List[Int](capacity=len(x) + len(y))
    for v in x:
        z.append(v)
    for v in y:
        z.append(v)
    return z^


def bits_mul(x: List[Int], y: List[Int]) -> List[Int]:
    """`x * y`. Go's `Bits.mul`.

    A product of sums is the sum of the products, and two to the `a` times two
    to the `b` is two to the `a + b`, so this is every pairwise sum.
    """
    var p = List[Int](capacity=len(x) * len(y))
    for a in x:
        for b in y:
            p.append(a + b)
    return p^


def bits_norm(x: List[Int]) -> List[Int]:
    """`x` with every exponent appearing once, in order. Go's `Bits.norm`.

    Two copies of the same exponent add up to one of the next one along, which
    can collide in turn, so the carry runs until it lands somewhere free. Go
    uses a map and sorts at the end; a sorted list does both at once here, and
    the lists in these tests are a handful of entries long.
    """
    var z = List[Int]()
    for b in x:
        var v = b
        while _index_of(z, v) >= 0:
            var at = _index_of(z, v)
            _ = z.pop(at)
            v += 1
        _insert_sorted(z, v)
    return z^


def _index_of(z: List[Int], v: Int) -> Int:
    """Where `v` is in the sorted list `z`, or `-1`."""
    for i in range(len(z)):
        if z[i] == v:
            return i
        if z[i] > v:
            return -1
    return -1


def _insert_sorted(mut z: List[Int], v: Int):
    """Put `v` into the sorted list `z`, which does not hold it yet."""
    var at = len(z)
    for i in range(len(z)):
        if z[i] > v:
            at = i
            break
    z.append(v)
    var k = len(z) - 1
    while k > at:
        z[k] = z[k - 1]
        k -= 1
    z[at] = v


def bits_float(bits: List[Int]) raises -> big.Float:
    """The number `bits` stands for, exactly. Go's `Bits.Float`.

    The exponents are shifted up so that the smallest is zero, which turns the
    number into a whole one that a `big.Int` can hold, and the shift goes back
    on as an exponent afterwards. Go writes that last step by assigning to the
    `exp` field, which is `set_mant_exp` from outside the package and means the
    same thing.
    """
    if len(bits) == 0:
        return big.Float()

    var least = bits[0]
    for b in bits:
        if b < least:
            least = b

    var x = big.Int()
    for b in bits:
        var at = b - least
        # A bit that is already set carries into the one above it, which can
        # carry again.
        while x.bit(at) != 0:
            x = x.set_bit(at, 0)
            at += 1
        x = x.set_bit(at, 1)

    var mant = big.Float()
    mant.set_int(x)
    var z = big.Float()
    z.set_mant_exp(mant, least)
    return z^


def bits_round(x: List[Int], prec: Int, mode: RoundingMode) raises -> big.Float:
    """`x` rounded to `prec` bits under `mode`. Go's `Bits.round`.

    Rounding is easy in this form: the exponents above the cut are the answer,
    an exponent exactly on the cut is the rounding bit, and anything below it is
    the sticky bit. Go leaves `ToNearestAway` unimplemented here and so does
    this, because no caller asks for it.
    """
    var n = bits_norm(x)
    if len(n) == 0:
        return big.Float()

    var least = n[0]
    var most = n[len(n) - 1]
    var prec0 = most + 1 - least
    if prec >= prec0:
        return bits_float(n)

    if mode == big.ToNearestAway:
        raise Error("bits_round does not do ToNearestAway")

    var bit0 = 0
    var rbit = 0
    var sbit = 0
    var z = List[Int]()
    var r = most - prec
    for b in n:
        if b == r:
            rbit = 1
        elif b < r:
            sbit = 1
        else:
            if b == r + 1:
                bit0 = 1
            z.append(b)

    var fz = bits_float(z)
    var away = mode == big.AwayFromZero
    if mode == big.ToNearestEven and rbit == 1:
        if sbit == 1 or bit0 != 0:
            away = True
    if not away:
        return fz^

    # One unit in the last place kept, added at the truncating mode so that the
    # addition itself cannot round again.
    var one = List[Int]()
    one.append(r + 1)
    var t = fz.copy()
    t.set_mode(big.ToZero)
    t.set_prec(prec)
    return t.add(bits_float(one), prec)


def bits_list() -> List[List[Int]]:
    """The numbers Go runs the arithmetic tests over. Go's `bitsList`.

    Zero, one, two, a half, a thousand and a bit, its reciprocal, a number
    whose bits are far apart and one whose bits are close together.
    """
    var out: List[List[Int]] = [
        [],
        [0],
        [1],
        [-1],
        [10],
        [-10],
        [100, 10, 1],
        [0, -1, -2, -10],
    ]
    return out^


def prec_list() -> List[Int]:
    """The precisions Go runs the arithmetic tests at. Go's `precList`.

    The interesting machine widths, the numbers on either side of a word
    boundary, and a few that are nothing like either.
    """
    var out: List[Int] = [
        1,
        2,
        5,
        8,
        10,
        16,
        23,
        24,
        32,
        50,
        53,
        64,
        100,
        128,
        500,
        511,
        512,
        513,
        1000,
        10000,
    ]
    return out^


def bits_string(x: List[Int]) raises -> String:
    """`x` written out, for a message that has to say which row failed."""
    var s = String("[")
    for i in range(len(x)):
        if i > 0:
            s += " "
        s += format_int(Int64(x[i]), 10)
    return s + "]"
