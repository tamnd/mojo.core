"""What a decoder refuses, and where it says the input went wrong.

Go's table for this is declared inside `TestDecodeCorrupt` rather than at
package level, so `tools/testgen` cannot see it and the rows are typed out here.
They are Go's rows in Go's order, and the offset of -1 means the input is fine.

Base32 refuses more shapes than base64 does, because a group of eight has five
valid padding lengths rather than two and a final group of one, three or six
symbols carries no whole byte. Half of Go's rows are about exactly that.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import matches, partial
from core.errors.codes import ErrCorruptBase32
from core.encoding.base32 import CorruptInputError, std_encoding

from ._fixtures import as_text


struct _Case(Copyable, Movable):
    """One row of Go's table inside `TestDecodeCorrupt`."""

    var input: String
    var offset: Int

    def __init__(out self, input: String, offset: Int):
        self.input = input
        self.offset = offset


def _cases() -> List[_Case]:
    """Go's rows, in Go's order. -1 is a row that decodes."""
    return [
        _Case("", -1),
        _Case("!!!!", 0),
        _Case("x===", 0),
        _Case("AA=A====", 2),
        _Case("AAA=AAAA", 3),
        _Case("MMMMMMMMM", 8),
        _Case("MMMMMM", 0),
        _Case("A=", 1),
        _Case("AA=", 3),
        _Case("AA==", 4),
        _Case("AA===", 5),
        _Case("AAAA=", 5),
        _Case("AAAA==", 6),
        _Case("AAAAA=", 6),
        _Case("AAAAA==", 7),
        _Case("A=======", 1),
        _Case("AA======", -1),
        _Case("AAA=====", 3),
        _Case("AAAA====", -1),
        _Case("AAAAA===", -1),
        _Case("AAAAAA==", 6),
        _Case("AAAAAAA=", -1),
        _Case("AAAAAAAA", -1),
    ]


def test_decode_corrupt() raises:
    """Go's `TestDecodeCorrupt`, offset for offset."""
    var enc = std_encoding()
    var rows = _cases()
    for i in range(len(rows)):
        var room = enc.decoded_len(rows[i].input.byte_length())
        var out = List[UInt8](length=room, fill=0)
        var raised = False
        var at = -1
        try:
            _ = enc.decode(Span(out), rows[i].input.as_bytes())
        except e:
            raised = True
            var bad = CorruptInputError.of(e)
            assert_true(Bool(bad))
            at = Int(bad.value().offset)
        if rows[i].offset == -1:
            assert_false(raised)
        else:
            assert_true(raised)
            assert_equal(at, rows[i].offset)


def test_the_code_is_the_one_matches_answers() raises:
    """A caller who only wants to know which package refused it."""
    var refused = False
    try:
        _ = std_encoding().decode_string("!!!!!!!!")
    except e:
        refused = True
        assert_true(matches(e, ErrCorruptBase32))
    assert_true(refused)


def test_the_message_is_gos() raises:
    """Byte for byte, because it is the thing that ends up in a log."""
    try:
        _ = std_encoding().decode_string("A=======")
    except e:
        assert_equal(
            CorruptInputError.of(e).value().error(),
            "illegal base32 data at input byte 1",
        )


def test_an_error_from_elsewhere_is_not_one_of_these() raises:
    """What Go's type assertion does by failing."""
    var enc = std_encoding()
    try:
        _ = enc.decode_string("!!!!!!!!")
    except e:
        assert_true(Bool(CorruptInputError.of(e)))
    try:
        raise Error("something else entirely")
    except e:
        assert_false(Bool(CorruptInputError.of(e)))


def test_the_good_prefix_is_counted() raises:
    """`errors.partial` carries the count Go returns beside the error."""
    var enc = std_encoding()
    var out = List[UInt8](length=32, fill=0)
    try:
        _ = enc.decode(Span(out), "MZXW6YTB!!!!!!!!".as_bytes())
    except e:
        assert_equal(partial(e), 5)
        out.resize(5, 0)
        assert_equal(as_text(out), "fooba")


def test_a_group_of_one_three_or_six_carries_nothing() raises:
    """The refusal base64 has no equivalent for. RFC 4648 sections 6 and 9.

    One symbol is five bits, three are fifteen and six are thirty, and none of
    those is a whole number of bytes, so an input that ends with a group that
    size is not a shorter document but a broken one.
    """
    var enc = std_encoding()
    for text in [String("A======="), String("AAA====="), String("AAAAAA==")]:
        var refused = False
        try:
            _ = enc.decode_string(text)
        except e:
            refused = True
            assert_true(matches(e, ErrCorruptBase32))
        assert_true(refused)

    # The five lengths that do carry whole bytes, for contrast.
    assert_equal(len(enc.decode_string("AA======")), 1)
    assert_equal(len(enc.decode_string("AAAA====")), 2)
    assert_equal(len(enc.decode_string("AAAAA===")), 3)
    assert_equal(len(enc.decode_string("AAAAAAA=")), 4)
    assert_equal(len(enc.decode_string("AAAAAAAA")), 5)
