"""Go's `TestDecimalString`, `TestDecimalInit` and `TestDecimalRounding`, from
`decimal_test.go`.

`_Decimal` is the digit buffer a `Float` is printed through, and Go's is
unexported for the same reason this one has a leading underscore. It is tested
directly all the same, because the rounding in it is where a printed number
gains or loses its last digit and a table of `Float` strings would not say
which of the two halves went wrong.

The point the whole file rests on is that ten is divisible by two, so a binary
fraction can be written out in decimal exactly. `TestDecimalInit` is that claim
checked against numbers whose exact decimal form runs to a hundred digits.
"""

from std.testing import assert_equal

from core.math.big.arith import Word
from core.math.big.decimal import _Decimal


def _digits(s: String) -> List[UInt8]:
    """`s` as the ASCII digit list a `_Decimal` holds."""
    var out = List[UInt8](capacity=s.byte_length())
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


def _nat(x: Word) -> List[Word]:
    """`x` as a normalised nat, which is Go's `nat{x}.norm()`.

    A zero has no words at all, which is the only thing normalising does to a
    single word.
    """
    var out = List[Word]()
    if x != 0:
        out.append(x)
    return out^


def test_string() raises:
    # Go's `TestDecimalString`. The digits are a fraction with the point in
    # front of them, so the exponent says how far to move it, and a value with
    # no digits is a zero whatever the exponent says.
    var mants: List[String] = [
        "",
        "",
        "12345",
        "12345",
        "12345",
        "12345",
    ]
    var exps: List[Int] = [0, 1000, 0, -3, 3, 10]
    var wants: List[String] = [
        "0",
        "0",
        "0.12345",
        "0.00012345",
        "123.45",
        "1234500000",
    ]
    for i in range(len(mants)):
        var d = _Decimal()
        d.mant = _digits(mants[i])
        d.exp = exps[i]
        assert_equal(d.string(), wants[i], mants[i])


def test_init() raises:
    # Go's `TestDecimalInit`. A word shifted either way and written out in
    # full. The negative shifts are the interesting ones: two to the minus one
    # hundred has a hundred decimal digits and every one of them is exact.
    var xs: List[Word] = [
        0,
        0,
        0,
        1,
        1,
        1,
        1,
        12345678,
        12345678,
        195312,
        1953125,
    ]
    var shifts: List[Int] = [0, -100, 100, 0, 10, 100, -100, 8, -8, 9, 9]
    var wants: List[String] = [
        "0",
        "0",
        "0",
        "1",
        "1024",
        "1267650600228229401496703205376",
        (
            "0.000000000000000000000000000000788860905221011805411728565282786"
            "2296732064351090230047702789306640625"
        ),
        "3160493568",
        "48225.3046875",
        "99999744",
        "1000000000",
    ]
    for i in range(len(xs)):
        var m = _nat(xs[i])
        var d = _Decimal()
        d.set(Span(m), shifts[i])
        assert_equal(d.string(), wants[i], wants[i])


def test_rounding() raises:
    # Go's `TestDecimalRounding`. The three ways of cutting a number down to
    # `n` digits, checked on the rows where they differ: below the halfway
    # point, exactly on it and above it, and the carries that run off the front
    # and make the number one digit longer.
    var xs: List[Word] = [
        0,
        0,
        1,
        5,
        9,
        15,
        45,
        95,
        12344999,
        12345000,
        12345001,
        23454999,
        23455000,
        23455001,
        99994999,
        99995000,
        99999999,
        12994999,
        12995000,
        12999999,
    ]
    var ns: List[Int] = [
        0,
        1,
        0,
        0,
        0,
        1,
        1,
        1,
        4,
        4,
        4,
        4,
        4,
        4,
        4,
        4,
        4,
        4,
        4,
        4,
    ]
    var downs: List[String] = [
        "0",
        "0",
        "0",
        "0",
        "0",
        "10",
        "40",
        "90",
        "12340000",
        "12340000",
        "12340000",
        "23450000",
        "23450000",
        "23450000",
        "99990000",
        "99990000",
        "99990000",
        "12990000",
        "12990000",
        "12990000",
    ]
    var evens: List[String] = [
        "0",
        "0",
        "0",
        "0",
        "10",
        "20",
        "40",
        "100",
        "12340000",
        "12340000",
        "12350000",
        "23450000",
        "23460000",
        "23460000",
        "99990000",
        "100000000",
        "100000000",
        "12990000",
        "13000000",
        "13000000",
    ]
    var ups: List[String] = [
        "0",
        "0",
        "10",
        "10",
        "10",
        "20",
        "50",
        "100",
        "12350000",
        "12350000",
        "12350000",
        "23460000",
        "23460000",
        "23460000",
        "100000000",
        "100000000",
        "100000000",
        "13000000",
        "13000000",
        "13000000",
    ]
    for i in range(len(xs)):
        var m = _nat(xs[i])
        var label = downs[i] + " " + evens[i] + " " + ups[i]

        var d = _Decimal()
        d.set(Span(m), 0)
        d.round_down(ns[i])
        assert_equal(d.string(), downs[i], label)

        d = _Decimal()
        d.set(Span(m), 0)
        d.round(ns[i])
        assert_equal(d.string(), evens[i], label)

        d = _Decimal()
        d.set(Span(m), 0)
        d.round_up(ns[i])
        assert_equal(d.string(), ups[i], label)
