"""The tables, transcribed from Go's `unicode` tests.

`upperTest`, `notupperTest`, `letterTest`, `notletterTest`, `spaceTest` and
`caseTest` from `letter_test.go`, `testDigit` and `testLetter` from
`digit_test.go`, `inCategoryTest` and `inPropTest` from `script_test.go`, and
the fold cycles from `simpleFoldTests`.

They are worth transcribing rather than generating for the reason the utf8
fixtures give: these code points were chosen by somebody reading the Unicode
files, one per interesting block and one on each side of every boundary they
could find, so a table derived from this implementation would agree with it by
construction and prove nothing. The differ in `tools/differ` is the exhaustive
half and this is the hand written half, and neither replaces the other.

Go writes the fold cycles as strings, `"KkK"` and `"ρϱΡ"`. They are lists of
code points here, because the interesting thing about them is which code points
they hold and a Mojo `String` would have to be decoded again to say.
"""

from core.unicode import LOWER_CASE, TITLE_CASE, UPPER_CASE


@fieldwise_init
struct Case(Copyable, Movable):
    """One row of Go's `caseTest`: a case, a code point, and the answer."""

    var case_: Int
    """`UPPER_CASE`, `LOWER_CASE`, `TITLE_CASE`, or -1 for the error row."""

    var in_: Int32
    var out: Int32


@fieldwise_init
struct Named(Copyable, Movable):
    """One row of Go's `inCategoryTest` or `inPropTest`: a code point in a table.
    """

    var rune: Int32
    var name: String


def upper_cases() -> List[Int32]:
    """Go's `upperTest`. Upper case letters, one per block that has any."""
    var out: List[Int32] = [
        0x41,
        0xC0,
        0xD8,
        0x100,
        0x139,
        0x14A,
        0x178,
        0x181,
        0x376,
        0x3CF,
        0x13BD,
        0x1F2A,
        0x2102,
        0x2C00,
        0x2C10,
        0x2C20,
        0xA650,
        0xA722,
        0xFF3A,
        0x10400,
        0x1D400,
        0x1D7CA,
    ]
    return out^


def not_upper_cases() -> List[Int32]:
    """Go's `notupperTest`. Both sides of the ASCII run, and four near misses.
    """
    var out: List[Int32] = [
        0x40,
        0x5B,
        0x61,
        0x185,
        0x1B0,
        0x377,
        0x387,
        0x2150,
        0xAB7D,
        0xFFFF,
        0x10000,
    ]
    return out^


def letter_cases() -> List[Int32]:
    """Go's `letterTest`. A letter from thirty two different scripts."""
    var out: List[Int32] = [
        0x41,
        0x61,
        0xAA,
        0xBA,
        0xC8,
        0xDB,
        0xF9,
        0x2EC,
        0x535,
        0x620,
        0x6E6,
        0x93D,
        0xA15,
        0xB99,
        0xDC0,
        0xEDD,
        0x1000,
        0x1200,
        0x1312,
        0x1401,
        0x2C00,
        0xA800,
        0xF900,
        0xFA30,
        0xFFDA,
        0xFFDC,
        0x10000,
        0x10300,
        0x10400,
        0x20000,
        0x2F800,
        0x2FA1D,
    ]
    return out^


def not_letter_cases() -> List[Int32]:
    """Go's `notletterTest`. Includes the two non characters and the last one.
    """
    var out: List[Int32] = [
        0x20,
        0x35,
        0x375,
        0x619,
        0x700,
        0x1885,
        0xFFFE,
        0x1FFFF,
        0x10FFFF,
    ]
    return out^


def space_cases() -> List[Int32]:
    """Go's `spaceTest`. Every special cased Latin-1 space, and two above it."""
    var out: List[Int32] = [
        0x09,
        0x0A,
        0x0B,
        0x0C,
        0x0D,
        0x20,
        0x85,
        0xA0,
        0x2000,
        0x3000,
    ]
    return out^


def case_cases() -> List[Case]:
    """Go's `caseTest`, with Go's comments kept as the grouping.

    The two rows worth pointing at are U+0131 dotless i, whose upper case is
    `I` under the general mapping and is the reason Turkish needs its own
    table, and the U+A640 block, which is an `UPPER_LOWER` sequence: one row of
    the case table covering an alternating run of capitals and smalls, where
    the answer is arithmetic on the code point rather than a stored delta.
    """
    var out = List[Case]()

    # errors
    out.append(Case(-1, 0x0A, 0xFFFD))
    out.append(Case(UPPER_CASE, -1, -1))
    out.append(Case(UPPER_CASE, 1 << 30, 1 << 30))

    # ASCII, which is special cased in both libraries and so tested carefully
    out.append(Case(UPPER_CASE, 0x0A, 0x0A))
    out.append(Case(UPPER_CASE, Int32(ord("a")), Int32(ord("A"))))
    out.append(Case(UPPER_CASE, Int32(ord("A")), Int32(ord("A"))))
    out.append(Case(UPPER_CASE, Int32(ord("7")), Int32(ord("7"))))
    out.append(Case(LOWER_CASE, 0x0A, 0x0A))
    out.append(Case(LOWER_CASE, Int32(ord("a")), Int32(ord("a"))))
    out.append(Case(LOWER_CASE, Int32(ord("A")), Int32(ord("a"))))
    out.append(Case(LOWER_CASE, Int32(ord("7")), Int32(ord("7"))))
    out.append(Case(TITLE_CASE, 0x0A, 0x0A))
    out.append(Case(TITLE_CASE, Int32(ord("a")), Int32(ord("A"))))
    out.append(Case(TITLE_CASE, Int32(ord("A")), Int32(ord("A"))))
    out.append(Case(TITLE_CASE, Int32(ord("7")), Int32(ord("7"))))

    # Latin-1
    out.append(Case(UPPER_CASE, 0x80, 0x80))
    out.append(Case(UPPER_CASE, 0xC5, 0xC5))
    out.append(Case(UPPER_CASE, 0xE5, 0xC5))
    out.append(Case(LOWER_CASE, 0x80, 0x80))
    out.append(Case(LOWER_CASE, 0xC5, 0xE5))
    out.append(Case(LOWER_CASE, 0xE5, 0xE5))
    out.append(Case(TITLE_CASE, 0x80, 0x80))
    out.append(Case(TITLE_CASE, 0xC5, 0xC5))
    out.append(Case(TITLE_CASE, 0xE5, 0xC5))

    # 0131 LATIN SMALL LETTER DOTLESS I
    out.append(Case(UPPER_CASE, 0x0131, Int32(ord("I"))))
    out.append(Case(LOWER_CASE, 0x0131, 0x0131))
    out.append(Case(TITLE_CASE, 0x0131, Int32(ord("I"))))

    # 0133 LATIN SMALL LIGATURE IJ
    out.append(Case(UPPER_CASE, 0x0133, 0x0132))
    out.append(Case(LOWER_CASE, 0x0133, 0x0133))
    out.append(Case(TITLE_CASE, 0x0133, 0x0132))

    # 212A KELVIN SIGN
    out.append(Case(UPPER_CASE, 0x212A, 0x212A))
    out.append(Case(LOWER_CASE, 0x212A, Int32(ord("k"))))
    out.append(Case(TITLE_CASE, 0x212A, 0x212A))

    # From an UpperLower sequence, the Cyrillic one
    out.append(Case(UPPER_CASE, 0xA640, 0xA640))
    out.append(Case(LOWER_CASE, 0xA640, 0xA641))
    out.append(Case(TITLE_CASE, 0xA640, 0xA640))
    out.append(Case(UPPER_CASE, 0xA641, 0xA640))
    out.append(Case(LOWER_CASE, 0xA641, 0xA641))
    out.append(Case(TITLE_CASE, 0xA641, 0xA640))
    out.append(Case(UPPER_CASE, 0xA64E, 0xA64E))
    out.append(Case(LOWER_CASE, 0xA64E, 0xA64F))
    out.append(Case(TITLE_CASE, 0xA64E, 0xA64E))
    out.append(Case(UPPER_CASE, 0xA65F, 0xA65E))
    out.append(Case(LOWER_CASE, 0xA65F, 0xA65F))
    out.append(Case(TITLE_CASE, 0xA65F, 0xA65E))

    # From another UpperLower sequence, the Latin one
    out.append(Case(UPPER_CASE, 0x0139, 0x0139))
    out.append(Case(LOWER_CASE, 0x0139, 0x013A))
    out.append(Case(TITLE_CASE, 0x0139, 0x0139))
    out.append(Case(UPPER_CASE, 0x013F, 0x013F))
    out.append(Case(LOWER_CASE, 0x013F, 0x0140))
    out.append(Case(TITLE_CASE, 0x013F, 0x013F))
    out.append(Case(UPPER_CASE, 0x0148, 0x0147))
    out.append(Case(LOWER_CASE, 0x0148, 0x0148))
    out.append(Case(TITLE_CASE, 0x0148, 0x0147))

    # Lower case lower than upper case, which is Cherokee
    out.append(Case(UPPER_CASE, 0xAB78, 0x13A8))
    out.append(Case(LOWER_CASE, 0xAB78, 0xAB78))
    out.append(Case(TITLE_CASE, 0xAB78, 0x13A8))
    out.append(Case(UPPER_CASE, 0x13A8, 0x13A8))
    out.append(Case(LOWER_CASE, 0x13A8, 0xAB78))
    out.append(Case(TITLE_CASE, 0x13A8, 0x13A8))

    # The last block in the 5.1.0 table, which is Deseret
    out.append(Case(UPPER_CASE, 0x10400, 0x10400))
    out.append(Case(LOWER_CASE, 0x10400, 0x10428))
    out.append(Case(TITLE_CASE, 0x10400, 0x10400))
    out.append(Case(UPPER_CASE, 0x10427, 0x10427))
    out.append(Case(LOWER_CASE, 0x10427, 0x1044F))
    out.append(Case(TITLE_CASE, 0x10427, 0x10427))
    out.append(Case(UPPER_CASE, 0x10428, 0x10400))
    out.append(Case(LOWER_CASE, 0x10428, 0x10428))
    out.append(Case(TITLE_CASE, 0x10428, 0x10400))
    out.append(Case(UPPER_CASE, 0x1044F, 0x10427))
    out.append(Case(LOWER_CASE, 0x1044F, 0x1044F))
    out.append(Case(TITLE_CASE, 0x1044F, 0x10427))

    # The first one not in that table
    out.append(Case(UPPER_CASE, 0x10450, 0x10450))
    out.append(Case(LOWER_CASE, 0x10450, 0x10450))
    out.append(Case(TITLE_CASE, 0x10450, 0x10450))

    # Non letters with case
    out.append(Case(LOWER_CASE, 0x2161, 0x2171))
    out.append(Case(UPPER_CASE, 0x0345, 0x0399))

    return out^


def fold_cycles() -> List[List[Int32]]:
    """Go's `simpleFoldTests`, as the code points rather than as strings.

    Each list is one whole equivalence class under simple case folding, in the
    order `simple_fold` walks it. The last one is Cherokee, where the upper
    case letter has the lower code point, which is the case that breaks an
    implementation assuming the cycle only ever goes up.
    """
    var out = List[List[Int32]]()
    # Easy cases: A and a, delta and capital delta.
    out.append([Int32(ord("A")), Int32(ord("a"))])
    out.append([Int32(0x3B4), Int32(0x394)])
    # ASCII special cases: K, k and the Kelvin sign; S, s and long s.
    out.append([Int32(ord("K")), Int32(ord("k")), Int32(0x212A)])
    out.append([Int32(ord("S")), Int32(ord("s")), Int32(0x17F)])
    # Non ASCII special cases.
    out.append([Int32(0x3C1), Int32(0x3F1), Int32(0x3A1)])
    out.append([Int32(0x345), Int32(0x399), Int32(0x3B9), Int32(0x1FBE)])
    # Has an upper and a lower case mapping but no fold: Turkish, both of them.
    out.append([Int32(0x130)])
    out.append([Int32(0x131)])
    # Upper comes before lower, which is Cherokee.
    out.append([Int32(0x13B0), Int32(0xAB80)])
    return out^


def digit_cases() -> List[Int32]:
    """Go's `testDigit`. The first and last digit of each decimal system."""
    var out: List[Int32] = [
        0x0030,
        0x0039,
        0x0661,
        0x06F1,
        0x07C9,
        0x0966,
        0x09EF,
        0x0A66,
        0x0AEF,
        0x0B66,
        0x0B6F,
        0x0BE6,
        0x0BEF,
        0x0C66,
        0x0CEF,
        0x0D66,
        0x0D6F,
        0x0E50,
        0x0E59,
        0x0ED0,
        0x0ED9,
        0x0F20,
        0x0F29,
        0x1040,
        0x1049,
        0x1090,
        0x1091,
        0x1099,
        0x17E0,
        0x17E9,
        0x1810,
        0x1819,
        0x1946,
        0x194F,
        0x19D0,
        0x19D9,
        0x1B50,
        0x1B59,
        0x1BB0,
        0x1BB9,
        0x1C40,
        0x1C49,
        0x1C50,
        0x1C59,
        0xA620,
        0xA629,
        0xA8D0,
        0xA8D9,
        0xA900,
        0xA909,
        0xAA50,
        0xAA59,
        0xFF10,
        0xFF19,
        0x104A1,
        0x1D7CE,
    ]
    return out^


def digit_letter_cases() -> List[Int32]:
    """Go's `testLetter` from `digit_test.go`, the letters no digit test may claim.

    Nearly `letter_cases` and not quite, which is Go's doing: this one has
    U+1885 MONGOLIAN LETTER ALI GALI BALUDA, which the other list has among the
    things that are not letters. Both are right for the edition they were
    written against and Unicode moved the code point from Mn to Lo in 9.0.
    """
    var out: List[Int32] = [
        0x0041,
        0x0061,
        0x00AA,
        0x00BA,
        0x00C8,
        0x00DB,
        0x00F9,
        0x02EC,
        0x0535,
        0x06E6,
        0x093D,
        0x0A15,
        0x0B99,
        0x0DC0,
        0x0EDD,
        0x1000,
        0x1200,
        0x1312,
        0x1401,
        0x1885,
        0x2C00,
        0xA800,
        0xF900,
        0xFA30,
        0xFFDA,
        0xFFDC,
        0x10000,
        0x10300,
        0x10400,
        0x20000,
        0x2F800,
        0x2FA1D,
    ]
    return out^


def category_cases() -> List[Named]:
    """Go's `inCategoryTest`. One code point per category, unified ones too.

    Go asserts that this list names every category, and so does the test here,
    which is what makes it fail when Unicode adds one rather than quietly
    testing the same thirty eight as last year.
    """
    var out = List[Named]()
    out.append(Named(0x0081, "Cc"))
    out.append(Named(0x200B, "Cf"))
    out.append(Named(0xF0000, "Co"))
    out.append(Named(0xDB80, "Cs"))
    out.append(Named(0x0236, "Ll"))
    out.append(Named(0x1D9D, "Lm"))
    out.append(Named(0x07CF, "Lo"))
    out.append(Named(0x1F8A, "Lt"))
    out.append(Named(0x03FF, "Lu"))
    out.append(Named(0x0BC1, "Mc"))
    out.append(Named(0x20DF, "Me"))
    out.append(Named(0x07F0, "Mn"))
    out.append(Named(0x1BB2, "Nd"))
    out.append(Named(0x10147, "Nl"))
    out.append(Named(0x2478, "No"))
    out.append(Named(0xFE33, "Pc"))
    out.append(Named(0x2011, "Pd"))
    out.append(Named(0x301E, "Pe"))
    out.append(Named(0x2E03, "Pf"))
    out.append(Named(0x2E02, "Pi"))
    out.append(Named(0x0022, "Po"))
    out.append(Named(0x2770, "Ps"))
    out.append(Named(0x00A4, "Sc"))
    out.append(Named(0xA711, "Sk"))
    out.append(Named(0x25F9, "Sm"))
    out.append(Named(0x2108, "So"))
    out.append(Named(0x2028, "Zl"))
    out.append(Named(0x2029, "Zp"))
    out.append(Named(0x202F, "Zs"))
    # The unified ones.
    out.append(Named(0x04AA, "L"))
    out.append(Named(0x0009, "C"))
    out.append(Named(0x1712, "M"))
    out.append(Named(0x0031, "N"))
    out.append(Named(0x00BB, "P"))
    out.append(Named(0x00A2, "S"))
    out.append(Named(0x00A0, "Z"))
    out.append(Named(0x0065, "LC"))
    # Unassigned.
    out.append(Named(0x0378, "Cn"))
    out.append(Named(0x0378, "C"))
    return out^


def property_cases() -> List[Named]:
    """Go's `inPropTest`. One code point per binary property, all thirty five.
    """
    var out = List[Named]()
    out.append(Named(0x0046, "ASCII_Hex_Digit"))
    out.append(Named(0x200F, "Bidi_Control"))
    out.append(Named(0x2212, "Dash"))
    out.append(Named(0xE0001, "Deprecated"))
    out.append(Named(0x00B7, "Diacritic"))
    out.append(Named(0x30FE, "Extender"))
    out.append(Named(0xFF46, "Hex_Digit"))
    out.append(Named(0x2E17, "Hyphen"))
    out.append(Named(0x2FFB, "IDS_Binary_Operator"))
    out.append(Named(0x2FF3, "IDS_Trinary_Operator"))
    out.append(Named(0xFA6A, "Ideographic"))
    out.append(Named(0x200D, "Join_Control"))
    out.append(Named(0x0EC4, "Logical_Order_Exception"))
    out.append(Named(0x2FFFF, "Noncharacter_Code_Point"))
    out.append(Named(0x065E, "Other_Alphabetic"))
    out.append(Named(0x2065, "Other_Default_Ignorable_Code_Point"))
    out.append(Named(0x0BD7, "Other_Grapheme_Extend"))
    out.append(Named(0x0387, "Other_ID_Continue"))
    out.append(Named(0x212E, "Other_ID_Start"))
    out.append(Named(0x2094, "Other_Lowercase"))
    out.append(Named(0x2040, "Other_Math"))
    out.append(Named(0x216F, "Other_Uppercase"))
    out.append(Named(0x0027, "Pattern_Syntax"))
    out.append(Named(0x0020, "Pattern_White_Space"))
    out.append(Named(0x06DD, "Prepended_Concatenation_Mark"))
    out.append(Named(0x300D, "Quotation_Mark"))
    out.append(Named(0x2EF3, "Radical"))
    out.append(Named(0x1F1FF, "Regional_Indicator"))
    # `STerm` is the deprecated alias of the name under it, and both are keys.
    out.append(Named(0x061F, "STerm"))
    out.append(Named(0x061F, "Sentence_Terminal"))
    out.append(Named(0x2071, "Soft_Dotted"))
    out.append(Named(0x003A, "Terminal_Punctuation"))
    out.append(Named(0x9FC3, "Unified_Ideograph"))
    out.append(Named(0xFE0F, "Variation_Selector"))
    out.append(Named(0x0020, "White_Space"))
    return out^


def turkish_alphabet() -> List[Tuple[Int32, Int32]]:
    """The Turkish alphabet as lower and upper pairs. Go's `TestTurkishCase`.

    Go writes the two alphabets as strings and pairs them up by index. The
    pairs are written out here, and the two that matter are `i` with U+0130 and
    U+0131 with `I`, which are the whole reason the table exists.
    """
    var out = List[Tuple[Int32, Int32]]()
    out.append((Int32(ord("a")), Int32(ord("A"))))
    out.append((Int32(ord("b")), Int32(ord("B"))))
    out.append((Int32(ord("c")), Int32(ord("C"))))
    out.append((Int32(0xE7), Int32(0xC7)))
    out.append((Int32(ord("d")), Int32(ord("D"))))
    out.append((Int32(ord("e")), Int32(ord("E"))))
    out.append((Int32(ord("f")), Int32(ord("F"))))
    out.append((Int32(ord("g")), Int32(ord("G"))))
    out.append((Int32(0x11F), Int32(0x11E)))
    out.append((Int32(ord("h")), Int32(ord("H"))))
    out.append((Int32(0x131), Int32(ord("I"))))
    out.append((Int32(ord("i")), Int32(0x130)))
    out.append((Int32(ord("j")), Int32(ord("J"))))
    out.append((Int32(ord("k")), Int32(ord("K"))))
    out.append((Int32(ord("l")), Int32(ord("L"))))
    out.append((Int32(ord("m")), Int32(ord("M"))))
    out.append((Int32(ord("n")), Int32(ord("N"))))
    out.append((Int32(ord("o")), Int32(ord("O"))))
    out.append((Int32(0xF6), Int32(0xD6)))
    out.append((Int32(ord("p")), Int32(ord("P"))))
    out.append((Int32(ord("r")), Int32(ord("R"))))
    out.append((Int32(ord("s")), Int32(ord("S"))))
    out.append((Int32(0x15F), Int32(0x15E)))
    out.append((Int32(ord("t")), Int32(ord("T"))))
    out.append((Int32(ord("u")), Int32(ord("U"))))
    out.append((Int32(0xFC), Int32(0xDC)))
    out.append((Int32(ord("v")), Int32(ord("V"))))
    out.append((Int32(ord("y")), Int32(ord("Y"))))
    out.append((Int32(ord("z")), Int32(ord("Z"))))
    return out^
