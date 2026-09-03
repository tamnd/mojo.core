"""Unicode's character database, as tables and predicates. Go's `unicode`.

Three hundred and nine symbols, of which two hundred and forty seven are tables
of code points and the rest are the functions that ask questions of them. Everything is derived from the vendored Unicode 15.0.0 files under
`tests/data/ucd` by `tools/gen/ucd.py`, and the derivation is checked against
Go's own tables for every one of the 1,114,112 code points rather than by
sampling. `docs/testing.md` says how.

This package has no dependencies and allocates nothing in the common path.

## The three things to know

**A table is a `comptime` constant, not an object.** `unicode.Greek` is four
integers naming a slice of one big array in `data.mojo`, so passing one costs
nothing and there is no pointer and no lifetime. What it costs is that you
cannot build your own: `RangeTable` has no useful constructor and Go's
`rangetable.New` has no equivalent here. `letter.mojo` says why at length, and
`docs/deviations.md` has the row.

**Go's six maps are functions.** `Categories()`, `Scripts()`, `Properties()`,
`FoldCategory()`, `FoldScript()` and `CategoryAliases()` each build a `Dict`
when called, because a `Dict` cannot be a compile time value. Hold the result
if you need it twice. Reaching for the named table, `unicode.Lu` rather than
`unicode.Categories()["Lu"]`, is better whenever the name is known when the
code is written.

**`Is` is `is_in` and `In` is `in_any`.** Both of Go's names are Mojo keywords.
The calls read the same: `is_in(unicode.Greek, r)` asks whether one table has
a code point, `in_any(r, unicode.L, unicode.N)` asks whether any of several do,
and `is_one_of(ranges, r)` is `in_any` over a list rather than an argument
list.

## Simple mappings only

`to_upper`, `to_lower`, `to_title` and `simple_fold` take one code point and
give back one code point, which is all a rune to rune function can do. ß upper
cases to ß and not to SS, and the Turkish mappings in `casetables.mojo` are
four code points rather than a language. Full case mapping is a string
operation and belongs to `core.strings`.

`simple_fold` is the odd one and repays reading its docstring. It is not a
fold: it walks the cycle of code points equal to its argument under case
folding, so calling it repeatedly enumerates an equivalence class. `K`, `k` and
U+212A KELVIN SIGN are one such class, which is why case insensitive comparison
cannot be an exclusive or with 0x20.

## The files

- `data.mojo`: generated. Five arrays of numbers, no code.
- `tables.mojo`: generated. Go's 258 named tables and six maps.
- `letter.mojo`: the types, the constants, and the case and fold arithmetic.
- `graphic.mojo`: the predicates, all of which read a named table.
- `digit.mojo`: `is_digit`, which is not `is_number`.
- `casetables.mojo`: Turkish and Azerbaijani.
"""

from .casetables import AzeriCase, TurkishCase
from .data import VERSION
from .digit import is_digit
from .graphic import (
    GraphicRanges,
    PrintRanges,
    is_control,
    is_graphic,
    is_letter,
    is_lower,
    is_mark,
    is_number,
    is_one_of,
    is_print,
    is_punct,
    is_space,
    is_symbol,
    is_title,
    is_upper,
)
from .letter import (
    MAX_ASCII,
    MAX_CASE,
    MAX_LATIN1,
    MAX_RUNE,
    REPLACEMENT_CHAR,
    TITLE_CASE,
    UPPER_CASE,
    UPPER_LOWER,
    LOWER_CASE,
    CaseRange,
    CaseRanges,
    Range16,
    Range32,
    RangeTable,
    SpecialCase,
    in_any,
    is_in,
    simple_fold,
    to,
    to_lower,
    to_title,
    to_upper,
)

# The one star import in the library, and it is here because the alternative is
# a list of two hundred and forty seven names that a generator writes and a
# human maintains. Those names are `tables.mojo`'s whole contents, they are
# Go's spellings unchanged, and the set of them changes only when the Unicode
# edition does.
from .tables import *
