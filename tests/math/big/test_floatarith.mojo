"""Go's `TestFloatInc` through `TestFloatCmpSpecialValues`, from `float_test.go`.

The four operations and the comparison. Most of the checking is done against
`_bits.mojo`, which works the same answers out from a list of exponents and
shares no code with the package, so a mistake in one of them does not hide in
the other. The rest is checked against `Float64` arithmetic, which the hardware
does, at the precisions where the two have to agree.

Go writes `new(Float).SetPrec(prec).SetMode(mode).Add(x, y)`, where the
destination carries both settings. There is no destination here: the precision
is an argument and the rounding mode comes from the left operand, so `_at` makes
a copy of the left operand with the mode set on it.
"""

from std.testing import assert_equal, assert_true

from core.math import float64frombits, is_nan
from core.strconv import format_int, parse_int
import core.math.big as big
from core.math.big.rounding import RoundingMode

from tests.math.big._bits import (
    bits_add,
    bits_float,
    bits_list,
    bits_mul,
    bits_round,
    bits_string,
    prec_list,
)
from tests.math.big._fixtures import alike, f


def _at(x: big.Float, mode: RoundingMode) -> big.Float:
    """`x` with `mode` set on it, so that an operation on it rounds that way.

    Go's `SetMode` on the destination.
    """
    var z = x.copy()
    z.set_mode(mode)
    return z^


def _rounding_modes() -> List[RoundingMode]:
    """The three modes the `Bits` comparison runs, which are the ones
    `bits_round` implements."""
    var out: List[RoundingMode] = [
        big.ToZero,
        big.ToNearestEven,
        big.AwayFromZero,
    ]
    return out^


def _where(prec: Int, mode: RoundingMode) raises -> String:
    """A prefix naming the precision and the mode a row failed at."""
    return String("prec ") + format_int(Int64(prec), 10) + " " + mode.string()


def test_inc() raises:
    # Go's `TestFloatInc`. Adding one ten times gives ten, at any precision
    # wide enough to hold the numbers along the way.
    #
    # Go skips a precision when `1<<prec < n`, which is meant to be that test
    # and which also skips every precision of sixty three or more, because the
    # shift overflows a machine integer and comes out zero or negative. Four
    # bits hold ten, so this runs everything from four bits up and the wide
    # precisions are actually tested.
    comptime n = 10
    var one = big.Float()
    one.set_int64(1)
    var want = big.Float()
    want.set_int64(n)

    for prec in prec_list():
        if prec < 4:
            continue
        var x = big.Float()
        x.set_prec(prec)
        for _ in range(n):
            x = x.add(one, prec)
        assert_equal(x.cmp(want), 0, _where(prec, x.mode()))


def test_add() raises:
    # Go's `TestFloatAdd`. Every pair from `bits_list` added and subtracted at
    # every precision in every mode, against the answer `_bits.mojo` works out
    # on its own.
    var bl = bits_list()
    for xbits in bl:
        for ybits in bl:
            var x = bits_float(xbits)
            var y = bits_float(ybits)
            var zbits = bits_add(xbits, ybits)
            var z = bits_float(zbits)

            for mode in _rounding_modes():
                for prec in prec_list():
                    var got = _at(x, mode).add(y, prec)
                    var want = bits_round(zbits, prec, mode)
                    assert_equal(
                        got.cmp(want),
                        0,
                        _where(prec, mode)
                        + ": "
                        + bits_string(xbits)
                        + " + "
                        + bits_string(ybits),
                    )

                    var d = _at(z, mode).sub(x, prec)
                    var dwant = bits_round(ybits, prec, mode)
                    assert_equal(
                        d.cmp(dwant),
                        0,
                        _where(prec, mode)
                        + ": "
                        + bits_string(zbits)
                        + " - "
                        + bits_string(xbits),
                    )


def test_add_rounding_to_zero() raises:
    # Go's `TestFloatAddRoundZero`. A sum that lands exactly on zero is a
    # positive zero in every mode but the one that rounds towards negative
    # infinity, where it is a negative one.
    var modes: List[RoundingMode] = [
        big.ToNearestEven,
        big.ToNearestAway,
        big.ToZero,
        big.AwayFromZero,
        big.ToPositiveInf,
        big.ToNegativeInf,
    ]
    for mode in modes:
        var x = big.new_float(5.0)
        var y = x.neg()
        var want = big.new_float(0.0)
        if mode == big.ToNegativeInf:
            want = want.neg()

        var got = _at(x, mode).add(y)
        assert_equal(got.cmp(want), 0, mode.string())
        assert_equal(got.signbit(), mode == big.ToNegativeInf, mode.string())

        var diff = _at(x, mode).sub(x)
        assert_equal(diff.cmp(want), 0, mode.string())
        assert_equal(diff.signbit(), mode == big.ToNegativeInf, mode.string())


def test_add_at_24_bits_matches_float32() raises:
    # Go's `TestFloatAdd32`. Twenty four bits is a `Float32` mantissa, so
    # adding and subtracting there has to give exactly what the hardware gives,
    # for a base chosen to sit right on the edge of what fits.
    comptime base = Float64((1 << 26) - 0x10)  # 26 bits, ending in four zeros
    for d in range(0x11):
        for i in range(2):
            var x0 = base
            var y0 = Float64(d)
            if i & 1 != 0:
                x0 = Float64(d)
                y0 = base

            var x = big.new_float(x0)
            var y = big.new_float(y0)
            var z = x.add(y, 24)

            var got, acc = z.float32()
            var want = Float32(y0) + Float32(x0)
            assert_equal(got, want, String("add ") + format_int(Int64(d), 10))
            assert_equal(
                acc, big.Exact, String("add ") + format_int(Int64(d), 10)
            )

            var z2 = z.sub(y, 24)
            var got2, acc2 = z2.float32()
            var want2 = want - Float32(y0)
            assert_equal(got2, want2, String("sub ") + format_int(Int64(d), 10))
            assert_equal(
                acc2, big.Exact, String("sub ") + format_int(Int64(d), 10)
            )


def test_add_at_53_bits_matches_float64() raises:
    # Go's `TestFloatAdd64`. The same at a `Float64` mantissa width.
    comptime base = Float64((1 << 55) - 0x10)  # 55 bits, ending in four zeros
    for d in range(0x11):
        for i in range(2):
            var x0 = base
            var y0 = Float64(d)
            if i & 1 != 0:
                x0 = Float64(d)
                y0 = base

            var x = big.new_float(x0)
            var y = big.new_float(y0)
            var z = x.add(y, 53)

            var got, acc = z.float64()
            var want = x0 + y0
            assert_equal(got, want, String("add ") + format_int(Int64(d), 10))
            assert_equal(
                acc, big.Exact, String("add ") + format_int(Int64(d), 10)
            )

            var z2 = z.sub(y, 53)
            var got2, acc2 = z2.float64()
            var want2 = want - y0
            assert_equal(got2, want2, String("sub ") + format_int(Int64(d), 10))
            assert_equal(
                acc2, big.Exact, String("sub ") + format_int(Int64(d), 10)
            )


def test_writing_a_result_over_an_operand() raises:
    # Go's `TestIssue20490`. Go is checking that a destination which aliases an
    # operand still gives the same answer, which was a real bug in `Sub`. There
    # is no destination here, so what is left to check is that assigning the
    # answer back over the operand it was computed from gives the same number,
    # which is the value semantics doing the same job.
    var rows: List[List[Float64]] = [
        [4, 1],
        [-4, 1],
        [4, -1],
        [-4, -1],
    ]
    for r in rows:
        var a = big.new_float(r[0])
        var b = big.new_float(r[1])

        var diff = a.sub(b)
        b = a.sub(b)
        assert_equal(b.cmp(diff), 0, "sub")

        b = big.new_float(r[1])
        var sum = a.add(b)
        b = a.add(b)
        assert_equal(b.cmp(sum), 0, "add")


def test_mul() raises:
    # Go's `TestFloatMul`. Every pair from `bits_list` multiplied and divided
    # at every precision in every mode, against `_bits.mojo` again.
    var bl = bits_list()
    for xbits in bl:
        for ybits in bl:
            var x = bits_float(xbits)
            var y = bits_float(ybits)
            var zbits = bits_mul(xbits, ybits)
            var z = bits_float(zbits)

            for mode in _rounding_modes():
                for prec in prec_list():
                    var got = _at(x, mode).mul(y, prec)
                    var want = bits_round(zbits, prec, mode)
                    assert_equal(
                        got.cmp(want),
                        0,
                        _where(prec, mode)
                        + ": "
                        + bits_string(xbits)
                        + " * "
                        + bits_string(ybits),
                    )

                    if x.sign() == 0:
                        # Nothing divided by zero is a number, so there is no
                        # row to check back.
                        continue
                    var d = _at(z, mode).quo(x, prec)
                    var dwant = bits_round(ybits, prec, mode)
                    assert_equal(
                        d.cmp(dwant),
                        0,
                        _where(prec, mode)
                        + ": "
                        + bits_string(zbits)
                        + " / "
                        + bits_string(xbits),
                    )


def test_mul_at_53_bits_matches_float64() raises:
    # Go's `TestFloatMul64`. Multiplying and dividing at a `Float64` mantissa
    # width has to give what the hardware gives, over both signs of both
    # operands and both orders.
    var rows: List[List[Float64]] = [
        [0, 0],
        [0, 1],
        [1, 1],
        [1, 1.5],
        [1.234, 0.5678],
        [2.718281828, 3.14159265358979],
        [2.718281828e10, 3.14159265358979e-32],
        [1.0 / 3, 1e200],
    ]
    for r in rows:
        for i in range(8):
            var x0 = r[0]
            var y0 = r[1]
            if i & 1 != 0:
                x0 = -x0
            if i & 2 != 0:
                y0 = -y0
            if i & 4 != 0:
                var t = x0
                x0 = y0
                y0 = t

            var x = big.new_float(x0)
            var y = big.new_float(y0)
            var z = x.mul(y, 53)

            var got, _ = z.float64()
            var want = x0 * y0
            assert_equal(got, want, "mul")

            if y0 == 0:
                continue
            var z2 = z.quo(y, 53)
            var got2, _ = z2.float64()
            assert_equal(got2, want / y0, "quo")


def test_two_ways_of_writing_zero_agree() raises:
    # Go's `TestIssue6866`. Two plus a third times minus six, and two minus a
    # third times plus six, are both zero at every precision. They were not,
    # because the sign was applied after the rounding rather than before.
    for prec in prec_list():
        var two = big.Float()
        two.set_prec(prec)
        two.set_int64(2)
        var one = big.Float()
        one.set_prec(prec)
        one.set_int64(1)
        var three = big.Float()
        three.set_prec(prec)
        three.set_int64(3)
        var msix = big.Float()
        msix.set_prec(prec)
        msix.set_int64(-6)
        var psix = big.Float()
        psix.set_prec(prec)
        psix.set_int64(6)

        var z1 = two.add(one.quo(three, prec).mul(msix, prec), prec)
        var z2 = two.sub(one.quo(three, prec).mul(psix, prec), prec)

        assert_equal(z1.cmp(z2), 0, _where(prec, big.ToNearestEven))
        assert_equal(z1.sign(), 0, _where(prec, big.ToNearestEven))
        assert_equal(z2.sign(), 0, _where(prec, big.ToNearestEven))


def test_quo() raises:
    # Go's `TestFloatQuo`. Build an exact `x` as `z * y`, then check that
    # dividing it back by `y` at a range of precisions and modes gives `z`
    # rounded the same way `_bits.mojo` rounds it.
    comptime preci = 200  # bits of integer part
    comptime precf = 20  # bits of fractional part

    for i in range(8):
        var bits: List[Int] = [preci - 1]
        if i & 3 != 0:
            bits.append(0)
        if i & 2 != 0:
            bits.append(-1)
        if i & 1 != 0:
            bits.append(-precf)
        var z = bits_float(bits)

        var y = big.new_float(3.14159265358979323e123)
        var x = _at(z, big.ToZero).mul(y, z.prec() + y.prec())
        assert_equal(x.acc(), big.Exact, "the product has to be exact")

        for mode in _rounding_modes():
            for d in range(-5, 5):
                var prec = preci + d
                var got = _at(x, mode).quo(y, prec)
                var want = bits_round(bits, prec, mode)
                assert_equal(
                    got.cmp(want),
                    0,
                    _where(prec, mode) + ": " + bits_string(bits),
                )


def test_quo_smoke() raises:
    # Go's `TestFloatQuoSmoke`. Every quotient of two small whole numbers, with
    # the operand precisions varied around a width that still holds them
    # exactly, has to come out as the `Float64` division does.
    comptime n = 10
    comptime dprec = 3  # how far the operand precision moves
    comptime prec = 10 + dprec  # enough bits for every numerator here

    for x in range(-n, n + 1):
        for y in range(-n, n):
            if y == 0:
                continue
            var a = Float64(x)
            var b = Float64(y)
            var c = a / b

            for ad in range(-dprec, dprec + 1):
                for bd in range(-dprec, dprec + 1):
                    var af = big.Float()
                    af.set_prec(prec + ad)
                    af.set_float64(a)
                    var bf = big.Float()
                    bf.set_prec(prec + bd)
                    bf.set_float64(b)

                    var cf = af.quo(bf, 53)
                    var got, acc = cf.float64()
                    assert_equal(got, c, "quo")
                    assert_equal(acc, big.Exact, "quo")


def _special_args() raises -> List[Float64]:
    """Go's `args` in the special value tests: the two infinities, a signed
    zero, a whole number and one that is not."""
    var out: List[Float64] = [
        float64frombits(0xFFF0000000000000),  # -Inf
        -2.71828,
        -1.0,
        float64frombits(0x8000000000000000),  # -0
        0.0,
        1.0,
        2.71828,
        float64frombits(0x7FF0000000000000),  # +Inf
    ]
    return out^


def _apply(op: Int, x: big.Float, y: big.Float) raises -> big.Float:
    """The `op`th of the four operations, in the order Go's switch has them."""
    if op == 0:
        return x.add(y)
    if op == 1:
        return x.sub(y)
    if op == 2:
        return x.mul(y)
    return x.quo(y)


def _apply64(op: Int, x: Float64, y: Float64) -> Float64:
    """The same four on machine numbers."""
    if op == 0:
        return x + y
    if op == 1:
        return x - y
    if op == 2:
        return x * y
    return x / y


def _op_name(op: Int) -> String:
    """The `op`th operator as a character, for a message."""
    var names: List[String] = ["+", "-", "*", "/"]
    return names[op]


def test_arithmetic_on_special_values() raises:
    # Go's `TestFloatArithmeticSpecialValues`. The zeros, the infinities and
    # two ordinary numbers through the four operations, against what the
    # hardware does with the same values.
    #
    # Where the hardware makes a NaN there is no answer to return, because a
    # `Float` has no NaN. Go panics with `ErrNaN` and this raises it, so the
    # rows that Go recovers from are the rows caught here.
    var args = _special_args()
    for op in range(4):
        for x in args:
            var xx = big.Float()
            xx.set_float64(x)

            var back, acc = xx.float64()
            assert_equal(back, x, "the conversion has to be exact")
            assert_equal(acc, big.Exact, "the conversion has to be exact")

            for y in args:
                var yy = big.Float()
                yy.set_float64(y)
                var z = _apply64(op, x, y)

                var raised = False
                var got = big.Float()
                try:
                    got = _apply(op, xx, yy)
                except:
                    raised = True

                if is_nan(z):
                    assert_true(
                        raised, String("want a raise for ") + _op_name(op)
                    )
                    continue

                assert_true(
                    not raised, String("want a number for ") + _op_name(op)
                )
                var want = big.Float()
                want.set_float64(z)
                assert_true(alike(got, want), String("op ") + _op_name(op))


def test_arithmetic_overflow_and_underflow() raises:
    # Go's `TestFloatArithmeticOverflow`. An exponent that runs past `MaxExp`
    # becomes an infinity and one that runs past `MinExp` becomes a zero, and
    # the accuracy says which way the number went. The columns are the
    # precision, the mode, the operator, the two operands, the answer and the
    # accuracy.
    var rows: List[List[String]] = [
        ["4", "ToNearestEven", "+", "0", "0", "0", "Exact"],
        ["4", "ToNearestEven", "+", "0x.8p+0", "0x.8p+0", "0x.8p+1", "Exact"],
        # An exponent right at the top is fine on its own.
        [
            "4",
            "ToNearestEven",
            "+",
            "0",
            "0x.8p2147483647",
            "0x.8p+2147483647",
            "Exact",
        ],
        # The smaller operand falls off the bottom of the mantissa.
        [
            "4",
            "ToNearestEven",
            "+",
            "0x.8p2147483500",
            "0x.8p2147483647",
            "0x.8p+2147483647",
            "Below",
        ],
        # The sum needs one more exponent than there is.
        [
            "4",
            "ToNearestEven",
            "+",
            "0x.8p2147483647",
            "0x.8p2147483647",
            "+Inf",
            "Above",
        ],
        [
            "4",
            "ToNearestEven",
            "+",
            "-0x.8p2147483647",
            "-0x.8p2147483647",
            "-Inf",
            "Below",
        ],
        [
            "4",
            "ToNearestEven",
            "-",
            "-0x.8p2147483647",
            "0x.8p2147483647",
            "-Inf",
            "Below",
        ],
        # The rounding itself is what pushes the exponent over, so the answer
        # depends on which way the mode rounds.
        [
            "4",
            "ToZero",
            "+",
            "0x.fp2147483647",
            "0x.8p2147483643",
            "0x.fp+2147483647",
            "Below",
        ],
        [
            "4",
            "ToNearestEven",
            "+",
            "0x.fp2147483647",
            "0x.8p2147483643",
            "+Inf",
            "Above",
        ],
        [
            "4",
            "AwayFromZero",
            "+",
            "0x.fp2147483647",
            "0x.8p2147483643",
            "+Inf",
            "Above",
        ],
        [
            "4",
            "AwayFromZero",
            "-",
            "-0x.fp2147483647",
            "0x.8p2147483644",
            "-Inf",
            "Below",
        ],
        [
            "4",
            "ToNearestEven",
            "-",
            "-0x.fp2147483647",
            "0x.8p2147483643",
            "-Inf",
            "Below",
        ],
        [
            "4",
            "ToZero",
            "-",
            "-0x.fp2147483647",
            "0x.8p2147483643",
            "-0x.fp+2147483647",
            "Above",
        ],
        # The bottom of the exponent range, where nothing overflows.
        [
            "4",
            "ToNearestEven",
            "+",
            "0",
            "0x.8p-2147483648",
            "0x.8p-2147483648",
            "Exact",
        ],
        [
            "4",
            "ToNearestEven",
            "+",
            "0x.8p-2147483648",
            "0x.8p-2147483648",
            "0x.8p-2147483647",
            "Exact",
        ],
        [
            "4",
            "ToNearestEven",
            "*",
            "1",
            "0x.8p2147483647",
            "0x.8p+2147483647",
            "Exact",
        ],
        [
            "4",
            "ToNearestEven",
            "*",
            "2",
            "0x.8p2147483647",
            "+Inf",
            "Above",
        ],
        [
            "4",
            "ToNearestEven",
            "*",
            "-2",
            "0x.8p2147483647",
            "-Inf",
            "Below",
        ],
        [
            "4",
            "ToNearestEven",
            "/",
            "0.5",
            "0x.8p2147483647",
            "0x.8p-2147483646",
            "Exact",
        ],
        [
            "4",
            "ToNearestEven",
            "/",
            "0x.8p+0",
            "0x.8p2147483647",
            "0x.8p-2147483646",
            "Exact",
        ],
        [
            "4",
            "ToNearestEven",
            "/",
            "0x.8p-1",
            "0x.8p2147483647",
            "0x.8p-2147483647",
            "Exact",
        ],
        [
            "4",
            "ToNearestEven",
            "/",
            "0x.8p-2",
            "0x.8p2147483647",
            "0x.8p-2147483648",
            "Exact",
        ],
        # One step further down and there is no exponent left, so the answer
        # is a zero the number is above.
        [
            "4",
            "ToNearestEven",
            "/",
            "0x.8p-3",
            "0x.8p2147483647",
            "0",
            "Below",
        ],
    ]
    for r in rows:
        var prec = Int(_dec(r[0]))
        var mode = _mode_named(r[1])
        var x = f(r[3])
        var y = f(r[4])
        var op = _op_index(r[2])

        var z = _apply_at(op, _at(x, mode), y, prec)
        var label = r[3] + " " + r[2] + " " + r[4]
        assert_equal(z.text(UInt8(ord("p")), 0), r[5], label)
        assert_equal(z.acc().string(), r[6], label)


def test_rounding_happens_after_the_sign_is_set() raises:
    # Go's `TestFloatArithmeticRounding`. The two modes that round towards an
    # infinity care which side of zero the answer is on, so the sign has to be
    # decided first. These rows are the ones that come out wrong if it is not.
    # The columns are the mode, the precision, the two operands, the answer and
    # the operator.
    var rows: List[List[String]] = [
        ["ToZero", "3", "-8", "-1", "-8", "+"],
        ["AwayFromZero", "3", "-8", "-1", "-10", "+"],
        ["ToNegativeInf", "3", "-8", "-1", "-10", "+"],
        ["ToZero", "3", "-8", "1", "-8", "-"],
        ["AwayFromZero", "3", "-8", "1", "-10", "-"],
        ["ToNegativeInf", "3", "-8", "1", "-10", "-"],
        ["ToZero", "3", "-9", "1", "-8", "*"],
        ["AwayFromZero", "3", "-9", "1", "-10", "*"],
        ["ToNegativeInf", "3", "-9", "1", "-10", "*"],
        ["ToZero", "3", "-9", "1", "-8", "/"],
        ["AwayFromZero", "3", "-9", "1", "-10", "/"],
        ["ToNegativeInf", "3", "-9", "1", "-10", "/"],
    ]
    for r in rows:
        var mode = _mode_named(r[0])
        var prec = Int(_dec(r[1]))
        var x = big.Float()
        x.set_int64(_dec(r[2]))
        var y = big.Float()
        y.set_int64(_dec(r[3]))

        var z = _apply_at(_op_index(r[5]), _at(x, mode), y, prec)
        var got, acc = z.int64()
        var label = r[0] + " " + r[2] + " " + r[5] + " " + r[3]
        assert_equal(got, _dec(r[4]), label)
        assert_equal(acc, big.Exact, label)


def test_cmp_on_special_values() raises:
    # Go's `TestFloatCmpSpecialValues`. Comparing the zeros, the infinities and
    # two ordinary numbers has to order them the way the machine numbers order.
    var args = _special_args()
    for x in args:
        var xx = big.Float()
        xx.set_float64(x)

        var back, acc = xx.float64()
        assert_equal(back, x, "the conversion has to be exact")
        assert_equal(acc, big.Exact, "the conversion has to be exact")

        for y in args:
            var yy = big.Float()
            yy.set_float64(y)
            var want = 0
            if x < y:
                want = -1
            elif x > y:
                want = 1
            assert_equal(xx.cmp(yy), want, "cmp")


def _apply_at(
    op: Int, x: big.Float, y: big.Float, prec: Int
) raises -> big.Float:
    """The `op`th operation at `prec` bits, rounded the way `x` says."""
    if op == 0:
        return x.add(y, prec)
    if op == 1:
        return x.sub(y, prec)
    if op == 2:
        return x.mul(y, prec)
    return x.quo(y, prec)


def _dec(s: String) raises -> Int64:
    """The whole number written in `s` in decimal.

    The tables here hold their numbers as strings, the way Go's do, so that a
    row reads as one line.
    """
    return parse_int(s, 10, 64)


def _op_index(op: String) raises -> Int:
    """Where `op` sits in the order the four operations are written in."""
    if op == "+":
        return 0
    if op == "-":
        return 1
    if op == "*":
        return 2
    if op == "/":
        return 3
    raise Error("no such operator: " + op)


def _mode_named(name: String) raises -> RoundingMode:
    """The rounding mode Go prints as `name`.

    The tables are written with the names rather than the numbers, which is
    what Go's own tables hold, and this reads them back.
    """
    if name == "ToNearestEven":
        return big.ToNearestEven
    if name == "ToNearestAway":
        return big.ToNearestAway
    if name == "ToZero":
        return big.ToZero
    if name == "AwayFromZero":
        return big.AwayFromZero
    if name == "ToNegativeInf":
        return big.ToNegativeInf
    if name == "ToPositiveInf":
        return big.ToPositiveInf
    raise Error("no such rounding mode: " + name)
