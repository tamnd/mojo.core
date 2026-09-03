"""Go's `TestMulBits`, `TestNormBits` and `TestFromBits`, from `bits_test.go`.

`_bits.mojo` is the independent second implementation the arithmetic tests
check `Float` against, so it gets tests of its own first. If it were wrong the
tests built on it would agree with it and both would be wrong together.
"""

from std.testing import assert_equal

import core.math.big as big

from tests.math.big._bits import (
    bits_float,
    bits_mul,
    bits_norm,
    bits_string,
)


def test_mul_bits() raises:
    # Go's `TestMulBits`. Multiplying is every pairwise sum of exponents, in
    # the order the two lists are read, with nothing normalised away.
    var xs: List[List[Int]] = [
        [],
        [],
        [0],
        [0],
        [1],
        [-1],
        [-10, -1, 0, 1, 10],
    ]
    var ys: List[List[Int]] = [
        [],
        [],
        [0],
        [1],
        [1, 2, 3],
        [1],
        [1, 2, 3],
    ]
    var wants: List[String] = [
        "[]",
        "[]",
        "[0]",
        "[1]",
        "[2 3 4]",
        "[0]",
        "[-9 -8 -7 0 1 2 1 2 3 2 3 4 11 12 13]",
    ]
    for i in range(len(xs)):
        var got = bits_string(bits_mul(xs[i], ys[i]))
        assert_equal(
            got,
            wants[i],
            String("mul ") + bits_string(xs[i]) + " " + bits_string(ys[i]),
        )


def test_norm_bits() raises:
    # Go's `TestNormBits`. A repeated exponent is an addition and carries into
    # the one above, which can carry again, and the answer comes out sorted.
    var xs: List[List[Int]] = [
        [],
        [0],
        [0, 0],
        [3, 1, 1],
        [10, 9, 8, 7, 6, 6],
    ]
    var wants: List[String] = [
        "[]",
        "[0]",
        "[1]",
        "[2 3]",
        "[11]",
    ]
    for i in range(len(xs)):
        assert_equal(
            bits_string(bits_norm(xs[i])),
            wants[i],
            String("norm ") + bits_string(xs[i]),
        )


def test_from_bits() raises:
    # Go's `TestFromBits`. The number a list stands for, printed in the `p`
    # format so that the mantissa and the exponent are both visible and no
    # rounding hides in the middle.
    var xs: List[List[Int]] = [
        # All different bit numbers.
        [],
        [0],
        [1],
        [-1],
        [63],
        [33, -30],
        [255, 0],
        # The same bit number more than once, which adds.
        [0, 0],
        [0, 0, 0, 0],
        [0, 1, 0],
        # Seven and ten, written out as two lists run together.
        [2, 1, 0, 3, 1],
    ]
    var wants: List[String] = [
        "0",
        "0x.8p+1",
        "0x.8p+2",
        "0x.8p+0",
        "0x.8p+64",
        "0x.8000000000000001p+34",
        (
            "0x.8000000000000000000000000000000000000000000000000000000000000001p"
            "+256"
        ),
        "0x.8p+2",
        "0x.8p+3",
        "0x.8p+3",
        "0x.88p+5",
    ]
    for i in range(len(xs)):
        var got = bits_float(xs[i]).text(UInt8(ord("p")), 0)
        assert_equal(got, wants[i], String("float ") + bits_string(xs[i]))
