"""Go's `ratconv_test.go`.

Go's `TestScanExponent` calls `scanExponent` directly, over a table that also
records which character the reader is left on. That function is private here
and reads from a span rather than from a reader, so the exponents are tested
through `set_string`, which is the only way into it and is what the rest of the
table exercises anyway.

`TestRatScan` is Go's `fmt.Fscanf` support, which this library does not have,
and its rows are the same `setStringTests` this file already reads.
"""

from std.testing import assert_equal, assert_false, assert_true

import core.math.big as big
from core.errors import matches
from core.errors.codes import ErrRange
from core.math import (
    float32bits,
    float64bits,
    inf,
    is_inf,
    nextafter,
    nextafter32,
)
from core.strconv import parse_float

from tests.math.big._fixtures import p, parses_rat, q


def _set_string_rows() -> List[List[String]]:
    """The valid rows of Go's `setStringTests` and `setStringTests2`, as the
    string and what `rat_string` gives back."""
    return [
        ["0", "0"],
        ["-0", "0"],
        ["1", "1"],
        ["-1", "-1"],
        ["1.", "1"],
        ["1e0", "1"],
        ["1.e1", "10"],
        ["-0.1", "-1/10"],
        ["-.1", "-1/10"],
        ["2/4", "1/2"],
        [".25", "1/4"],
        ["-1/5", "-1/5"],
        ["8129567.7690E14", "812956776900000000000"],
        ["78189e+4", "781890000"],
        ["553019.8935e+8", "55301989350000"],
        [
            "98765432109876543210987654321e-10",
            "98765432109876543210987654321/10000000000",
        ],
        ["9877861857500000E-7", "3951144743/4"],
        ["2169378.417e-3", "2169378417/1000000"],
        [
            "884243222337379604041632732738665534",
            "884243222337379604041632732738665534",
        ],
        ["53/70893980658822810696", "53/70893980658822810696"],
        ["106/141787961317645621392", "53/70893980658822810696"],
        ["204211327800791583.81095", "4084226556015831676219/20000"],
        # Go's issue 16176, where the exponent is enormous and the mantissa is
        # zero, so nothing has to be computed.
        ["0e9999999999", "0"],
        # From `setStringTests2`, which Go keeps apart because `fmt.Fscanf`
        # does not accept them.
        ["0b1000/3", "8/3"],
        ["0B1000/0x8", "1"],
        # A leading zero is an octal prefix here, because this is a fraction.
        ["-010/1", "-8"],
        ["-010.0", "-10"],
        ["-0o10/1", "-8"],
        ["0x10/1", "16"],
        ["0x10/0x20", "1/2"],
        # And here it is ignored, because this is not a fraction.
        ["0010", "10"],
        ["0x10.0", "16"],
        ["0x1.8", "3/2"],
        ["0X1.8p4", "24"],
        # The `E` belongs to the hexadecimal mantissa rather than starting an
        # exponent.
        ["0x1.1E2", "2289/2048"],
        ["0b1.1E2", "150"],
        ["0B1.1P3", "12"],
        ["0o10e-2", "2/25"],
        ["0O10p-3", "1"],
        # Separators.
        ["0b_1000/3", "8/3"],
        ["0B_10_00/0x8", "1"],
        ["0xdead/0B1101_1110_1010_1101", "1"],
        ["0B1101_1110_1010_1101/0XD_E_A_D", "1"],
        ["1_000.0", "1000"],
        ["0x_10.0", "16"],
        ["0x1_0.0", "16"],
        ["0x1.8_0", "3/2"],
        ["0X1.8p0_4", "24"],
        ["0b1.1_0E2", "150"],
        ["0o1_0e-2", "2/25"],
        ["0O_10p-3", "1"],
    ]


def test_set_string() raises:
    # Go's `TestRatSetString`, the valid half.
    for row in _set_string_rows():
        var x = q(row[0])
        assert_equal(x.rat_string(), row[1], row[0])


def test_set_string_rejects() raises:
    # Go's `TestRatSetString`, the invalid half, from both of its tables.
    var bad: List[String] = [
        "1e",
        "1.e",
        "1e+14e-5",
        "1e4.5",
        "r",
        "a/b",
        "a.b",
        "1/0",
        # Go's issue 17001.
        "4/3/2",
        "4/3/",
        "4/3.",
        "4/",
        # CVE-2022-23772, an exponent that overflows on being negated.
        "13e-9223372036854775808",
        "4/3x",
        "0/-1",
        "-1/-1",
        # Separators in the wrong places.
        "10_/1",
        "_10/1",
        "1/1__0",
    ]
    for s in bad:
        assert_false(parses_rat(s), s)


def test_set_string_leaves_the_value_alone() raises:
    # Not from Go, which documents the value as undefined after a failure and
    # returns nil. A raise here has to leave the receiver as it was, or a
    # caller that recovers is holding something it never wrote.
    var x = q("22/7")
    var raised = False
    try:
        x.set_string("not a number")
    except:
        raised = True
    assert_true(raised)
    assert_equal(x.rat_string(), "22/7")


def test_set_string_exponents() raises:
    # Go's `TestScanExponent`, through the only door this library has to the
    # exponent scanner. The rows are its own, with a mantissa put in front of
    # each so that there is a number for the exponent to apply to.
    var good: List[List[String]] = [
        ["1e0", "1"],
        ["1E1", "10"],
        ["1e+10", "10000000000"],
        ["1e-10", "1/10000000000"],
        ["0x1p0", "1"],
        ["0x1P-3", "1/8"],
        ["0b1p+3", "8"],
        ["0o1p0", "1"],
        # A `p` exponent goes with a decimal mantissa too, which is what Go
        # accepts here even though its own scanner takes the question.
        ["1p0", "1"],
        ["2p10", "2048"],
        ["1P+8", "256"],
        ["1p-4", "1/16"],
        # Separators inside an exponent.
        ["1e+1_0", "10000000000"],
        ["1e-1_0", "1/10000000000"],
        ["0x1p-1_2_3", "1/10633823966279326983230456482242756608"],
    ]
    for row in good:
        assert_equal(q(row[0]).rat_string(), row[1], row[0])

    var bad: List[String] = [
        # No digits after the exponent letter.
        "1e",
        "1ef",
        "1e+",
        "1E-x",
        "0x1p",
        "0x1P-",
        "1e+_x",
        "1p",
        "1P-",
        # Separators in the wrong places.
        "1e0_",
        "1e_0",
        "1e-1_2__3",
    ]
    for s in bad:
        assert_false(parses_rat(s), s)


def test_float_string() raises:
    # Go's `TestFloatString`. The negative precisions at the end round to a
    # whole number and drop the point.
    var rows: List[List[String]] = [
        ["0", "0", "0"],
        ["0", "4", "0.0000"],
        ["1", "0", "1"],
        ["1", "2", "1.00"],
        ["-1", "0", "-1"],
        ["0.05", "1", "0.1"],
        ["-0.05", "1", "-0.1"],
        [".25", "2", "0.25"],
        [".25", "1", "0.3"],
        [".25", "3", "0.250"],
        ["-1/3", "3", "-0.333"],
        ["-2/3", "4", "-0.6667"],
        ["0.96", "1", "1.0"],
        ["0.999", "2", "1.00"],
        ["0.9", "0", "1"],
        [".25", "-1", "0"],
        [".55", "-1", "1"],
    ]
    for row in rows:
        var x = q(row[0])
        var prec = Int(p(row[1]).int64())
        assert_equal(x.float_string(prec), row[2], row[0] + " to " + row[1])


def _float64_inputs() -> List[String]:
    """Go's `float64inputs`, without the rows it marks `long:`.

    Those five are a four thousand digit mantissa, a ten thousand digit tail
    and exponents of four hundred thousand, which Go itself runs only under a
    flag.
    """
    return [
        # Table 1: stress inputs for conversion to a 53 bit mantissa, under
        # half an ulp away from the boundary.
        "5e+125",
        "69e+267",
        "999e-026",
        "7861e-034",
        "75569e-254",
        "928609e-261",
        "9210917e+080",
        "84863171e+114",
        "653777767e+273",
        "5232604057e-298",
        "27235667517e-109",
        "653532977297e-123",
        "3142213164987e-294",
        "46202199371337e-072",
        "231010996856685e-073",
        "9324754620109615e+212",
        "78459735791271921e+049",
        "272104041512242479e+200",
        "6802601037806061975e+198",
        "20505426358836677347e-221",
        "836168422905420598437e-234",
        "4891559871276714924261e+222",
        # Table 2: the same, over half an ulp.
        "9e-265",
        "85e-037",
        "623e+100",
        "3571e+263",
        "81661e+153",
        "920657e-023",
        "4603285e-024",
        "87575437e-309",
        "245540327e+122",
        "6138508175e+120",
        "83356057653e+193",
        "619534293513e+124",
        "2335141086879e+218",
        "36167929443327e-159",
        "609610927149051e-255",
        "3743626360493413e-165",
        "94080055902682397e-242",
        "899810892172646163e+283",
        "7120190517612959703e+120",
        "25188282901709339043e-252",
        "308984926168550152811e-052",
        "6372891218502368041059e+064",
        # Table 14: a 24 bit mantissa, under half an ulp.
        "5e-20",
        "67e+14",
        "985e+15",
        "7693e-42",
        "55895e-16",
        "996622e-44",
        "7038531e-32",
        "60419369e-46",
        "702990899e-20",
        "6930161142e-48",
        "25933168707e+13",
        "596428896559e+20",
        # Table 15: a 24 bit mantissa, over half an ulp.
        "3e-23",
        "57e+18",
        "789e-35",
        "2539e-18",
        "76173e+28",
        "887745e-11",
        "5382571e-37",
        "82381273e-35",
        "750486563e-38",
        "3752432815e-39",
        "75224575729e-45",
        "459926601011e+15",
        # From Go's `strconv` tests.
        "0",
        "1",
        "+1",
        "1e23",
        "1E23",
        "100000000000000000000000",
        "1e-100",
        "123456700",
        "99999999999999974834176",
        "100000000000000000000001",
        "100000000000000008388608",
        "100000000000000016777215",
        "100000000000000016777216",
        "-1",
        "-0.1",
        # A rational has one zero, so this one is handled apart.
        "-0",
        "1e-20",
        "625e-3",
        # The largest float64, then the first one past it.
        "1.7976931348623157e308",
        "-1.7976931348623157e308",
        "1.7976931348623159e308",
        "-1.7976931348623159e308",
        # The border is at ...158079, so these round back down and these do
        # not.
        "1.7976931348623158e308",
        "-1.7976931348623158e308",
        "1.797693134862315808e308",
        "-1.797693134862315808e308",
        # A little too large, then far too large.
        "1e308",
        "2e308",
        "1e309",
        "1e310",
        "-1e310",
        "1e400",
        "-1e400",
        # Subnormals.
        "1e-305",
        "1e-306",
        "1e-307",
        "1e-308",
        "1e-309",
        "1e-310",
        "1e-322",
        # The smallest subnormal, then two that round up to it.
        "5e-324",
        "4e-324",
        "3e-324",
        # Too small, then far too small.
        "2e-324",
        "1e-350",
        "-1e-350",
        # Two numbers that used to hang other libraries.
        "2.2250738585072012e-308",
        "2.2250738585072011e-308",
        # A very large one that a fast path once got wrong.
        "4.630813248087435e+307",
        "22.222222222222222",
        # Exactly halfway between one and the float above it, so it rounds
        # down to the even mantissa, then one either side of that.
        "1.00000000000000011102230246251565404236316680908203125",
        "1.00000000000000011102230246251565404236316680908203124",
        "1.00000000000000011102230246251565404236316680908203126",
        # The smallest subnormal written out, then half of it, then a little
        # over half of it, then the exact halfway point between the smallest
        # normal and the largest subnormal.
        "4.940656458412465441765687928682213723651e-324",
        "2.470328229206232720882843964341106861825e-324",
        "2.470328302827751011111470718709768633275e-324",
        "2.225073858507201136057409796709131975935e-308",
        "1152921504606846975",
        "-1152921504606846975",
        "1152921504606846977",
        "-1152921504606846977",
        "1/3",
    ]


def _delta(r: big.Rat, f: Float64) raises -> big.Rat:
    """How far `r` is from `f`. Go's `delta`."""
    var other = big.Rat()
    other.set_float64(f)
    return r.sub(other).abs()


def _is_best_approx64(f: Float64, r: big.Rat) raises -> Bool:
    """Whether `f` is the closest `Float64` to `r`. Go's
    `checkIsBestApprox64`."""
    if f >= 1.7976931348623157e308 or f <= -1.7976931348623157e308:
        # The largest float has no neighbour above it to compare against.
        return True

    var df = _delta(r, f)
    var df0 = _delta(r, nextafter(f, inf(-1)))
    var df1 = _delta(r, nextafter(f, inf(1)))
    if df.cmp(df0) > 0 or df.cmp(df1) > 0:
        return False
    var even = (float64bits(f) & 1) == 0
    if not even and (df.cmp(df0) == 0 or df.cmp(df1) == 0):
        return False
    return True


def _is_best_approx32(f: Float32, r: big.Rat) raises -> Bool:
    """Whether `f` is the closest `Float32` to `r`. Go's
    `checkIsBestApprox32`."""
    if f >= Float32(3.4028234663852886e38) or f <= Float32(
        -3.4028234663852886e38
    ):
        return True

    var df = _delta(r, Float64(f))
    var df0 = _delta(r, Float64(nextafter32(f, Float32(-1e38))))
    var df1 = _delta(r, Float64(nextafter32(f, Float32(1e38))))
    if df.cmp(df0) > 0 or df.cmp(df1) > 0:
        return False
    var even = (float32bits(f) & 1) == 0
    if not even and (df.cmp(df0) == 0 or df.cmp(df1) == 0):
        return False
    return True


def _out_of_range(s: String) -> Bool:
    """Whether `parse_float` says `s` is a number the type cannot hold.

    Go's `ParseFloat` hands back an infinity or a zero alongside the range
    error and its test compares against that value; this raises and keeps no
    value, so a row that is out of range is checked for being at the right end
    rather than for its bits.
    """
    try:
        _ = parse_float(s, 64)
        return False
    except e:
        return matches(e, ErrRange)


def _out_of_range32(s: String) -> Bool:
    """`_out_of_range` for the narrower type."""
    try:
        _ = parse_float(s, 32)
        return False
    except e:
        return matches(e, ErrRange)


def test_float64_special_cases() raises:
    # slow: a hundred and forty numbers, several of them with a few hundred
    # digits, each converted four ways
    # Go's `TestFloat64SpecialCases`, the four checks it makes on every input.
    for input in _float64_inputs():
        var r = q(input)
        var f, exact = r.float64()

        # 1. The string read as a rational and rounded has to be the string
        # read as a float. Rows written as a fraction have no float reading, so
        # they are skipped.
        if "/" not in input:
            if _out_of_range(input):
                # Both sides agree it does not fit, which for a float is an
                # infinity at the top and a zero at the bottom, neither exact.
                assert_true(is_inf(f, 0) or f == 0.0, input + " does not fit")
                assert_false(exact, input + " is not exact")
            else:
                var e = parse_float(input, 64)
                var same = float64bits(e) == float64bits(f)
                # A negative number too small for the type reads as a negative
                # zero, and a rational has only the one zero.
                var both_zero = f == 0.0 and r.num().sign() == 0
                assert_true(same or both_zero, input)

        if is_inf(f, 0):
            continue

        # 2. No other float is closer to the rational than this one.
        assert_true(_is_best_approx64(f, r), input)

        # 3. The float read back as a rational and rounded again is itself.
        var back = big.Rat()
        back.set_float64(f)
        var again, again_exact = back.float64()
        assert_equal(again, f, input + " round trip")
        assert_true(again_exact, input + " round trip is exact")

        # 4. The flag agrees with the slow way of asking, which is whether the
        # float is the rational.
        assert_equal(exact, back.cmp(r) == 0, input + " exactness")


def test_float32_special_cases() raises:
    # slow: the same hundred and forty numbers through the narrower type
    # Go's `TestFloat32SpecialCases`.
    for input in _float64_inputs():
        var r = q(input)
        var f, exact = r.float32()

        if "/" not in input:
            if _out_of_range32(input):
                assert_true(
                    is_inf(Float64(f), 0) or f == Float32(0),
                    input + " does not fit",
                )
                assert_false(exact, input + " is not exact")
            else:
                var e = Float32(parse_float(input, 32))
                var same = float32bits(e) == float32bits(f)
                var both_zero = f == Float32(0) and r.num().sign() == 0
                assert_true(same or both_zero, input)

        if is_inf(Float64(f), 0):
            continue

        assert_true(_is_best_approx32(f, r), input)

        var back = big.Rat()
        back.set_float64(Float64(f))
        var again, again_exact = back.float32()
        assert_equal(again, f, input + " round trip")
        assert_true(again_exact, input + " round trip is exact")

        assert_equal(exact, back.cmp(r) == 0, input + " exactness")


def test_issue_31184() raises:
    # Go's `TestIssue31184`, where printing at a fixed precision lost a digit.
    var values: List[String] = ["-213.090", "8.192", "16.000"]
    for want in values:
        var x = q(want)
        assert_equal(x.float_string(3), want)


def test_issue_45910() raises:
    # Go's `TestIssue45910`. An exponent past the limit is refused rather than
    # turned into a number nobody has the memory for, and a zero mantissa is
    # allowed any exponent at all because there is nothing to scale.
    var rows: List[List[String]] = [
        ["1e-1000001", "no"],
        ["1e-1000000", "yes"],
        ["1e+1000000", "yes"],
        ["1e+1000001", "no"],
        ["0p1000000000000", "yes"],
        ["1p-10000001", "no"],
        ["1p-10000000", "yes"],
        ["1p+10000000", "yes"],
        ["1p+10000001", "no"],
        # The row from the issue itself.
        ["1.770p02041010010011001001", "no"],
    ]
    for row in rows:
        assert_equal(parses_rat(row[0]), row[1] == "yes", row[0])


def _float_prec_rows() -> List[List[String]]:
    """Go's `TestFloatPrec` table, as the number, the precision, whether it is
    exact and the decimal it prints as."""
    return [
        # From Go's issue 50489.
        ["10/100", "1", "yes", "0.1"],
        ["3/100", "2", "yes", "0.03"],
        ["10", "0", "yes", "10"],
        ["0", "0", "yes", "0"],
        ["1", "0", "yes", "1"],
        ["1/2", "1", "yes", "0.5"],
        ["1/3", "0", "no", "0"],
        ["1/4", "2", "yes", "0.25"],
        ["1/5", "1", "yes", "0.2"],
        ["1/6", "1", "no", "0.2"],
        ["1/7", "0", "no", "0"],
        ["1/8", "3", "yes", "0.125"],
        ["1/9", "0", "no", "0"],
        ["1/10", "1", "yes", "0.1"],
        ["1/11", "0", "no", "0"],
        ["1/12", "2", "no", "0.08"],
        ["1/13", "0", "no", "0"],
        ["1/14", "1", "no", "0.1"],
        ["1/15", "1", "no", "0.1"],
        ["1/16", "4", "yes", "0.0625"],
        ["10/2", "0", "yes", "5"],
        ["10/3", "0", "no", "3"],
        ["10/6", "0", "no", "2"],
        ["1/10000000", "7", "yes", "0.0000001"],
        ["1/3125", "5", "yes", "0.00032"],
        ["1/1024", "10", "yes", "0.0009765625"],
        ["1/304000", "7", "no", "0.0000033"],
        ["1/48828125", "11", "yes", "0.00000002048"],
    ]


def test_float_prec() raises:
    # Go's `TestFloatPrec`. The answer for a number and for its negative are
    # the same, so every row is run twice.
    for row in _float_prec_rows():
        var f = q(row[0])
        var want_prec = Int(p(row[1]).int64())
        var want_ok = row[2] == "yes"
        var want_dec = row[3]

        for _ in range(2):
            var prec, ok = f.float_prec()
            assert_equal(prec, want_prec, row[0])
            assert_equal(ok, want_ok, row[0] + " exactness")
            assert_equal(f.float_string(want_prec), want_dec, row[0])

            if f.sign() > 0:
                f = f.neg()
                want_dec = "-" + want_dec


def test_float_prec_of_the_zero_value() raises:
    # Go's `TestFloatPrec` runs its table over a `Rat` that was never set as
    # well, which here is the zero value with a denominator of one.
    var f = big.Rat()
    var prec, ok = f.float_prec()
    assert_equal(prec, 0)
    assert_true(ok)
    assert_equal(f.float_string(0), "0")


def test_float_prec_powers_of_five() raises:
    # From Go's `BenchmarkFloatPrecExact`, which is the only place the squaring
    # table inside `float_prec` gets a denominator big enough to use it. One
    # over five to the n is exact at n digits.
    var powers: List[Int] = [1, 10, 100, 1000]
    for n in powers:
        var d = big.Int(Int64(5)).exp(big.Int(Int64(n)), big.Int())
        var r = big.Rat()
        r.set_frac(big.Int(Int64(1)), d)
        var prec, ok = r.float_prec()
        assert_equal(prec, n)
        assert_true(ok)

    # Five to the n with one added is not a power of five and never terminates.
    for n in powers:
        var d = big.Int(Int64(5)).exp(big.Int(Int64(n)), big.Int())
        var r = big.Rat()
        r.set_frac(big.Int(Int64(1)), d.add(big.Int(Int64(1))))
        var prec, ok = r.float_prec()
        assert_false(ok, "one over five to the n plus one")
        # Five to the n plus one is even, so there is a factor of two in there
        # and the terminating part is not empty.
        assert_true(prec >= 1, "one over five to the n plus one")
