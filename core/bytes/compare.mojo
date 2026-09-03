"""Asking whether two byte slices are the same. Go's `bytes` comparison half.

Five functions, all of them read-only and none of them allocating. `equal` and
`compare` are the exact ones, `has_prefix` and `has_suffix` are `equal` over a
window, and `equal_fold` is the one that is not exact and is the reason this
file has a docstring longer than its code.

`equal_fold` compares under Unicode simple case folding, which is not the same
as comparing lower cased copies and is not the same as ignoring bit 0x20. `K`,
`k` and U+212A KELVIN SIGN are one equivalence class and the case mappings only
reach two of the three, so a comparison built out of `to_lower` says a Kelvin
sign is not a `k`, and a comparison built out of `to_upper` says a long s is
not an `s`. `core.unicode.simple_fold` walks the class and gets both right.

What none of this covers is normalization. `é` written as one code point and
`é` written as `e` followed by a combining acute are different byte strings,
they fold to different things, and `equal_fold` says they differ. Go is the
same, and the answer in both languages is a normalization pass this library
does not have yet.
"""

from core.io import Byte
from core.unicode import simple_fold, to_lower
from core.unicode.utf8 import RUNE_SELF, decode_rune


def equal[o1: Origin, o2: Origin](a: Span[Byte, o1], b: Span[Byte, o2]) -> Bool:
    """Whether `a` and `b` are the same length and hold the same bytes.

    ```mojo
    from core.bytes import equal

    print(equal(String("hi").as_bytes(), String("hi").as_bytes()))  # => True
    ```

    Two empty slices are equal, and an empty slice is equal to another empty
    slice regardless of where either of them points. Go says the same, and it
    matters because a slice of length zero taken from the end of a buffer is
    a perfectly ordinary thing to be handed.
    """
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def compare[
    o1: Origin, o2: Origin
](a: Span[Byte, o1], b: Span[Byte, o2]) -> Int:
    """-1, 0 or +1 for `a` before, equal to or after `b`. Go's `bytes.Compare`.

    Lexicographic on unsigned bytes, with a shorter slice before a longer one
    that starts with it, which is the ordering `sort` wants and the one a
    caller comparing two keys expects. The result is exactly -1, 0 or 1 rather
    than any negative or positive number, because Go documents those three and
    a caller writing `compare(a, b) == -1` should not be wrong.
    """
    var n = len(a)
    if len(b) < n:
        n = len(b)
    for i in range(n):
        if a[i] != b[i]:
            return -1 if a[i] < b[i] else 1
    if len(a) == len(b):
        return 0
    return -1 if len(a) < len(b) else 1


def has_prefix[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], prefix: Span[Byte, o2]) -> Bool:
    """Whether `s` starts with `prefix`. Go's `bytes.HasPrefix`.

    An empty prefix is a prefix of everything, including of an empty slice.
    """
    if len(prefix) > len(s):
        return False
    return equal(s[0 : len(prefix)], prefix)


def has_suffix[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], suffix: Span[Byte, o2]) -> Bool:
    """Whether `s` ends with `suffix`. Go's `bytes.HasSuffix`."""
    if len(suffix) > len(s):
        return False
    return equal(s[len(s) - len(suffix) : len(s)], suffix)


def _fold_equal(a: Int32, b: Int32) -> Bool:
    """Whether two code points are equal under simple case folding.

    Walks `a`'s orbit looking for `b`. The orbits have at most four members,
    so this is at most four comparisons and no allocation, and it is right for
    the three member classes where mapping to one case is not.
    """
    if a == b:
        return True
    var r = simple_fold(a)
    while r != a:
        if r == b:
            return True
        r = simple_fold(r)
    return False


def equal_fold[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], t: Span[Byte, o2]) -> Bool:
    """Whether `s` and `t` are equal under Unicode simple case folding.

    ```mojo
    from core.bytes import equal_fold

    var a = String("Go").as_bytes()
    var b = String("GO").as_bytes()
    print(equal_fold(a, b))  # => True
    ```

    Both sides are decoded rune by rune, so this is not a byte comparison and
    two slices of different lengths can be equal: `K` is one byte and U+212A
    KELVIN SIGN is three, and they fold together.

    Invalid UTF-8 decodes to `RUNE_ERROR` a byte at a time, which means two
    slices that are invalid in different ways can compare equal here. Go has
    the same property for the same reason. A caller who cares should check
    `utf8.valid` first, because the alternative — refusing to answer — turns a
    comparison into something that can fail.
    """
    var i = 0
    var j = 0
    while i < len(s) and j < len(t):
        # ASCII on both sides is the common case and skips the decoder.
        if s[i] < RUNE_SELF and t[j] < RUNE_SELF:
            var sr = Int32(Int(s[i]))
            var tr = Int32(Int(t[j]))
            if sr != tr and to_lower(sr) != to_lower(tr):
                return False
            i += 1
            j += 1
            continue
        var sr, sn = decode_rune(s[i : len(s)])
        var tr, tn = decode_rune(t[j : len(t)])
        if not _fold_equal(sr, tr):
            return False
        i += sn
        j += tn
    return i == len(s) and j == len(t)
