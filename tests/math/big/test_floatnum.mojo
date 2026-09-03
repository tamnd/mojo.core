"""Go's `TestFloatSetFloat64` through `TestFloatRat`, from `float_test.go`.

A `Float` and a machine number, in both directions: setting one from a
`Float64`, an `Int` or a `Rat`, and reading one back out as an integer, a
`Float32`, a `Float64`, an `Int` or a `Rat`. `test_float.mojo` has the shape of
the type and `test_floatarith.mojo` has the arithmetic.

The two big tables here are the denormal boundaries of `Float32` and
`Float64`. They are the rows that catch a rounding step which forgets that the
mantissa of a subnormal number is shorter than a normal one, and Go collected
several of them from bugs that got as far as a release. Every row is checked
twice, once as written and once negated, and cross checked against
`core.strconv` wherever the string is one `parse_float` accepts.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.math import (
    float32frombits,
    float64frombits,
    MAX_FLOAT32,
    MAX_FLOAT64,
    nan,
    signbit,
    SMALLEST_NONZERO_FLOAT32,
    SMALLEST_NONZERO_FLOAT64,
)
from core.strconv import parse_float, parse_int
import core.math.big as big

from tests.math.big._fixtures import f, p, q


def _acc_named(name: String) raises -> big.Accuracy:
    """The accuracy Go prints as `name`."""
    if name == "Exact":
        return big.Exact
    if name == "Below":
        return big.Below
    if name == "Above":
        return big.Above
    raise Error("no such accuracy: " + name)


def _flip(a: big.Accuracy) -> big.Accuracy:
    """The accuracy of the negated number. Go writes it as `-acc`.

    A number that was above its answer is below the negation of it, and an
    exact one stays exact.
    """
    if a == big.Below:
        return big.Above
    if a == big.Above:
        return big.Below
    return big.Exact


def _alike32(x: Float32, y: Float32) -> Bool:
    """Whether these are the same number and the same sign. Go's `alike32`.

    Nothing here produces a NaN, so the only thing plain equality misses is
    that a positive and a negative zero compare equal.
    """
    return x == y and signbit(Float64(x)) == signbit(Float64(y))


def _alike64(x: Float64, y: Float64) -> Bool:
    """Whether these are the same number and the same sign. Go's `alike64`."""
    return x == y and signbit(x) == signbit(y)


def test_set_float64() raises:
    # Go's `TestFloatSetFloat64`. Every `Float64` goes in and comes back out
    # unchanged and exact, because fifty three bits always fit.
    var values: List[Float64] = [
        0,
        1,
        2,
        12345,
        1e10,
        1e100,
        3.14159265e10,
        2.718281828e-123,
        1.0 / 3,
        Float64(MAX_FLOAT32),
        MAX_FLOAT64,
        Float64(SMALLEST_NONZERO_FLOAT32),
        SMALLEST_NONZERO_FLOAT64,
        float64frombits(0xFFF0000000000000),  # -Inf
        float64frombits(0x7FF0000000000000),  # +Inf
    ]
    for v in values:
        for i in range(2):
            var want = v
            if i != 0:
                want = -want
            var z = big.Float()
            z.set_float64(want)
            var got, acc = z.float64()
            assert_true(_alike64(got, want), z.text(UInt8(ord("p")), 0))
            assert_equal(acc, big.Exact, z.text(UInt8(ord("p")), 0))

    # Rounding on the way in, at every width narrower than the number needs.
    # The exhaustive rounding table is in `test_float.mojo`; this is the check
    # that `set_float64` goes through it at all.
    comptime x = UInt64(0x8765432143218)  # takes 53 bits
    for prec in range(1, 53):
        var z = big.Float()
        z.set_prec(prec)
        z.set_mode(big.ToZero)
        z.set_float64(Float64(x))
        var got, _ = z.float64()
        # The low `53 - prec` bits are the ones that fall off.
        var mask = (UInt64(1) << UInt64(52 - prec)) - 1
        assert_equal(got, Float64(x & ~mask), z.text(UInt8(ord("p")), 0))


def test_set_float64_refuses_a_nan() raises:
    # The tail of Go's `TestFloatSetFloat64`, where Go panics with `ErrNaN`. A
    # `Float` has no NaN to be set to, so there is nothing to return and this
    # raises.
    var z = big.Float()
    with assert_raises(contains="NaN"):
        z.set_float64(nan())


def test_set_int() raises:
    # Go's `TestFloatSetInt`. An integer arrives exactly, and the precision is
    # the number of bits it takes or sixty four, whichever is more.
    var values: List[String] = [
        "0",
        "1",
        "-1",
        "1234567890",
        "123456789012345678901234567890",
        (
            "123456789012345678901234567890123456789012345678901234567890"
            "123456789012345678901234567890"
        ),
    ]
    for want in values:
        var x = p(want)
        var n = x.bit_len()
        if n < 64:
            n = 64

        var z = big.Float()
        z.set_int(x)
        assert_equal(z.prec(), n, want)
        assert_equal(z.text(UInt8(ord("g")), 100), want, want)


def test_set_rat() raises:
    # Go's `TestFloatSetRat`. A fraction arrives at the width of its wider
    # half, or sixty four, and a thousand bits is enough to write every one of
    # these back out in full.
    var values: List[String] = [
        "0",
        "1",
        "-1",
        "1234567890",
        "123456789012345678901234567890",
        (
            "123456789012345678901234567890123456789012345678901234567890"
            "123456789012345678901234567890"
        ),
        "1.2",
        "3.14159265",
    ]
    for want in values:
        var x = q(want)
        var n = x.num().bit_len()
        if x.denom().bit_len() > n:
            n = x.denom().bit_len()
        if n < 64:
            n = 64

        var f1 = big.Float()
        f1.set_rat(x)
        assert_equal(f1.prec(), n, want)

        var f2 = big.Float()
        f2.set_prec(1000)
        f2.set_rat(x)
        assert_equal(f2.text(UInt8(ord("g")), 100), want, want)


def test_uint64() raises:
    # Go's `TestFloatUint64`. Anything below zero clamps to zero and anything
    # above the range clamps to the largest one, and the accuracy says which
    # way the answer moved. The columns are the number, what comes out and the
    # accuracy.
    var rows: List[List[String]] = [
        ["-Inf", "0", "Above"],
        ["-1", "0", "Above"],
        ["-1e-1000", "0", "Above"],
        ["-0", "0", "Exact"],
        ["0", "0", "Exact"],
        ["1e-1000", "0", "Below"],
        ["1", "1", "Exact"],
        ["1.000000000000000000001", "1", "Below"],
        ["12345.0", "12345", "Exact"],
        ["12345.000000000000000000001", "12345", "Below"],
        ["18446744073709551615", "18446744073709551615", "Exact"],
        [
            "18446744073709551615.000000000000000000001",
            "18446744073709551615",
            "Below",
        ],
        ["18446744073709551616", "18446744073709551615", "Below"],
        ["1e10000", "18446744073709551615", "Below"],
        ["+Inf", "18446744073709551615", "Below"],
    ]
    for r in rows:
        var got, acc = f(r[0]).uint64()
        assert_equal(got, _udec(r[1]), r[0])
        assert_equal(acc, _acc_named(r[2]), r[0])


def test_int64() raises:
    # Go's `TestFloatInt64`. The same at both ends of the signed range.
    var rows: List[List[String]] = [
        ["-Inf", "-9223372036854775808", "Above"],
        ["-1e10000", "-9223372036854775808", "Above"],
        ["-9223372036854775809", "-9223372036854775808", "Above"],
        [
            "-9223372036854775808.000000000000000000001",
            "-9223372036854775808",
            "Above",
        ],
        ["-9223372036854775808", "-9223372036854775808", "Exact"],
        [
            "-9223372036854775807.000000000000000000001",
            "-9223372036854775807",
            "Above",
        ],
        ["-9223372036854775807", "-9223372036854775807", "Exact"],
        ["-12345.000000000000000000001", "-12345", "Above"],
        ["-12345.0", "-12345", "Exact"],
        ["-1.000000000000000000001", "-1", "Above"],
        ["-1.5", "-1", "Above"],
        ["-1", "-1", "Exact"],
        ["-1e-1000", "0", "Above"],
        ["0", "0", "Exact"],
        ["1e-1000", "0", "Below"],
        ["1", "1", "Exact"],
        ["1.000000000000000000001", "1", "Below"],
        ["1.5", "1", "Below"],
        ["12345.0", "12345", "Exact"],
        ["12345.000000000000000000001", "12345", "Below"],
        ["9223372036854775807", "9223372036854775807", "Exact"],
        [
            "9223372036854775807.000000000000000000001",
            "9223372036854775807",
            "Below",
        ],
        ["9223372036854775808", "9223372036854775807", "Below"],
        ["1e10000", "9223372036854775807", "Below"],
        ["+Inf", "9223372036854775807", "Below"],
    ]
    for r in rows:
        var got, acc = f(r[0]).int64()
        assert_equal(got, parse_int(r[1], 10, 64), r[0])
        assert_equal(acc, _acc_named(r[2]), r[0])


def test_float32() raises:
    # Go's `TestFloatFloat32`. The columns are the number, the bit pattern of
    # the `Float32` it becomes and the accuracy of that. The answer is written
    # as bits rather than as a decimal, because most of these rows are
    # subnormal numbers a decimal literal cannot name exactly.
    var rows: List[List[String]] = [
        ["0", "0x00000000", "Exact"],
        # Too small for even the smallest subnormal.
        ["1e-1000", "0x00000000", "Below"],
        ["0x0.000002p-127", "0x00000000", "Below"],
        ["0x.0000010p-126", "0x00000000", "Below"],
        # Subnormal numbers.
        ["1.401298464e-45", "0x00000001", "Above"],
        ["0x.ffffff8p-149", "0x00000001", "Above"],
        ["0x.0000018p-126", "0x00000001", "Above"],
        ["0x.0000020p-126", "0x00000001", "Exact"],
        ["0x.8p-148", "0x00000001", "Exact"],
        ["1p-149", "0x00000001", "Exact"],
        ["0x.fffffep-126", "0x007fffff", "Exact"],
        # The rows Go collected from issues 14553 and 14651, where a shorter
        # subnormal mantissa was rounded as though it were a normal one.
        ["0x0.0000001p-126", "0x00000000", "Below"],
        ["0x0.0000008p-126", "0x00000000", "Below"],
        ["0x0.0000010p-126", "0x00000000", "Below"],
        ["0x0.0000011p-126", "0x00000001", "Above"],
        ["0x0.0000018p-126", "0x00000001", "Above"],
        ["0x1.0000000p-149", "0x00000001", "Exact"],
        ["0x0.0000020p-126", "0x00000001", "Exact"],
        ["0x0.fffffe0p-126", "0x007fffff", "Exact"],
        ["0x1.0000000p-126", "0x00800000", "Exact"],
        ["0x0.8p-149", "0x00000000", "Below"],
        ["0x0.9p-149", "0x00000001", "Above"],
        ["0x0.ap-149", "0x00000001", "Above"],
        ["0x0.bp-149", "0x00000001", "Above"],
        ["0x0.cp-149", "0x00000001", "Above"],
        ["0x1.0p-149", "0x00000001", "Exact"],
        ["0x1.7p-149", "0x00000001", "Below"],
        ["0x1.8p-149", "0x00000002", "Above"],
        ["0x1.9p-149", "0x00000002", "Above"],
        ["0x2.0p-149", "0x00000002", "Exact"],
        ["0x2.8p-149", "0x00000002", "Below"],
        ["0x2.9p-149", "0x00000003", "Above"],
        ["0x3.0p-149", "0x00000003", "Exact"],
        ["0x3.7p-149", "0x00000003", "Below"],
        ["0x3.8p-149", "0x00000004", "Above"],
        ["0x4.0p-149", "0x00000004", "Exact"],
        ["0x4.8p-149", "0x00000004", "Below"],
        ["0x4.9p-149", "0x00000005", "Above"],
        ["0x7.7p-149", "0x00000007", "Below"],
        ["0x7.8p-149", "0x00000008", "Above"],
        ["0x7.9p-149", "0x00000008", "Above"],
        # Normal numbers.
        ["0x.ffffffp-126", "0x00800000", "Above"],
        ["1p-126", "0x00800000", "Exact"],
        ["0x1.fffffep-126", "0x00ffffff", "Exact"],
        ["0x1.ffffffp-126", "0x01000000", "Above"],
        ["1", "0x3f800000", "Exact"],
        ["1.000000000000000000001", "0x3f800000", "Below"],
        ["12345.0", "0x4640e400", "Exact"],
        ["12345.000000000000000000001", "0x4640e400", "Below"],
        ["0x1.fffffe0p127", "0x7f7fffff", "Exact"],
        ["0x1.fffffe8p127", "0x7f7fffff", "Below"],
        # Past the top of the range.
        ["0x1.ffffff0p127", "0x7f800000", "Above"],
        ["0x1p128", "0x7f800000", "Above"],
        ["1e10000", "0x7f800000", "Above"],
        ["0x1.ffffff0p2147483646", "0x7f800000", "Above"],
        ["Inf", "0x7f800000", "Exact"],
    ]
    for r in rows:
        for i in range(2):
            var tx = r[0]
            var tout = float32frombits(UInt32(_udec(r[1])))
            var tacc = _acc_named(r[2])
            if i != 0:
                tx = "-" + tx
                tout = -tout
                tacc = _flip(tacc)

            # Where `core.strconv` accepts the same string it has to give the
            # same number, which checks the table itself rather than the code.
            try:
                var s = parse_float(tx, 32)
                assert_true(_alike32(Float32(s), tout), tx)
            except:
                pass

            var got, acc = f(tx).float32()
            assert_true(_alike32(got, tout), tx)
            assert_equal(acc, tacc, tx)

            # A number that came out of a `Float32` goes back in exactly.
            var back = big.Float()
            back.set_float64(Float64(got))
            var got2, acc2 = back.float32()
            assert_true(_alike32(got2, got), tx)
            assert_equal(acc2, big.Exact, tx)


def test_float64() raises:
    # Go's `TestFloatFloat64`. The same table at twice the width.
    var rows: List[List[String]] = [
        ["0", "0x0000000000000000", "Exact"],
        # Too small for even the smallest subnormal.
        ["1e-1000", "0x0000000000000000", "Below"],
        ["0x0.0000000000001p-1023", "0x0000000000000000", "Below"],
        ["0x0.00000000000008p-1022", "0x0000000000000000", "Below"],
        # Subnormal numbers.
        ["0x0.0000000000000cp-1022", "0x0000000000000001", "Above"],
        ["0x0.00000000000010p-1022", "0x0000000000000001", "Exact"],
        ["0x.8p-1073", "0x0000000000000001", "Exact"],
        ["1p-1074", "0x0000000000000001", "Exact"],
        ["0x.fffffffffffffp-1022", "0x000fffffffffffff", "Exact"],
        # The rows from issues 14553 and 14651 again.
        ["0x0.00000000000001p-1022", "0x0000000000000000", "Below"],
        ["0x0.00000000000004p-1022", "0x0000000000000000", "Below"],
        ["0x0.00000000000008p-1022", "0x0000000000000000", "Below"],
        ["0x0.00000000000009p-1022", "0x0000000000000001", "Above"],
        ["0x0.0000000000000ap-1022", "0x0000000000000001", "Above"],
        ["0x0.8p-1074", "0x0000000000000000", "Below"],
        ["0x0.9p-1074", "0x0000000000000001", "Above"],
        ["0x0.ap-1074", "0x0000000000000001", "Above"],
        ["0x0.bp-1074", "0x0000000000000001", "Above"],
        ["0x0.cp-1074", "0x0000000000000001", "Above"],
        ["0x1.0p-1074", "0x0000000000000001", "Exact"],
        ["0x1.7p-1074", "0x0000000000000001", "Below"],
        ["0x1.8p-1074", "0x0000000000000002", "Above"],
        ["0x1.9p-1074", "0x0000000000000002", "Above"],
        ["0x2.0p-1074", "0x0000000000000002", "Exact"],
        ["0x2.8p-1074", "0x0000000000000002", "Below"],
        ["0x2.9p-1074", "0x0000000000000003", "Above"],
        ["0x3.0p-1074", "0x0000000000000003", "Exact"],
        ["0x3.7p-1074", "0x0000000000000003", "Below"],
        ["0x3.8p-1074", "0x0000000000000004", "Above"],
        ["0x4.0p-1074", "0x0000000000000004", "Exact"],
        ["0x4.8p-1074", "0x0000000000000004", "Below"],
        ["0x4.9p-1074", "0x0000000000000005", "Above"],
        # Normal numbers.
        ["0x.fffffffffffff8p-1022", "0x0010000000000000", "Above"],
        ["1p-1022", "0x0010000000000000", "Exact"],
        ["1", "0x3ff0000000000000", "Exact"],
        ["1.000000000000000000001", "0x3ff0000000000000", "Below"],
        ["12345.0", "0x40c81c8000000000", "Exact"],
        ["12345.000000000000000000001", "0x40c81c8000000000", "Below"],
        ["0x1.fffffffffffff0p1023", "0x7fefffffffffffff", "Exact"],
        ["0x1.fffffffffffff4p1023", "0x7fefffffffffffff", "Below"],
        # Past the top of the range.
        ["0x1.fffffffffffff8p1023", "0x7ff0000000000000", "Above"],
        ["0x1p1024", "0x7ff0000000000000", "Above"],
        ["1e10000", "0x7ff0000000000000", "Above"],
        ["0x1.fffffffffffff8p2147483646", "0x7ff0000000000000", "Above"],
        ["Inf", "0x7ff0000000000000", "Exact"],
        # The largest subnormal, written two ways, which used to come out
        # wrong.
        ["0x.fffffffffffffp-1022", "0x000fffffffffffff", "Exact"],
        ["4503599627370495p-1074", "0x000fffffffffffff", "Exact"],
        # The two decimal numbers that used to hang a parser: one is just
        # under the smallest normal and one is just over it.
        ["2.2250738585072011e-308", "0x000fffffffffffff", "Below"],
        ["2.2250738585072012e-308", "0x0010000000000000", "Above"],
    ]
    for r in rows:
        for i in range(2):
            var tx = r[0]
            var tout = float64frombits(_udec(r[1]))
            var tacc = _acc_named(r[2])
            if i != 0:
                tx = "-" + tx
                tout = -tout
                tacc = _flip(tacc)

            try:
                var s = parse_float(tx, 64)
                assert_true(_alike64(s, tout), tx)
            except:
                pass

            var got, acc = f(tx).float64()
            assert_true(_alike64(got, tout), tx)
            assert_equal(acc, tacc, tx)

            var back = big.Float()
            back.set_float64(got)
            var got2, acc2 = back.float64()
            assert_true(_alike64(got2, got), tx)
            assert_equal(acc2, big.Exact, tx)


def test_int() raises:
    # Go's `TestFloatInt`. Truncation towards zero, with the accuracy saying
    # which way the number moved. The columns are the number, the integer and
    # the accuracy.
    var rows: List[List[String]] = [
        ["0", "0", "Exact"],
        ["+0", "0", "Exact"],
        ["-0", "0", "Exact"],
        ["1", "1", "Exact"],
        ["-1", "-1", "Exact"],
        ["1.23", "1", "Below"],
        ["-1.23", "-1", "Above"],
        ["123e-2", "1", "Below"],
        ["123e-3", "0", "Below"],
        ["123e-4", "0", "Below"],
        ["1e-1000", "0", "Below"],
        ["-1e-1000", "0", "Above"],
        ["1e+10", "10000000000", "Exact"],
        [
            "1e+100",
            (
                "1000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000"
            ),
            "Exact",
        ],
    ]
    for r in rows:
        var acc = big.Exact
        var got = f(r[0]).int(acc)
        assert_equal(got.string(), r[1], r[0])
        assert_equal(acc, _acc_named(r[2]), r[0])


def test_int_refuses_an_infinity() raises:
    # The three rows of Go's `TestFloatInt` that expect a nil `Int`. Go returns
    # one alongside an accuracy saying which side of the infinity the missing
    # answer would be on; there is no nil here, so this raises instead and the
    # accuracy is not reported.
    var names: List[String] = ["Inf", "+Inf", "-Inf"]
    for s in names:
        var acc = big.Exact
        with assert_raises(contains="not an integer"):
            _ = f(s).int(acc)


def test_rat() raises:
    # Go's `TestFloatRat`. Every finite `Float` is a fraction exactly, so this
    # never rounds. The columns are the number and the fraction.
    var rows: List[List[String]] = [
        ["0", "0/1"],
        ["+0", "0/1"],
        ["-0", "0/1"],
        ["1", "1/1"],
        ["-1", "-1/1"],
        ["1.25", "5/4"],
        ["-1.25", "-5/4"],
        ["1e10", "10000000000/1"],
        ["1p10", "1024/1"],
        ["-1p-10", "-1/1024"],
        ["3.14159265", "7244019449799623199/2305843009213693952"],
    ]
    for r in rows:
        var x = f(r[0])
        x.set_prec(64)
        var got = x.rat()
        assert_equal(got.string(), r[1], r[0])

        # And the fraction goes back to the number it came from.
        var back = big.Float()
        back.set_prec(64)
        back.set_rat(got)
        assert_equal(back.cmp(x), 0, r[0])


def test_rat_refuses_an_infinity() raises:
    # The three rows of Go's `TestFloatRat` that expect a nil `Rat`, for the
    # same reason as the integer ones.
    var names: List[String] = ["Inf", "+Inf", "-Inf"]
    for s in names:
        with assert_raises(contains="not a rational number"):
            _ = f(s).rat()


def _udec(s: String) raises -> UInt64:
    """The unsigned number written in `s`, in whatever base its prefix says.

    The tables here hold their numbers as strings so that a row reads as one
    line, and the bit patterns are written in hexadecimal. `parse_int` would
    do it but it stops at the top of a signed sixty four bit number, and one
    of the rows here is the largest unsigned one.
    """
    var base = UInt64(10)
    var at = 0
    if s.startswith("0x"):
        base = 16
        at = 2

    var bytes = s.as_bytes()
    var value = UInt64(0)
    for i in range(at, len(bytes)):
        var c = UInt64(bytes[i])
        var d: UInt64
        if c >= UInt64(ord("a")):
            d = c - UInt64(ord("a")) + 10
        else:
            d = c - UInt64(ord("0"))
        if d >= base:
            raise Error("not a number in that base: " + s)
        value = value * base + d
    return value
