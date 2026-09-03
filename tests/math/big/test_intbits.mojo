"""Go's `TestBitwise`, `TestBitSet`, `TestTrailingZeroBits`, `TestNot`,
`TestRsh`, `TestLsh` and `TestLshRsh`, from `int_test.go`.

The bit operations read a number as if it were written in two's complement and
extended forever to the left, so a negative operand contributes ones above its
magnitude. That is the only part of `Int` where the sign changes what the digits
mean rather than what they are prefixed with, and it is why Go's table has three
rows for each pair of signs rather than one.
"""

from std.testing import assert_equal, assert_true

import core.math.big as big
from core.errors import matches
from core.errors.codes import ErrInvalidArgument

from tests.math.big._fixtures import p


def _bitwise() -> List[List[String]]:
    """Go's `bitwiseTests`, as `x`, `y`, `and`, `or`, `xor`, `andNot`."""
    return [
        ["0x00", "0x00", "0x00", "0x00", "0x00", "0x00"],
        ["0x00", "0x01", "0x00", "0x01", "0x01", "0x00"],
        ["0x01", "0x00", "0x00", "0x01", "0x01", "0x01"],
        ["-0x01", "0x00", "0x00", "-0x01", "-0x01", "-0x01"],
        ["-0xaf", "-0x50", "-0xf0", "-0x0f", "0xe1", "0x41"],
        ["0x00", "-0x01", "0x00", "-0x01", "-0x01", "0x00"],
        ["0x01", "0x01", "0x01", "0x01", "0x00", "0x00"],
        ["-0x01", "-0x01", "-0x01", "-0x01", "0x00", "0x00"],
        ["0x07", "0x08", "0x00", "0x0f", "0x0f", "0x07"],
        ["0x05", "0x0f", "0x05", "0x0f", "0x0a", "0x00"],
        ["0xff", "-0x0a", "0xf6", "-0x01", "-0xf7", "0x09"],
        [
            "0x013ff6",
            "0x9a4e",
            "0x1a46",
            "0x01bffe",
            "0x01a5b8",
            "0x0125b0",
        ],
        [
            "-0x013ff6",
            "0x9a4e",
            "0x800a",
            "-0x0125b2",
            "-0x01a5bc",
            "-0x01c000",
        ],
        [
            "-0x013ff6",
            "-0x9a4e",
            "-0x01bffe",
            "-0x1a46",
            "0x01a5b8",
            "0x8008",
        ],
        [
            "0x1000009dc6e3d9822cba04129bcbe3401",
            "0xb9bd7d543685789d57cb918e833af352559021483cdb05cc21fd",
            "0x1000001186210100001000009048c2001",
            "0xb9bd7d543685789d57cb918e8bfeff7fddb2ebe87dfbbdfe35fd",
            "0xb9bd7d543685789d57ca918e8ae69d6fcdb2eae87df2b97215fc",
            "0x8c40c2d8822caa04120b8321400",
        ],
        [
            "0x1000009dc6e3d9822cba04129bcbe3401",
            "-0xb9bd7d543685789d57cb918e833af352559021483cdb05cc21fd",
            "0x8c40c2d8822caa04120b8321401",
            "-0xb9bd7d543685789d57ca918e82229142459020483cd2014001fd",
            "-0xb9bd7d543685789d57ca918e8ae69d6fcdb2eae87df2b97215fe",
            "0x1000001186210100001000009048c2000",
        ],
        [
            "-0x1000009dc6e3d9822cba04129bcbe3401",
            "-0xb9bd7d543685789d57cb918e833af352559021483cdb05cc21fd",
            "-0xb9bd7d543685789d57cb918e8bfeff7fddb2ebe87dfbbdfe35fd",
            "-0x1000001186210100001000009048c2001",
            "0xb9bd7d543685789d57ca918e8ae69d6fcdb2eae87df2b97215fc",
            "0xb9bd7d543685789d57ca918e82229142459020483cd2014001fc",
        ],
    ]


def test_bitwise() raises:
    # Go's `TestBitwise`. The four operations against every row of the table.
    for row in _bitwise():
        var x = p(row[0])
        var y = p(row[1])
        assert_equal(x.__and__(y).string(), p(row[2]).string(), "and")
        assert_equal(x.__or__(y).string(), p(row[3]).string(), "or")
        assert_equal(x.__xor__(y).string(), p(row[4]).string(), "xor")
        assert_equal(x.and_not(y).string(), p(row[5]).string(), "and_not")

        # And, Or and Xor commute; AndNot does not, and that is the point of
        # having it as an operation of its own.
        assert_equal(y.__and__(x).string(), p(row[2]).string(), "and reversed")
        assert_equal(y.__or__(x).string(), p(row[3]).string(), "or reversed")
        assert_equal(y.__xor__(x).string(), p(row[4]).string(), "xor reversed")


def test_bitwise_identities() raises:
    # Not from Go. The four operations are written out here as sign case
    # analyses over the nat level primitives, and an identity that holds for
    # every pair of signs catches a case swapped with its neighbour, which the
    # table above can only catch where somebody wrote a row for it.
    for row in _bitwise():
        var x = p(row[0])
        var y = p(row[1])
        # x = (x & y) | (x &^ y), which splits x on whether y agrees.
        assert_equal(
            x.__and__(y).__or__(x.and_not(y)).string(), x.string(), "split"
        )
        # x ^ y = (x | y) &^ (x & y).
        assert_equal(
            x.__or__(y).and_not(x.__and__(y)).string(),
            x.__xor__(y).string(),
            "xor by or and and",
        )
        # De Morgan, which is where a missing complement shows up.
        assert_equal(
            x.__and__(y).__invert__().string(),
            x.__invert__().__or__(y.__invert__()).string(),
            "de morgan",
        )
        # x &^ y is x & ~y.
        assert_equal(
            x.and_not(y).string(),
            x.__and__(y.__invert__()).string(),
            "and_not is and with the complement",
        )


def test_not() raises:
    # Go's `notTests`. Complementing twice has to give the number back, which
    # is the half of the test that does not depend on the table being right.
    var rows: List[List[String]] = [
        ["0", "-1"],
        ["1", "-2"],
        ["7", "-8"],
        ["-81910", "81909"],
        [
            "298472983472983471903246121093472394872319615612417471234712061",
            "-298472983472983471903246121093472394872319615612417471234712062",
        ],
    ]
    for row in rows:
        var x = p(row[0])
        assert_equal(x.__invert__().string(), row[1], row[0])
        assert_equal(x.__invert__().__invert__().string(), row[0], row[0])
        # ~x is -x - 1 by definition, so the two have to agree.
        assert_equal(
            x.neg().sub(big.Int(Int64(1))).string(), row[1], "minus x minus one"
        )


def test_bit() raises:
    # Go's `bitsetTests`, the half that reads a single bit.
    var rows: List[List[String]] = [
        ["0", "0", "0"],
        ["0", "200", "0"],
        ["1", "0", "1"],
        ["1", "1", "0"],
        ["-1", "0", "1"],
        ["-1", "200", "1"],
        ["0x2000000000000000000000000000", "108", "0"],
        ["0x2000000000000000000000000000", "109", "1"],
        ["0x2000000000000000000000000000", "110", "0"],
        ["-0x2000000000000000000000000001", "108", "1"],
        ["-0x2000000000000000000000000001", "109", "0"],
        ["-0x2000000000000000000000000001", "110", "1"],
    ]
    for row in rows:
        var x = p(row[0])
        var i = Int(p(row[1]).int64())
        assert_equal(String(x.bit(i)), row[2], row[0] + " bit " + row[1])


def test_bitset() raises:
    # Go's `testBitset`, run over every number in the bitwise table. Each bit
    # from zero to ten past the top is read, set, cleared and put back, and the
    # answers are checked against the same thing written with shifts and the
    # bitwise operations. Setting a bit and reading it back is a tautology; the
    # second spelling is what makes it a test.
    var one = big.Int(Int64(1))
    for row in _bitwise():
        for which in range(2):
            var x = p(row[which])
            var n = x.bit_len()
            var z = x.copy()
            for i in range(n + 10):
                var mask = one.lsh(i)

                var old = z.bit(i)
                var alt_old = 0
                if z.rsh(i).__and__(one).sign() != 0:
                    alt_old = 1
                assert_equal(old, alt_old, "bit against shift and mask")

                var set = z.set_bit(i, 1)
                assert_equal(set.bit(i), 1, "the bit is set")
                assert_equal(
                    set.string(), z.__or__(mask).string(), "set_bit against or"
                )

                var cleared = set.set_bit(i, 0)
                assert_equal(cleared.bit(i), 0, "the bit is clear")
                assert_equal(
                    cleared.string(),
                    z.and_not(mask).string(),
                    "set_bit against and_not",
                )

                # Putting the bit back where it was leaves the number alone.
                z = cleared.set_bit(i, old)
            assert_equal(z.string(), x.string(), "every bit was restored")


def test_bit_and_set_bit_reject_bad_arguments() raises:
    # Go panics on all three of these.
    var x = big.Int(Int64(3))
    var raised = False
    var err = Error()
    try:
        _ = x.bit(-1)
    except e:
        raised = True
        err = e
    assert_true(raised, "a negative bit index has to raise")
    assert_true(matches(err, ErrInvalidArgument))

    raised = False
    try:
        _ = x.set_bit(-1, 1)
    except:
        raised = True
    assert_true(raised, "a negative bit index has to raise")

    raised = False
    try:
        _ = x.set_bit(0, 2)
    except e:
        raised = True
        err = e
    assert_true(raised, "a bit that is not zero or one has to raise")
    assert_true(matches(err, ErrInvalidArgument))


def test_trailing_zero_bits() raises:
    # Go's `tzbTests`. Zero has no lowest set bit and answers zero, which is a
    # convention rather than a fact and so is worth a row of its own.
    var rows: List[List[String]] = [
        ["0", "0"],
        ["1", "0"],
        ["-1", "0"],
        ["4", "2"],
        ["-8", "3"],
        ["0x4000000000000000000", "74"],
        ["-0x8000000000000000000", "75"],
    ]
    for row in rows:
        assert_equal(String(p(row[0]).trailing_zero_bits()), row[1], row[0])


def test_rsh() raises:
    # Go's `rshTests`. The shift is arithmetic, so a negative number goes
    # towards negative infinity and stops at minus one rather than reaching
    # zero, which is what the four rows starting `-1` and `-100` are for.
    var rows: List[List[String]] = [
        ["0", "0", "0"],
        ["-0", "0", "0"],
        ["0", "1", "0"],
        ["0", "2", "0"],
        ["1", "0", "1"],
        ["1", "1", "0"],
        ["1", "2", "0"],
        ["2", "0", "2"],
        ["2", "1", "1"],
        ["-1", "0", "-1"],
        ["-1", "1", "-1"],
        ["-1", "10", "-1"],
        ["-100", "2", "-25"],
        ["-100", "3", "-13"],
        ["-100", "100", "-1"],
        ["4294967296", "0", "4294967296"],
        ["4294967296", "1", "2147483648"],
        ["4294967296", "2", "1073741824"],
        ["18446744073709551616", "0", "18446744073709551616"],
        ["18446744073709551616", "1", "9223372036854775808"],
        ["18446744073709551616", "2", "4611686018427387904"],
        ["18446744073709551616", "64", "1"],
        [
            "340282366920938463463374607431768211456",
            "64",
            "18446744073709551616",
        ],
        ["340282366920938463463374607431768211456", "128", "1"],
    ]
    for row in rows:
        var x = p(row[0])
        var s = Int(p(row[1]).int64())
        assert_equal(x.rsh(s).string(), row[2], row[0] + " >> " + row[1])
        # An arithmetic shift down is Euclidean division by a power of two, so
        # the two have to agree on every row including the negative ones.
        var divisor = big.Int(Int64(1)).lsh(s)
        assert_equal(x.rsh(s).string(), x.div(divisor).string(), "rsh is div")


def test_lsh() raises:
    # Go's `lshTests`.
    var rows: List[List[String]] = [
        ["0", "0", "0"],
        ["0", "1", "0"],
        ["0", "2", "0"],
        ["1", "0", "1"],
        ["1", "1", "2"],
        ["1", "2", "4"],
        ["2", "0", "2"],
        ["2", "1", "4"],
        ["2", "2", "8"],
        ["-87", "1", "-174"],
        ["4294967296", "0", "4294967296"],
        ["4294967296", "1", "8589934592"],
        ["4294967296", "2", "17179869184"],
        ["18446744073709551616", "0", "18446744073709551616"],
        ["9223372036854775808", "1", "18446744073709551616"],
        ["4611686018427387904", "2", "18446744073709551616"],
        ["1", "64", "18446744073709551616"],
        [
            "18446744073709551616",
            "64",
            "340282366920938463463374607431768211456",
        ],
        ["1", "128", "340282366920938463463374607431768211456"],
    ]
    for row in rows:
        var x = p(row[0])
        var s = Int(p(row[1]).int64())
        assert_equal(x.lsh(s).string(), row[2], row[0] + " << " + row[1])
        var factor = big.Int(Int64(1)).lsh(s)
        assert_equal(x.lsh(s).string(), x.mul(factor).string(), "lsh is mul")


def test_lsh_rsh() raises:
    # Go's `TestLshRsh`. Shifting up and back down is the identity for every
    # number and every distance, which is a stronger statement than either
    # table makes on its own.
    var shifts: List[Int] = [0, 1, 2, 8, 10, 63, 64, 65, 127, 128, 129, 500]
    for row in _bitwise():
        for which in range(2):
            var x = p(row[which])
            for s in shifts:
                assert_equal(
                    x.lsh(s).rsh(s).string(), x.string(), "up and back down"
                )
