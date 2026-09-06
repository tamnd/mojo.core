"""Reading blocks out of a document. Go's `TestGetLine`, `TestDecode`,
`TestBadDecode`, `TestDecodeStrangeCases`, `TestJustEnd` and
`TestMissingEndTrailer`.

The decoder is where almost all of this package is, because the format is
forgiving in ways that have to be spelled out one at a time: text before a
block, text between two of them, a run of opening lines with nothing to close
them, an opening line that is not at the start of a line at all. Each of those
is a row somewhere below.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.encoding.pem import decode
from core.encoding.pem.pem import _get_line, _remove_spaces_and_tabs
from core.io import Byte
from core.strings import repeat
from tests.generated.pem import bad_pem_tests_rows, get_line_tests_rows

from ._fixtures import as_text, bytes_of, document


def _text[o: Origin](data: Span[Byte, o]) raises -> String:
    """A span as a string, so a failure prints the line rather than the bytes.
    """
    return String(from_utf8=data)


def test_get_line() raises:
    """Go's `TestGetLine`, all twelve rows.

    Both line endings, and the whitespace rule that goes with them: trailing
    spaces and tabs come off the line, leading ones stay on, and a lone
    carriage return with no newline after it is an ordinary character.
    """
    var rows = get_line_tests_rows()
    for i in range(len(rows)):
        var got = _get_line(Span(rows[i].arg))
        assert_equal(_text(got[0]), as_text(rows[i].out1))
        assert_equal(_text(got[1]), as_text(rows[i].out2))


def test_get_line_says_how_much_it_used() raises:
    """The third answer, which the two Go checks above throw away.

    It is the offset of the byte after the line ending, and `decode` subtracts
    it from two offsets it is carrying, so a wrong answer here would not fail a
    line test and would fail every block with a header in it.
    """
    var unix = bytes_of("abc\nd")
    assert_equal(_get_line(Span(unix))[2], 4)
    var windows = bytes_of("abc\r\nd")
    assert_equal(_get_line(Span(windows))[2], 5)
    var bare = bytes_of("abc")
    assert_equal(_get_line(Span(bare))[2], 3)


def test_bad_decode() raises:
    """Go's `TestBadDecode`, all seven rows.

    Nothing comes back, and the whole of the input comes back as the rest,
    which is the part that matters: a caller looping over a file has to be able
    to tell that nothing was consumed.
    """
    var rows = bad_pem_tests_rows()
    for i in range(len(rows)):
        var got = decode(Span(rows[i].input))
        assert_false(Bool(got[0]))
        assert_equal(_text(got[1]), as_text(rows[i].input))


def test_decode_walks_a_document() raises:
    """Go's `TestDecode`: six blocks out of a file that is mostly not PEM."""
    var doc = document()
    var rest = doc.as_bytes().as_imm()

    var first = decode(rest)
    rest = first[1]
    assert_true(Bool(first[0]))
    assert_equal(first[0].value().type, "CERTIFICATE")
    assert_equal(len(first[0].value().headers), 0)
    assert_equal(as_text(first[0].value().bytes), "hello world")

    var second = decode(rest)
    rest = second[1]
    assert_true(Bool(second[0]))
    assert_equal(second[0].value().type, "RSA PRIVATE KEY")
    assert_equal(len(second[0].value().headers), 2)
    assert_equal(second[0].value().headers["Proc-Type"], "4,ENCRYPTED")
    assert_equal(
        second[0].value().headers["DEK-Info"], "DES-EDE3-CBC,80C7C7A09690757A"
    )
    assert_equal(len(second[0].value().bytes), 18)

    # Three blocks with nothing between the two lines, written with no blank
    # line, with one, and with two. All three are the same block.
    for _ in range(3):
        var empty = decode(rest)
        rest = empty[1]
        assert_true(Bool(empty[0]))
        assert_equal(empty[0].value().type, "EMPTY")
        assert_equal(len(empty[0].value().headers), 0)
        assert_equal(len(empty[0].value().bytes), 0)

    # `INVALID HEADERS` has a header and no blank line after it, so the header
    # loop eats the closing line and the block is never finished. It is skipped
    # rather than refused, and the next one is found.
    var last = decode(rest)
    rest = last[1]
    assert_true(Bool(last[0]))
    assert_equal(last[0].value().type, "VALID HEADERS")
    assert_equal(len(last[0].value().headers), 1)
    assert_equal(last[0].value().headers["Header"], "1")

    assert_equal(len(rest), 0)


def test_decode_strange_cases() raises:
    """Go's `TestDecodeStrangeCases`, all seven, each one a way to be wrong.

    Every document here holds one readable block at the end and something
    misleading in front of it, and the answer for all seven is the same block.
    """
    var docs: List[String] = [
        String(
            "-----BEGIN COMMENT-----\n"
            "foo foo foo\n"
            "-----END COMMENT-----\n"
            "-----BEGIN TEST BLOCK-----\n"
            "aGVsbG8=\n"
            "-----END TEST BLOCK-----"
        ),
        String(
            "foo foo foo-----BEGIN CERTIFICATE-----\n"
            "MCowBQYDK2VwAyEApVjJeLW5MoP6uR3+OeITokM+rBDng6dgl1vvhcy+wws=\n"
            "-----END PUBLIC KEY-----\n"
            "-----BEGIN TEST BLOCK-----\n"
            "aGVsbG8=\n"
            "-----END TEST BLOCK-----"
        ),
        String(
            "foo foo foo\n"
            "-----BEGIN TEST BLOCK-----\n"
            "aGVsbG8=\n"
            "-----END TEST BLOCK-----"
        ),
        String(
            "foo foo foo\n"
            "-----END COMMENT-----\n"
            "-----BEGIN TEST BLOCK-----\n"
            "aGVsbG8=\n"
            "-----END TEST BLOCK-----"
        ),
        String(
            "-----BEGIN TEST BLOCK-----\n"
            "-----BEGIN TEST BLOCK-----\n"
            "-----BEGIN TEST BLOCK-----\n"
            "aGVsbG8=\n"
            "-----END TEST BLOCK-----"
        ),
        String(
            "-----BEGIN TEST BLOCK-----\n"
            "aGVsbG8=\n"
            "-----END TEST BLOCK-----\n"
            "-----END TEST BLOCK-----\n"
            "-----END TEST BLOCK-----"
        ),
        String(
            "-----BEGIN PUBLIC KEY\n"
            "aGVsbG8=\n"
            "-----END PUBLIC KEY-----\n"
            "-----BEGIN TEST BLOCK-----\n"
            "aGVsbG8=\n"
            "-----END TEST BLOCK-----"
        ),
    ]
    for i in range(len(docs)):
        var got = decode(docs[i].as_bytes())
        assert_true(Bool(got[0]))
        assert_equal(got[0].value().type, "TEST BLOCK")
        assert_equal(as_text(got[0].value().bytes), "hello")


def test_just_end() raises:
    """Go's `TestJustEnd`: a closing line with nothing before it."""
    var doc = String("\n-----END PUBLIC KEY-----")
    var got = decode(doc.as_bytes())
    assert_false(Bool(got[0]))
    assert_equal(_text(got[1]), doc)


def test_missing_end_trailer() raises:
    """Go's `TestMissingEndTrailer`, which asserts nothing and is still a test.

    It is a document whose closing line runs off the end of the input, and it
    is here because Go's decoder indexes straight into the rest at that point.
    Go's slice would panic if the offset were wrong; a slice out of range in
    Mojo is not a panic, so this one is checked for rather than caught, and
    this row is what watches the check.
    """
    var doc = String("-----BEGIN ") + repeat(" ", 85) + "\n-----END "
    var got = decode(doc.as_bytes())
    assert_false(Bool(got[0]))
    assert_equal(len(got[1]), doc.byte_length())


def test_repeating_begin_is_not_quadratic() raises:
    """Go's `TestCVE202224675`, at a size a test suite can afford.

    Before that fix the decoder recursed once per opening line and ten million
    of them overflowed the stack. The loop here finds the first closing line
    and then the last opening line before it, so a run of opening lines with
    nothing to close them costs one pass rather than one per line. Go uses ten
    million; a hundred thousand is enough to take minutes if the shape of the
    loop is wrong and is over in no time when it is right.
    """
    var doc = repeat("-----BEGIN \n", 100000)
    var got = decode(doc.as_bytes())
    assert_false(Bool(got[0]))
    assert_equal(len(got[1]), doc.byte_length())


def test_headers_are_trimmed() raises:
    """The space after the colon is not part of the value, and neither is any
    other.

    Go trims both sides of both halves, which is why `Header : 1 ` and
    `Header:1` are the same header.
    """
    var doc = String(
        "-----BEGIN A-----\nHeader :   1  \nOther:2\n\naGk=\n-----END A-----"
    )
    var got = decode(doc.as_bytes())
    assert_true(Bool(got[0]))
    assert_equal(len(got[0].value().headers), 2)
    assert_equal(got[0].value().headers["Header"], "1")
    assert_equal(got[0].value().headers["Other"], "2")


def test_body_spaces_and_tabs_are_ignored() raises:
    """Go takes spaces and tabs out of the base64 and leaves newlines to the
    base64 decoder, which skips them itself. Both ways in, one way out.
    """
    var doc = String(
        "-----BEGIN A-----\naG Vs\tbG8g\nd29y bGQ=\n-----END A-----"
    )
    var got = decode(doc.as_bytes())
    assert_true(Bool(got[0]))
    assert_equal(as_text(got[0].value().bytes), "hello world")


def test_remove_spaces_and_tabs() raises:
    """The helper on its own, because the newline rule is easy to get wrong."""
    var mixed = bytes_of("a b\tc\nd")
    assert_equal(as_text(_remove_spaces_and_tabs(Span(mixed))), "abc\nd")
    var clean = bytes_of("abc")
    assert_equal(as_text(_remove_spaces_and_tabs(Span(clean))), "abc")
    var blank = bytes_of(" \t \t")
    assert_equal(len(_remove_spaces_and_tabs(Span(blank))), 0)


def test_a_body_that_is_not_base64_is_skipped() raises:
    """The block is not refused, and the search carries on after its end line.
    """
    var doc = String(
        "-----BEGIN A-----\n"
        "not base64 at all\n"
        "-----END A-----\n"
        "-----BEGIN B-----\n"
        "aGk=\n"
        "-----END B-----"
    )
    var got = decode(doc.as_bytes())
    assert_true(Bool(got[0]))
    assert_equal(got[0].value().type, "B")


def test_crlf_endings_read_the_same() raises:
    """A document written on Windows is the same document."""
    var doc = String(
        "-----BEGIN A-----\r\nHeader: 1\r\n\r\naGk=\r\n-----END A-----\r\n"
    )
    var got = decode(doc.as_bytes())
    assert_true(Bool(got[0]))
    assert_equal(got[0].value().type, "A")
    assert_equal(got[0].value().headers["Header"], "1")
    assert_equal(as_text(got[0].value().bytes), "hi")


def test_a_type_that_is_not_utf8_is_skipped() raises:
    """The one place this cannot do what Go does, and it has a row in
    `docs/deviations.md`.

    Go builds a string holding whatever bytes were on the type line. A Mojo
    `String` is UTF-8 by construction, so a type line that is not UTF-8 has no
    string to become, and the block goes the way a block with a corrupt body
    goes: skipped, with the search carrying on after it.
    """
    var shape = String("-----BEGIN @-----\naGk=\n-----END @-----")
    var good = decode(shape.as_bytes())
    assert_true(Bool(good[0]))
    assert_equal(good[0].value().type, "@")

    var doc = bytes_of(shape)
    for i in range(len(doc)):
        if doc[i] == Byte(ord("@")):
            doc[i] = 0xFF
    var got = decode(Span(doc))
    assert_false(Bool(got[0]))
