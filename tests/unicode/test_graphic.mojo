"""The predicates, each one checked against the table it is a shortcut for.

Go's `graphic_test.go` and `digit_test.go`. Every predicate in this package
answers Latin-1 from the 256 byte table in `data.mojo` and everything above it
from a range table, and the two halves are written by different code from
different inputs. Go's whole graphic test file is ten loops that ask both
halves the same 256 questions, and so is most of this one.

`is_control` is the exception and is written out rather than compared, because
there is no `Control` table to compare it against: Go defines the control
characters as two ranges in the source of the test itself, which is the only
place in either library where the answer is a literal.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.unicode import (
    MAX_LATIN1,
    MAX_RUNE,
    Digit,
    GraphicRanges,
    Letter,
    Lower,
    Nd,
    Number,
    PrintRanges,
    Punct,
    RangeTable,
    Symbol,
    Upper,
    White_Space,
    Zs,
    in_any,
    is_control,
    is_digit,
    is_graphic,
    is_letter,
    is_lower,
    is_number,
    is_one_of,
    is_print,
    is_punct,
    is_space,
    is_symbol,
    is_upper,
    is_in,
)

from tests.unicode._fixtures import digit_cases, digit_letter_cases


def test_is_control_in_latin1() raises:
    """Go's `TestIsControlLatin1`. The two ranges, written down.

    C0 is U+0000 to U+001F and C1 is U+007F to U+009F. Everything else is not
    a control character, including the code points either side of both ranges,
    which is the half of this loop that does the work.
    """
    for code in range(0, Int(MAX_LATIN1) + 1):
        var r = Int32(code)
        var want = (code <= 0x1F) or (0x7F <= code and code <= 0x9F)
        assert_equal(is_control(r), want)


def test_the_predicates_agree_with_their_tables_in_latin1() raises:
    """Go's eight remaining Latin-1 loops, as one loop over eight questions.

    Go writes `TestIsLetterLatin1`, `TestIsUpperLatin1` and six more, each of
    them the same three lines with a different pair of names. They are one loop
    here because a failure names the code point and the predicate either way,
    and eight copies of a loop is eight places for the pair to be mismatched.
    """
    for code in range(0, Int(MAX_LATIN1) + 1):
        var r = Int32(code)
        assert_equal(is_letter(r), is_in(Letter, r))
        assert_equal(is_upper(r), is_in(Upper, r))
        assert_equal(is_lower(r), is_in(Lower, r))
        assert_equal(is_number(r), is_in(Number, r))
        assert_equal(is_punct(r), is_in(Punct, r))
        assert_equal(is_space(r), is_in(White_Space, r))
        assert_equal(is_symbol(r), is_in(Symbol, r))
        assert_equal(is_digit(r), is_in(Digit, r))


def test_graphic_and_print_agree_with_their_range_lists() raises:
    """Go's `TestIsGraphicLatin1` and `TestIsPrintLatin1`.

    `is_graphic` and `is_print` do not read `GraphicRanges` or `PrintRanges`;
    they read a bit in the byte table below U+0100 and a category table above
    it, and the two lists exist for callers who want to say which categories
    they mean. This asserts that the fast answer and the list are the same
    answer, which is the thing that would otherwise silently drift.

    ASCII space is the exception Go carves out by hand: it is printable and it
    is in Zs, which is in `GraphicRanges` and not in `PrintRanges`.
    """
    var graphic = GraphicRanges()
    var printable = PrintRanges()
    for code in range(0, Int(MAX_LATIN1) + 1):
        var r = Int32(code)
        assert_equal(is_graphic(r), is_one_of(graphic, r))
        var want_print = is_one_of(printable, r)
        if code == 0x20:
            want_print = True
        assert_equal(is_print(r), want_print)


def test_the_two_lists_differ_by_exactly_zs() raises:
    """`GraphicRanges` is `PrintRanges` and Zs, which is the whole difference.

    Six tables against five, and the one that is only in the graphic list is
    the space separators. U+00A0 NO-BREAK SPACE is the code point that shows
    it: graphic, not printable, and the reason `is_print` is not `is_graphic`.
    """
    assert_equal(len(GraphicRanges()), 6)
    assert_equal(len(PrintRanges()), 5)
    assert_true(is_graphic(Int32(0xA0)))
    assert_false(is_print(Int32(0xA0)))
    assert_true(is_in(Zs, Int32(0xA0)))
    # And ASCII space, which is in the same table and is printable anyway.
    assert_true(is_graphic(Int32(0x20)))
    assert_true(is_print(Int32(0x20)))
    assert_true(is_in(Zs, Int32(0x20)))


def test_is_one_of_over_a_list_matches_in_any_over_an_argument_list() raises:
    """The two spellings of the same question, asked of the same code points.

    `in_any` takes tables as arguments and `is_one_of` takes them as a list.
    They are separate functions here as they are in Go, so they are separate
    opportunities to get the loop wrong.
    """
    var graphic = GraphicRanges()
    var interesting: List[Int32] = [
        0x00,
        0x20,
        0x41,
        0xA0,
        0xFF,
        0x0100,
        0x0300,
        0x2028,
        0x3000,
        0xFFFD,
        0x10FFFF,
    ]
    for r in interesting:
        assert_equal(
            is_one_of(graphic, r),
            in_any(
                r,
                graphic[0],
                graphic[1],
                graphic[2],
                graphic[3],
                graphic[4],
                graphic[5],
            ),
        )


def test_an_empty_list_holds_nothing() raises:
    """`is_one_of` over no tables, which a caller assembling a set will hit."""
    var none = List[RangeTable]()
    assert_false(is_one_of(none, Int32(ord("A"))))


def test_the_digits() raises:
    """Go's `TestDigit`. The first and last digit of every decimal system."""
    for r in digit_cases():
        assert_true(is_digit(r))
        # Every decimal digit is a number, and this is the direction that
        # holds. The other one does not, which is the next test.
        assert_true(is_number(r))


def test_a_letter_is_not_a_digit() raises:
    """Go's second loop in `TestDigit`, over `testLetter`."""
    for r in digit_letter_cases():
        assert_false(is_digit(r))


def test_a_number_that_is_not_a_digit() raises:
    """The distinction `is_digit` exists to make, as the code points.

    Category Nd is the decimal digits. Category N also holds the superscripts,
    the fractions and the Roman numerals, and a parser that accepts `is_number`
    where it means `is_digit` accepts ½ as a numeral.
    """
    var not_digits: List[Int32] = [0xB2, 0xB3, 0xB9, 0xBD, 0x2160, 0x2474]
    for r in not_digits:
        assert_true(is_number(r))
        assert_false(is_digit(r))
        assert_false(is_in(Nd, r))


def test_digit_is_nd() raises:
    """`Digit` and `Nd` are the same table under two names, as in Go.

    Go writes `Digit = _Nd` in `tables.go`, so the two are one table and the
    generator here has to produce them as one as well: two tables with the
    same contents would pass every test above and still be a byte more than
    the library needs.
    """
    for code in range(0, 0x3000):
        var r = Int32(code)
        assert_equal(is_in(Digit, r), is_in(Nd, r))


def test_a_rune_that_is_not_one() raises:
    """Above `MAX_RUNE`, no predicate says yes."""
    var beyond = MAX_RUNE + 1
    assert_false(is_control(beyond))
    assert_false(is_digit(beyond))
    assert_false(is_graphic(beyond))
    assert_false(is_letter(beyond))
    assert_false(is_lower(beyond))
    assert_false(is_number(beyond))
    assert_false(is_print(beyond))
    assert_false(is_punct(beyond))
    assert_false(is_space(beyond))
    assert_false(is_symbol(beyond))
