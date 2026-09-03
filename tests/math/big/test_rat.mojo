"""Go's `rat_test.go`.

Go's tests here iterate over `setStringTests`, which lives in
`ratconv_test.go`, because both files are the same package. Two test files here
are two modules, so the strings a test needs are in the file that needs them:
the table that says what each string parses to is in `test_ratconv.mojo`, and
this file has a list of valid ones for the tests that only need something to
work on.

The aliasing tests Go carries, `TestIssue2379` and `TestIssue3521`, are about
pointers into a `Rat`: what happens when the numerator handed to `SetFrac` is
the receiver's own, and whether `Denom` hands back a pointer that changes with
the value. A `Rat` here is a value and `num` and `denom` return copies, so
those questions have one answer rather than five, and the two tests come down
to checking that answer once.
"""

from std.testing import assert_equal, assert_false, assert_true

import core.math.big as big
from core.errors import matches
from core.errors.codes import ErrDivideByZero, ErrInvalidArgument
from core.math import float64bits, inf, is_inf, nan, nextafter

from tests.math.big._fixtures import p, q


def _rationals() -> List[String]:
    """Valid rows of Go's `setStringTests` and `setStringTests2`, as written.

    A spread of both forms and both signs, which is what the tests that work
    over every value need.
    """
    return [
        "0",
        "-0",
        "1",
        "-1",
        "1.",
        "1e0",
        "1.e1",
        "-0.1",
        "-.1",
        "2/4",
        ".25",
        "-1/5",
        "8129567.7690E14",
        "78189e+4",
        "553019.8935e+8",
        "98765432109876543210987654321e-10",
        "9877861857500000E-7",
        "2169378.417e-3",
        "884243222337379604041632732738665534",
        "53/70893980658822810696",
        "106/141787961317645621392",
        "204211327800791583.81095",
        "0b1000/3",
        "-010/1",
        "0x10/0x20",
        "0X1.8p4",
    ]


def test_zero_rat() raises:
    # Go's `TestZeroRat`. The zero value is a number, not a value waiting to be
    # initialised, and dividing by it is the one thing it cannot do.
    var x = big.Rat()
    var y = big.Rat()
    y.set_frac64(0, 42)

    assert_equal(x.cmp(y), 0, "both are zero")
    assert_equal(x.string(), "0/1")
    assert_equal(x.rat_string(), "0")
    assert_equal(x.add(y).rat_string(), "0")
    assert_equal(x.sub(y).rat_string(), "0")
    assert_equal(x.mul(y).rat_string(), "0")

    var raised = False
    var err = Error()
    try:
        _ = x.quo(y)
    except e:
        raised = True
        err = e
    assert_true(raised, "dividing by zero")
    assert_true(matches(err, ErrDivideByZero))


def test_sign() raises:
    # Go's `TestRatSign`. The sign and the comparison against zero are two
    # readings of the same thing and have to agree.
    var zero = big.new_rat(0, 1)
    for s in _rationals():
        var x = q(s)
        assert_equal(x.sign(), x.cmp(zero), s)


def test_is_int() raises:
    # Go's `TestIsInt`.
    var one = big.Int(Int64(1))
    for s in _rationals():
        var x = q(s)
        assert_equal(x.is_int(), x.denom().cmp(one) == 0, s)


def test_abs() raises:
    # Go's `TestRatAbs`.
    var zero = big.Rat()
    for s in _rationals():
        var x = q(s)
        var want = x.copy()
        if want.cmp(zero) < 0:
            want = zero.sub(x)
        assert_equal(x.abs().cmp(want), 0, s)


def test_neg() raises:
    # Go's `TestRatNeg`.
    var zero = big.Rat()
    for s in _rationals():
        var x = q(s)
        assert_equal(x.neg().cmp(zero.sub(x)), 0, s)


def test_inv() raises:
    # Go's `TestRatInv`. The inverse is the same value with the two halves
    # swapped, which is what `set_frac` is asked for here.
    var zero = big.Rat()
    for s in _rationals():
        var x = q(s)
        if x.cmp(zero) == 0:
            continue
        var want = big.Rat()
        want.set_frac(x.denom(), x.num())
        assert_equal(x.inv().cmp(want), 0, s)

    var raised = False
    var err = Error()
    try:
        _ = zero.inv()
    except e:
        raised = True
        err = e
    assert_true(raised, "one over zero")
    assert_true(matches(err, ErrDivideByZero))


def _cmp_rows() -> List[List[String]]:
    """Go's `ratCmpTests`, as `x`, `y`, `out`."""
    return [
        ["0", "0/1", "0"],
        ["1/1", "1", "0"],
        ["-1", "-2/2", "0"],
        ["1", "0", "1"],
        ["0/1", "1/1", "-1"],
        ["-5/1434770811533343057144", "-5/1434770811533343057145", "-1"],
        [
            "49832350382626108453/8964749413",
            "49832350382626108454/8964749413",
            "-1",
        ],
        [
            "-37414950961700930/7204075375675961",
            "37414950961700930/7204075375675961",
            "-1",
        ],
        [
            "37414950961700930/7204075375675961",
            "74829901923401860/14408150751351922",
            "0",
        ],
    ]


def test_cmp() raises:
    # Go's `TestRatCmp`. The last row is the same number written twice, which
    # is the case that fails when a comparison looks at the digits rather than
    # at the value.
    for row in _cmp_rows():
        var x = q(row[0])
        var y = q(row[1])
        var want = Int(p(row[2]).int64())
        assert_equal(x.cmp(y), want, row[0] + " against " + row[1])
        assert_equal(y.cmp(x), -want, row[1] + " against " + row[0])

        # The operators are the comparison read six ways.
        assert_equal(x == y, want == 0, row[0] + " ==")
        assert_equal(x != y, want != 0, row[0] + " !=")
        assert_equal(x < y, want < 0, row[0] + " <")
        assert_equal(x <= y, want <= 0, row[0] + " <=")
        assert_equal(x > y, want > 0, row[0] + " >")
        assert_equal(x >= y, want >= 0, row[0] + " >=")


def _bin_rows() -> List[List[String]]:
    """Go's `ratBinTests`, as `x`, `y`, `sum`, `prod`."""
    return [
        ["0", "0", "0", "0"],
        ["0", "1", "1", "0"],
        ["-1", "0", "-1", "0"],
        ["-1", "1", "0", "-1"],
        ["1", "1", "2", "1"],
        ["1/2", "1/2", "1", "1/4"],
        ["1/4", "1/3", "7/12", "1/12"],
        ["2/5", "-14/3", "-64/15", "-28/15"],
        [
            "4707/49292519774798173060",
            "-3367/70976135186689855734",
            "84058377121001851123459/1749296273614329067191168098769082663020",
            "-1760941/388732505247628681598037355282018369560",
        ],
        [
            "-61204110018146728334/3",
            "-31052192278051565633/2",
            "-215564796870448153567/6",
            "950260896245257153059642991192710872711/3",
        ],
        [
            "-854857841473707320655/4237645934602118692642972629634714039",
            "-18/31750379913563777419",
            "-27/133467566250814981",
            (
                "15387441146526731771790/"
                "134546868362786310073779084329032722548987800600710485341"
            ),
        ],
        [
            "618575745270541348005638912139/19198433543745179392300736",
            "-19948846211000086/637313996471",
            "27674141753240653/30123979153216",
            (
                "-6169936206128396568797607742807090270137721977/"
                "6117715203873571641674006593837351328"
            ),
        ],
        [
            "-3/26206484091896184128",
            "5/2848423294177090248",
            "15310893822118706237/9330894968229805033368778458685147968",
            "-5/24882386581946146755650075889827061248",
        ],
        [
            "26946729/330400702820",
            "41563965/225583428284",
            "1238218672302860271/4658307703098666660055",
            "224002580204097/14906584649915733312176",
        ],
        [
            "-8259900599013409474/7",
            "-84829337473700364773/56707961321161574960",
            "-468402123685491748914621885145127724451/396955729248131024720",
            "350340947706464153265156004876107029701/198477864624065512360",
        ],
        [
            "575775209696864/1320203974639986246357",
            "29/712593081308",
            "410331716733912717985762465/940768218243776489278275419794956",
            "808/45524274987585732633",
        ],
        [
            "1786597389946320496771/2066653520653241",
            "6269770/1992362624741777",
            (
                "3559549865190272133656109052308126637/"
                "4117523232840525481453983149257"
            ),
            "8967230/3296219033",
        ],
        [
            "-36459180403360509753/32150500941194292113930",
            "9381566963714/9633539",
            (
                "301622077145533298008420642898530153/"
                "309723104686531919656937098270"
            ),
            "-3784609207827/3426986245",
        ],
    ]


def test_add_and_sub() raises:
    # Go's `TestRatBin`, the `Add` and `Sub` half, both ways round each.
    for row in _bin_rows():
        var x = q(row[0])
        var y = q(row[1])
        var sum = q(row[2])
        assert_equal(x.add(y).cmp(sum), 0, row[0] + " + " + row[1])
        assert_equal(y.add(x).cmp(sum), 0, row[1] + " + " + row[0])
        assert_equal(sum.sub(x).cmp(y), 0, row[2] + " - " + row[0])
        assert_equal(sum.sub(y).cmp(x), 0, row[2] + " - " + row[1])


def test_mul_and_quo() raises:
    # Go's `TestRatBin`, the `Mul` and `Quo` half. Go skips the division when
    # the divisor is the zero row, and so does this.
    var zero = big.Rat()
    for row in _bin_rows():
        var x = q(row[0])
        var y = q(row[1])
        var prod = q(row[3])
        assert_equal(x.mul(y).cmp(prod), 0, row[0] + " * " + row[1])
        assert_equal(y.mul(x).cmp(prod), 0, row[1] + " * " + row[0])
        if x.cmp(zero) != 0:
            assert_equal(prod.quo(x).cmp(y), 0, row[3] + " / " + row[0])
        if y.cmp(zero) != 0:
            assert_equal(prod.quo(y).cmp(x), 0, row[3] + " / " + row[1])


def test_mul_squares() raises:
    # Not from Go as a test, but it is the path Go's `Mul` takes when both
    # arguments are the same pointer, and here when they are the same value.
    # That path multiplies the two halves and stops, on the grounds that a
    # reduced fraction squared is still reduced, so what has to be checked is
    # that it agrees with dividing the common factor out.
    var values: List[String] = [
        "0",
        "1",
        "-1",
        "2/3",
        "-7/12",
        "618575745270541348005638912139/19198433543745179392300736",
    ]
    for s in values:
        var x = q(s)
        var want = big.Rat()
        want.set_frac(x.num().mul(x.num()), x.denom().mul(x.denom()))
        assert_equal(x.mul(x).cmp(want), 0, s)
        assert_true(x.mul(x).sign() >= 0, s + " squared is not negative")


def test_quo_of_a_value_by_itself() raises:
    # Go's `TestIssue820`, where dividing into one of the arguments used to
    # leave the other one wrong. A value cannot be the receiver and an argument
    # at once here, so the bug is not expressible, and what is left is that the
    # three answers are right.
    assert_equal(
        big.new_rat(3, 1).quo(big.new_rat(2, 1)).cmp(big.new_rat(3, 2)), 0
    )
    assert_equal(
        big.new_rat(2, 1).quo(big.new_rat(3, 1)).cmp(big.new_rat(2, 3)), 0
    )
    var x = big.new_rat(3, 1)
    assert_equal(x.quo(x).cmp(big.new_rat(3, 3)), 0)


def test_set_frac64() raises:
    # Go's `TestRatSetFrac64Rat`. The last row is the most negative `Int64`
    # over itself, where negating either half overflows and the answer is still
    # one.
    var rows: List[List[String]] = [
        ["0", "1", "0"],
        ["0", "-1", "0"],
        ["1", "1", "1"],
        ["-1", "1", "-1"],
        ["1", "-1", "-1"],
        ["-1", "-1", "1"],
        ["-9223372036854775808", "-9223372036854775808", "1"],
        ["-9223372036854775808", "1", "-9223372036854775808"],
        ["2", "-4", "-1/2"],
        ["-6", "-4", "3/2"],
    ]
    for row in rows:
        var x = big.Rat()
        x.set_frac64(p(row[0]).int64(), p(row[1]).int64())
        assert_equal(x.rat_string(), row[2], row[0] + " over " + row[1])

    var raised = False
    var err = Error()
    try:
        var x = big.Rat()
        x.set_frac64(1, 0)
    except e:
        raised = True
        err = e
    assert_true(raised, "one over zero")
    assert_true(matches(err, ErrDivideByZero))


def test_set_frac() raises:
    # Go's `TestIssue2379`, which is five cases of the same call with the
    # arguments aliasing the receiver in every combination. `num` and `denom`
    # return copies here, so all five are the same call and all five have to
    # give the same answer.
    var want = big.new_rat(3, 2)

    var x = big.Rat()
    x.set_frac(big.Int(Int64(3)), big.Int(Int64(2)))
    assert_equal(x.cmp(want), 0, "no aliasing")

    x = big.new_rat(2, 3)
    x.set_frac(big.Int(Int64(3)), x.num())
    assert_equal(x.cmp(want), 0, "the numerator was its own")

    x = big.new_rat(2, 3)
    x.set_frac(x.denom(), big.Int(Int64(2)))
    assert_equal(x.cmp(want), 0, "the denominator was its own")

    x = big.new_rat(2, 3)
    x.set_frac(x.denom(), x.num())
    assert_equal(x.cmp(want), 0, "both were its own")

    var n = big.Int(Int64(7))
    x = big.Rat()
    x.set_frac(n, n)
    assert_equal(x.cmp(big.new_rat(1, 1)), 0, "the same number twice")

    # A negative denominator moves its sign to the numerator.
    x.set_frac(big.Int(Int64(3)), big.Int(Int64(-2)))
    assert_equal(x.rat_string(), "-3/2", "a negative denominator")
    assert_equal(x.denom().sign(), 1, "the denominator stays positive")

    var raised = False
    try:
        x.set_frac(big.Int(Int64(1)), big.Int())
    except e:
        raised = True
        assert_true(matches(e, ErrDivideByZero))
    assert_true(raised, "over zero")


def test_num_and_denom_are_copies() raises:
    # Go's `TestIssue3521`, adapted. Go's `Num` and `Denom` return pointers
    # into the value, and most of that test is about what changes when they are
    # written through. Here they are copies, which `docs/deviations.md`
    # records, so what is checked is that writing to one changes nothing.
    var x = big.new_rat(10, 4)
    var n = x.num()
    var d = x.denom()
    assert_equal(n.string(), "5", "the numerator comes back reduced")
    assert_equal(d.string(), "2", "and so does the denominator")

    n.set_int64(99)
    d.set_int64(99)
    assert_equal(x.rat_string(), "5/2", "the number did not move")

    # The zero value has a denominator of one, where Go has to make one up on
    # the way out because it stores an empty one.
    var zero = big.Rat()
    assert_equal(zero.denom().string(), "1")
    assert_equal(zero.num().string(), "0")


def test_set_int_and_set_int64() raises:
    # Go's `TestRatSetInt64` and `TestRatSetUint64`, and `SetInt` alongside
    # them. Every one of these is a whole number, so `is_int` is true and the
    # numerator is the number.
    var values: List[String] = [
        "0",
        "1",
        "-1",
        "12345",
        "-98765",
        "9223372036854775807",
        "-9223372036854775808",
    ]
    for s in values:
        var x = big.Rat()
        x.set_int64(p(s).int64())
        assert_true(x.is_int(), s)
        assert_true(x.num().is_int64(), s + " fits")
        assert_equal(x.num().int64(), p(s).int64(), s)

        var y = big.Rat()
        y.set_int(p(s))
        assert_equal(y.cmp(x), 0, s + " through set_int")

    var unsigned: List[String] = ["0", "1", "12345", "18446744073709551615"]
    for s in unsigned:
        var x = big.Rat()
        x.set_uint64(p(s).uint64())
        assert_true(x.is_int(), s)
        assert_true(x.num().is_uint64(), s + " fits")
        assert_equal(x.num().uint64(), p(s).uint64(), s)

    # A big number that no machine integer holds, through `set_int`.
    var big_one = p("298472983472983471903246121093472394872319615612417471")
    var z = big.Rat()
    z.set_int(big_one)
    assert_true(z.is_int())
    assert_equal(z.num().cmp(big_one), 0)


def test_set() raises:
    # Go's `Rat.Set`, which is a copy. The two are separate numbers afterwards,
    # which is the whole difference between this library and Go's pointers.
    var x = q("22/7")
    var y = big.Rat()
    y.set(x)
    assert_equal(y.rat_string(), "22/7")

    y.set_int64(3)
    assert_equal(x.rat_string(), "22/7", "the source did not move")


def test_set_float64_round_trip() raises:
    # Go's `checkNonLossyRoundtrip64`. Every finite float is a whole number
    # over a power of two, so the rational is exact and reading it back gives
    # the float again with nothing lost.
    var values: List[Float64] = [
        0.0,
        1.0,
        -1.0,
        0.5,
        -0.5,
        2.0,
        1.0 / 3.0,
        1e23,
        -1e23,
        1.7976931348623157e308,
        -1.7976931348623157e308,
        2.2250738585072014e-308,
        5e-324,
        -5e-324,
        1234.5678,
        -0.0,
    ]
    for f in values:
        var r = big.Rat()
        r.set_float64(f)
        var got, exact = r.float64()
        assert_equal(got, f, "round trip")
        assert_true(exact, "round trip is exact")

    # A denormal and a normal both come back as fractions over a power of two.
    var half = big.Rat()
    half.set_float64(0.5)
    assert_equal(half.rat_string(), "1/2")

    var quarter = big.Rat()
    quarter.set_float64(-0.25)
    assert_equal(quarter.rat_string(), "-1/4")

    var three = big.Rat()
    three.set_float64(3.0)
    assert_equal(three.rat_string(), "3")


def test_set_float64_rejects_the_non_finite() raises:
    # Go's `TestSetFloat64NonFinite`, where Go returns nil.
    var values: List[Float64] = [nan(), inf(1), inf(-1)]
    for f in values:
        var r = big.new_rat(7, 5)
        var raised = False
        var err = Error()
        try:
            r.set_float64(f)
        except e:
            raised = True
            err = e
        assert_true(raised, "a non finite float")
        assert_true(matches(err, ErrInvalidArgument))
        assert_equal(r.rat_string(), "7/5", "the receiver was not touched")


def _delta(r: big.Rat, f: Float64) raises -> big.Rat:
    """How far `r` is from `f`. Go's `delta`."""
    var other = big.Rat()
    other.set_float64(f)
    return r.sub(other).abs()


def _is_best_approx64(f: Float64, r: big.Rat) raises -> Bool:
    """Whether `f` is the closest `Float64` to `r`. Go's
    `checkIsBestApprox64`.

    The two floats either side of `f` must both be at least as far from `r` as
    `f` is, and on an exact tie the winner has to be the one with the even
    mantissa.
    """
    if f >= 1.7976931348623157e308 or f <= -1.7976931348623157e308:
        # The largest float and the infinities have no neighbour on one side.
        return True

    var below = nextafter(f, inf(-1))
    var above = nextafter(f, inf(1))
    var df = _delta(r, f)
    var df0 = _delta(r, below)
    var df1 = _delta(r, above)
    if df.cmp(df0) > 0 or df.cmp(df1) > 0:
        return False
    var even = (float64bits(f) & 1) == 0
    if df.cmp(df0) == 0 and not even:
        return False
    if df.cmp(df1) == 0 and not even:
        return False
    return True


def test_float64_distribution() raises:
    # slow: builds a few hundred rationals with exponents out to a thousand
    # Go's `TestFloat64Distribution`, at the step sizes its quick mode uses. A
    # mantissa near a power of two, scaled by every power of two across the
    # whole range of the type and past both ends of it, is where a rounding
    # rule that is nearly right goes wrong.
    var add: List[Int64] = [0, 1, 3, 5, 7, 9, 11]
    var signs: List[Int64] = [1, -1]
    for sign in signs:
        for a in add:
            for wid in range(0, 60, 10):
                var b = big.Int(Int64(1)).lsh(wid).add(big.Int(a))
                if sign < 0:
                    b = b.neg()
                for exp in range(-1100, 1100, 500):
                    var num = b.copy()
                    var den = big.Int(Int64(1))
                    if exp > 0:
                        num = num.lsh(exp)
                    else:
                        den = den.lsh(-exp)
                    var r = big.Rat()
                    r.set_frac(num, den)

                    var f, exact = r.float64()
                    assert_true(
                        _is_best_approx64(f, r),
                        "the nearest float to " + r.rat_string(),
                    )
                    if not is_inf(f, 0):
                        # The flag has to say what the slow check says, which
                        # is whether the float read back as a rational is the
                        # number itself.
                        assert_equal(
                            exact,
                            _delta(r, f).sign() == 0,
                            "exactness for " + r.rat_string(),
                        )


def test_float64_of_a_whole_number() raises:
    # Not from Go. A rational whose denominator is one is an integer, and the
    # answer has to be the one `Int.float64` gives, which is a separate piece
    # of code that rounds the same way.
    var values: List[String] = [
        "0",
        "1",
        "-1",
        "9007199254740993",
        "-9007199254740993",
        "18446744073709551616",
        "298472983472983471903246121093472394872319615612417471234712061",
    ]
    for s in values:
        var x = p(s)
        var r = big.Rat()
        r.set_int(x)
        var got, exact = r.float64()
        var want, acc = x.float64()
        assert_equal(got, want, s)
        assert_equal(exact, acc == big.Exact, s + " exactness")


def test_float32_matches_float64_when_narrow() raises:
    # Not from Go. Every number here fits a `Float32` exactly, so both
    # conversions have to be exact and the narrow one has to be the wide one.
    var values: List[String] = [
        "0",
        "1",
        "-1",
        "1/2",
        "-3/4",
        "16777215",
        "-16777215",
        "1/1024",
    ]
    for s in values:
        var r = q(s)
        var wide, wide_exact = r.float64()
        var narrow, narrow_exact = r.float32()
        assert_true(wide_exact, s + " is exact as a float64")
        assert_true(narrow_exact, s + " is exact as a float32")
        assert_equal(Float64(narrow), wide, s)


def test_float32_and_float64_overflow() raises:
    # Go's tests reach this through the `float64inputs` table; here it is said
    # directly. Past the top of the type the answer is an infinity with the
    # sign of the number, and it is not exact.
    var big_one = big.Rat()
    big_one.set_int(big.Int(Int64(1)).lsh(2000))
    var f, exact = big_one.float64()
    assert_true(f > 0 and f * 0.5 == f, "an infinity")
    assert_false(exact, "an infinity is not exact")

    var negative = big_one.neg()
    var g, g_exact = negative.float64()
    assert_true(g < 0 and g * 0.5 == g, "a negative infinity")
    assert_false(g_exact)

    # A number a `Float64` holds and a `Float32` does not.
    var wide = big.Rat()
    wide.set_float64(1e300)
    var narrow, narrow_exact = wide.float32()
    assert_true(Float64(narrow) > 0 and narrow * Float32(0.5) == narrow)
    assert_false(narrow_exact, "too large for a float32")

    var f64, f64_exact = wide.float64()
    assert_equal(f64, 1e300)
    assert_true(f64_exact, "but it is a float64")


def test_float64_underflow() raises:
    # Not from Go directly. Below the smallest denormal the answer is a zero
    # that is not exact, and the sign is kept.
    var tiny = big.Rat()
    tiny.set_frac(big.Int(Int64(1)), big.Int(Int64(1)).lsh(2000))
    var f, exact = tiny.float64()
    assert_equal(f, 0.0, "too small to hold")
    assert_false(exact)

    # The smallest denormal itself is exact, and half of it rounds to it.
    var smallest = big.Rat()
    smallest.set_float64(5e-324)
    var got, got_exact = smallest.float64()
    assert_equal(got, 5e-324)
    assert_true(got_exact)

    var half = smallest.quo(big.new_rat(2, 1))
    var rounded, rounded_exact = half.float64()
    assert_false(rounded_exact, "half a denormal is not a float")
    assert_true(rounded == 0.0 or rounded == 5e-324, "it goes to a neighbour")


def test_float64_rounds_to_even() raises:
    # Not from Go as a table, but it is what `checkIsBestApprox64` is for. The
    # halfway point between two floats goes to the one with the even mantissa,
    # so the same distance rounds down here and up one step along.
    var one = big.Rat()
    one.set_float64(1.0)
    var step = big.Rat()
    step.set_float64(nextafter(1.0, 2.0) - 1.0)
    var half = step.quo(big.new_rat(2, 1))

    var down, down_exact = one.add(half).float64()
    assert_equal(down, 1.0, "a tie goes to the even mantissa")
    assert_false(down_exact)

    var next = big.Rat()
    next.set_float64(nextafter(1.0, 2.0))
    var up, up_exact = next.add(half).float64()
    assert_equal(up, nextafter(nextafter(1.0, 2.0), 2.0), "and up from here")
    assert_false(up_exact)


def test_copies_do_not_share() raises:
    # Not from Go, which cannot ask the question: its documentation says a
    # shallow copy of a `Rat` is not supported. Here a copy is a number.
    var x = q("355/113")
    var y = x.copy()
    y = y.add(big.new_rat(1, 1))
    assert_equal(x.rat_string(), "355/113", "the original did not move")
    assert_equal(y.rat_string(), "468/113")
