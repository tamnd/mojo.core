"""One function. Go's `digit.go`.

Its own file because Go's is, and because the distinction it draws is worth
having somewhere a reader will find it rather than buried among the other
twelve predicates.
"""

from .letter import MAX_LATIN1, _is_excluding_latin
from .tables import Digit


def is_digit(r: Int32) -> Bool:
    """Whether `r` is a decimal digit, category Nd. Go's `unicode.IsDigit`.

    Not `is_number`, which is the whole of category N and includes the Roman
    numerals and the superscripts. Not ASCII either: the Arabic-Indic and
    Devanagari digits are in here, so a parser that wants only `0` to `9` has
    to say so rather than reaching for this.

    The Latin-1 half is a comparison rather than a bit from the byte table,
    because the only digits below U+0100 are ASCII and the superscripts one,
    two and three, which are category No and so not digits.
    """
    if r >= 0 and r <= MAX_LATIN1:
        return Int32(ord("0")) <= r and r <= Int32(ord("9"))
    return _is_excluding_latin(Digit, r)
