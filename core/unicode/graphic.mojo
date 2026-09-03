"""Is this code point a letter, a digit, a space. Go's `graphic.go`.

Every function here is the same shape: answer from the 256 byte Latin-1 table
if the code point is small enough, and search a range table otherwise. That is
not an optimisation bolted on afterwards, it is why `data.mojo` has a byte
table at all, and it is worth reading one of these to see what the two halves
cost before assuming a predicate is cheap.

Go keeps `IsUpper`, `IsLower` and `IsTitle` in `letter.go` with the case
mappings. They are here instead, because they read the named tables in
`tables.mojo` and that file imports `letter.mojo`. Nothing about them changes.

## Graphic against printable

Two definitions that differ by one bit, and Go's documentation for them is
easy to skim past. Graphic is Unicode's: letters, marks, numbers, punctuation,
symbols and spaces, categories L, M, N, P, S and Zs. Printable is Go's, and it
is the graphic characters with every space except ASCII space taken out,
because that is the set `%q` can put in a Go string literal without escaping.

So U+00A0 NO-BREAK SPACE is graphic and not printable, and that is the whole of
the difference for anybody who has to choose between them.
"""

from .letter import (
    MAX_LATIN1,
    RangeTable,
    _CONTROL,
    _GRAPHIC,
    _LETTER,
    _NUMBER,
    _PRINTABLE,
    _PUNCT,
    _SYMBOL,
    _UPPER,
    _LOWER,
    _is_excluding_latin,
    _latin,
    in_any,
    is_in,
)
from .tables import L, Letter, Lower, M, Mark, N, Number, P, S, Title, Upper
from .tables import Symbol, White_Space, Zs


def GraphicRanges() -> List[RangeTable]:
    """The six tables that make up the graphic characters. Go's `GraphicRanges`.

    L, M, N, P, S and Zs. A function rather than a variable, and a new list on
    every call, because a `List` cannot be a compile time constant. `is_graphic`
    does not go through it.
    """
    return [L, M, N, P, S, Zs]


def PrintRanges() -> List[RangeTable]:
    """The five tables that make up the printable characters. Go's `PrintRanges`.

    The graphic ranges without Zs. The module docstring says why ASCII space is
    still printable despite not being in any of these.
    """
    return [L, M, N, P, S]


def is_one_of[o: Origin](ranges: Span[RangeTable, o], r: Int32) -> Bool:
    """Whether `r` is in any of `ranges`. Go's `unicode.IsOneOf`.

    The same question as `in_any` asked of a list instead of an argument list,
    which is what makes it the one that works with `graphic_ranges` or with a
    set of tables assembled at run time.
    """
    for index in range(len(ranges)):
        if is_in(ranges[index], r):
            return True
    return False


def is_control(r: Int32) -> Bool:
    """Whether `r` is a control character. Go's `unicode.IsControl`.

    There is no search half to this one. Every control character in Unicode is
    below U+0100, so a code point above Latin-1 is not one and the answer is
    the byte table or nothing.
    """
    if r >= 0 and r <= MAX_LATIN1:
        return (_latin(r) & _CONTROL) != 0
    return False


def is_letter(r: Int32) -> Bool:
    """Whether `r` is a letter, category L. Go's `unicode.IsLetter`."""
    if r >= 0 and r <= MAX_LATIN1:
        return (_latin(r) & _LETTER) != 0
    return _is_excluding_latin(Letter, r)


def is_mark(r: Int32) -> Bool:
    """Whether `r` is a mark, category M. Go's `unicode.IsMark`.

    No Latin-1 half, because there are no marks below U+0100 and a bit in the
    byte table for a set with no members would be a bit that is always zero.
    """
    return _is_excluding_latin(Mark, r)


def is_number(r: Int32) -> Bool:
    """Whether `r` is a number, category N. Go's `unicode.IsNumber`.

    Not the same question as `is_digit`, which is category Nd alone. The
    superscript two and the Roman numeral twelve are numbers and are not
    digits.
    """
    if r >= 0 and r <= MAX_LATIN1:
        return (_latin(r) & _NUMBER) != 0
    return _is_excluding_latin(Number, r)


def is_punct(r: Int32) -> Bool:
    """Whether `r` is punctuation, category P. Go's `unicode.IsPunct`.

    The one predicate that searches the whole table rather than skipping the
    Latin-1 prefix. It is what Go does, and changing it here would make this
    the only function in the package whose answers had to be justified on their
    own rather than by pointing at Go.
    """
    if r >= 0 and r <= MAX_LATIN1:
        return (_latin(r) & _PUNCT) != 0
    return is_in(P, r)


def is_space(r: Int32) -> Bool:
    """Whether `r` is white space. Go's `unicode.IsSpace`.

    The Latin-1 half is a list of eight code points rather than a bit, because
    Go's definition here is the White_Space property and not category Z, and
    the two disagree below U+0100: tab and newline and their neighbours are
    control characters that count as space, and U+00A0 is a space in both.
    """
    if r >= 0 and r <= MAX_LATIN1:
        if r == 0x09 or r == 0x0A or r == 0x0B or r == 0x0C or r == 0x0D:
            return True
        return r == 0x20 or r == 0x85 or r == 0xA0
    return _is_excluding_latin(White_Space, r)


def is_symbol(r: Int32) -> Bool:
    """Whether `r` is a symbol, category S. Go's `unicode.IsSymbol`."""
    if r >= 0 and r <= MAX_LATIN1:
        return (_latin(r) & _SYMBOL) != 0
    return _is_excluding_latin(Symbol, r)


def is_upper(r: Int32) -> Bool:
    """Whether `r` is an upper case letter, category Lu. Go's `unicode.IsUpper`.

    The mask is compared rather than tested, because the byte table spells a
    letter that is neither upper nor lower with both bits set and a test would
    call it both.
    """
    if r >= 0 and r <= MAX_LATIN1:
        return (_latin(r) & _LETTER) == _UPPER
    return _is_excluding_latin(Upper, r)


def is_lower(r: Int32) -> Bool:
    """Whether `r` is a lower case letter, category Ll. Go's `unicode.IsLower`.
    """
    if r >= 0 and r <= MAX_LATIN1:
        return (_latin(r) & _LETTER) == _LOWER
    return _is_excluding_latin(Lower, r)


def is_title(r: Int32) -> Bool:
    """Whether `r` is a title case letter, category Lt. Go's `unicode.IsTitle`.

    A category with forty odd members, all of them digraphs like U+01C8 Lj, and
    none of them in Latin-1. A caller asking whether a letter is capitalised
    almost always wants `is_upper`.
    """
    if r >= 0 and r <= MAX_LATIN1:
        return False
    return _is_excluding_latin(Title, r)


def is_graphic(r: Int32) -> Bool:
    """Whether `r` is a graphic character. Go's `unicode.IsGraphic`.

    Categories L, M, N, P, S and Zs. The module docstring has the difference
    from `is_print`, which is one code point wide and catches people.
    """
    if r >= 0 and r <= MAX_LATIN1:
        return (_latin(r) & _GRAPHIC) != 0
    return in_any(r, L, M, N, P, S, Zs)


def is_print(r: Int32) -> Bool:
    """Whether `r` is printable by Go's definition. Go's `unicode.IsPrint`.

    Categories L, M, N, P, S and ASCII space. Everything Go's `%q` can put in a
    string literal without an escape.
    """
    if r >= 0 and r <= MAX_LATIN1:
        return (_latin(r) & _PRINTABLE) != 0
    return in_any(r, L, M, N, P, S)
