"""Go's `bits_test.go`, ported.

Go's tests here are loops rather than tables. `tab` holds the leading zero
count, trailing zero count and population count of all 256 byte values, worked
out by a naive loop that shifts one bit at a time, and the counting tests walk
that table across every shift that fits. That is the shape worth keeping: the
expected answers come from an independent implementation rather than from the
one under test, so a wrong answer cannot agree with a wrong expectation.

The panic tests become raise tests, which is the only difference in substance.
Go recovers a `runtime.Error` and compares its message; here the code on the
record is the thing to compare, and `ErrDivideByZero` and `ErrOverflow` say
which of the two Go messages it would have been.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.errors import matches
from core.errors.codes import ErrDivideByZero, ErrOverflow

from core.math.bits import (
    UINT_SIZE,
    add,
    add32,
    add64,
    div,
    div32,
    div64,
    leading_zeros,
    leading_zeros16,
    leading_zeros32,
    leading_zeros64,
    leading_zeros8,
    len16,
    len32,
    len64,
    len8,
    mul,
    mul32,
    mul64,
    ones_count,
    ones_count16,
    ones_count32,
    ones_count64,
    ones_count8,
    rem,
    rem32,
    rem64,
    reverse,
    reverse16,
    reverse32,
    reverse64,
    reverse8,
    reverse_bytes,
    reverse_bytes16,
    reverse_bytes32,
    reverse_bytes64,
    rotate_left,
    rotate_left16,
    rotate_left32,
    rotate_left64,
    rotate_left8,
    sub,
    sub32,
    sub64,
    trailing_zeros,
    trailing_zeros16,
    trailing_zeros32,
    trailing_zeros64,
    trailing_zeros8,
)

from core.math.bits import len as bit_len


comptime _DE_BRUIJN64 = UInt64(0x03F79D71B4CA8B09)
"""The constant Go's `TrailingZeros64` is built on, used here only as a bit
pattern with no run of equal bits in it, which is what makes it a good
rotation input."""

comptime _M = UInt(UInt64.MAX)
comptime _M32 = UInt32.MAX
comptime _M64 = UInt64.MAX


struct Counts(Copyable, Movable):
    """Go's `entry`: what one byte value's three counts are."""

    var nlz: Int
    var ntz: Int
    var pop: Int

    def __init__(out self, nlz: Int, ntz: Int, pop: Int):
        self.nlz = nlz
        self.ntz = ntz
        self.pop = pop


def counts() -> List[Counts]:
    """Go's `tab`, built the way Go builds it: one bit at a time.

    A shift and a test per bit, which is nobody's idea of how to count bits and
    is exactly why it belongs on this side of the comparison. The package under
    test asks the processor; this counts.
    """
    var out = List[Counts]()
    out.append(Counts(8, 8, 0))
    for i in range(1, 256):
        var x = i
        var nlz = 0
        while x & 0x80 == 0:
            nlz += 1
            x <<= 1

        x = i
        var ntz = 0
        while x & 1 == 0:
            ntz += 1
            x >>= 1

        x = i
        var pop = 0
        while x != 0:
            pop += x & 1
            x >>= 1

        out.append(Counts(nlz, ntz, pop))
    return out^


def test_uint_size() raises:
    """Go's `TestUintSize`. Go measures a `uint`; every platform here is 64 bit
    and `docs/platforms.md` is the list."""
    assert_equal(UINT_SIZE, 64)


def test_leading_zeros() raises:
    """Go's `TestLeadingZeros`. Every byte value at every shift that fits."""
    var tab = counts()
    for i in range(256):
        var nlz = tab[i].nlz
        for k in range(64 - 8):
            var x = UInt64(i) << UInt64(k)
            if x <= 0xFF:
                var want = 8 if x == 0 else nlz - k
                assert_equal(leading_zeros8(UInt8(x)), want)
            if x <= 0xFFFF:
                var want = 16 if x == 0 else nlz - k + 8
                assert_equal(leading_zeros16(UInt16(x)), want)
            if x <= 0xFFFFFFFF:
                var want = 32 if x == 0 else nlz - k + 24
                assert_equal(leading_zeros32(UInt32(x)), want)
            var want64 = 64 if x == 0 else nlz - k + 56
            assert_equal(leading_zeros64(x), want64)
            assert_equal(leading_zeros(UInt(x)), want64)


def test_trailing_zeros() raises:
    """Go's `TestTrailingZeros`, the same walk from the other end."""
    var tab = counts()
    for i in range(256):
        var ntz = tab[i].ntz
        for k in range(64 - 8):
            var x = UInt64(i) << UInt64(k)
            if x <= 0xFF:
                var want = 8 if x == 0 else ntz + k
                assert_equal(trailing_zeros8(UInt8(x)), want)
            if x <= 0xFFFF:
                var want = 16 if x == 0 else ntz + k
                assert_equal(trailing_zeros16(UInt16(x)), want)
            if x <= 0xFFFFFFFF:
                var want = 32 if x == 0 else ntz + k
                assert_equal(trailing_zeros32(UInt32(x)), want)
            var want64 = 64 if x == 0 else ntz + k
            assert_equal(trailing_zeros64(x), want64)
            assert_equal(trailing_zeros(UInt(x)), want64)


def check_ones_count(x: UInt64, want: Int) raises:
    """Go's `testOnesCount`: the same count at every width the value fits."""
    if x <= 0xFF:
        assert_equal(ones_count8(UInt8(x)), want)
    if x <= 0xFFFF:
        assert_equal(ones_count16(UInt16(x)), want)
    if x <= 0xFFFFFFFF:
        assert_equal(ones_count32(UInt32(x)), want)
    assert_equal(ones_count64(x), want)
    assert_equal(ones_count(UInt(x)), want)


def test_ones_count() raises:
    """Go's `TestOnesCount`: a run of ones growing from the bottom, then the
    same run walking off the top, then the byte table at every shift."""
    var x = UInt64(0)
    for i in range(65):
        check_ones_count(x, i)
        x = (x << 1) | 1

    for i in range(64, -1, -1):
        check_ones_count(x, i)
        x = x << 1

    var tab = counts()
    for i in range(256):
        for k in range(64 - 8):
            check_ones_count(UInt64(i) << UInt64(k), tab[i].pop)


def test_len() raises:
    """Go's `TestLen`. The width of a byte value at every shift that fits."""
    var tab = counts()
    for i in range(256):
        var width = 8 - tab[i].nlz
        for k in range(64 - 8):
            var x = UInt64(i) << UInt64(k)
            var want = 0 if x == 0 else width + k
            if x <= 0xFF:
                assert_equal(len8(UInt8(x)), want)
            if x <= 0xFFFF:
                assert_equal(len16(UInt16(x)), want)
            if x <= 0xFFFFFFFF:
                assert_equal(len32(UInt32(x)), want)
            assert_equal(len64(x), want)
            assert_equal(bit_len(UInt(x)), want)


def test_rotate_left() raises:
    """Go's `TestRotateLeft`.

    Every distance from 0 to 127, so that the wrap at the width and the second
    lap past it are both covered, and each rotation undone by the negative of
    the distance that made it, which is how Go spells rotate right.
    """
    var m = _DE_BRUIJN64
    for k in range(128):
        var x8 = UInt8(m & 0xFF)
        var s8 = UInt8(k & 7)
        var want8 = (x8 << s8) | (x8 >> ((8 - s8) & 7))
        assert_equal(rotate_left8(x8, k), want8)
        assert_equal(rotate_left8(want8, -k), x8)

        var x16 = UInt16(m & 0xFFFF)
        var s16 = UInt16(k & 15)
        var want16 = (x16 << s16) | (x16 >> ((16 - s16) & 15))
        assert_equal(rotate_left16(x16, k), want16)
        assert_equal(rotate_left16(want16, -k), x16)

        var x32 = UInt32(m & 0xFFFFFFFF)
        var s32 = UInt32(k & 31)
        var want32 = (x32 << s32) | (x32 >> ((32 - s32) & 31))
        assert_equal(rotate_left32(x32, k), want32)
        assert_equal(rotate_left32(want32, -k), x32)

        var s64 = UInt64(k & 63)
        var want64 = (m << s64) | (m >> ((64 - s64) & 63))
        assert_equal(rotate_left64(m, k), want64)
        assert_equal(rotate_left64(want64, -k), m)

        assert_equal(rotate_left(UInt(m), k), UInt(want64))
        assert_equal(rotate_left(UInt(want64), -k), UInt(m))


def check_reverse(x64: UInt64, want64: UInt64) raises:
    """Go's `testReverse`: the same reversal read at four widths.

    A narrower reversal is the top of the wide one, because reversing throws
    the bits that were cut off to the far end.
    """
    assert_equal(reverse8(UInt8(x64 & 0xFF)), UInt8(want64 >> 56))
    assert_equal(reverse16(UInt16(x64 & 0xFFFF)), UInt16(want64 >> 48))
    assert_equal(reverse32(UInt32(x64 & 0xFFFFFFFF)), UInt32(want64 >> 32))
    assert_equal(reverse64(x64), want64)
    assert_equal(reverse(UInt(x64)), UInt(want64))


def test_reverse() raises:
    """Go's `TestReverse`: each single bit, then Go's patterns both ways."""
    for i in range(64):
        check_reverse(UInt64(1) << UInt64(i), UInt64(1) << UInt64(63 - i))

    var xs = List[UInt64]()
    var rs = List[UInt64]()
    for i in range(16):
        # Go writes these out one nibble at a time. The reversal of a nibble is
        # its bits backwards, which is what this builds, and it lands at the
        # top of the word.
        var reversed = UInt64(0)
        for bit in range(4):
            if (i >> bit) & 1 == 1:
                reversed |= UInt64(1) << UInt64(3 - bit)
        xs.append(UInt64(i))
        rs.append(reversed << 60)
    xs.append(UInt64(0x5686487))
    rs.append(UInt64(0xE12616A000000000))
    xs.append(UInt64(0x0123456789ABCDEF))
    rs.append(UInt64(0xF7B3D591E6A2C480))

    for i in range(len(xs)):
        check_reverse(xs[i], rs[i])
        check_reverse(rs[i], xs[i])


def check_reverse_bytes(x64: UInt64, want64: UInt64) raises:
    """Go's `testReverseBytes`, read at three widths for the same reason."""
    assert_equal(reverse_bytes16(UInt16(x64 & 0xFFFF)), UInt16(want64 >> 48))
    assert_equal(
        reverse_bytes32(UInt32(x64 & 0xFFFFFFFF)), UInt32(want64 >> 32)
    )
    assert_equal(reverse_bytes64(x64), want64)
    assert_equal(reverse_bytes(UInt(x64)), UInt(want64))


def test_reverse_bytes() raises:
    """Go's `TestReverseBytes`, both ways round."""
    var xs: List[UInt64] = [
        UInt64(0),
        UInt64(0x01),
        UInt64(0x0123),
        UInt64(0x012345),
        UInt64(0x01234567),
        UInt64(0x0123456789),
        UInt64(0x0123456789AB),
        UInt64(0x0123456789ABCD),
        UInt64(0x0123456789ABCDEF),
    ]
    var rs: List[UInt64] = [
        UInt64(0),
        UInt64(0x01) << 56,
        UInt64(0x2301) << 48,
        UInt64(0x452301) << 40,
        UInt64(0x67452301) << 32,
        UInt64(0x8967452301) << 24,
        UInt64(0xAB8967452301) << 16,
        UInt64(0xCDAB8967452301) << 8,
        UInt64(0xEFCDAB8967452301),
    ]
    for i in range(len(xs)):
        check_reverse_bytes(xs[i], rs[i])
        check_reverse_bytes(rs[i], xs[i])


struct AddRow(Copyable, Movable):
    """Go's row: `x + y + c` is `z` with `cout` carried out of the top."""

    var x: UInt64
    var y: UInt64
    var c: UInt64
    var z: UInt64
    var cout: UInt64

    def __init__(
        out self, x: UInt64, y: UInt64, c: UInt64, z: UInt64, cout: UInt64
    ):
        self.x = x
        self.y = y
        self.c = c
        self.z = z
        self.cout = cout


def add_rows(top: UInt64) -> List[AddRow]:
    """Go's table, with `top` standing for the all ones value of the width.

    Go writes the same eleven rows three times over `_M`, `_M32` and `_M64`.
    One builder over the width's maximum is those three tables.
    """
    return [
        AddRow(0, 0, 0, 0, 0),
        AddRow(0, 1, 0, 1, 0),
        AddRow(0, 0, 1, 1, 0),
        AddRow(0, 1, 1, 2, 0),
        AddRow(12345, 67890, 0, 80235, 0),
        AddRow(12345, 67890, 1, 80236, 0),
        AddRow(top, 1, 0, 0, 1),
        AddRow(top, 0, 1, 0, 1),
        AddRow(top, 1, 1, 1, 1),
        AddRow(top, top, 0, top - 1, 1),
        AddRow(top, top, 1, top, 1),
    ]


def test_add_sub_uint() raises:
    """Go's `TestAddSubUint`. Every row is also its own subtraction, twice."""
    for row in add_rows(UInt64(_M)):
        var z, cout = add(UInt(row.x), UInt(row.y), UInt(row.c))
        assert_equal(z, UInt(row.z))
        assert_equal(cout, UInt(row.cout))

        var z2, cout2 = add(UInt(row.y), UInt(row.x), UInt(row.c))
        assert_equal(z2, UInt(row.z))
        assert_equal(cout2, UInt(row.cout))

        var d, bout = sub(UInt(row.z), UInt(row.x), UInt(row.c))
        assert_equal(d, UInt(row.y))
        assert_equal(bout, UInt(row.cout))

        var d2, bout2 = sub(UInt(row.z), UInt(row.y), UInt(row.c))
        assert_equal(d2, UInt(row.x))
        assert_equal(bout2, UInt(row.cout))


def test_add_sub_uint32() raises:
    """Go's `TestAddSubUint32`."""
    for row in add_rows(UInt64(_M32)):
        var z, cout = add32(UInt32(row.x), UInt32(row.y), UInt32(row.c))
        assert_equal(z, UInt32(row.z))
        assert_equal(cout, UInt32(row.cout))

        var z2, cout2 = add32(UInt32(row.y), UInt32(row.x), UInt32(row.c))
        assert_equal(z2, UInt32(row.z))
        assert_equal(cout2, UInt32(row.cout))

        var d, bout = sub32(UInt32(row.z), UInt32(row.x), UInt32(row.c))
        assert_equal(d, UInt32(row.y))
        assert_equal(bout, UInt32(row.cout))

        var d2, bout2 = sub32(UInt32(row.z), UInt32(row.y), UInt32(row.c))
        assert_equal(d2, UInt32(row.x))
        assert_equal(bout2, UInt32(row.cout))


def test_add_sub_uint64() raises:
    """Go's `TestAddSubUint64`."""
    for row in add_rows(_M64):
        var z, cout = add64(row.x, row.y, row.c)
        assert_equal(z, row.z)
        assert_equal(cout, row.cout)

        var z2, cout2 = add64(row.y, row.x, row.c)
        assert_equal(z2, row.z)
        assert_equal(cout2, row.cout)

        var d, bout = sub64(row.z, row.x, row.c)
        assert_equal(d, row.y)
        assert_equal(bout, row.cout)

        var d2, bout2 = sub64(row.z, row.y, row.c)
        assert_equal(d2, row.x)
        assert_equal(bout2, row.cout)


struct MulRow(Copyable, Movable):
    """Go's row: `x * y` is `(hi, lo)`, and `r` is a remainder to divide back
    out."""

    var x: UInt64
    var y: UInt64
    var hi: UInt64
    var lo: UInt64
    var r: UInt64

    def __init__(
        out self, x: UInt64, y: UInt64, hi: UInt64, lo: UInt64, r: UInt64
    ):
        self.x = x
        self.y = y
        self.hi = hi
        self.lo = lo
        self.r = r


def test_mul_div() raises:
    """Go's `TestMulDiv`: a product, then the division that undoes it."""
    var rows: List[MulRow] = [
        MulRow(UInt64(1) << 63, 2, 1, 0, 1),
        MulRow(UInt64(_M), UInt64(_M), UInt64(_M) - 1, 1, 42),
    ]
    for row in rows:
        var hi, lo = mul(UInt(row.x), UInt(row.y))
        assert_equal(hi, UInt(row.hi))
        assert_equal(lo, UInt(row.lo))

        var hi2, lo2 = mul(UInt(row.y), UInt(row.x))
        assert_equal(hi2, UInt(row.hi))
        assert_equal(lo2, UInt(row.lo))

        var q, r = div(UInt(row.hi), UInt(row.lo + row.r), UInt(row.y))
        assert_equal(q, UInt(row.x))
        assert_equal(r, UInt(row.r))

        var q2, r2 = div(UInt(row.hi), UInt(row.lo + row.r), UInt(row.x))
        assert_equal(q2, UInt(row.y))
        assert_equal(r2, UInt(row.r))


def test_mul_div32() raises:
    """Go's `TestMulDiv32`."""
    var rows: List[MulRow] = [
        MulRow(UInt64(1) << 31, 2, 1, 0, 1),
        MulRow(0xC47DFA8C, 50911, 0x98A4, 0x998587F4, 13),
        MulRow(UInt64(_M32), UInt64(_M32), UInt64(_M32) - 1, 1, 42),
    ]
    for row in rows:
        var hi, lo = mul32(UInt32(row.x), UInt32(row.y))
        assert_equal(hi, UInt32(row.hi))
        assert_equal(lo, UInt32(row.lo))

        var hi2, lo2 = mul32(UInt32(row.y), UInt32(row.x))
        assert_equal(hi2, UInt32(row.hi))
        assert_equal(lo2, UInt32(row.lo))

        var q, r = div32(UInt32(row.hi), UInt32(row.lo + row.r), UInt32(row.y))
        assert_equal(q, UInt32(row.x))
        assert_equal(r, UInt32(row.r))

        var q2, r2 = div32(
            UInt32(row.hi), UInt32(row.lo + row.r), UInt32(row.x)
        )
        assert_equal(q2, UInt32(row.y))
        assert_equal(r2, UInt32(row.r))


def test_mul_div64() raises:
    """Go's `TestMulDiv64`."""
    var rows: List[MulRow] = [
        MulRow(UInt64(1) << 63, 2, 1, 0, 1),
        MulRow(
            0x3626229738A3B9,
            0xD8988A9F1CC4A61,
            0x2DD0712657FE8,
            0x9DD6A3364C358319,
            13,
        ),
        MulRow(_M64, _M64, _M64 - 1, 1, 42),
    ]
    for row in rows:
        var hi, lo = mul64(row.x, row.y)
        assert_equal(hi, row.hi)
        assert_equal(lo, row.lo)

        var hi2, lo2 = mul64(row.y, row.x)
        assert_equal(hi2, row.hi)
        assert_equal(lo2, row.lo)

        var q, r = div64(row.hi, row.lo + row.r, row.y)
        assert_equal(q, row.x)
        assert_equal(r, row.r)

        var q2, r2 = div64(row.hi, row.lo + row.r, row.x)
        assert_equal(q2, row.y)
        assert_equal(r2, row.r)


def test_a_quotient_that_does_not_fit_is_refused() raises:
    """Go's three `TestDivPanicOverflow` tests, as raises.

    `y <= hi` means the quotient needs more bits than the return has. Go
    panics with the runtime's `integer overflow`; the code here says the same
    thing to a caller who can act on it.
    """
    for shape in range(3):
        var raised = False
        try:
            if shape == 0:
                _ = div(UInt(1), UInt(0), UInt(1))
            elif shape == 1:
                _ = div32(UInt32(1), UInt32(0), UInt32(1))
            else:
                _ = div64(UInt64(1), UInt64(0), UInt64(1))
        except e:
            raised = True
            assert_true(matches(e, ErrOverflow))
        assert_true(raised, "a quotient that does not fit should be refused")


def test_a_zero_divisor_is_refused() raises:
    """Go's three `TestDivPanicZero` tests, as raises."""
    for shape in range(3):
        var raised = False
        try:
            if shape == 0:
                _ = div(UInt(1), UInt(1), UInt(0))
            elif shape == 1:
                _ = div32(UInt32(1), UInt32(1), UInt32(0))
            else:
                _ = div64(UInt64(1), UInt64(1), UInt64(0))
        except e:
            raised = True
            assert_true(matches(e, ErrDivideByZero))
        assert_true(raised, "a zero divisor should be refused")

    with assert_raises():
        _ = rem(UInt(1), UInt(1), UInt(0))
    with assert_raises():
        _ = rem32(UInt32(1), UInt32(1), UInt32(0))
    with assert_raises():
        _ = rem64(UInt64(1), UInt64(1), UInt64(0))


def test_rem32() raises:
    """Go's `TestRem32`: where the quotient fits, `rem32` is `div32`'s
    remainder."""
    var hi = UInt32(510510)
    var lo = UInt32(9699690)
    var y = UInt32(510510 + 1)
    for _ in range(1000):
        var r = rem32(hi, lo, y)
        var _q, r2 = div32(hi, lo, y)
        assert_equal(r, r2)
        y += 13


def test_rem32_where_the_quotient_would_not_fit() raises:
    """Go's `TestRem32Overflow`. `div32` would refuse these; the remainder
    exists anyway and `rem32` is the function that returns it."""
    var hi = UInt32(510510)
    var lo = UInt32(9699690)
    var y = UInt32(7)
    for _ in range(1000):
        var r = rem32(hi, lo, y)
        var _q, r2 = div64(
            UInt64(0), (UInt64(hi) << 32) | UInt64(lo), UInt64(y)
        )
        assert_equal(UInt64(r), r2)
        y += 13


def test_rem64() raises:
    """Go's `TestRem64`, the same check one width up."""
    var hi = UInt64(510510)
    var lo = UInt64(9699690)
    var y = UInt64(510510 + 1)
    for _ in range(1000):
        var r = rem64(hi, lo, y)
        var _q, r2 = div64(hi, lo, y)
        assert_equal(r, r2)
        y += 13


struct RemRow(Copyable, Movable):
    """Go's `Rem64Tests` row, every one of them a quotient that overflows."""

    var hi: UInt64
    var lo: UInt64
    var y: UInt64
    var rem: UInt64

    def __init__(out self, hi: UInt64, lo: UInt64, y: UInt64, rem: UInt64):
        self.hi = hi
        self.lo = lo
        self.y = y
        self.rem = rem


def test_rem64_where_the_quotient_would_not_fit() raises:
    """Go's `TestRem64Overflow`, whose answers Go computed in Python."""
    var rows: List[RemRow] = [
        RemRow(42, 1119, 42, 27),
        RemRow(42, 1119, 38, 9),
        RemRow(42, 1119, 26, 23),
        RemRow(469, 0, 467, 271),
        RemRow(469, 0, 113, 58),
        RemRow(111111, 111111, 1171, 803),
        RemRow(3968194946088682615, 3192705705065114702, 1000037, 56067),
    ]
    for row in rows:
        assert_true(row.hi >= row.y, "this row is not a quotient overflow")
        assert_equal(rem64(row.hi, row.lo, row.y), row.rem)
