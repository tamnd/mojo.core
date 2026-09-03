"""Go's `TestPCG` and `TestPCGMarshal`, plus the encodings Go never feeds it.

`TestPCG` is twenty values from `new_pcg(1, 2)`. It is short and it is the most
valuable test in the package: DXSM is four lines of arithmetic with no internal
structure to check, so either the whole stream is right or the multiplier is
wrong, and twenty values says which.

The values are written out here rather than harvested because Go writes them
inline in the test function and `tools/testgen` harvests declarations. Copying
them is the same act the harvest would have been.
"""

from std.testing import assert_equal, assert_true

from core.errors import matches
from core.errors.codes import ErrInvalidEncoding
from core.math.rand import PCG, new_pcg

from tests.math.rand._fixtures import hexed


def _want() -> List[UInt64]:
    """The first twenty values of `new_pcg(1, 2)`. Go's `want` in `TestPCG`."""
    return [
        UInt64(0xC4F5A58656EEF510),
        UInt64(0x9DCEC3AD077DEC6C),
        UInt64(0xC8D04605312F8088),
        UInt64(0xCBEDC0DCB63AC19A),
        UInt64(0x3BF98798CAE97950),
        UInt64(0x0A8C6D7F8D485ABC),
        UInt64(0x7FFA3780429CD279),
        UInt64(0x730AD2626B1C2F8E),
        UInt64(0x21FF2330F4A0AD99),
        UInt64(0x2F0901A1947094B0),
        UInt64(0xA9735A3CFBE36CEF),
        UInt64(0x71DDB0A01A12C84A),
        UInt64(0xF0E53E77A78453BB),
        UInt64(0x1F173E9663BE1E9D),
        UInt64(0x657651DA3AC4115E),
        UInt64(0xC8987376B65A157B),
        UInt64(0xBB17008F5FCA28E7),
        UInt64(0x8232BD645F29ED22),
        UInt64(0x12BE8F07AD14C539),
        UInt64(0x54908A48E8E4736E),
    ]


def test_pcg() raises:
    var p = new_pcg(1, 2)
    var want = _want()
    for i in range(len(want)):
        assert_equal(p.uint64(), want[i], "PCG #" + String(i))


def test_pcg_zero_value_is_a_usable_generator() raises:
    # Go's rule for the zero value, exercised by `TestPCGMarshal` starting from
    # `var p PCG` and by the benchmark next to it. A generator whose state is
    # zero is not a broken one here, because the increment is not.
    var zero = PCG()
    var explicit = new_pcg(0, 0)
    for _ in range(8):
        assert_equal(zero.uint64(), explicit.uint64())


def test_pcg_marshal() raises:
    var p = PCG()
    p.seed(0x123456789ABCDEF0, 0xFEDCBA9876543210)
    # "pcg:" and the two state words, most significant byte first.
    comptime want = "7063673a123456789abcdef0fedcba9876543210"

    var data = p.marshal_binary()
    assert_equal(hexed(Span(data)), want, "marshal_binary")

    var appended: List[UInt8] = [0, 0, 0, 0]
    var count = p.append_binary(appended)
    assert_equal(count, 20, "append_binary returned the wrong count")
    assert_equal(hexed(Span(appended)), "00000000" + want, "append_binary")

    var q = PCG()
    q.unmarshal_binary(Span(data))
    assert_equal(q.hi, p.hi, "hi after the round trip")
    assert_equal(q.lo, p.lo, "lo after the round trip")
    assert_equal(q.uint64(), p.uint64(), "the next value after the round trip")


def test_pcg_unmarshal_rejects_a_bad_encoding() raises:
    # Go has no test for this: `UnmarshalBinary` returns an error there and the
    # test never asks for one. Both refusals are still behaviour somebody can
    # depend on, so both are pinned.
    var good = new_pcg(1, 2).marshal_binary()

    var p = new_pcg(7, 7)
    var raised = False
    try:
        p.unmarshal_binary(good[: len(good) - 1])
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidEncoding))
    assert_true(raised, "a nineteen byte encoding should be refused")

    var wrong = good.copy()
    wrong[0] = UInt8(ord("q"))
    raised = False
    try:
        p.unmarshal_binary(Span(wrong))
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidEncoding))
    assert_true(raised, "a wrong tag should be refused")

    # And the refusal left the generator alone, which is what the docstring
    # promises and what a caller decoding untrusted input relies on.
    var untouched = new_pcg(7, 7)
    assert_equal(p.uint64(), untouched.uint64())
