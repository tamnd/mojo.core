"""Changing case. Go's `upperTests`, `lowerTests` and `ToTitleTests`.

Two of Go's rows exist to make the result a different length from the input:
U+0250 upper cases to U+2C6F and grows a byte per rune, U+2C6D lower cases to
U+0251 and shrinks one. An implementation that wrote the answer back over the
input would pass everything else in the table and fail those two.

`to_upper` and `to_lower` take an all-ASCII shortcut, so every row that has a
byte above 127 in it is testing a second implementation. The rows are written
here in `\\xNN` form where the characters would otherwise be hard to tell apart
on screen — U+0250 ɐ, U+2C6F Ɐ, U+2C6D Ɱ and U+0251 ɑ are four shapes that
differ by a hairline in most fonts, and getting the wrong one into a table is a
failure that takes an hour to see.
"""

from std.testing import assert_equal

from core.bytes import (
    to_lower,
    to_lower_special,
    to_title,
    to_title_special,
    to_upper,
    to_upper_special,
)
from core.unicode import TurkishCase

from tests.bytes._fixtures import enc, expect, quote

comptime SMALL_TURNED_A = "\\xc9\\x90"
"""U+0250 LATIN SMALL LETTER TURNED A. Upper cases to `TURNED_A`."""

comptime TURNED_A = "\\xe2\\xb1\\xaf"
"""U+2C6F LATIN CAPITAL LETTER TURNED A. Three bytes to the other's two."""

comptime TURNED_M = "\\xe2\\xb1\\xad"
"""U+2C6D LATIN CAPITAL LETTER TURNED M. Lower cases to `ALPHA`."""

comptime ALPHA = "\\xc9\\x91"
"""U+0251 LATIN SMALL LETTER ALPHA. Two bytes to the other's three."""


@fieldwise_init
struct CaseCase(Copyable, Movable):
    """Go's `StringTest`: an input and what the mapping makes of it."""

    var input: String
    var want: String


def test_to_upper() raises:
    """Go's `upperTests`.

    The last row is Go's comment about `RuneSelf` and `MaxRune`: U+0080 is the
    first rune that is not one byte and U+10FFFF is the last rune there is, and
    neither has an upper case, so both have to survive the mapping unchanged.
    """
    var cases = List[CaseCase]()
    cases.append(CaseCase("", ""))
    cases.append(CaseCase("ONLYUPPER", "ONLYUPPER"))
    cases.append(CaseCase("abc", "ABC"))
    cases.append(CaseCase("AbC123", "ABC123"))
    cases.append(CaseCase("azAZ09_", "AZAZ09_"))
    cases.append(
        CaseCase(
            "longStrinGwitHmixofsmaLLandcAps",
            "LONGSTRINGWITHMIXOFSMALLANDCAPS",
        )
    )
    cases.append(
        CaseCase(
            "long"
            + SMALL_TURNED_A
            + "string"
            + SMALL_TURNED_A
            + "with"
            + SMALL_TURNED_A
            + "nonascii"
            + TURNED_A
            + "chars",
            "LONG"
            + TURNED_A
            + "STRING"
            + TURNED_A
            + "WITH"
            + TURNED_A
            + "NONASCII"
            + TURNED_A
            + "CHARS",
        )
    )
    # Grows one byte per character.
    cases.append(CaseCase(SMALL_TURNED_A * 5, TURNED_A * 5))
    cases.append(
        CaseCase(
            "a\\xc2\\x80\\xf4\\x8f\\xbf\\xbf", "A\\xc2\\x80\\xf4\\x8f\\xbf\\xbf"
        )
    )
    for row in cases:
        var b = enc(row.input)
        var got = to_upper(Span(b))
        assert_equal(quote(Span(got)), expect(row.want))


def test_to_lower() raises:
    """Go's `lowerTests`."""
    var cases = List[CaseCase]()
    cases.append(CaseCase("", ""))
    cases.append(CaseCase("abc", "abc"))
    cases.append(CaseCase("AbC123", "abc123"))
    cases.append(CaseCase("azAZ09_", "azaz09_"))
    cases.append(
        CaseCase(
            "longStrinGwitHmixofsmaLLandcAps",
            "longstringwithmixofsmallandcaps",
        )
    )
    cases.append(
        CaseCase(
            "LONG"
            + TURNED_A
            + "STRING"
            + TURNED_A
            + "WITH"
            + TURNED_A
            + "NONASCII"
            + TURNED_A
            + "CHARS",
            "long"
            + SMALL_TURNED_A
            + "string"
            + SMALL_TURNED_A
            + "with"
            + SMALL_TURNED_A
            + "nonascii"
            + SMALL_TURNED_A
            + "chars",
        )
    )
    # Shrinks one byte per character.
    cases.append(CaseCase(TURNED_M * 5, ALPHA * 5))
    cases.append(
        CaseCase(
            "A\\xc2\\x80\\xf4\\x8f\\xbf\\xbf", "a\\xc2\\x80\\xf4\\x8f\\xbf\\xbf"
        )
    )
    for row in cases:
        var b = enc(row.input)
        var got = to_lower(Span(b))
        assert_equal(quote(Span(got)), expect(row.want))


def test_to_title() raises:
    """Go's `ToTitleTests`.

    Every rune, not the first letter of every word. ` aaa aaa aaa ` becomes
    ` AAA AAA AAA `, which is the row that says so and the reason Go's other
    function — the one that title cases word initials — is deprecated and not
    in this library.
    """
    var cases = List[CaseCase]()
    cases.append(CaseCase("", ""))
    cases.append(CaseCase("a", "A"))
    cases.append(CaseCase(" aaa aaa aaa ", " AAA AAA AAA "))
    cases.append(CaseCase(" Aaa Aaa Aaa ", " AAA AAA AAA "))
    cases.append(CaseCase("123a456", "123A456"))
    cases.append(CaseCase("double-blind", "DOUBLE-BLIND"))
    cases.append(CaseCase("ÿøû", "ŸØÛ"))
    for row in cases:
        var b = enc(row.input)
        var got = to_title(Span(b))
        assert_equal(quote(Span(got)), expect(row.want))


def test_title_case_is_not_upper_case_for_a_digraph() raises:
    """The one place `to_title` and `to_upper` differ, which no Go row covers.

    U+01C4 DŽ upper cases to itself and title cases to U+01C5 Dž, the form with
    only the first letter capital. There are a few dozen of these and they are
    the entire reason `to_title` is a separate function.
    """
    var b = enc("\\xc7\\x86")  # U+01C6 dž, the lower case form.
    assert_equal(quote(Span(to_upper(Span(b)))), expect("\\xc7\\x84"))
    assert_equal(quote(Span(to_title(Span(b)))), expect("\\xc7\\x85"))


def test_case_mapping_is_one_rune_to_one_rune() raises:
    """The German ß upper cases to itself, not to SS.

    This is Go's behaviour and the docstring on the module says so; the check
    is here because it is the first thing anyone tries and the answer looks
    like a bug until you know that the expansion lives in full case mapping,
    which needs the Unicode text tables neither library carries.
    """
    var b = enc("stra\\xc3\\x9fe")
    assert_equal(quote(Span(to_upper(Span(b)))), expect("STRA\\xc3\\x9fE"))


def test_turkish_special_case() raises:
    """Go's `strings.TestSpecialCase`, which `bytes_test.go` does not have.

    Turkish is the language the special cases exist for: `i` upper cases to
    U+0130, the capital I with a dot, and U+0131, the dotless small i, is what
    `I` lower cases to. Without the special case both go to plain ASCII and the
    result is a different word.
    """
    var lower = enc("istanbul")
    var upper = to_upper_special(TurkishCase(), Span(lower))
    assert_equal(quote(Span(upper)), expect("\\xc4\\xb0STANBUL"))

    var shouting = enc("ISTANBUL")
    var quiet = to_lower_special(TurkishCase(), Span(shouting))
    assert_equal(quote(Span(quiet)), expect("\\xc4\\xb1stanbul"))

    var titled = to_title_special(TurkishCase(), Span(lower))
    assert_equal(quote(Span(titled)), expect("\\xc4\\xb0STANBUL"))


def test_special_case_falls_back_to_the_general_mapping() raises:
    """A rune the special case says nothing about is mapped the ordinary way,
    which is what makes `to_upper_special` usable on a whole document rather
    than on the letters somebody picked out of it."""
    var b = enc("mix")
    var got = to_upper_special(TurkishCase(), Span(b))
    assert_equal(quote(Span(got)), expect("M\\xc4\\xb0X"))
