"""The four types every table is made of, and the case and fold arithmetic.

Go's `letter.go`. The predicates that read a named table are not here but in
`graphic.mojo`, because `tables.mojo` sits between the two and a Mojo module
cannot import a module that imports it. Go has the same dependency and does not
notice it, since `letter.go` and `tables.go` are one package and a package has
no internal order.

## What a `RangeTable` is here

Go's is two slices and an int. This one is four integers: where its ranges
start in `data.mojo`'s one big array, how many are sixteen bit, how many are
thirty two bit, and the Latin-1 offset. Every table in the library lives in
that one array end to end.

The reason is that Mojo has no global variables and no way to hold a `Span`
over a compile time array, so a table that owned its ranges would have to be a
`List` built at run time, and `unicode.Letter` would be a function call that
allocates. Four integers can be a `comptime` value, copied for nothing and
read straight out of read only memory. What it costs is that a `RangeTable`
cannot be built out of ranges a caller has: `docs/deviations.md` has the row,
and `Is` over a set somebody assembled is `is_one_of` over a `List` instead.

## The case ranges

`to` is a binary search over 328 rows of five numbers, and the fifth column is
the thing to know about: a delta larger than `MAX_RUNE` does not mean add that
much, it means this range alternates upper, lower, upper, lower and the answer
is arithmetic on the low bit. Go writes that as `UpperLower` and it is why
`to` cannot be a table lookup.
"""

from .data import (
    _ASCII_FOLD,
    _CASE_COUNT,
    _CASES,
    _LATIN,
    _ORBIT,
    _ORBIT_COUNT,
    _RANGES,
)

comptime MAX_RUNE = Int32(0x10FFFF)
"""The largest code point. Go's `MaxRune`."""

comptime REPLACEMENT_CHAR = Int32(0xFFFD)
"""U+FFFD, what `to` answers when asked for a case that does not exist.

Go's `ReplacementChar`. `core.unicode.utf8.RUNE_ERROR` is the same code point
under the name that package uses for it.
"""

comptime MAX_ASCII = Int32(0x7F)
"""The last ASCII code point. Go's `MaxASCII`."""

comptime MAX_LATIN1 = Int32(0xFF)
"""The last Latin-1 code point. Go's `MaxLatin1`.

Almost every predicate in this package opens by comparing against this, because
below it the answer is one byte out of a 256 byte table and above it the answer
is a search.
"""

comptime UPPER_CASE = 0
"""The upper case column of a `CaseRange`. Go's `UpperCase`."""

comptime LOWER_CASE = 1
"""The lower case column of a `CaseRange`. Go's `LowerCase`."""

comptime TITLE_CASE = 2
"""The title case column of a `CaseRange`. Go's `TitleCase`."""

comptime MAX_CASE = 3
"""How many cases there are, so how wide a `CaseRange`'s delta is. Go's `MaxCase`."""

comptime UPPER_LOWER = MAX_RUNE + 1
"""A delta that means the range alternates upper and lower. Go's `UpperLower`.

Not a code point and not an offset. It is a sentinel in the delta column
saying that this range is a run of pairs, so the upper case of a code point in
it is the even neighbour and the lower case is the odd one. `to` is the only
thing that reads it.
"""

# The bits in `data.mojo`'s Latin-1 table, which Go calls `properties` and
# names `pC`, `pP` and so on. Spelled out here because a mask called `pZ` in
# an expression is not something a reader can check against the standard.
comptime _CONTROL = UInt8(1 << 0)
comptime _PUNCT = UInt8(1 << 1)
comptime _NUMBER = UInt8(1 << 2)
comptime _SYMBOL = UInt8(1 << 3)
comptime _SPACING = UInt8(1 << 4)
comptime _UPPER = UInt8(1 << 5)
comptime _LOWER = UInt8(1 << 6)
comptime _PRINTABLE = UInt8(1 << 7)

# Graphic is Unicode's definition and printable is Go's, and they differ by
# exactly the spacing characters: Go prints a space and nothing else that is
# only a space. A letter that is neither upper nor lower carries both letter
# bits, which is how the Latin-1 table spells category Lo in two bits.
comptime _GRAPHIC = _PRINTABLE | _SPACING
comptime _LETTER = _UPPER | _LOWER

# Go's `linearMax`. Below this a scan beats a binary search, and above it the
# Latin-1 code points are still at the front of every table so they are still
# reached by a scan. Both halves of that are Go's measurement, not ours.
comptime _LINEAR_MAX = 18


@fieldwise_init
struct Range16(Copyable, ImplicitlyCopyable, Movable):
    """A range of code points below U+10000. Go's `Range16`.

    `stride` is almost always one. Where it is not, the range holds every
    `stride`th code point from `lo`, which is how a table of, say, the even
    numbered characters in a block stays one row instead of hundreds.
    """

    var lo: UInt16
    """The first code point in the range."""

    var hi: UInt16
    """The last one, included."""

    var stride: UInt16
    """The step between two code points in the range. One means every one."""


@fieldwise_init
struct Range32(Copyable, ImplicitlyCopyable, Movable):
    """A range of code points at or above U+10000. Go's `Range32`.

    The same three fields as `Range16` and the same meaning. Two types rather
    than one because Go's tables are mostly below U+10000 and halving the width
    of those rows halves the size of the tables.
    """

    var lo: UInt32
    """The first code point in the range."""

    var hi: UInt32
    """The last one, included."""

    var stride: UInt32
    """The step between two code points in the range. One means every one."""


def _range_at(index: Int) -> Tuple[UInt32, UInt32, UInt32]:
    """One packed range from `data.mojo`, unpacked.

    `materialize` here is a read from the constant array rather than a copy of
    it, which is the property the whole design rests on. See `data.mojo`.
    """
    var word = materialize[_RANGES]()[index]
    return (
        UInt32(word & 0x1FFFFF),
        UInt32((word >> 21) & 0x1FFFFF),
        UInt32((word >> 42) & 0x3FFFFF),
    )


@fieldwise_init
struct RangeTable(Copyable, ImplicitlyCopyable, Movable):
    """A set of code points. Go's `RangeTable`.

    Four integers naming a slice of the one array in `data.mojo`, so this is
    cheap to copy and can be a `comptime` constant. `tables.mojo` has one of
    these for every table Go exports.

    It cannot be constructed usefully from outside this package, because there
    is nowhere to put the ranges. A caller with their own set of code points
    wants `is_one_of` over a `List[RangeTable]` of the tables that are here, or
    their own predicate. The module docstring says why.
    """

    var _at: UInt32
    var _n16: UInt32
    var _n32: UInt32

    var latin_offset: Int
    """How many of the sixteen bit ranges end at or below U+00FF.

    Go's `LatinOffset`. The predicates that have already answered for Latin-1
    from the byte table skip this many ranges rather than search them again.
    """

    def r16_len(self) -> Int:
        """How many sixteen bit ranges this table has."""
        return Int(self._n16)

    def r32_len(self) -> Int:
        """How many thirty two bit ranges this table has."""
        return Int(self._n32)

    def r16(self, index: Int) -> Range16:
        """One sixteen bit range. Go reaches these as the `R16` field.

        A method rather than a field because the ranges are not stored here,
        and building a `List` to hand back would allocate on every call.
        """
        var lo, hi, stride = _range_at(Int(self._at) + index)
        return Range16(UInt16(lo), UInt16(hi), UInt16(stride))

    def r32(self, index: Int) -> Range32:
        """One thirty two bit range. Go reaches these as the `R32` field."""
        var lo, hi, stride = _range_at(Int(self._at + self._n16) + index)
        return Range32(lo, hi, stride)


@fieldwise_init
struct CaseRange(Copyable, ImplicitlyCopyable, Movable):
    """A range of code points that all change case the same way. Go's `CaseRange`.

    `delta` is Go's `[MaxCase]rune` indexed by `UPPER_CASE`, `LOWER_CASE` and
    `TITLE_CASE`. It is four lanes wide rather than three because Mojo's
    fixed size array is not implicitly copyable and its vector type only comes
    in powers of two; the fourth lane is always zero and nothing reads it.

    A delta of `UPPER_LOWER` is the sentinel the module docstring describes.
    """

    var lo: UInt32
    """The first code point in the range."""

    var hi: UInt32
    """The last one, included."""

    var delta: SIMD[DType.int32, 4]
    """What to add for each case, indexed by `UPPER_CASE` and its siblings."""


def _is16(at: Int, count: Int, r: UInt32) -> Bool:
    """Whether `r` is in `count` sixteen bit ranges starting at `at`.

    Go's `is16`, including the reason for the two halves: a scan is faster than
    a binary search on a short table, and on a long one a Latin-1 code point is
    still found in the first few rows because the tables are sorted.
    """
    if count <= _LINEAR_MAX or r <= UInt32(MAX_LATIN1):
        for index in range(at, at + count):
            var lo, hi, stride = _range_at(index)
            if r < lo:
                return False
            if r <= hi:
                return stride == 1 or (r - lo) % stride == 0
        return False

    var low = at
    var high = at + count
    while low < high:
        var middle = (low + high) >> 1
        var lo, hi, stride = _range_at(middle)
        if lo <= r and r <= hi:
            return stride == 1 or (r - lo) % stride == 0
        if r < lo:
            high = middle
        else:
            low = middle + 1
    return False


def _is32(at: Int, count: Int, r: UInt32) -> Bool:
    """Whether `r` is in `count` thirty two bit ranges starting at `at`.

    Go's `is32`. The same two halves as `_is16` without the Latin-1 case, which
    cannot apply to a table that starts at U+10000.
    """
    if count <= _LINEAR_MAX:
        for index in range(at, at + count):
            var lo, hi, stride = _range_at(index)
            if r < lo:
                return False
            if r <= hi:
                return stride == 1 or (r - lo) % stride == 0
        return False

    var low = at
    var high = at + count
    while low < high:
        var middle = (low + high) >> 1
        var lo, hi, stride = _range_at(middle)
        if lo <= r and r <= hi:
            return stride == 1 or (r - lo) % stride == 0
        if r < lo:
            high = middle
        else:
            low = middle + 1
    return False


def _is_from(table: RangeTable, skip: Int, r: Int32) -> Bool:
    """Whether `r` is in `table`, ignoring its first `skip` sixteen bit ranges.

    Go writes this twice, as `Is` and `isExcludingLatin`, and the only
    difference between them is the number passed here. The comparison is
    unsigned so that a negative rune, which a caller can produce by decoding
    bad input, falls off the top rather than matching the first range.
    """
    var unsigned = UInt32(Int(r) & 0xFFFFFFFF)
    var at = Int(table._at)
    var n16 = table.r16_len()
    if n16 > skip:
        var _lo, last, _stride = _range_at(at + n16 - 1)
        if unsigned <= last:
            return _is16(at + skip, n16 - skip, unsigned)
    var n32 = table.r32_len()
    if n32 > 0:
        var first, _hi, _stride32 = _range_at(at + n16)
        if r >= 0 and unsigned >= first:
            return _is32(at + n16, n32, unsigned)
    return False


def is_in(range_tab: RangeTable, r: Int32) -> Bool:
    """Whether `r` is in `range_tab`. Go's `unicode.Is`.

    Named `is_in` because `is` is a Mojo keyword, the same trade
    `core.errors.matches` makes for `errors.Is`. It reads as the question it
    asks: `is_in(unicode.Greek, r)`.
    """
    return _is_from(range_tab, 0, r)


def _is_excluding_latin(range_tab: RangeTable, r: Int32) -> Bool:
    """Go's `isExcludingLatin`, for a caller that has already tried Latin-1."""
    return _is_from(range_tab, range_tab.latin_offset, r)


def in_any(r: Int32, *ranges: RangeTable) -> Bool:
    """Whether `r` is in any of `ranges`. Go's `unicode.In`.

    Named `in_any` because `in` is a Mojo keyword. `is_one_of` in
    `graphic.mojo` is the same question asked of a list rather than of an
    argument list, and is what `graphic_ranges` is for.
    """
    for table in ranges:
        if is_in(table, r):
            return True
    return False


def _case_at(index: Int) -> CaseRange:
    """One row of `data.mojo`'s case table."""
    var cases = materialize[_CASES]()
    var base = index * 5
    return CaseRange(
        UInt32(cases[base]),
        UInt32(cases[base + 1]),
        SIMD[DType.int32, 4](
            cases[base + 2], cases[base + 3], cases[base + 4], 0
        ),
    )


def _apply(row: CaseRange, case_: Int, r: Int32) -> Int32:
    """`r` mapped by one case range, sentinel and all.

    The branch is Go's. A delta above `MAX_RUNE` means the range alternates, so
    the answer is the pair `r` belongs to with the low bit set to the case
    asked for: clear the low bit of the offset, then put back one for lower
    case and zero for upper.
    """
    var delta = row.delta[case_]
    if delta > MAX_RUNE:
        return Int32(row.lo) + (
            (r - Int32(row.lo)) & ~Int32(1) | Int32(case_ & 1)
        )
    return r + delta


def _to_table(case_: Int, r: Int32) -> Tuple[Int32, Bool]:
    """`to` over the library's own case ranges, without building a list."""
    if case_ < 0 or MAX_CASE <= case_:
        return (REPLACEMENT_CHAR, False)
    var low = 0
    var high = _CASE_COUNT
    while low < high:
        var middle = (low + high) >> 1
        var row = _case_at(middle)
        if Int32(row.lo) <= r and r <= Int32(row.hi):
            return (_apply(row, case_, r), True)
        if r < Int32(row.lo):
            high = middle
        else:
            low = middle + 1
    return (r, False)


def _to_span[
    o: Origin
](case_: Int, r: Int32, rows: Span[CaseRange, o]) -> Tuple[Int32, Bool]:
    """`to` over case ranges somebody else owns, which is what a `SpecialCase` is.
    """
    if case_ < 0 or MAX_CASE <= case_:
        return (REPLACEMENT_CHAR, False)
    var low = 0
    var high = len(rows)
    while low < high:
        var middle = (low + high) >> 1
        var row = rows[middle]
        if Int32(row.lo) <= r and r <= Int32(row.hi):
            return (_apply(row, case_, r), True)
        if r < Int32(row.lo):
            high = middle
        else:
            low = middle + 1
    return (r, False)


def to(case_: Int, r: Int32) -> Int32:
    """`r` in the case named by `UPPER_CASE`, `LOWER_CASE` or `TITLE_CASE`.

    Go's `unicode.To`. Any other number gives `REPLACEMENT_CHAR`, which is Go's
    answer too and is worth knowing about: this is one of the few places in
    either library where a programming mistake produces a code point rather
    than a failure.
    """
    var mapped, _found = _to_table(case_, r)
    return mapped


def to_upper(r: Int32) -> Int32:
    """`r` in upper case. Go's `unicode.ToUpper`.

    One code point in and one out, so this is the simple case mapping and not
    the full one. ß stays ß rather than becoming SS, and a caller who needs the
    full mapping needs a string function rather than a rune one.
    """
    if r <= MAX_ASCII:
        if Int32(ord("a")) <= r and r <= Int32(ord("z")):
            return r - Int32(ord("a") - ord("A"))
        return r
    return to(UPPER_CASE, r)


def to_lower(r: Int32) -> Int32:
    """`r` in lower case. Go's `unicode.ToLower`. Simple mapping, as `to_upper`.
    """
    if r <= MAX_ASCII:
        if Int32(ord("A")) <= r and r <= Int32(ord("Z")):
            return r + Int32(ord("a") - ord("A"))
        return r
    return to(LOWER_CASE, r)


def to_title(r: Int32) -> Int32:
    """`r` in title case. Go's `unicode.ToTitle`.

    Different from upper case for the handful of digraphs that have a form with
    only the first letter capitalised, such as U+01C8 Lj against U+01C7 LJ.
    """
    if r <= MAX_ASCII:
        if Int32(ord("a")) <= r and r <= Int32(ord("z")):
            return r - Int32(ord("a") - ord("A"))
        return r
    return to(TITLE_CASE, r)


def CaseRanges() -> List[CaseRange]:
    """Every case range in the library, as a list. Go's `unicode.CaseRanges`.

    A function rather than a variable, and a new list of 328 rows on every
    call. `to_upper` and its siblings do not go through this; it is here so
    that a program that wants to inspect the mappings can, which is the only
    thing Go's variable is used for outside the package.
    """
    var out = List[CaseRange]()
    for index in range(_CASE_COUNT):
        out.append(_case_at(index))
    return out^


struct SpecialCase(Copyable, Movable, Sized):
    """Case mappings for one language, tried before the general ones.

    Go's `SpecialCase`, which is a slice of `CaseRange` with three methods. It
    is a struct here holding a `List`, so it owns its rows and `len` answers
    how many there are.

    `casetables.mojo` has the two Go ships. A caller can build their own from
    a list of `CaseRange`, which is the one part of this package's data that is
    open: a `RangeTable` cannot be built and this can, because these are small
    enough to carry rather than pack.
    """

    var _rows: List[CaseRange]

    def __init__(out self, var rows: List[CaseRange]):
        """Take ownership of the rows, which must be sorted by `lo`.

        Sorted because every lookup is a binary search, which is Go's
        requirement too and is unchecked in both libraries.
        """
        self._rows = rows^

    def __len__(self) -> Int:
        """How many case ranges this special case has."""
        return len(self._rows)

    def to_upper(self, r: Int32) -> Int32:
        """`r` in upper case for this language. Go's `SpecialCase.ToUpper`.

        Falls back to the general mapping when this table says nothing, which
        is why Turkish can name only the four code points it disagrees with.
        """
        var mapped, found = _to_span(UPPER_CASE, r, Span(self._rows))
        if mapped == r and not found:
            return to_upper(r)
        return mapped

    def to_lower(self, r: Int32) -> Int32:
        """`r` in lower case for this language. Go's `SpecialCase.ToLower`."""
        var mapped, found = _to_span(LOWER_CASE, r, Span(self._rows))
        if mapped == r and not found:
            return to_lower(r)
        return mapped

    def to_title(self, r: Int32) -> Int32:
        """`r` in title case for this language. Go's `SpecialCase.ToTitle`."""
        var mapped, found = _to_span(TITLE_CASE, r, Span(self._rows))
        if mapped == r and not found:
            return to_title(r)
        return mapped


def simple_fold(r: Int32) -> Int32:
    """The next code point that folds to the same thing as `r`. Go's `SimpleFold`.

    Not a fold and not a case mapping: it walks the cycle of everything equal
    to `r` under simple case folding, smallest to largest and then round to the
    smallest again. Calling it repeatedly enumerates the whole equivalence
    class, which is how a case insensitive comparison is written without
    allocating.

    The famous one is `K`: folding `K` gives `k`, and folding `k` gives U+212A
    KELVIN SIGN, and folding that gives `K` back. It is also why this cannot be
    an exclusive or with 0x20 on ASCII.
    """
    if r < 0 or r > MAX_RUNE:
        return r
    if r <= MAX_ASCII:
        return Int32(materialize[_ASCII_FOLD]()[Int(r)])

    var orbit = materialize[_ORBIT]()
    var low = 0
    var high = _ORBIT_COUNT
    while low < high:
        var middle = (low + high) >> 1
        if Int32(orbit[middle] >> 16) < r:
            low = middle + 1
        else:
            high = middle
    if low < _ORBIT_COUNT and Int32(orbit[low] >> 16) == r:
        return Int32(orbit[low] & 0xFFFF)

    # No orbit, so the class is `r` and whichever of its cases differs from it.
    var lower = to_lower(r)
    if lower != r:
        return lower
    return to_upper(r)


def _latin(r: Int32) -> UInt8:
    """The Latin-1 property byte for `r`, which the caller has checked is one.
    """
    return materialize[_LATIN]()[Int(r)]
