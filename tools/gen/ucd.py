#!/usr/bin/env python3
"""Read the Unicode character database and derive the tables Go publishes.

This is the derivation only. `tools/gen/unicode.py` turns what comes out of
here into Mojo source, and keeping the two apart means the part that has to be
right can be checked against Go's own tables without a compiler anywhere near
it.

Every rule here is Go's, taken from the generator that produces
`src/unicode/tables.go`, which lives in `golang.org/x/text/internal/export/
unicode`. Nothing is invented: a category is derived exactly where Go derives
one, the fold orbits are built by Go's four passes in Go's order, and the run
packing that turns a set of code points into `Range16` and `Range32` entries is
Go's `rangetable.Merge` reduced to the one case it is used in. Where a rule
looks arbitrary it is arbitrary in Go too, and the comment says so rather than
tidying it into something that would produce a different table.

The files are the vendored ones under `tests/data/ucd`, pinned by digest in
`tests/data/LOCK.toml`. Unicode 15.0.0, which is what go1.26.7 reports as
`unicode.Version`. A different edition of the database is a different library
and the version is written into the generated source so that the two cannot
drift apart quietly.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT

UCD = ROOT / "tests" / "data" / "ucd"

MAX_RUNE = 0x10FFFF
MAX_LATIN1 = 0xFF
MAX_ASCII = 0x7F

# The nine names Go derives rather than reads. Everything else in `Categories`
# is a general category that appears in UnicodeData.txt.
DERIVED = ("C", "LC", "L", "M", "N", "P", "S", "Z")

# Go carries this one alias forward by hand. Unicode renamed the property and
# Go kept the old name working, so `Properties` has both keys pointing at one
# table and `STerm` is a variable of its own.
DEPRECATED_ALIASES = {"Sentence_Terminal": "STerm"}


@dataclass
class Char:
    """One code point, with the four fields Go keeps about it."""

    category: str = "Cn"
    upper: int = 0
    lower: int = 0
    title: int = 0
    fold: int = 0
    orbit: int = 0
    # Whether UnicodeData.txt has a line for this code point at all. Go spells
    # this as `codePoint != 0`, which is why its own comment says NUL comes out
    # wrong and does not matter; carrying the flag separately says the same
    # thing without the lie.
    assigned: bool = False


def _lines(name: str) -> list[list[str]]:
    """One UCD file as semicolon separated fields, comments and blanks dropped."""
    out = []
    for line in (UCD / name).read_text(encoding="utf-8").splitlines():
        cut = line.find("#")
        if cut != -1:
            line = line[:cut]
        line = line.strip()
        if not line:
            continue
        out.append([f.strip() for f in line.split(";")])
    return out


def _span(field_: str) -> tuple[int, int]:
    """`0041` or `0041..005A` as an inclusive pair."""
    if ".." in field_:
        lo, hi = field_.split("..", 1)
        return int(lo, 16), int(hi, 16)
    value = int(field_, 16)
    return value, value


@dataclass
class Database:
    """The database, parsed, with Go's derivations already applied."""

    chars: list[Char] = field(default_factory=list)
    by_category: dict[str, list[int]] = field(default_factory=dict)
    scripts: dict[str, list[int]] = field(default_factory=dict)
    props: dict[str, list[int]] = field(default_factory=dict)
    aliases: dict[str, str] = field(default_factory=dict)
    categories: list[str] = field(default_factory=list)


def version() -> str:
    """The edition of the standard the vendored files are, from their own header.

    Read out of the data rather than written down next to it, so that swapping
    the files in `tests/data/ucd` for a newer edition changes the version that
    reaches `unicode.VERSION` without anybody having to remember to.
    """
    first = (UCD / "Scripts.txt").read_text().splitlines()[0]
    found = re.match(r"#\s*Scripts-(\d+\.\d+\.\d+)\.txt", first)
    if not found:
        raise ValueError(f"Scripts.txt does not open with its version: {first!r}")
    return found.group(1)


_LOADED: Database | None = None


def load() -> Database:
    """Parse the five files and apply every derivation Go applies.

    Cached, because parsing is a second and four generators asking for it is
    four seconds of a build that has nothing else to do.
    """
    global _LOADED
    if _LOADED is not None:
        return _LOADED
    db = Database(chars=[Char() for _ in range(MAX_RUNE + 1)])
    _load_chars(db)
    _load_folding(db)
    _load_ranges(db, "Scripts.txt", db.scripts)
    _load_ranges(db, "PropList.txt", db.props)
    _load_aliases(db)
    _build_orbits(db)
    _LOADED = db
    return db


def _load_chars(db: Database) -> None:
    """UnicodeData.txt: the general category and the simple case mappings.

    The file spells a large block as a pair of lines ending `, First>` and
    `, Last>` rather than as one line per code point, and every code point in
    such a block takes the fields of the first line. Expanding that here is
    what Go's parser does before the generator ever sees a line.
    """
    rows = _lines("UnicodeData.txt")
    index = 0
    while index < len(rows):
        row = rows[index]
        first = int(row[0], 16)
        last = first
        if row[1].endswith(", First>"):
            following = rows[index + 1]
            if not following[1].endswith(", Last>"):
                raise ValueError(f"unmatched <..., First> at U+{first:04X}")
            last = int(following[0], 16)
            index += 1
        index += 1

        category = row[2]
        for code in range(first, last + 1):
            char = db.chars[code]
            char.category = category
            char.assigned = True
            # Go reads a letter's own case from the code point itself rather
            # than from the file, because UnicodeData.txt leaves the field
            # empty when a letter maps to itself and the generator needs the
            # value to compute a delta from.
            upper = int(row[12], 16) if row[12] else 0
            lower = int(row[13], 16) if row[13] else 0
            title = int(row[14], 16) if row[14] else 0
            if category == "Lu":
                upper = code
            elif category == "Ll":
                lower = code
            elif category == "Lt":
                title = code
            char.upper, char.lower, char.title = upper, lower, title

    for code, char in enumerate(db.chars):
        db.by_category.setdefault(char.category, []).append(code)
    db.categories = sorted(set(db.by_category) | set(DERIVED) | {"Cn"})


def _load_folding(db: Database) -> None:
    """CaseFolding.txt, common and simple foldings only.

    The full foldings, status F, map one code point to several and there is no
    field on a `Char` that could hold the result. Go drops them for the same
    reason and its documentation carries a BUG note saying so.
    """
    for row in _lines("CaseFolding.txt"):
        if row[1] not in ("C", "S"):
            continue
        db.chars[int(row[0], 16)].fold = int(row[2], 16)


def _load_ranges(db: Database, name: str, into: dict[str, list[int]]) -> None:
    """Scripts.txt or PropList.txt, which have the same two column shape."""
    for row in _lines(name):
        lo, hi = _span(row[0])
        into.setdefault(row[1], []).extend(range(lo, hi + 1))


def _load_aliases(db: Database) -> None:
    """PropertyValueAliases.txt, the `gc` lines, short and long names both."""
    known = set(db.categories)
    for row in _lines("PropertyValueAliases.txt"):
        if row[0] != "gc":
            continue
        name = row[1]
        if name not in known:
            raise ValueError(f"PropertyValueAliases names an unknown category {name}")
        db.aliases[row[2]] = name
        if len(row) > 3 and row[3]:
            db.aliases[row[3]] = name


def in_category(db: Database, name: str) -> list[int]:
    """Every code point in one category, derived names included.

    A one letter name matches every category starting with that letter, which
    is how `L` becomes the union of `Lu`, `Ll`, `Lt`, `Lm` and `Lo`. `LC` is
    the one exception and is spelled out.
    """
    if name == "LC":
        wanted = ("Ll", "Lt", "Lu")
    elif len(name) == 1:
        wanted = tuple(c for c in db.by_category if c.startswith(name))
    else:
        wanted = (name,)
    out: list[int] = []
    for one in wanted:
        out.extend(db.by_category.get(one, ()))
    out.sort()
    return out


def in_category_for_folding(db: Database, name: str) -> list[int]:
    """`in_category`, except that `LC` is empty.

    Go has two functions here and they disagree on one name. The one that
    builds `Categories` reads `LC` as the union of `Ll`, `Lt` and `Lu`; the one
    that builds `FoldCategory` compares the name against each code point's own
    category and so never matches `LC` at all. The result is that
    `FoldCategory` has no `LC` entry while `Categories` does.

    That is almost certainly an oversight in Go rather than a decision, and it
    is reproduced here because a table that differs from Go's would make
    `unicode.FoldCategory["LC"]` answer here and not there. It is written down
    in deviations.md so that nobody fixes it by accident.
    """
    if name == "LC":
        return []
    return in_category(db, name)


def _build_orbits(db: Database) -> None:
    """The simple case folding orbits, in Go's four passes and Go's order.

    An orbit is the cycle `SimpleFold` walks. Most of them are the pair of a
    letter and its other case, and those are left out of the table entirely
    because `SimpleFold` can reconstruct them from the case mappings. What is
    left is the exceptions: k, K and the Kelvin sign, and the eighty-odd others
    where the equivalence class is not simply [upper, lower].

    The passes are Go's and the order matters. Reordering the third and the
    fourth changes which groups survive.
    """
    orbits: list[list[int]] = [[] for _ in range(MAX_RUNE + 1)]

    # One: gather everything that folds to the same code point.
    for code in range(MAX_RUNE + 1):
        fold = db.chars[code].fold
        if fold == 0:
            continue
        if not orbits[fold]:
            orbits[fold] = [fold]
        orbits[fold].append(code)

    # Two: a code point that folds to nothing but has a case mapping still
    # needs a group of its own, because the default assumption `SimpleFold`
    # makes about it would be wrong.
    for code in range(MAX_RUNE + 1):
        char = db.chars[code]
        fold = char.fold or code
        if orbits[fold]:
            continue
        if (char.upper and char.upper != code) or (char.lower and char.lower != code):
            orbits[code] = [code]

    # Three: drop the groups the default assumption already gets right.
    for code, orbit in enumerate(orbits):
        if len(orbit) != 2:
            continue
        a, b = orbit
        if db.chars[a].upper == b and db.chars[b].lower == a:
            orbits[code] = []
        elif db.chars[b].upper == a and db.chars[a].lower == b:
            orbits[code] = []

    # Four: record each surviving group as a cycle, smallest first, with the
    # largest pointing back at the smallest.
    for orbit in orbits:
        if not orbit:
            continue
        ordered = sorted(orbit)
        previous = ordered[-1]
        for code in ordered:
            db.chars[previous].orbit = code
            previous = code


def fold_exceptions(db: Database, class_: list[int]) -> list[int]:
    """Code points fold equivalent to something in `class_` but not in it.

    This is what `FoldCategory` and `FoldScript` hold. Searching for a Greek
    letter case insensitively has to reach the Coptic ones that fold onto it,
    and a table of the script alone would miss them.
    """
    inside = set(class_)
    reachable: set[int] = set()
    for code in class_:
        char = db.chars[code]
        if char.orbit == 0:
            if char.upper:
                reachable.add(char.upper)
            if char.lower:
                reachable.add(char.lower)
            reachable.add(code)
            continue
        walk = code
        while True:
            reachable.add(walk)
            walk = db.chars[walk].orbit
            if walk == code:
                break
    return sorted(reachable - inside)


def simple_fold_of(db: Database, code: int) -> int:
    """What `SimpleFold` answers for one code point, from the database.

    Used to fill the ASCII shortcut table and to check the rest. The rule is
    the orbit if there is one, otherwise the other case if there is one,
    otherwise the code point itself.
    """
    char = db.chars[code]
    if char.orbit:
        return char.orbit
    if char.lower and char.lower != code:
        return char.lower
    if char.upper and char.upper != code:
        return char.upper
    return code


# --- runs -------------------------------------------------------------------


@dataclass
class Run:
    """One `Range16` or `Range32`: an arithmetic progression of code points."""

    lo: int
    hi: int
    stride: int


def runs(codes: list[int]) -> tuple[list[Run], list[Run], int]:
    """A sorted set of code points as 16-bit runs, 32-bit runs and a Latin offset.

    This is `rangetable.Merge` with one input table whose entries are all
    single code points, which is the only way Go ever calls it from the table
    generator. In that shape the whole algorithm is one greedy pass: extend the
    current run while the gap to the next code point equals the run's stride,
    where a run of two sets the stride and a run of one has not chosen yet.

    The greed is what makes the tables small and it is also why they are not
    minimal. `{0x41, 0x5A, 1}` followed by a lone `0x61` cannot absorb the
    `0x61`, and a smarter packing that looked ahead would sometimes split a run
    earlier and win. Go does not do that, so neither does this, because a table
    that differs from Go's is a table that has to be justified code point by
    code point.
    """
    below = [c for c in codes if c <= 0xFFFF]
    above = [c for c in codes if c > 0xFFFF]
    r16 = _pack(below)
    r32 = _pack(above)
    latin = 0
    for run in r16:
        if run.hi > MAX_LATIN1:
            break
        latin += 1
    return r16, r32, latin


def _pack(codes: list[int]) -> list[Run]:
    out: list[Run] = []
    current: Run | None = None
    for code in codes:
        if current is None:
            current = Run(code, code, 1)
            continue
        stride = code - current.hi
        if current.lo == current.hi or stride == current.stride:
            current = Run(current.lo, code, stride)
        else:
            out.append(current)
            current = Run(code, code, 1)
    if current is not None:
        out.append(current)
    return out


# --- the case ranges --------------------------------------------------------

CASE_NONE = 0
CASE_UPPER = 1
CASE_LOWER = 2
CASE_TITLE = 3
CASE_MISSING = 4

UPPER_LOWER = MAX_RUNE + 1


@dataclass
class CaseState:
    """One code point's case, and how far it is from its other cases."""

    point: int
    kind: int = CASE_NONE
    to_upper: int = 0
    to_lower: int = 0
    to_title: int = 0

    def is_upper_lower(self) -> bool:
        """Whether this starts an alternating Upper, Lower, Upper, Lower run."""
        return self.to_upper == 0 and self.to_lower == 1 and self.to_title == 0

    def is_lower_upper(self) -> bool:
        return self.to_upper == -1 and self.to_lower == 0 and self.to_title == -1


def case_state(db: Database, code: int) -> CaseState:
    """Go's `getCaseState`, including its two second guesses.

    A Roman numeral does not call itself upper case and has a lower case
    mapping anyway, so Go infers the case from the mappings when the category
    does not supply one. Both directions, and both are load bearing: without
    them the runs break in different places and the table comes out different.
    """
    state = CaseState(point=code)
    char = db.chars[code]
    if not char.assigned:
        state.kind = CASE_MISSING
        return state
    if char.upper == code:
        state.kind = CASE_UPPER
    elif char.lower == code:
        state.kind = CASE_LOWER
    elif char.title == code:
        state.kind = CASE_TITLE
    if state.kind == CASE_NONE and char.lower != 0:
        state.kind = CASE_UPPER
    if state.kind == CASE_NONE and char.upper != 0:
        state.kind = CASE_LOWER
    if char.upper:
        state.to_upper = char.upper - code
    if char.lower:
        state.to_lower = char.lower - code
    if char.title:
        state.to_title = char.title - code
    return state


def _adjacent(c: CaseState, d: CaseState) -> bool:
    """Whether `d` continues the run `c` is in. Go's `caseState.adjacent`."""
    if d.point < c.point:
        c, d = d, c
    if d.point != c.point + 1:
        return False
    if d.kind != c.kind:
        return _upper_lower_adjacent(c, d)
    if c.kind in (CASE_NONE, CASE_MISSING):
        return False
    return (
        d.to_upper == c.to_upper
        and d.to_lower == c.to_lower
        and d.to_title == c.to_title
    )


def _upper_lower_adjacent(c: CaseState, d: CaseState) -> bool:
    if c.kind == CASE_UPPER and d.kind != CASE_LOWER:
        return False
    if c.kind == CASE_LOWER and d.kind != CASE_UPPER:
        return False
    if c.kind == CASE_LOWER:
        c, d = d, c
    return c.is_upper_lower() and d.is_lower_upper()


@dataclass
class CaseRange:
    """One row of `CaseRanges`: a run of code points sharing three deltas."""

    lo: int
    hi: int
    delta: tuple[int, int, int]


def case_ranges(db: Database) -> list[CaseRange]:
    """Go's `printCases`, which is one pass building runs of equal deltas.

    An alternating sequence such as U+0100 to U+012F, where every even code
    point is upper case and every odd one is the lower case of the one before
    it, collapses to a single row carrying the impossible delta `UPPER_LOWER`
    in all three positions. `convert_case` recognises that value and works the
    answer out from the offset instead.
    """
    out: list[CaseRange] = []
    start: CaseState | None = None
    previous = CaseState(point=0, kind=CASE_NONE)
    for code in range(MAX_RUNE + 1):
        state = case_state(db, code)
        if _adjacent(state, previous):
            previous = state
            continue
        emitted = _emit(start, previous)
        if emitted is not None:
            out.append(emitted)
        start = None
        if state.kind not in (CASE_MISSING, CASE_NONE):
            start = state
        previous = state
    return out


def _emit(lo: CaseState | None, hi: CaseState) -> CaseRange | None:
    if lo is None:
        return None
    if lo.to_upper == 0 and lo.to_lower == 0 and lo.to_title == 0:
        return None
    if hi.point > lo.point and lo.is_upper_lower():
        return CaseRange(lo.point, hi.point, (UPPER_LOWER, UPPER_LOWER, UPPER_LOWER))
    if hi.point > lo.point and lo.is_lower_upper():
        # Go stops here rather than emitting the row, because `To` has no
        # branch that would read it. If Unicode ever adds one, both halves
        # need writing at once.
        raise ValueError(f"LowerUpper sequence at U+{lo.point:04X}, To() needs a branch")
    return CaseRange(lo.point, hi.point, (lo.to_upper, lo.to_lower, lo.to_title))


# --- the two tables SimpleFold reads ----------------------------------------


def case_orbit(db: Database) -> list[tuple[int, int]]:
    """Every code point with an orbit, and the next one round it.

    Go calls this `caseOrbit` and searches it binary. Both halves of a pair fit
    in sixteen bits, which is not an accident of the current database so much as
    a bet Go has been making since 2010; `orbit_fits_16_bits` below is the
    assertion that keeps the bet honest.
    """
    return [
        (code, db.chars[code].orbit)
        for code in range(MAX_RUNE + 1)
        if db.chars[code].orbit
    ]


def orbit_fits_16_bits(orbit: list[tuple[int, int]]) -> bool:
    """Whether every orbit pair is still a pair of `uint16`, as Go assumes."""
    return all(a <= 0xFFFF and b <= 0xFFFF for a, b in orbit)


def ascii_fold(db: Database) -> list[int]:
    """`SimpleFold` for the 128 ASCII code points, precomputed.

    The whole of `SimpleFold` for ASCII is one array read, which matters
    because ASCII is what almost every caller passes. `K` folding to the Kelvin
    sign is in here, and it is the reason this cannot be `r ^ 0x20`.
    """
    return [simple_fold_of(db, code) for code in range(MAX_ASCII + 1)]


# --- the Latin-1 bitmask ----------------------------------------------------

pC = 1 << 0
pP = 1 << 1
pN = 1 << 2
pS = 1 << 3
pZ = 1 << 4
pLu = 1 << 5
pLl = 1 << 6
pp = 1 << 7

_LATIN_BY_CATEGORY = {
    "Cc": pC,
    "Cf": 0,  # the soft hyphen, which is the only one and is not printable
    "Ll": pLl | pp,
    "Lo": pLl | pLu | pp,
    "Lu": pLu | pp,
    "Nd": pN | pp,
    "No": pN | pp,
    "Pc": pP | pp,
    "Pd": pP | pp,
    "Pe": pP | pp,
    "Pf": pP | pp,
    "Pi": pP | pp,
    "Po": pP | pp,
    "Ps": pP | pp,
    "Sc": pS | pp,
    "Sk": pS | pp,
    "Sm": pS | pp,
    "So": pS | pp,
    "Zs": pZ,
}


def latin1(db: Database) -> list[int]:
    """The 256 byte table the Latin-1 fast paths read.

    Every predicate in the package answers from this for a code point at or
    below U+00FF and from a range table above it, which is Go's arrangement and
    is why `is_upper` on an ASCII letter is one load and a mask.

    ASCII space is the special case: it is category Zs, so the table would call
    it graphic and not printable, and Go's definition of printable is the
    graphic characters plus exactly this one space.
    """
    out = []
    for code in range(MAX_LATIN1 + 1):
        bits = _LATIN_BY_CATEGORY[db.chars[code].category]
        if code == 0x20:
            bits = pZ | pp
        out.append(bits)
    return out
