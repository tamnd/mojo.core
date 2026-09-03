"""The two languages whose case mappings are not the general ones.

Go's `casetables.go`, and Go's comment on it is worth repeating: this is not a
serious attempt at language specific casing. It is four code points for
Turkish, which Azerbaijani shares, and it exists because those four are the
ones where getting it wrong changes what a word means rather than how it looks.

Turkish has a dotted and a dotless i and keeps them apart in both cases. So the
upper case of `i` is U+0130 İ rather than `I`, and the lower case of `I` is
U+0131 ı rather than `i`. A program that upper cases a Turkish word with the
general mapping turns `iş` into `IS` and loses the distinction.

Both are functions rather than variables because a `SpecialCase` owns a list
and a list cannot be a compile time constant. Each call builds four rows.
"""

from .letter import CaseRange, SpecialCase


def _turkish() -> SpecialCase:
    """The four rows, shared by both names because Go shares them too."""
    return SpecialCase(
        [
            CaseRange(
                0x0049, 0x0049, SIMD[DType.int32, 4](0, 0x131 - 0x49, 0, 0)
            ),
            CaseRange(
                0x0069,
                0x0069,
                SIMD[DType.int32, 4](0x130 - 0x69, 0, 0x130 - 0x69, 0),
            ),
            CaseRange(
                0x0130, 0x0130, SIMD[DType.int32, 4](0, 0x69 - 0x130, 0, 0)
            ),
            CaseRange(
                0x0131,
                0x0131,
                SIMD[DType.int32, 4](0x49 - 0x131, 0, 0x49 - 0x131, 0),
            ),
        ]
    )


def TurkishCase() -> SpecialCase:
    """Turkish case mappings. Go's `unicode.TurkishCase`.

    `TurkishCase().to_upper(Int32(ord("i")))` is U+0130 and not `I`. Every code
    point these four rows do not name falls through to the general mapping.
    """
    return _turkish()


def AzeriCase() -> SpecialCase:
    """Azerbaijani case mappings. Go's `unicode.AzeriCase`.

    The same four rows as `TurkishCase`, which is what Go ships. Azerbaijani
    has the same dotted and dotless i and nothing else here differs.
    """
    return _turkish()
