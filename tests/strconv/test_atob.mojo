"""Booleans. Go's `atob_test.go`."""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import matches
from core.errors.codes import ErrSyntax

from core.strconv import NumError, append_bool, format_bool, parse_bool


def test_parse_bool_accepts_the_twelve() raises:
    """Go's `atobtests`, the rows that succeed."""
    assert_true(parse_bool("1"))
    assert_true(parse_bool("t"))
    assert_true(parse_bool("T"))
    assert_true(parse_bool("true"))
    assert_true(parse_bool("TRUE"))
    assert_true(parse_bool("True"))
    assert_false(parse_bool("0"))
    assert_false(parse_bool("f"))
    assert_false(parse_bool("F"))
    assert_false(parse_bool("false"))
    assert_false(parse_bool("FALSE"))
    assert_false(parse_bool("False"))


def test_parse_bool_refuses_everything_else() raises:
    """Go's failing rows plus the near misses somebody will try.

    `tRuE` is the one worth naming: three capitalisations are accepted and it
    is not one of them, in Go and here.
    """
    var bad = [
        "",
        "asdf",
        "0x1",
        "2",
        "TRue",
        "tRuE",
        "yes",
        "no",
        "on",
        "off",
        "true ",
        " true",
        "TRUE\n",
    ]
    for text in bad:
        var raised = False
        try:
            _ = parse_bool(text)
        except e:
            raised = True
            assert_true(matches(e, ErrSyntax))
            var failure = NumError.of(e)
            assert_true(Bool(failure))
            assert_equal(failure.value().func, "parse_bool")
        assert_true(raised, "parse_bool should have refused " + text)


def test_format_bool() raises:
    """Go spells a boolean in lower case and so does this."""
    assert_equal(format_bool(True), "true")
    assert_equal(format_bool(False), "false")


def test_append_bool() raises:
    """Go's `TestAppendBool`, with the count this library returns instead."""
    var dst = List[UInt8]()
    for byte in "value=".as_bytes():
        dst.append(byte)
    assert_equal(append_bool(dst, True), 4)
    assert_equal(append_bool(dst, False), 5)
    assert_equal(String(from_utf8_lossy=Span(dst)), "value=truefalse")


def test_the_round_trip_works_both_ways() raises:
    """What `format_bool` writes, `parse_bool` reads, and so does Mojo's own
    spelling, which is what a caller pasting `String(True)` will hand it.
    """
    assert_true(parse_bool(format_bool(True)))
    assert_false(parse_bool(format_bool(False)))
    assert_true(parse_bool(String(True)))
    assert_false(parse_bool(String(False)))
