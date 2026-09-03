"""Go's `TestSetString`, `TestIntText` and `TestAppendText`, from
`intconv_test.go`.

Go's table carries five columns for each string: the string, how it comes back
out, the base to read it in, its value as a machine integer, and whether it is a
number at all. Every column is a `String` here, because a Mojo list holds one
type and a table that reads as a table is worth more than saving a conversion.

Base zero is the interesting one. It means the prefix decides, so `0x` is
hexadecimal, `0b` binary, `0o` and a bare leading zero octal, and underscores
are allowed as digit separators. Every other base takes the digits literally,
which is why `0x10` in base 16 is not a number and `1_000` in base 10 is not
either.
"""

from std.testing import assert_equal, assert_false, assert_true

import core.math.big as big
from core.errors import matches
from core.errors.codes import ErrBase, ErrSyntax

from tests.math.big._fixtures import p, parses, pb


def _bad() -> List[List[String]]:
    """The rows of Go's `stringTests` that are not numbers, as `in`, `base`."""
    return [
        ["", "0"],
        ["a", "0"],
        ["z", "0"],
        ["+", "0"],
        ["-", "0"],
        ["0b", "0"],
        ["0o", "0"],
        ["0x", "0"],
        ["0y", "0"],
        ["2", "2"],
        ["0b2", "0"],
        ["08", "0"],
        ["8", "8"],
        ["0xg", "0"],
        ["g", "16"],
        # The separator smoke tests. `natconv_test.go` has the exhaustive set.
        ["_", "0"],
        ["0_", "0"],
        ["_0", "0"],
        ["-1__0", "0"],
        ["0x10_", "0"],
        ["1_000", "10"],
        ["d_e_a_d", "16"],
        # A prefix is only read when the base is zero.
        ["0x10", "16"],
    ]


def _good() -> List[List[String]]:
    """The rows of Go's `stringTests` that are numbers, as `in`, `out`, `base`,
    `val`."""
    return [
        ["0", "0", "0", "0"],
        ["0", "0", "10", "0"],
        ["0", "0", "16", "0"],
        ["+0", "0", "0", "0"],
        ["-0", "0", "0", "0"],
        ["10", "10", "0", "10"],
        ["10", "10", "10", "10"],
        ["10", "10", "16", "16"],
        ["-10", "-10", "16", "-16"],
        ["+10", "10", "16", "16"],
        ["0b10", "2", "0", "2"],
        ["0o10", "8", "0", "8"],
        ["0x10", "16", "0", "16"],
        ["-0x10", "-16", "0", "-16"],
        ["+0x10", "16", "0", "16"],
        ["00", "0", "0", "0"],
        ["0", "0", "8", "0"],
        ["07", "7", "0", "7"],
        ["7", "7", "8", "7"],
        ["023", "19", "0", "19"],
        ["23", "23", "8", "19"],
        ["cafebabe", "cafebabe", "16", "3405691582"],
        ["0b0", "0", "0", "0"],
        ["-111", "-111", "2", "-7"],
        ["-0b111", "-7", "0", "-7"],
        ["0b1001010111", "599", "0", "599"],
        ["1001010111", "1001010111", "2", "599"],
        ["A", "a", "36", "10"],
        ["A", "A", "37", "36"],
        ["ABCXYZ", "abcxyz", "36", "623741435"],
        ["ABCXYZ", "ABCXYZ", "62", "33536793425"],
        # Separators, again only a smoke test.
        ["1_000", "1000", "0", "1000"],
        ["0b_1010", "10", "0", "10"],
        ["+0o_660", "432", "0", "432"],
        ["-0xF00D_1E", "-15731998", "0", "-15731998"],
    ]


def test_set_string_rejects() raises:
    # Go's `TestSetString`, the rows where `ok` is false. Go returns a nil and
    # a false; this raises, and either way the receiver must not be left
    # holding a number.
    for row in _bad():
        var base = Int(pb(row[1], 10).int64())
        assert_false(parses(row[0], base), "'" + row[0] + "' is not a number")

        # A failed parse leaves the receiver alone rather than half written.
        # Go's test starts from 1234567890 for the same reason.
        var z = big.Int(Int64(1234567890))
        var raised = False
        var err = Error()
        try:
            z.set_string(row[0], base)
        except e:
            raised = True
            err = e
        assert_true(raised)
        assert_true(
            matches(err, ErrSyntax), "'" + row[0] + "' is a syntax error"
        )
        assert_equal(z.string(), "1234567890", "the receiver was not touched")


def test_set_string_accepts() raises:
    # Go's `TestSetString`, the rows where `ok` is true.
    for row in _good():
        var base = Int(pb(row[2], 10).int64())
        var z = big.Int(Int64(1234567890))
        z.set_string(row[0], base)
        assert_equal(String(z.int64()), row[3], row[0] + " base " + row[2])
        # Reading the same string twice into the same receiver has to give the
        # same answer, which catches a setter that appends to what is there.
        z.set_string(row[0], base)
        assert_equal(String(z.int64()), row[3], "read twice")


def test_text() raises:
    # Go's `TestIntText`. The base to write in is the base it was read in,
    # except that base zero means the prefix chose and decimal comes back.
    for row in _good():
        var base = Int(pb(row[2], 10).int64())
        var z = pb(row[0], base)
        var out_base = base
        if out_base == 0:
            out_base = 10
        assert_equal(z.text(out_base), row[1], row[0] + " base " + row[2])


def test_append_text() raises:
    # Go's `TestAppendText`. The buffer is written to end to end across every
    # row, so anything that clears it rather than appending shows up here and
    # not in `test_text`.
    var buf = List[UInt8]()
    for row in _good():
        var base = Int(pb(row[2], 10).int64())
        var z = pb(row[0], base)
        var out_base = base
        if out_base == 0:
            out_base = 10
        var start = len(buf)
        z.append(buf, out_base)
        var got = String(from_utf8_lossy=Span(buf)[start:])
        assert_equal(got, row[1], row[0] + " base " + row[2])


def test_string_is_base_ten() raises:
    # Go's `TestGetString`, the half that does not go through `fmt`.
    for row in _good():
        if row[2] != "10":
            continue
        assert_equal(pb(row[0], 10).string(), row[1], row[0])


def test_text_round_trips() raises:
    # Not from Go. Writing a number in a base and reading it back has to give
    # the number, for every base the package accepts and for both signs. A
    # digit table with one wrong entry passes the tables above wherever no row
    # happens to use that digit, and fails here.
    var values: List[String] = [
        "0",
        "1",
        "-1",
        "255",
        "65535",
        "18446744073709551615",
        "18446744073709551616",
        "-340282366920938463463374607431768211457",
        "298472983472983471903246121093472394872319615612417471234712061",
        (
            "-6864797660130609714981900799081393217269435300143305409394463"
            "4591855431833976560521225596406614545549772963113914808580371"
            "21987999716643812574028291115057151"
        ),
    ]
    for s in values:
        var x = p(s)
        for base in range(2, big.MaxBase + 1):
            var written = x.text(base)
            assert_equal(
                pb(written, base).string(), s, s + " base " + String(base)
            )


def test_bad_base_raises() raises:
    # Go panics for a base outside two to `MaxBase`, and its `SetString`
    # returns false. Base 1 has no positional notation and base 63 has no
    # digit to write, so both are refused at every door.
    var x = big.Int(Int64(255))
    var bases: List[Int] = [-1, 1, big.MaxBase + 1, 100]
    for base in bases:
        var raised = False
        var err = Error()
        try:
            _ = x.text(base)
        except e:
            raised = True
            err = e
        assert_true(raised, "text base " + String(base))
        assert_true(matches(err, ErrBase))

        assert_false(parses("11", base), "set_string base " + String(base))

    # Base zero is a reader convention and has no meaning when writing.
    var raised = False
    try:
        _ = x.text(0)
    except:
        raised = True
    assert_true(raised, "text base 0")


def test_large_round_trip() raises:
    # Not from Go. Numbers long enough to go down the recursive conversion
    # path rather than the digit at a time one, in a power of two base where
    # the split is exact and in decimal where it is not.
    var x = big.Int(Int64(1))
    var ten = big.Int(Int64(10))
    for _ in range(2000):
        x = x.mul(ten)
    x = x.add(big.Int(Int64(1)))

    var decimal = x.text(10)
    assert_equal(decimal.byte_length(), 2001)
    assert_equal(decimal[byte=0:1], "1")
    assert_equal(pb(decimal, 10).cmp(x), 0)

    var hex = x.text(16)
    assert_equal(pb(hex, 16).cmp(x), 0)
    assert_equal(p("0x" + hex).cmp(x), 0)


def test_must_set_string() raises:
    # Not from Go, which has no `MustSetString`. Only the path that succeeds
    # can be tested, because the other one ends the process, which is the whole
    # point of the name.
    assert_equal(big.Int.must_set_string("0", 10).string(), "0")
    assert_equal(
        big.Int.must_set_string("-1234567890", 10).string(), "-1234567890"
    )
    assert_equal(
        big.Int.must_set_string("0xffffffffffffffff", 0).string(),
        "18446744073709551615",
    )
    assert_equal(big.Int.must_set_string("ff", 16).string(), "255")

    # The curve order of P-256, which is the kind of number this is for.
    var n = big.Int.must_set_string(
        "0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 0
    )
    assert_equal(n.bit_len(), 256)
    assert_equal(
        n.text(16),
        "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551",
    )
