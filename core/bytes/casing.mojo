"""Changing the case of a byte slice. Go's `bytes` case half.

Six functions, and all six are `map` with a different mapping. The three plain
ones use `core.unicode`'s general mappings and the three `_special` ones take a
`unicode.SpecialCase` and try its rows first, which is how Turkish gets a
dotted capital I out of `i`.

`to_upper` and `to_lower` check for an all-ASCII input first and do the whole
thing a byte at a time when they find one, which is Go's optimisation and is
worth keeping: the ASCII path is most inputs and it skips the decoder, the
encoder and the case tables. `to_title` has no such path, in Go or here,
because title case differs from upper case only outside ASCII and the check
would never pay for itself.

None of these is a Unicode case *transformation*. `to_upper` of the German ß
is ß, not SS, because the general mapping is one rune to one rune and the
expansion lives in full case mapping, which needs `golang.org/x/text` in Go and
is not in this library either. `to_upper(to_lower(s))` is not `to_upper(s)` for
the same reason, in both languages.
"""

from core.io import Byte
from core.unicode import SpecialCase, to_lower as rune_to_lower
from core.unicode import to_title as rune_to_title
from core.unicode import to_upper as rune_to_upper
from core.unicode.utf8 import RUNE_SELF

from .edit import map


def _ascii_only[o: Origin](s: Span[Byte, o]) -> Bool:
    """Whether every byte of `s` is below `RUNE_SELF`."""
    for i in range(len(s)):
        if Int(s[i]) >= RUNE_SELF:
            return False
    return True


def to_upper[o: Origin](s: Span[Byte, o]) -> List[Byte]:
    """`s` with every rune in upper case. Go's `bytes.ToUpper`.

    ```mojo
    from core.bytes import to_upper

    var loud = to_upper(String("go").as_bytes())  # GO
    ```
    """
    if _ascii_only(s):
        var out = List[Byte](capacity=len(s))
        for i in range(len(s)):
            var c = s[i]
            if c >= Byte(ord("a")) and c <= Byte(ord("z")):
                c -= Byte(ord("a") - ord("A"))
            out.append(c)
        return out^

    @parameter
    def up(r: Int32) -> Int32:
        return rune_to_upper(r)

    return map[up](s)


def to_lower[o: Origin](s: Span[Byte, o]) -> List[Byte]:
    """`s` with every rune in lower case. Go's `bytes.ToLower`."""
    if _ascii_only(s):
        var out = List[Byte](capacity=len(s))
        for i in range(len(s)):
            var c = s[i]
            if c >= Byte(ord("A")) and c <= Byte(ord("Z")):
                c += Byte(ord("a") - ord("A"))
            out.append(c)
        return out^

    @parameter
    def down(r: Int32) -> Int32:
        return rune_to_lower(r)

    return map[down](s)


def to_title[o: Origin](s: Span[Byte, o]) -> List[Byte]:
    """`s` with every rune in title case. Go's `bytes.ToTitle`.

    Every rune, not the first of every word: that one is Go's deprecated
    `Title` and is not here. Title case differs from upper case for a few dozen
    digraphs — U+01C4 DŽ upper cases to itself and title cases to U+01C5 Dž —
    and for everything else the two are the same.
    """

    @parameter
    def title(r: Int32) -> Int32:
        return rune_to_title(r)

    return map[title](s)


def to_upper_special[o: Origin](c: SpecialCase, s: Span[Byte, o]) -> List[Byte]:
    """`to_upper` with `c`'s rules tried first. Go's `bytes.ToUpperSpecial`.

    ```mojo
    from core.bytes import to_upper_special
    from core.unicode import TurkishCase

    var t = to_upper_special(TurkishCase(), String("i").as_bytes())
    # U+0130, the dotted capital I, and not ASCII I
    ```
    """

    @parameter
    def up(r: Int32) -> Int32:
        return c.to_upper(r)

    return map[up](s)


def to_lower_special[o: Origin](c: SpecialCase, s: Span[Byte, o]) -> List[Byte]:
    """`to_lower` with `c`'s rules tried first. Go's `bytes.ToLowerSpecial`."""

    @parameter
    def down(r: Int32) -> Int32:
        return c.to_lower(r)

    return map[down](s)


def to_title_special[o: Origin](c: SpecialCase, s: Span[Byte, o]) -> List[Byte]:
    """`to_title` with `c`'s rules tried first. Go's `bytes.ToTitleSpecial`."""

    @parameter
    def title(r: Int32) -> Int32:
        return c.to_title(r)

    return map[title](s)
