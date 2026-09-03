"""Case mapping, and the Latin-1 shortcuts that are the reason to distrust it.

Go's `letter_test.go`. The rows come from `_fixtures.mojo` and the interesting
ones are named there.

Two of these tests are worth more than the rest. `test_latin1_shortcuts_agree`
is Go's `TestLetterOptimizations` and it is the one that catches the mistake
this package is shaped to make: every predicate answers from a 256 byte table
below U+0100 and from a range table above it, so a bit set wrong in the byte
table gives a wrong answer for a code point that the range table would have got
right, and nothing else here would notice. `test_negative_runes_are_nothing` is
Go's `TestNegativeRune`, which exists because those shortcuts start by
narrowing a rune to a byte, and a negative rune narrowed to a byte looks like a
perfectly ordinary letter.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.unicode import (
    LOWER_CASE,
    MAX_CASE,
    MAX_LATIN1,
    MAX_RUNE,
    REPLACEMENT_CHAR,
    TITLE_CASE,
    UPPER_CASE,
    UPPER_LOWER,
    AzeriCase,
    CaseRange,
    CaseRanges,
    Letter,
    Lower,
    SpecialCase,
    Title,
    TurkishCase,
    Upper,
    White_Space,
    is_control,
    is_digit,
    is_graphic,
    is_in,
    is_letter,
    is_lower,
    is_mark,
    is_number,
    is_print,
    is_punct,
    is_space,
    is_symbol,
    is_title,
    is_upper,
    to,
    to_lower,
    to_title,
    to_upper,
)

from tests.unicode._fixtures import (
    case_cases,
    letter_cases,
    not_letter_cases,
    not_upper_cases,
    space_cases,
    turkish_alphabet,
    upper_cases,
)


def test_the_case_indices_are_gos_numbers() raises:
    """`to` takes an index into a three element delta, so the numbers are API.

    Go documents `UpperCase`, `LowerCase` and `TitleCase` as 0, 1 and 2, and
    the case ranges in `data.mojo` are generated in that order, so a value
    changing here would silently swap two mappings.
    """
    assert_equal(UPPER_CASE, 0)
    assert_equal(LOWER_CASE, 1)
    assert_equal(TITLE_CASE, 2)
    assert_equal(MAX_CASE, 3)
    assert_equal(Int(MAX_RUNE), 0x10FFFF)
    assert_equal(Int(REPLACEMENT_CHAR), 0xFFFD)
    assert_equal(Int(MAX_LATIN1), 0xFF)
    assert_equal(Int(UPPER_LOWER), Int(MAX_RUNE) + 1)


def test_the_letter_lists_are_letters() raises:
    """Go's `TestIsLetter`. Every upper case letter is a letter."""
    for r in upper_cases():
        assert_true(is_letter(r))
    for r in letter_cases():
        assert_true(is_letter(r))
    for r in not_letter_cases():
        assert_false(is_letter(r))


def test_is_upper() raises:
    """Go's `TestIsUpper`. The near misses matter more than the hits here."""
    for r in upper_cases():
        assert_true(is_upper(r))
    for r in not_upper_cases():
        assert_false(is_upper(r))
    for r in not_letter_cases():
        assert_false(is_upper(r))


def test_to_maps_every_row() raises:
    """Go's `TestTo`. Includes the row where the case index is not a case.

    `to(-1, r)` is `REPLACEMENT_CHAR` rather than a failure, which is Go's
    answer and one of the few places in either library where a programming
    mistake produces a code point.
    """
    for row in case_cases():
        assert_equal(to(row.case_, row.in_), row.out)


def test_to_upper_lower_and_title_agree_with_to() raises:
    """Go's `TestToUpperCase`, `TestToLowerCase` and `TestToTitleCase`.

    The three named functions have their own ASCII shortcut, so they are not
    `to` with an argument bound and have to be checked against the same rows.
    """
    for row in case_cases():
        if row.case_ == UPPER_CASE:
            assert_equal(to_upper(row.in_), row.out)
        elif row.case_ == LOWER_CASE:
            assert_equal(to_lower(row.in_), row.out)
        elif row.case_ == TITLE_CASE:
            assert_equal(to_title(row.in_), row.out)


def test_is_space() raises:
    """Go's `TestIsSpace`. The Latin-1 half is a list rather than a bit."""
    for r in space_cases():
        assert_true(is_space(r))
    for r in letter_cases():
        assert_false(is_space(r))


def test_latin1_shortcuts_agree() raises:
    """Go's `TestLetterOptimizations`, and the reason this file exists.

    Every predicate below U+0100 comes from the byte table in `data.mojo` and
    every one above it comes from a range table. This asks both of them the
    same 256 questions.
    """
    for code in range(0, Int(MAX_LATIN1) + 1):
        var r = Int32(code)
        assert_equal(is_in(Letter, r), is_letter(r))
        assert_equal(is_in(Upper, r), is_upper(r))
        assert_equal(is_in(Lower, r), is_lower(r))
        assert_equal(is_in(Title, r), is_title(r))
        assert_equal(is_in(White_Space, r), is_space(r))
        assert_equal(to(UPPER_CASE, r), to_upper(r))
        assert_equal(to(LOWER_CASE, r), to_lower(r))
        assert_equal(to(TITLE_CASE, r), to_title(r))


def test_negative_runes_are_nothing() raises:
    """Go's `TestNegativeRune`, its issue 43254 and our own hazard.

    Every value here is negative and narrows to a byte that looks like an
    ordinary Latin-1 character, and to a sixteen bit value that looks like an
    ordinary code point. A shortcut that converts before it checks the sign
    answers as though the letter were there.
    """
    var above: List[Int32] = [
        0x0100,
        0x0101,
        0x01C5,
        0x0300,
        0x0660,
        0x037E,
        0x02C2,
        0x1680,
    ]
    var bases = List[Int32]()
    for code in range(0, Int(MAX_LATIN1)):
        bases.append(Int32(code))
    for r in above:
        bases.append(r)

    for base in bases:
        # Negative, and yet the low eight and low sixteen bits are the ones the
        # code point above would have.
        var r = Int32(Int(base) - (1 << 31))
        assert_false(is_in(Letter, r))
        assert_false(is_control(r))
        assert_false(is_digit(r))
        assert_false(is_graphic(r))
        assert_false(is_letter(r))
        assert_false(is_lower(r))
        assert_false(is_mark(r))
        assert_false(is_number(r))
        assert_false(is_print(r))
        assert_false(is_punct(r))
        assert_false(is_space(r))
        assert_false(is_symbol(r))
        assert_false(is_title(r))
        assert_false(is_upper(r))


def test_case_ranges_are_ordered_and_sane() raises:
    """The table `to` searches, checked for the property the search assumes.

    A binary search over rows that are not sorted answers wrongly rather than
    failing, and nothing above would necessarily catch it, so the order is
    asserted here rather than trusted. `UPPER_LOWER` marks an alternating run
    and is a delta rather than a code point, which is why the delta bound only
    applies to the other rows.
    """
    var rows = CaseRanges()
    assert_equal(len(rows), 328)
    var previous = Int32(-1)
    for row in rows:
        assert_true(row.lo <= row.hi)
        assert_true(Int32(row.lo) > previous)
        previous = Int32(row.hi)
        assert_true(row.hi <= UInt32(MAX_RUNE))
        for index in range(MAX_CASE):
            var delta = row.delta[index]
            if delta != UPPER_LOWER:
                assert_true(Int32(row.lo) + delta >= 0)
                assert_true(Int32(row.hi) + delta <= MAX_RUNE)


def test_a_special_case_with_no_deltas_changes_nothing() raises:
    """Go's `TestSpecialCaseNoMapping`, its issue 25636.

    A row with three zero deltas is not the same as no row at all: it says
    that this code point is deliberately left alone, and an implementation
    that treats an unchanged answer as a miss falls through to the general
    mapping and lower cases it anyway.
    """
    var rows: List[CaseRange] = [
        CaseRange(0x41, 0x41, SIMD[DType.int32, 4](0, 0, 0, 0))
    ]
    var special = SpecialCase(rows^)
    assert_equal(len(special), 1)
    assert_equal(special.to_lower(Int32(ord("A"))), Int32(ord("A")))
    assert_equal(special.to_upper(Int32(ord("A"))), Int32(ord("A")))
    assert_equal(special.to_title(Int32(ord("A"))), Int32(ord("A")))
    # And a code point the table says nothing about still gets the general
    # mapping, which is what makes a four row table useful.
    assert_equal(special.to_lower(Int32(ord("B"))), Int32(ord("b")))


def test_turkish_and_azeri() raises:
    """Go's `TestTurkishCase`. The whole alphabet, both directions."""
    var turkish = TurkishCase()
    var azeri = AzeriCase()
    for pair in turkish_alphabet():
        var lower, upper = pair
        assert_equal(turkish.to_lower(lower), lower)
        assert_equal(turkish.to_upper(upper), upper)
        assert_equal(turkish.to_upper(lower), upper)
        assert_equal(turkish.to_lower(upper), lower)
        assert_equal(turkish.to_title(upper), upper)
        assert_equal(turkish.to_title(lower), upper)
        # Azerbaijani is the same four rows in Go and here, and the test says
        # so rather than the comment saying so.
        assert_equal(azeri.to_upper(lower), upper)
        assert_equal(azeri.to_lower(upper), lower)


def test_turkish_disagrees_with_the_general_mapping_in_four_places() raises:
    """The whole point of the table, written down as the four code points.

    Everything else falls through, and `x` is here to prove that it does.
    """
    var turkish = TurkishCase()
    assert_equal(len(turkish), 4)
    assert_equal(turkish.to_upper(Int32(ord("i"))), Int32(0x130))
    assert_equal(turkish.to_lower(Int32(ord("I"))), Int32(0x131))
    assert_equal(turkish.to_lower(Int32(0x130)), Int32(ord("i")))
    assert_equal(turkish.to_upper(Int32(0x131)), Int32(ord("I")))
    assert_equal(to_upper(Int32(ord("i"))), Int32(ord("I")))
    assert_equal(turkish.to_upper(Int32(ord("x"))), Int32(ord("X")))


def test_a_rune_that_is_not_one() raises:
    """Above `MAX_RUNE` and below zero, every mapping is the identity.

    Go answers this way rather than raising, and a caller decoding bytes will
    hand this package a negative rune sooner or later.
    """
    var beyond = MAX_RUNE + 1
    assert_equal(to_upper(beyond), beyond)
    assert_equal(to_lower(beyond), beyond)
    assert_equal(to_title(beyond), beyond)
    assert_equal(to_upper(Int32(-42)), Int32(-42))
    assert_equal(to_lower(Int32(-42)), Int32(-42))
    assert_equal(to_title(Int32(-42)), Int32(-42))
