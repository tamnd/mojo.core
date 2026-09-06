"""Encode and decode over Go's `pairs`. Go's `TestEncode` and `TestDecode`.

Three rows, and the middle one carries the weight: the Wikipedia paragraph from
Hamlet, whose encoded form is four hundred characters wrapped at seventy five.
It is the row that exercises a long run of ordinary groups, the newlines the
decoder has to skip, and the short final group all at once. The other two rows
are the empty input and the four zero bytes that shorten to `z`.
"""

from std.testing import assert_equal, assert_true

from core.encoding.ascii85 import (
    CorruptInputError,
    decode,
    encode,
    max_encoded_len,
)
from core.errors import Report
from core.errors.codes import EOF
from tests.generated.ascii85 import pairs_rows

from ._fixtures import as_text, bytes_of, strip85


def _encoded(data: List[UInt8]) raises -> String:
    """`data` encoded, into a buffer sized the way a caller would size one."""
    var out = List[UInt8](length=max_encoded_len(len(data)), fill=0)
    var n = encode(Span(out), Span(data))
    out.resize(n, 0)
    return as_text(out)


def test_encode() raises:
    """Go's `TestEncode`, whitespace out of both sides."""
    var rows = pairs_rows()
    for i in range(len(rows)):
        var got = _encoded(rows[i].decoded)
        assert_equal(strip85(got.as_bytes()), strip85(Span(rows[i].encoded)))


def test_max_encoded_len() raises:
    """Five characters to the group, and a short group still gets five.

    The most rather than the exact number, which is the whole reason this is
    named the way it is: the four zero bytes in the last row of `pairs` encode
    to one character where this says five.
    """
    assert_equal(max_encoded_len(0), 0)
    assert_equal(max_encoded_len(1), 5)
    assert_equal(max_encoded_len(4), 5)
    assert_equal(max_encoded_len(5), 10)
    assert_equal(max_encoded_len(8), 10)


def test_zeros_use_the_shorthand() raises:
    """Four zero bytes are one `z`, and only when there are four of them."""
    assert_equal(_encoded(List[UInt8](length=4, fill=0)), "z")
    assert_equal(_encoded(List[UInt8](length=8, fill=0)), "zz")
    # Five: a whole group shortens and the byte after it does not, because a
    # short group is written out the long way whatever is in it.
    assert_equal(_encoded(List[UInt8](length=5, fill=0)), "z!!")
    assert_equal(_encoded(List[UInt8](length=3, fill=0)), "!!!!")


def test_a_short_group_keeps_one_character_more_than_its_bytes() raises:
    """One byte is two characters, two is three, three is four.

    The encoding always spends one character on the group and the rest on the
    bytes, which is why a group of one character alone is refused on the way
    back: there would be no byte under it.
    """
    assert_equal(_encoded(bytes_of("a")).byte_length(), 2)
    assert_equal(_encoded(bytes_of("ab")).byte_length(), 3)
    assert_equal(_encoded(bytes_of("abc")).byte_length(), 4)
    assert_equal(_encoded(bytes_of("abcd")).byte_length(), 5)


def test_encode_of_nothing_is_nothing() raises:
    assert_equal(_encoded(List[UInt8]()), "")


def test_decode() raises:
    """Go's `TestDecode`: both counts and the bytes, over every row."""
    var rows = pairs_rows()
    for i in range(len(rows)):
        var src = rows[i].encoded.copy()
        var dst = List[UInt8](length=4 * len(src) + 4, fill=0)
        var ndst = 0
        var nsrc = 0
        ndst, nsrc = decode(Span(dst), Span(src), True)
        assert_equal(nsrc, len(src))
        assert_equal(ndst, len(rows[i].decoded))
        dst.resize(ndst, 0)
        assert_equal(as_text(dst), as_text(rows[i].decoded))


def test_decode_skips_whitespace_wherever_it_falls() raises:
    """Spaces, tabs, newlines and carriage returns, in the middle of a group.

    The big row already has newlines between groups. This one puts them inside
    one, which is where a decoder that only skipped at group boundaries would
    come apart.
    """
    var src = bytes_of("9j\nq o\t^\r")
    var dst = List[UInt8](length=16, fill=0)
    var ndst = 0
    var nsrc = 0
    ndst, nsrc = decode(Span(dst), Span(src), True)
    assert_equal(nsrc, len(src))
    dst.resize(ndst, 0)
    assert_equal(as_text(dst), "Man ")


def test_decode_without_flush_holds_the_last_group_back() raises:
    """The two counts are two numbers for this reason.

    Without `flush` a group that has not all arrived is left where it is, and
    the caller is told how much of the input was used so it can hand the rest
    back next time.
    """
    var src = bytes_of("9jqo^Blb")
    var dst = List[UInt8](length=16, fill=0)
    var ndst = 0
    var nsrc = 0
    ndst, nsrc = decode(Span(dst), Span(src), False)
    assert_equal(ndst, 4)
    assert_equal(nsrc, 5)
    dst.resize(4, 0)
    assert_equal(as_text(dst), "Man ")


def test_decode_stops_when_the_destination_is_full() raises:
    """Room for one group, so one group comes out and the rest waits."""
    var src = bytes_of("9jqo^Blb")
    var dst = List[UInt8](length=4, fill=0)
    var ndst = 0
    var nsrc = 0
    ndst, nsrc = decode(Span(dst), Span(src), True)
    assert_equal(ndst, 4)
    assert_equal(nsrc, 5)
    assert_equal(as_text(dst), "Man ")


def test_decode_corrupt() raises:
    """Go's `TestDecodeCorrupt`, both rows, plus the ones around them.

    `v` is the first character above the alphabet and `!z!!!!!!!!!` is the `z`
    shorthand where it does not belong: it stands for a whole group, so it only
    means anything at the start of one.

    The last two rows are the fence ascii85 usually arrives wrapped in. Neither
    end of it is understood, and the offset lands on the `~` rather than on the
    `<` because `<` is an ordinary symbol of the alphabet and only the `~` is
    outside it.
    """
    var inputs: List[String] = [
        "v",
        "!z!!!!!!!!!",
        "~",
        "9jqo^~>",
        "<~9jqo^",
    ]
    var offsets: List[Int] = [0, 1, 0, 5, 1]
    for i in range(len(inputs)):
        var src = bytes_of(inputs[i])
        var dst = List[UInt8](length=4 * len(src) + 4, fill=0)
        var refused = False
        try:
            _ = decode(Span(dst), Span(src), True)
        except e:
            refused = True
            var bad = CorruptInputError.of(e)
            assert_true(Bool(bad))
            assert_equal(bad.value().offset, Int64(offsets[i]))
        assert_true(refused)


def test_a_group_of_one_character_is_refused() raises:
    """One character is all overhead, so there is no input it came from.

    The offset on it is the length of the input rather than a byte in it, which
    is Go's choice too: the character that is wrong is the one that never
    arrived.
    """
    var src = bytes_of("9jqo^B")
    var dst = List[UInt8](length=16, fill=0)
    var refused = False
    try:
        _ = decode(Span(dst), Span(src), True)
    except e:
        refused = True
        var bad = CorruptInputError.of(e)
        assert_true(Bool(bad))
        assert_equal(bad.value().offset, Int64(6))
    assert_true(refused)


def test_the_message_is_gos() raises:
    """Word for word, because a message is an interface too."""
    assert_equal(
        CorruptInputError(Int64(3)).error(),
        "illegal ascii85 data at input byte 3",
    )
    assert_equal(
        String(CorruptInputError(Int64(0))),
        "illegal ascii85 data at input byte 0",
    )


def test_an_error_from_elsewhere_is_not_one_of_these() raises:
    """`of` is a type assertion, and a type assertion fails rather than lies."""
    var other = Report("ascii85: something else").with_code(EOF).error()
    assert_true(not CorruptInputError.of(other))
