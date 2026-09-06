"""What a decoder refuses, and where it says the input went wrong.

Go's table for this is declared inside `TestDecodeCorrupt` rather than at
package level, so `tools/testgen` cannot see it and the rows are typed out
here. They are Go's rows in Go's order, and the offset of -1 means the input is
fine.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import matches, partial
from core.errors.codes import ErrCorruptBase64
from core.encoding.base64 import CorruptInputError, std_encoding

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
        _Case("\n", -1),
        _Case("AAA=\n", -1),
        _Case("AAAA\n", -1),
        _Case("!!!!", 0),
        _Case("====", 0),
        _Case("x===", 1),
        _Case("=AAA", 0),
        _Case("A=AA", 1),
        _Case("AA=A", 2),
        _Case("AA==A", 4),
        _Case("AAA=AAAA", 4),
        _Case("AAAAA", 4),
        _Case("AAAAAA", 4),
        _Case("A=", 1),
        _Case("A==", 1),
        _Case("AA=", 3),
        _Case("AA==", -1),
        _Case("AAA=", -1),
        _Case("AAAA", -1),
        _Case("AAAAAA=", 7),
        _Case("YWJjZA=====", 8),
        _Case("A!\n", 1),
        _Case("A=\n", 1),
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
        _ = std_encoding().decode_string("!!!!")
    except e:
        refused = True
        assert_true(matches(e, ErrCorruptBase64))
    assert_true(refused)


def test_the_message_is_gos() raises:
    """Byte for byte, because it is the thing that ends up in a log."""
    try:
        _ = std_encoding().decode_string("A=AA")
    except e:
        assert_equal(
            CorruptInputError.of(e).value().error(),
            "illegal base64 data at input byte 1",
        )


def test_an_error_from_elsewhere_is_not_one_of_these() raises:
    """What Go's type assertion does by failing."""
    var enc = std_encoding()
    try:
        _ = enc.decode_string("!!!!")
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
        _ = enc.decode(Span(out), "Zm9vYmFy!!!!".as_bytes())
    except e:
        assert_equal(partial(e), 6)
        out.resize(6, 0)
        assert_equal(as_text(out), "foobar")


def test_strict_refuses_trailing_bits() raises:
    """RFC 4648 section 3.5, which Go's `Strict` turns on and this does too."""
    var loose = std_encoding()
    var strict = std_encoding().strict()

    # `AB==` spells one zero byte with two bits left over that are not zero.
    assert_equal(len(loose.decode_string("AB==")), 1)
    var refused = False
    try:
        _ = strict.decode_string("AB==")
    except e:
        refused = True
        assert_true(matches(e, ErrCorruptBase64))
        assert_equal(Int(CorruptInputError.of(e).value().offset), 2)
    assert_true(refused)

    # `AAB=` is the same case one character along.
    assert_equal(len(loose.decode_string("AAB=")), 2)
    var also = False
    try:
        _ = strict.decode_string("AAB=")
    except:
        also = True
    assert_true(also)

    # What a strict encoding does accept is what an encoder produces.
    assert_equal(as_text(strict.decode_string("Zg==")), "f")
    assert_equal(as_text(strict.decode_string("Zm8=")), "fo")


def test_strict_still_skips_newlines() raises:
    """Go says so in `Strict`'s own documentation, and it is worth pinning."""
    assert_equal(
        as_text(std_encoding().strict().decode_string("Zm9\nv")), "foo"
    )
