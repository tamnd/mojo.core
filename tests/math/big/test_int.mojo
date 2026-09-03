"""Go's `TestSignZ`, `TestAbsZ`, `TestSumZZ`, `TestProdZZ`, `TestMulRangeZ`,
`TestBinomial`, `TestDivisionSigns`, `TestQuo`, `TestBitLen`, `TestCmpAbs`,
`TestInt64` and `TestUint64`, from `int_test.go`.

The arithmetic half. The bit operations are in `test_intbits.mojo`, the modular
ones in `test_intmod.mojo`, and conversion in `test_intconv.mojo`.

Go's tests run each table twice, once into a fresh destination and once with the
destination aliasing an operand, because `z.Add(z, y)` is a shape its API
allows. There is no destination here, so that half of every Go test has nothing
to correspond to and is not written out. What replaces it is the check that an
operand is not disturbed, which is the property the aliasing tests were really
defending.
"""

from std.testing import assert_equal, assert_true

import core.math.big as big
from core.errors import matches
from core.errors.codes import ErrDivideByZero, ErrInvalidArgument

from tests.math.big._fixtures import p


def _sum_zz() -> List[List[String]]:
    """Go's `sumZZ`, as `z`, `x`, `y` with `z == x + y`."""
    return [
        ["0", "0", "0"],
        ["1", "1", "0"],
        ["1111111110", "123456789", "987654321"],
        ["-1", "-1", "0"],
        ["864197532", "-123456789", "987654321"],
        ["-1111111110", "-123456789", "-987654321"],
    ]


def _prod_zz() -> List[List[String]]:
    """Go's `prodZZ`, as `z`, `x`, `y` with `z == x * y`.

    The last row is not Go's. Go's table stops at products that fit in a
    machine integer and has a note asking for larger ones.
    """
    return [
        ["0", "0", "0"],
        ["0", "1", "0"],
        ["1", "1", "1"],
        ["-982081", "991", "-991"],
        ["121932631112635269", "123456789", "987654321"],
    ]


def test_sign() raises:
    # Go's `TestSignZ`, which reads the sign off every left hand side of the
    # sum table and off its negation.
    for row in _sum_zz():
        var x = p(row[0])
        var want = 0
        if row[0][byte=0:1] == "-":
            want = -1
        elif row[0] != "0":
            want = 1
        assert_equal(x.sign(), want, row[0])
        assert_equal(x.neg().sign(), -want, row[0])


def test_abs() raises:
    # Go's `TestAbsZ`.
    for row in _sum_zz():
        var x = p(row[0])
        var text = row[0]
        var stripped = text
        if text[byte=0:1] == "-":
            stripped = String(text[byte=1:])
        assert_equal(x.abs().string(), stripped)
        assert_equal(x.neg().abs().string(), stripped)


def test_sum() raises:
    # Go's `TestSumZZ`, which checks the addition and both subtractions each
    # row of the table implies.
    for row in _sum_zz():
        var z = p(row[0])
        var x = p(row[1])
        var y = p(row[2])
        assert_equal(x.add(y).string(), z.string(), "x + y")
        assert_equal(y.add(x).string(), z.string(), "y + x")
        assert_equal(z.sub(y).string(), x.string(), "z - y")
        assert_equal(z.sub(x).string(), y.string(), "z - x")
        # The operands are still what they were, which is what Go's aliasing
        # cases were guarding.
        assert_equal(x.string(), row[1])
        assert_equal(y.string(), row[2])


def test_prod() raises:
    # Go's `TestProdZZ`, plus the division back where the divisor is not zero.
    for row in _prod_zz():
        var z = p(row[0])
        var x = p(row[1])
        var y = p(row[2])
        assert_equal(x.mul(y).string(), z.string(), "x * y")
        assert_equal(y.mul(x).string(), z.string(), "y * x")
        if y.sign() != 0:
            assert_equal(z.quo(y).string(), x.string(), "z / y")
        if x.sign() != 0:
            assert_equal(z.quo(x).string(), y.string(), "z / x")


def test_mul_range() raises:
    # Go's `mulRangesZ`, the half of `TestMulRangeZ` that is not covered by the
    # unsigned table. The four rows at the end are the ones that overflow an
    # `Int64` product and so say whether the range is being multiplied out
    # rather than computed.
    var rows: List[List[String]] = [
        ["-1", "1", "0"],
        ["-2", "-1", "2"],
        ["-3", "-2", "6"],
        ["-3", "-1", "-6"],
        ["1", "3", "6"],
        ["-10", "-10", "-10"],
        # An empty range, twice.
        ["0", "-1", "1"],
        ["-1", "-100", "1"],
        # A range containing zero, three times.
        ["-1", "1", "0"],
        ["-1000000000", "0", "0"],
        ["-1000000000", "1000000000", "0"],
        ["-10", "-1", "3628800"],
        ["-20", "-2", "-2432902008176640000"],
        [
            "-99",
            "-1",
            (
                "-933262154439441526816992388562667004907159682643816214685929"
                "638952175999932299156089414639761565182862536979208272237582"
                "511852109168640000000000000000000000"
            ),
        ],
        ["9223372036854775807", "9223372036854775807", "9223372036854775807"],
        [
            "9223372036854775806",
            "9223372036854775807",
            "85070591730234615838173535747377725442",
        ],
        [
            "9223372036854775805",
            "9223372036854775807",
            "784637716923335094969050127519550606919189611815754530810",
        ],
        [
            "9223372036854775804",
            "9223372036854775807",
            (
                "7237005577332262206126809393809643289012107973151163787181"
                "513908099760521240"
            ),
        ],
    ]
    for row in rows:
        var a = p(row[0]).int64()
        var b = p(row[1]).int64()
        assert_equal(
            big.Int.mul_range(a, b).string(), row[2], row[0] + ".." + row[1]
        )


def test_binomial() raises:
    # Go's `TestBinomial`.
    var rows: List[List[Int64]] = [
        [0, 0],
        [0, 1],
        [1, 0],
        [1, 1],
        [1, 10],
        [4, 0],
        [4, 1],
        [4, 2],
        [4, 3],
        [4, 4],
        [10, 1],
        [10, 9],
        [10, 5],
        [11, 5],
        [11, 6],
        [100, 10],
        [100, 90],
        [1000, 10],
        [1000, 990],
        [5, -1],
    ]
    var want: List[String] = [
        "1",
        "0",
        "1",
        "1",
        "0",
        "1",
        "4",
        "6",
        "4",
        "1",
        "10",
        "10",
        "252",
        "462",
        "462",
        "17310309456440",
        "17310309456440",
        "263409560461970212832400",
        "263409560461970212832400",
        "0",
    ]
    for i in range(len(rows)):
        assert_equal(
            big.Int.binomial(rows[i][0], rows[i][1]).string(),
            want[i],
            String("binomial ", i),
        )


def test_division_signs() raises:
    # Go's `divisionSignsTests`, which are the examples from the Go language
    # specification's section on arithmetic operators. `q` and `r` are the
    # truncated pair and `d` and `m` the Euclidean one, and the point of the
    # table is that the two disagree on three of its six rows.
    var rows: List[List[Int64]] = [
        [5, 3, 1, 2, 1, 2],
        [-5, 3, -1, -2, -2, 1],
        [5, -3, -1, 2, -1, 2],
        [-5, -3, 1, -2, 2, 1],
        [1, 2, 0, 1, 0, 1],
        [8, 4, 2, 0, 2, 0],
    ]
    for row in rows:
        var x = big.Int(row[0])
        var y = big.Int(row[1])
        assert_equal(x.quo(y).int64(), row[2], "quo")
        assert_equal(x.rem(y).int64(), row[3], "rem")
        assert_equal(x.div(y).int64(), row[4], "div")
        assert_equal(x.mod(y).int64(), row[5], "mod")

        # The paired forms have to agree with the single ones.
        var r = big.Int()
        assert_equal(x.quo_rem(y, r).int64(), row[2], "quo_rem quotient")
        assert_equal(r.int64(), row[3], "quo_rem remainder")
        var m = big.Int()
        assert_equal(x.div_mod(y, m).int64(), row[4], "div_mod quotient")
        assert_equal(m.int64(), row[5], "div_mod modulus")

        # And the two identities that define them.
        assert_equal(y.mul(x.quo(y)).add(x.rem(y)).string(), x.string())
        assert_equal(y.mul(x.div(y)).add(x.mod(y)).string(), x.string())
        assert_true(x.mod(y).sign() >= 0, "the modulus is never negative")


def test_quo() raises:
    # Go's `quoTests`. Two divisions large enough that the answer comes from
    # the multi digit path rather than from a single digit shortcut.
    var rows: List[List[String]] = [
        [
            (
                "4762179539939507608405094442506247970979913627353299737417181"
                "02894495832294430498335824897858659711275234906400899559094370"
                "964723884706254265559534144986498357"
            ),
            (
                "9353930466774385905609975137998169297361893554149986716853295"
                "022578535724979483772383667534691121982974895531435241089241440"
                "253066816724367338287092081996"
            ),
            "50911",
            "1",
        ],
        [
            "11510768301994997771168",
            "1328165573307167369775",
            "8",
            "885443715537658812968",
        ],
    ]
    for row in rows:
        var x = p(row[0])
        var y = p(row[1])
        var r = big.Int()
        var q = x.quo_rem(y, r)
        assert_equal(q.string(), row[2], "quotient")
        assert_equal(r.string(), row[3], "remainder")
        assert_equal(y.mul(q).add(r).string(), x.string(), "y*q + r == x")


def test_quo_step_d6() raises:
    # Go's `TestQuoStepD6`, from Knuth's exercise 4.3.1-21. The one input that
    # reaches step D6 of algorithm D, which is the correction after a trial
    # quotient came out one too large. Go says it triggers in one case in
    # 10^19, so it is not an input anybody arrives at by generating numbers.
    comptime TOP = big.Word(1) << 63
    comptime ALL = ~big.Word(0)
    var u_digits: List[big.Word] = [0, 0, 1 + TOP, ALL ^ TOP]
    var v_digits: List[big.Word] = [5, 2 + TOP, TOP]

    var u = big.Int()
    u.set_bits(Span(u_digits))
    var v = big.Int()
    v.set_bits(Span(v_digits))

    var r = big.Int()
    var q = u.quo_rem(v, r)
    assert_equal(q.string(), "18446744073709551613")
    assert_equal(
        r.string(),
        "3138550867693340382088035895064302439801311770021610913807",
    )


def test_divide_by_zero_raises() raises:
    # Go panics on all four. The three sibling operations have to agree with
    # each other about it, which is the thing worth testing.
    var x = big.Int(Int64(5))
    var zero = big.Int()
    var r = big.Int()
    for i in range(6):
        var err = Error()
        var raised = False
        try:
            if i == 0:
                _ = x.quo(zero)
            elif i == 1:
                _ = x.rem(zero)
            elif i == 2:
                _ = x.div(zero)
            elif i == 3:
                _ = x.mod(zero)
            elif i == 4:
                _ = x.quo_rem(zero, r)
            else:
                _ = x.div_mod(zero, r)
        except e:
            raised = True
            err = e
        assert_true(raised, String("division ", i, " by zero has to raise"))
        assert_true(matches(err, ErrDivideByZero), String("code ", i))


def test_bit_len() raises:
    # Go's `bitLenTests`.
    var rows: List[List[String]] = [
        ["-1", "1"],
        ["0", "0"],
        ["1", "1"],
        ["2", "2"],
        ["4", "3"],
        ["0xabc", "12"],
        ["0x8000", "16"],
        ["0x80000000", "32"],
        ["0x800000000000", "48"],
        ["0x8000000000000000", "64"],
        ["0x80000000000000000000", "80"],
        ["-0x4000000000000000000000", "87"],
    ]
    for row in rows:
        assert_equal(String(p(row[0]).bit_len()), row[1], row[0])


def test_cmp_and_cmp_abs() raises:
    # Go's `cmpAbsTests`, a list in ascending order. Go compares every pair in
    # it both ways round and with both signs, which is 8 times 8 times 4 checks
    # from eight numbers.
    var values: List[String] = [
        "0",
        "1",
        "2",
        "10",
        "10000000",
        "2783678367462374683678456387645876387564783686583485",
        "2783678367462374683678456387645876387564783686583486",
        (
            "329573948679874209679765670760759765706709476097506"
            "70956097509670576075067076027578341538"
        ),
    ]
    for i in range(len(values)):
        for j in range(len(values)):
            var want = 0
            if i < j:
                want = -1
            elif i > j:
                want = 1
            var x = p(values[i])
            var y = p(values[j])

            assert_equal(x.cmp_abs(y), want, "abs of two positives")
            assert_equal(x.neg().cmp_abs(y), want, "abs ignores the left sign")
            assert_equal(x.cmp_abs(y.neg()), want, "abs ignores the right sign")
            assert_equal(x.neg().cmp_abs(y.neg()), want, "abs ignores both")

            assert_equal(x.cmp(y), want, "two positives")
            assert_equal(x.neg().cmp(y.neg()), -want, "two negatives")
            # Zero has no sign, so negating it changes nothing and the two
            # zeros still compare equal rather than one being the smaller.
            var negated_is_smaller = -1
            if i == 0 and j == 0:
                negated_is_smaller = 0
            assert_equal(x.neg().cmp(y), negated_is_smaller, "negative first")

    # The comparison operators come off `cmp` and are worth one row each.
    var a = p("10")
    var b = p("2783678367462374683678456387645876387564783686583485")
    assert_true(a < b)
    assert_true(a <= b)
    assert_true(b > a)
    assert_true(b >= a)
    assert_true(a != b)
    assert_true(a == p("10"))
    assert_true(a <= p("10"))
    assert_true(a >= p("10"))


def test_int64() raises:
    # Go's `int64Tests`. The first ten fit and the last four do not, and the
    # interesting one is the most negative `Int64`, whose magnitude has no
    # positive counterpart.
    var fits: List[String] = [
        "0",
        "1",
        "-1",
        "4294967295",
        "-4294967295",
        "4294967296",
        "-4294967296",
        "9223372036854775807",
        "-9223372036854775807",
        "-9223372036854775808",
    ]
    for s in fits:
        var x = p(s)
        assert_true(x.is_int64(), s)
        assert_equal(big.Int(x.int64()).string(), x.string(), s)

    var too_big: List[String] = [
        "0x8000000000000000",
        "-0x8000000000000001",
        "38579843757496759476987459679745",
        "-38579843757496759476987459679745",
    ]
    for s in too_big:
        assert_true(not p(s).is_int64(), s)


def test_uint64() raises:
    # Go's `uint64Tests`.
    var fits: List[String] = [
        "0",
        "1",
        "4294967295",
        "4294967296",
        "8589934591",
        "8589934592",
        "9223372036854775807",
        "9223372036854775808",
        "0x08000000000000000",
    ]
    for s in fits:
        var x = p(s)
        assert_true(x.is_uint64(), s)
        var back = big.Int()
        back.set_uint64(x.uint64())
        assert_equal(back.string(), x.string(), s)

    var too_big: List[String] = [
        "0x10000000000000000",
        "-0x08000000000000000",
        "-1",
    ]
    for s in too_big:
        assert_true(not p(s).is_uint64(), s)


def test_new_int_min_int64() raises:
    # Go's `TestNewIntMinInt64`. The most negative `Int64` is the one value
    # whose negation overflows, so a constructor that negates before it stores
    # gets this one wrong and nothing else.
    var x = big.new_int(-9223372036854775808)
    assert_equal(x.string(), "-9223372036854775808")
    assert_equal(x.int64(), -9223372036854775808)
    var y = big.Int()
    y.set_int64(-9223372036854775808)
    assert_equal(y.string(), "-9223372036854775808")


def test_set_and_copy_do_not_share() raises:
    # Go documents that a shallow copy of an `Int` is not supported, because
    # two of them would share one backing array. Here they do not, and that is
    # a property worth pinning rather than assuming.
    var a = p("123456789012345678901234567890")
    var b = a.copy()
    var c = big.Int()
    c.set(a)
    a = a.add(big.Int(Int64(1)))
    assert_equal(b.string(), "123456789012345678901234567890")
    assert_equal(c.string(), "123456789012345678901234567890")
    assert_equal(a.string(), "123456789012345678901234567891")


def test_bits_and_set_bits_copy() raises:
    # Go hands out the number's own digits and takes them in the same way. This
    # library copies in both directions, which is the deviation, so both halves
    # of it get a test.
    var x = p("0x1000000000000000200000000000000030")
    var digits = x.bits()
    digits[0] = big.Word(0)
    assert_equal(
        x.text(16), "1000000000000000200000000000000030", "bits copies"
    )

    var source: List[big.Word] = [7, 0, 3]
    var y = big.Int()
    y.set_bits(Span(source))
    source[0] = big.Word(9)
    assert_equal(y.bits()[0], big.Word(7), "set_bits copies")

    # A caller's digits may carry leading zeros; the value must not.
    var padded: List[big.Word] = [5, 0, 0, 0]
    var z = big.Int()
    z.set_bits(Span(padded))
    assert_equal(z.string(), "5")
    assert_equal(len(z.bits()), 1, "the leading zero digits are dropped")

    # All zero digits are the zero value, not a number with an empty magnitude
    # and a set sign.
    var zeros: List[big.Word] = [0, 0]
    var w = big.Int()
    w.set_bits(Span(zeros))
    assert_equal(w.sign(), 0)
    assert_equal(len(w.bits()), 0)
