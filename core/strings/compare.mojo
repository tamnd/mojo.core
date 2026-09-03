"""Comparing strings. Go's `strings.Compare`, `EqualFold` and the two affixes.

Go has an `Equal` in `bytes` and none in `strings`, because two Go strings are
compared with `==`. Two Mojo strings are compared with `==` as well, so there
is nothing here for it either, and the parity manifest agrees: `strings` owes
`Compare`, `EqualFold`, `HasPrefix` and `HasSuffix` and no more.

`compare` exists in Go with a docstring saying not to use it. It is here for
the same reason it is there, which is that a sort comparator wants a three way
answer and writing `if a < b ... elif a > b` compares twice.
"""

import core.bytes.compare as bc


def compare[
    o1: ImmOrigin, o2: ImmOrigin
](a: StringSlice[o1], b: StringSlice[o2]) -> Int:
    """-1, 0 or 1 as `a` sorts before, with, or after `b`. Go's `Compare`.

    Byte order, which for UTF-8 is code point order, which is not the order a
    reader of any particular language would call alphabetical. `core.cmp` is
    where a total order for sorting comes from; this is the three way form of
    `<` and nothing more.
    """
    return bc.compare(a.as_bytes(), b.as_bytes())


def has_prefix[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], prefix: StringSlice[o2]) -> Bool:
    """Whether `s` starts with `prefix`. Go's `strings.HasPrefix`.

    An empty prefix is a prefix of everything, including the empty string.
    """
    return bc.has_prefix(s.as_bytes(), prefix.as_bytes())


def has_suffix[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], suffix: StringSlice[o2]) -> Bool:
    """Whether `s` ends with `suffix`. Go's `strings.HasSuffix`."""
    return bc.has_suffix(s.as_bytes(), suffix.as_bytes())


def equal_fold[
    o1: ImmOrigin, o2: ImmOrigin
](a: StringSlice[o1], b: StringSlice[o2]) -> Bool:
    """Whether `a` and `b` are equal under simple Unicode case folding.

    Go's `strings.EqualFold`. Simple folding, so `K` equals U+212A KELVIN SIGN
    and `s` equals U+017F LONG S, and the German ß does not equal `ss`, because
    that is a full case folding and full folding needs the text tables neither
    library carries. `core.unicode.simple_fold` is the machinery and its
    docstring is the one to read on why one direction of case mapping is never
    enough.
    """
    return bc.equal_fold(a.as_bytes(), b.as_bytes())
