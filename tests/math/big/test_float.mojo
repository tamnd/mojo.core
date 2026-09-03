"""Go's `TestFloatZeroValue` through `TestFloatSetInf`, from `float_test.go`.

The shape of a `Float` rather than its arithmetic: the zero value, the
precision, the rounding, the sign, the mantissa and exponent split, and the
setters that take a machine number. `test_floatarith.mojo` has the four
operations and `test_floatconv.mojo` has the text.

Go's tables are written as strings and read with `makeFloat`, which parses at a
thousand bits so that no row is rounded before the test asks for it. `f` in
`_fixtures.mojo` is that helper.
"""

from std.testing import assert_equal, assert_true

from core.strconv import format_int, parse_int
import core.math.big as big
from core.math.big.rounding import RoundingMode

from tests.math.big._fixtures import alike, exact_int64, exact_uint64, f


def _accuracy_name(a: big.Accuracy) -> String:
    """The accuracy as Go prints it, for a message that says which one came
    out."""
    return a.string()


def test_zero_value() raises:
    # Go's `TestFloatZeroValue`. The zero value is a usable `+0` with a
    # precision of nothing decided.
    var x = big.Float()
    assert_equal(x.text(UInt8(ord("f")), 1), "0.0")
    assert_equal(x.prec(), 0)

    # It works in every position of a binary operation. The columns are the two
    # operands and the answer, with a zero standing for the zero value itself.
    var rows: List[List[Int]] = [
        [0, 0, 0],
        [1, 2, 3],
        [2, 0, 2],
        [0, 1, 1],
    ]
    for r in rows:
        assert_equal(exact_int64(_mk(r[0]).add(_mk(r[1]))), Int64(r[2]))

    var subs: List[List[Int]] = [
        [0, 0, 0],
        [1, 2, -1],
        [2, 0, 2],
        [0, 1, -1],
    ]
    for r in subs:
        assert_equal(exact_int64(_mk(r[0]).sub(_mk(r[1]))), Int64(r[2]))

    var muls: List[List[Int]] = [
        [0, 0, 0],
        [1, 2, 2],
        [2, 0, 0],
        [0, 1, 0],
    ]
    for r in muls:
        assert_equal(exact_int64(_mk(r[0]).mul(_mk(r[1]))), Int64(r[2]))

    # Division has one row Go leaves out because it panics, and `2 / 0` gives
    # an infinity rather than a number, so the answer there is read off
    # `is_inf` instead.
    assert_equal(exact_int64(_mk(2).quo(_mk(1))), Int64(2))
    assert_true(_mk(2).quo(_mk(0)).is_inf())
    assert_equal(exact_int64(_mk(0).quo(_mk(1))), Int64(0))


def _mk(v: Int) raises -> big.Float:
    """`v` as a `Float`, with zero standing for the zero value. Go's `make`
    inside `TestFloatZeroValue`."""
    var z = big.Float()
    if v != 0:
        z.set_int64(Int64(v))
    return z^


def test_set_prec() raises:
    # Go's `TestFloatSetPrec`. The columns are the number, the precision, what
    # it becomes and the accuracy of that.
    var rows: List[List[String]] = [
        # A precision of zero turns every finite number into a signed zero and
        # leaves the infinities alone.
        ["0", "0", "0", "Exact"],
        ["-0", "0", "-0", "Exact"],
        ["-Inf", "0", "-Inf", "Exact"],
        ["+Inf", "0", "+Inf", "Exact"],
        ["123", "0", "0", "Below"],
        ["-123", "0", "-0", "Above"],
        # At the upper limit.
        ["0", "4294967295", "0", "Exact"],
        ["-0", "4294967295", "-0", "Exact"],
        ["-Inf", "4294967295", "-Inf", "Exact"],
        ["+Inf", "4294967295", "+Inf", "Exact"],
        # A few ordinary rows. Rounding proper is tested by `test_round`.
        ["1.5", "1", "2", "Above"],
        ["-1.5", "1", "-2", "Below"],
        ["123", "1000000", "123", "Exact"],
        ["-123", "1000000", "-123", "Exact"],
    ]
    for row in rows:
        var prec = Int(parse_int(row[1], 10, 64))
        var x = f(row[0])
        x.set_prec(prec)
        assert_equal(x.prec(), min(prec, big.MaxPrec))
        assert_equal(x.string(), row[2])
        assert_equal(_accuracy_name(x.acc()), row[3])


def test_set_prec_refuses_a_negative() raises:
    # Not Go's, because Go's argument is unsigned and cannot be negative. Here
    # it can be, and it is a mistake rather than a very large precision.
    var x = f("1.5")
    var raised = False
    try:
        x.set_prec(-1)
    except:
        raised = True
    assert_true(raised)


def test_min_prec() raises:
    # Go's `TestFloatMinPrec`. Every row is set to a hundred bits first, so the
    # answer is how many of those hundred the number actually needs.
    var rows: List[List[String]] = [
        ["0", "0"],
        ["-0", "0"],
        ["+Inf", "0"],
        ["-Inf", "0"],
        ["1", "1"],
        ["2", "1"],
        ["3", "2"],
        ["0x8001", "16"],
        ["0x8001p-1000", "16"],
        ["0x8001p+1000", "16"],
        ["0.1", "100"],
    ]
    for row in rows:
        var x = f(row[0])
        x.set_prec(100)
        assert_equal(x.min_prec(), Int(parse_int(row[1], 10, 64)))


def test_sign() raises:
    # Go's `TestFloatSign`. Both zeros have a sign of nothing, whichever way
    # their sign bit points.
    var rows: List[List[String]] = [
        ["-Inf", "-1"],
        ["-1", "-1"],
        ["-0", "0"],
        ["+0", "0"],
        ["+1", "1"],
        ["+Inf", "1"],
    ]
    for row in rows:
        assert_equal(f(row[0]).sign(), Int(parse_int(row[1], 10, 64)))


def test_predicates() raises:
    # Go's `TestFloatPredicates`. The columns are the number, the sign, the
    # sign bit and whether it is an infinity.
    var rows: List[List[String]] = [
        ["-Inf", "-1", "1", "1"],
        ["-1", "-1", "1", "0"],
        ["-0", "0", "1", "0"],
        ["0", "0", "0", "0"],
        ["1", "1", "0", "0"],
        ["+Inf", "1", "0", "1"],
    ]
    for row in rows:
        var x = f(row[0])
        assert_equal(x.sign(), Int(parse_int(row[1], 10, 64)))
        assert_equal(x.signbit(), row[2] == "1")
        assert_equal(x.is_inf(), row[3] == "1")


def test_mant_exp() raises:
    # Go's `TestFloatMantExp`. The mantissa comes out in `[0.5, 1)` with the
    # sign on it, and a zero or an infinity comes out as itself with an
    # exponent of zero.
    var rows: List[List[String]] = [
        ["0", "0", "0"],
        ["+0", "0", "0"],
        ["-0", "-0", "0"],
        ["Inf", "+Inf", "0"],
        ["+Inf", "+Inf", "0"],
        ["-Inf", "-Inf", "0"],
        ["1.5", "0.75", "1"],
        ["1.024e3", "0.5", "11"],
        ["-0.125", "-0.5", "-2"],
    ]
    for row in rows:
        var x = f(row[0])
        var m = big.Float()
        var e = x.mant_exp(m)
        assert_true(alike(m, f(row[1])))
        assert_equal(e, Int(parse_int(row[2], 10, 64)))
        # The arity with no argument answers the same exponent.
        assert_equal(x.mant_exp(), e)


def test_mant_exp_leaves_the_source_alone() raises:
    # Go's `TestFloatMantExpAliasing`, which checks that `x.MantExp(x)` still
    # works when the two are the same value. Mojo will not let one value be
    # both the receiver and the mutable argument, so there is nothing to alias
    # and the property to check instead is that the source is untouched.
    var x = f("0.5p10")
    var m = big.Float()
    assert_equal(x.mant_exp(m), 10)
    assert_true(alike(m, f("0.5")))
    assert_true(alike(x, f("0.5p10")))


def test_set_mant_exp() raises:
    # Go's `TestFloatSetMantExp`. The columns are the mantissa, the exponent
    # and the number they make.
    var rows: List[List[String]] = [
        ["0", "0", "0"],
        ["+0", "0", "0"],
        ["-0", "0", "-0"],
        ["Inf", "1234", "+Inf"],
        ["+Inf", "-1234", "+Inf"],
        ["-Inf", "-1234", "-Inf"],
        ["0", "-2147483648", "0"],
        # The exponent underflows, and the sign survives it.
        ["0.25", "-2147483648", "+0"],
        ["-0.25", "-2147483648", "-0"],
        # And overflows.
        ["1", "2147483647", "+Inf"],
        ["2", "2147483646", "+Inf"],
        ["0.75", "1", "1.5"],
        ["0.5", "11", "1024"],
        ["-0.5", "-2", "-0.125"],
        ["32", "5", "1024"],
        ["1024", "-10", "1"],
    ]
    for row in rows:
        var frac = f(row[0])
        var exp = Int(parse_int(row[1], 10, 64))
        var want = f(row[2])
        var z = big.Float()
        z.set_mant_exp(frac, exp)
        assert_true(alike(z, want))

        # And the inverse property: taking the number apart and putting it back
        # together gives the same number.
        var mant = big.Float()
        var e = want.mant_exp(mant)
        var back = big.Float()
        back.set_mant_exp(mant, e)
        assert_equal(back.cmp(want), 0)


def test_is_int() raises:
    # Go's `TestFloatIsInt`. Go marks the whole ones by putting " int" on the
    # end of the string and trimming it back off; here the flag is a column.
    var rows: List[List[String]] = [
        ["0", "1"],
        ["-0", "1"],
        ["1", "1"],
        ["-1", "1"],
        ["0.5", "0"],
        ["1.23", "0"],
        ["1.23e1", "0"],
        ["1.23e2", "1"],
        ["0.000000001e+8", "0"],
        ["0.000000001e+9", "1"],
        ["1.2345e200", "1"],
        ["Inf", "0"],
        ["+Inf", "0"],
        ["-Inf", "0"],
    ]
    for row in rows:
        assert_equal(f(row[0]).is_int(), row[1] == "1")


def _from_binary(s: String) raises -> Int64:
    """The number written in binary in `s`. Go's `fromBinary`."""
    return parse_int(s, 2, 64)


def _check_round(x: Int64, r: Int64, prec: Int, mode: RoundingMode) raises:
    """Round `x` to `prec` bits under `mode` and check it gives `r`. Go's
    `testFloatRound`.

    Go also checks the row itself, that a mode which only ever moves one way
    was given an answer on that side. That check is kept, because a table this
    large is worth checking against itself.
    """
    var ok = True
    if mode == big.ToZero:
        ok = r <= x if x >= 0 else r >= x
    elif mode == big.AwayFromZero:
        ok = r >= x if x >= 0 else r <= x
    elif mode == big.ToNegativeInf:
        ok = r <= x
    elif mode == big.ToPositiveInf:
        ok = r >= x
    assert_true(ok)

    var want_acc = big.Exact
    if r < x:
        want_acc = big.Below
    elif r > x:
        want_acc = big.Above

    # Rounding by `set_prec` after the number went in at the default precision.
    var a = big.Float()
    a.set_mode(mode)
    a.set_int64(x)
    a.set_prec(prec)
    assert_equal(exact_int64(a), r)
    assert_equal(a.prec(), prec)
    assert_equal(a.acc(), want_acc)

    # Setting the precision first has to give the same number.
    var b = big.Float()
    b.set_mode(mode)
    b.set_prec(prec)
    b.set_int64(x)
    assert_true(alike(b, a))

    # And rounding an already rounded number changes nothing.
    var c = big.Float()
    c.set_mode(mode)
    c.set_prec(prec)
    c.set(a)
    assert_true(alike(c, a))


def test_round() raises:
    # Go's `TestFloatRound`. Every row is a run of bits and what it becomes at
    # a narrower precision under each of the four rounding directions, written
    # in binary because that is what rounding is about. The columns are the
    # precision, the input, and the answers for `ToZero`, `ToNearestEven`,
    # `ToNearestAway` and `AwayFromZero`.
    var rows: List[List[String]] = [
        ["5", "1000", "1000", "1000", "1000", "1000"],
        ["5", "1001", "1001", "1001", "1001", "1001"],
        ["5", "1010", "1010", "1010", "1010", "1010"],
        ["5", "1011", "1011", "1011", "1011", "1011"],
        ["5", "1100", "1100", "1100", "1100", "1100"],
        ["5", "1101", "1101", "1101", "1101", "1101"],
        ["5", "1110", "1110", "1110", "1110", "1110"],
        ["5", "1111", "1111", "1111", "1111", "1111"],
        ["4", "1000", "1000", "1000", "1000", "1000"],
        ["4", "1001", "1001", "1001", "1001", "1001"],
        ["4", "1010", "1010", "1010", "1010", "1010"],
        ["4", "1011", "1011", "1011", "1011", "1011"],
        ["4", "1100", "1100", "1100", "1100", "1100"],
        ["4", "1101", "1101", "1101", "1101", "1101"],
        ["4", "1110", "1110", "1110", "1110", "1110"],
        ["4", "1111", "1111", "1111", "1111", "1111"],
        ["3", "1000", "1000", "1000", "1000", "1000"],
        ["3", "1001", "1000", "1000", "1010", "1010"],
        ["3", "1010", "1010", "1010", "1010", "1010"],
        ["3", "1011", "1010", "1100", "1100", "1100"],
        ["3", "1100", "1100", "1100", "1100", "1100"],
        ["3", "1101", "1100", "1100", "1110", "1110"],
        ["3", "1110", "1110", "1110", "1110", "1110"],
        ["3", "1111", "1110", "10000", "10000", "10000"],
        ["3", "1000001", "1000000", "1000000", "1000000", "1010000"],
        ["3", "1001001", "1000000", "1010000", "1010000", "1010000"],
        ["3", "1010001", "1010000", "1010000", "1010000", "1100000"],
        ["3", "1011001", "1010000", "1100000", "1100000", "1100000"],
        ["3", "1100001", "1100000", "1100000", "1100000", "1110000"],
        ["3", "1101001", "1100000", "1110000", "1110000", "1110000"],
        ["3", "1110001", "1110000", "1110000", "1110000", "10000000"],
        ["3", "1111001", "1110000", "10000000", "10000000", "10000000"],
        ["2", "1000", "1000", "1000", "1000", "1000"],
        ["2", "1001", "1000", "1000", "1000", "1100"],
        ["2", "1010", "1000", "1000", "1100", "1100"],
        ["2", "1011", "1000", "1100", "1100", "1100"],
        ["2", "1100", "1100", "1100", "1100", "1100"],
        ["2", "1101", "1100", "1100", "1100", "10000"],
        ["2", "1110", "1100", "10000", "10000", "10000"],
        ["2", "1111", "1100", "10000", "10000", "10000"],
        ["2", "1000001", "1000000", "1000000", "1000000", "1100000"],
        ["2", "1001001", "1000000", "1000000", "1000000", "1100000"],
        ["2", "1010001", "1000000", "1100000", "1100000", "1100000"],
        ["2", "1011001", "1000000", "1100000", "1100000", "1100000"],
        ["2", "1100001", "1100000", "1100000", "1100000", "10000000"],
        ["2", "1101001", "1100000", "1100000", "1100000", "10000000"],
        ["2", "1110001", "1100000", "10000000", "10000000", "10000000"],
        ["2", "1111001", "1100000", "10000000", "10000000", "10000000"],
        ["1", "1000", "1000", "1000", "1000", "1000"],
        ["1", "1001", "1000", "1000", "1000", "10000"],
        ["1", "1010", "1000", "1000", "1000", "10000"],
        ["1", "1011", "1000", "1000", "1000", "10000"],
        ["1", "1100", "1000", "10000", "10000", "10000"],
        ["1", "1101", "1000", "10000", "10000", "10000"],
        ["1", "1110", "1000", "10000", "10000", "10000"],
        ["1", "1111", "1000", "10000", "10000", "10000"],
        ["1", "1000001", "1000000", "1000000", "1000000", "10000000"],
        ["1", "1001001", "1000000", "1000000", "1000000", "10000000"],
        ["1", "1010001", "1000000", "1000000", "1000000", "10000000"],
        ["1", "1011001", "1000000", "1000000", "1000000", "10000000"],
        ["1", "1100001", "1000000", "10000000", "10000000", "10000000"],
        ["1", "1101001", "1000000", "10000000", "10000000", "10000000"],
        ["1", "1110001", "1000000", "10000000", "10000000", "10000000"],
        ["1", "1111001", "1000000", "10000000", "10000000", "10000000"],
    ]
    for row in rows:
        var prec = Int(parse_int(row[0], 10, 64))
        var x = _from_binary(row[1])
        var z = _from_binary(row[2])
        var e = _from_binary(row[3])
        var n = _from_binary(row[4])
        var a = _from_binary(row[5])

        _check_round(x, z, prec, big.ToZero)
        _check_round(x, e, prec, big.ToNearestEven)
        _check_round(x, n, prec, big.ToNearestAway)
        _check_round(x, a, prec, big.AwayFromZero)

        # A positive number rounds towards minus infinity the way it rounds
        # towards zero, and the other way for the other direction.
        _check_round(x, z, prec, big.ToNegativeInf)
        _check_round(x, a, prec, big.ToPositiveInf)
        _check_round(-x, -a, prec, big.ToNegativeInf)
        _check_round(-x, -z, prec, big.ToPositiveInf)


def test_round_to_24_bits_matches_float32() raises:
    # Go's `TestFloatRound24`. Rounding a `Float64` to twenty four bits has to
    # agree with what IEEE does converting it to a `Float32`, which is the same
    # rounding written twice in two different places.
    var x0 = Int64(1) << 26 - 0x10
    for d in range(0x11):
        var x = Float64(x0 + Int64(d))
        var z = big.Float()
        z.set_prec(24)
        z.set_float64(x)
        var got, _ = z.float32()
        assert_equal(got, Float32(x))


def test_set_uint64() raises:
    # Go's `TestFloatSetUint64`. A precision of zero becomes sixty four, so
    # every one of these goes in and comes back exactly.
    var wants = List[UInt64]()
    for v in [
        UInt64(0),
        UInt64(1),
        UInt64(2),
        UInt64(10),
        UInt64(100),
        UInt64(4294967295),
        UInt64(4294967296),
        UInt64(18446744073709551615),
    ]:
        wants.append(v)
    for want in wants:
        var z = big.Float()
        z.set_uint64(want)
        assert_equal(exact_uint64(z), want)

    # And a little rounding on the way in. Truncating at `prec` bits is the
    # same as clearing the low `64 - prec` of them.
    var x = UInt64(0x8765432187654321)
    for prec in range(1, 65):
        var z = big.Float()
        z.set_prec(prec)
        z.set_mode(big.ToZero)
        z.set_uint64(x)
        var want = x & ~((UInt64(1) << UInt64(64 - prec)) - 1)
        assert_equal(exact_uint64(z), want)


def test_set_int64() raises:
    # Go's `TestFloatSetInt64`, both signs of every row.
    var wants = List[Int64]()
    for v in [
        Int64(0),
        Int64(1),
        Int64(2),
        Int64(10),
        Int64(100),
        Int64(1) << 31 - 1,
        Int64(1) << 31,
        Int64(1) << 63 - 1,
    ]:
        wants.append(v)
    for want in wants:
        for i in range(2):
            var v = want
            if i == 1:
                v = -v
            var z = big.Float()
            z.set_int64(v)
            assert_equal(exact_int64(z), v)

    # The rounding check Go writes, on a number that needs all sixty three
    # bits it has.
    var x = Int64(0x7654321076543210)
    for prec in range(1, 64):
        var z = big.Float()
        z.set_prec(prec)
        z.set_mode(big.ToZero)
        z.set_int64(x)
        var want = x & ~((Int64(1) << Int64(63 - prec)) - 1)
        assert_equal(exact_int64(z), want)


def test_set_int64_holds_the_smallest_one() raises:
    # Not a row of Go's, and the one value where negating first would be wrong:
    # the smallest `Int64` has no positive counterpart, so `set_int64` takes
    # the magnitude as unsigned rather than by negating.
    var z = big.Float()
    z.set_int64(-Int64(9223372036854775807) - 1)
    assert_equal(exact_int64(z), -Int64(9223372036854775807) - 1)
    assert_equal(z.min_prec(), 1)


def test_set_inf() raises:
    # Go's `TestFloatSetInf`. The precision does not change and the result is
    # always exact, whatever was in the value before.
    var rows: List[List[String]] = [
        ["0", "0", "+Inf"],
        ["0", "1", "-Inf"],
        ["10", "0", "+Inf"],
        ["10", "1", "-Inf"],
        ["4294967295", "0", "+Inf"],
        ["4294967295", "1", "-Inf"],
    ]
    for row in rows:
        var prec = Int(parse_int(row[0], 10, 64))
        var z = big.Float()
        z.set_prec(prec)
        z.set_inf(row[1] == "1")
        assert_equal(z.string(), row[2])
        assert_equal(z.prec(), prec)
        assert_equal(z.acc(), big.Exact)


def test_set_mode_clears_the_accuracy() raises:
    # Not Go's as a test of its own, but it is what Go's documentation promises
    # `SetMode` for, and it is the only way to clear a stale accuracy.
    var x = f("1.5")
    x.set_prec(1)
    assert_equal(x.acc(), big.Above)
    x.set_mode(x.mode())
    assert_equal(x.acc(), big.Exact)
    assert_equal(x.mode(), big.ToNearestEven)


def test_copy_keeps_everything() raises:
    # Go's `Float.Copy`, which is Mojo's `copy()`. Unlike `set`, it takes the
    # source's precision and mode rather than rounding to the destination's.
    var x = big.Float()
    x.set_prec(10)
    x.set_mode(big.ToZero)
    _ = x.parse("1.5", 0)
    var y = x.copy()
    assert_true(alike(y, x))
    assert_equal(y.prec(), 10)
    assert_equal(y.mode(), big.ToZero)

    # `set` into a value with its own precision rounds instead.
    var z = big.Float()
    z.set_prec(1)
    z.set(x)
    assert_equal(z.prec(), 1)
    assert_equal(z.string(), "2")
    assert_equal(z.acc(), big.Above)

    # And `set` into one with no precision takes the source's.
    var w = big.Float()
    w.set(x)
    assert_equal(w.prec(), 10)
    assert_true(alike(w, x))


def test_abs_and_neg() raises:
    # Go's `TestFloatAbs` and `TestFloatNeg`, which walk the same list of
    # numbers and check that the sign is the only thing either one touches.
    var names = List[String]()
    for s in ["0", "1", "1234", "1.2345e-10", "4p-1234", "Inf"]:
        names.append(String(s))
    for name in names:
        var p = f(name)
        var n = f("-" + name)
        assert_true(alike(p.abs(), p))
        assert_true(alike(n.abs(), p))
        assert_true(alike(p.neg(), n))
        assert_true(alike(n.neg(), p))
        # Negating twice is the identity, including on the zeros.
        assert_true(alike(p.neg().neg(), p))
        assert_true(alike(n.neg().neg(), n))


def test_neg_flips_a_zero() raises:
    # The one case where `neg` is visible and `cmp` is not: the two zeros are
    # equal as numbers, so only the sign bit says which one this is.
    var z = big.Float()
    assert_true(not z.signbit())
    assert_true(z.neg().signbit())
    assert_equal(z.neg().cmp(z), 0)


def test_binary_string_helper_agrees_with_itself() raises:
    # Not Go's. `test_round` reads its whole table through `_from_binary`, so a
    # fault there would move every row at once and none of them would fail.
    assert_equal(_from_binary("1111"), Int64(15))
    assert_equal(_from_binary("10000000"), Int64(128))
    assert_equal(format_int(Int64(15), 2), "1111")
