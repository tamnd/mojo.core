"""Go's `TestFloat64`, `TestBytes`, `TestSetBytes` and `TestFillBytes`, from
`int_test.go`.

These are the conversions that leave the world of numbers written as text.
`bytes` and `set_bytes` are big endian and carry no sign, so they are the shape
a key or a hash arrives in. `fill_bytes` is the same picture padded to a fixed
width, which is what a wire format wants and why it refuses a buffer that is too
small rather than silently writing part of the number.

Go writes the byte round trips with `testing/quick`, which draws random slices.
There is no property testing harness here, so the same ground is covered with a
small generator seeded by hand: the point is a lot of lengths and a lot of
leading zero patterns, not that the bytes are unpredictable.
"""

from std.testing import assert_equal, assert_true

from core.math import is_inf, ldexp
import core.math.big as big
from core.errors import matches
from core.errors.codes import ErrInvalidArgument

from tests.math.big._fixtures import p


def _accuracy(name: String) raises -> big.Accuracy:
    """The accuracy Go's table names in that column."""
    if name == "Below":
        return big.Below
    if name == "Exact":
        return big.Exact
    if name == "Above":
        return big.Above
    raise Error("no accuracy named " + name)


def test_float64() raises:
    # Go's `TestFloat64`. Go writes the expected float as a decimal literal,
    # which for the two big rows is fifty five digits that have to be read back
    # exactly. Here it is a mantissa and a power of two instead, both small
    # enough to be exact, so the row says what the float is rather than what it
    # prints as. The columns are the number, the mantissa, the exponent and the
    # accuracy.
    var rows: List[List[String]] = [
        [
            "-1000000000000000000000000000000000000000000000000000000",
            "-2938735877055719",
            "128",
            "Below",
        ],
        ["-9223372036854775809", "-1", "63", "Above"],
        ["-9223372036854775808", "-1", "63", "Exact"],  # -2^63
        ["-9223372036854775807", "-1", "63", "Below"],
        ["-18014398509481985", "-1", "54", "Above"],
        ["-18014398509481984", "-1", "54", "Exact"],  # -2^54
        ["-18014398509481983", "-1", "54", "Below"],
        ["-9007199254740993", "-1", "53", "Above"],
        ["-9007199254740992", "-1", "53", "Exact"],  # -2^53
        ["-9007199254740991", "-9007199254740991", "0", "Exact"],
        ["-4503599627370497", "-4503599627370497", "0", "Exact"],
        ["-4503599627370496", "-1", "52", "Exact"],  # -2^52
        ["-4503599627370495", "-4503599627370495", "0", "Exact"],
        ["-12345", "-12345", "0", "Exact"],
        ["-1", "-1", "0", "Exact"],
        ["0", "0", "0", "Exact"],
        ["1", "1", "0", "Exact"],
        ["12345", "12345", "0", "Exact"],
        # Past 2^53 and exact all the same, because the digits below the top
        # fifty three are all zero.
        ["0x1010000000000000", "257", "52", "Exact"],
        ["9223372036854775807", "1", "63", "Above"],
        ["9223372036854775808", "1", "63", "Exact"],  # 2^63
        [
            "1000000000000000000000000000000000000000000000000000000",
            "2938735877055719",
            "128",
            "Above",
        ],
    ]
    for row in rows:
        var x = p(row[0])
        var want = ldexp(Float64(p(row[1]).int64()), Int(p(row[2]).int64()))
        var got, acc = x.float64()
        assert_equal(got, want, row[0])
        assert_true(acc == _accuracy(row[3]), row[0] + " accuracy")

        # Every exponent in the table is positive, so the float is a whole
        # number and can be built exactly as a big one. `Exact` and that number
        # being the number under test are then the same statement, and the
        # other two accuracies say which side of it the float fell.
        var as_int = p(row[1]).lsh(Int(p(row[2]).int64()))
        var same = as_int.cmp(x) == 0
        assert_equal(acc == big.Exact, same, row[0] + " accuracy agrees")
        if not same:
            var want_acc = big.Below
            if as_int.cmp(x) > 0:
                want_acc = big.Above
            assert_true(acc == want_acc, row[0] + " error direction")


def test_float64_is_exact_below_two_to_the_fifty_three() raises:
    # Not from Go. Every integer up to 2^53 is a float exactly, so the answer
    # is the number and the accuracy is `Exact` with nothing to decide.
    var values: List[Int64] = [
        0,
        1,
        -1,
        2,
        1000,
        -1000,
        4503599627370495,
        4503599627370496,
        9007199254740991,
        9007199254740992,
        -9007199254740992,
    ]
    for v in values:
        var got, acc = big.Int(v).float64()
        assert_equal(got, Float64(v), String(v))
        assert_true(acc == big.Exact, String(v) + " is exact")


def test_float64_overflows_to_infinity() raises:
    # Go returns an infinity with `Above` or `Below` for a number past the
    # largest float, which is what its `Float` conversion does too.
    var one = big.Int(Int64(1))
    var huge = one.lsh(1024)
    var got, acc = huge.float64()
    assert_true(is_inf(got, 1), "positive infinity")
    assert_true(acc == big.Above, "rounded up to infinity")

    var got_neg, acc_neg = huge.neg().float64()
    assert_true(is_inf(got_neg, -1), "negative infinity")
    assert_true(acc_neg == big.Below, "rounded down to infinity")

    # The largest float there is, which is two to the 1024 less two to the 971,
    # is still a number and is exact.
    var largest = one.lsh(1024).sub(one.lsh(971))
    var f, facc = largest.float64()
    assert_true(not is_inf(f, 0), "the largest float is finite")
    assert_true(facc == big.Exact, "the largest float is exact")


def _bytes_of(x: big.Int) -> String:
    """The magnitude of `x` as hexadecimal, the way Go's test compares it."""
    var digits = "0123456789abcdef".as_bytes()
    var out = List[UInt8]()
    for b in x.bytes():
        out.append(digits[Int(b >> 4)])
        out.append(digits[Int(b & 15)])
    return String(from_utf8_lossy=Span(out))


struct _Bits(Copyable, Movable):
    """A tiny linear generator, so the byte patterns are many and fixed.

    Go draws these with `testing/quick`. What matters is the spread of lengths
    and of leading zeros, not where the numbers came from, so this is a
    multiplier and an addend rather than anything from `core.math.rand`.
    """

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> UInt8:
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        return UInt8((self.state >> 33) & 0xFF)


def test_bytes_round_trip() raises:
    # Go's `checkBytes`. Leading zero bytes are not part of the number, so a
    # slice that has them does not come back the same and Go's test trims them
    # before comparing. Everything else has to survive exactly.
    var g = _Bits(20240902)
    for n in range(0, 40):
        for zeros in range(0, 4):
            if zeros > n:
                continue
            var buf = List[UInt8]()
            for i in range(n):
                if i < zeros:
                    buf.append(0)
                else:
                    buf.append(g.next())

            var x = big.Int()
            x.set_bytes(Span(buf))

            # The number the bytes describe, worked out by shifting rather than
            # by the loop `set_bytes` uses.
            var want = big.Int()
            for b in buf:
                want = want.lsh(8).add(big.Int(Int64(Int(b))))
            assert_equal(x.string(), want.string(), "set_bytes")

            var trimmed = List[UInt8]()
            var started = False
            for b in buf:
                if b != 0:
                    started = True
                if started:
                    trimmed.append(b)

            var out = x.bytes()
            assert_equal(len(out), len(trimmed), "length")
            for i in range(len(trimmed)):
                assert_equal(out[i], trimmed[i], "byte " + String(i))


def test_set_bytes_ignores_the_sign() raises:
    # `set_bytes` reads a magnitude, so it always produces a number that is not
    # negative, and it overwrites whatever the receiver held including its sign.
    var buf: List[UInt8] = [1, 2, 3]
    var z = big.Int(Int64(-999))
    z.set_bytes(Span(buf))
    assert_equal(z.string(), "66051")
    assert_equal(z.sign(), 1)

    var empty = List[UInt8]()
    z.set_bytes(Span(empty))
    assert_equal(z.string(), "0")
    assert_equal(z.sign(), 0)


def test_bytes_drops_the_sign() raises:
    # A number and its negation have the same bytes, which is the half of the
    # conversion that loses information.
    var values: List[String] = [
        "0",
        "1",
        "255",
        "256",
        "0xffffffffffffffff",
        "0x10000000000000000",
        "298472983472983471903246121093472394872319615612417471234712061",
    ]
    for s in values:
        var x = p(s)
        assert_equal(_bytes_of(x), _bytes_of(x.neg()), s)


def test_fill_bytes() raises:
    # Go's `TestFillBytes`. The buffer is filled from the right and padded with
    # zeros, whatever was in it before.
    var values: List[String] = [
        "0",
        "1000",
        "0xffffffff",
        "-0xffffffff",
        "0xffffffffffffffff",
        "0x10000000000000000",
        "0xabababababababababababababababababababababababababa",
        "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    ]
    for s in values:
        var x = p(s)
        var byte_len = (x.bit_len() + 7) // 8

        # A buffer of exactly the right size.
        var exact = List[UInt8](length=byte_len, fill=0)
        x.fill_bytes(Span(exact))
        var got = big.Int()
        got.set_bytes(Span(exact))
        assert_equal(got.cmp_abs(x), 0, s + " into an exact buffer")

        # A much larger one, prefilled, so that every byte has to be written.
        var wide = List[UInt8](length=100, fill=0xFF)
        x.fill_bytes(Span(wide))
        got.set_bytes(Span(wide))
        assert_equal(got.cmp_abs(x), 0, s + " into a wide buffer")
        for i in range(100 - byte_len):
            assert_equal(wide[i], 0, "the padding was zeroed")

        # One byte short, which Go panics on.
        if byte_len > 0:
            var small = List[UInt8](length=byte_len - 1, fill=0)
            var raised = False
            var err = Error()
            try:
                x.fill_bytes(Span(small))
            except e:
                raised = True
                err = e
            assert_true(raised, s + " does not fit")
            assert_true(matches(err, ErrInvalidArgument))


def test_fill_bytes_matches_bytes() raises:
    # Not from Go. Filling a buffer of exactly the right size has to give the
    # same bytes `bytes` does, and the two are written separately.
    var g = _Bits(551)
    for n in range(1, 30):
        var buf = List[UInt8]()
        for _ in range(n):
            buf.append(g.next())
        var x = big.Int()
        x.set_bytes(Span(buf))

        var want = x.bytes()
        var filled = List[UInt8](length=len(want), fill=0xAA)
        x.fill_bytes(Span(filled))
        for i in range(len(want)):
            assert_equal(filled[i], want[i], "byte " + String(i))
