"""Taking runes off the ends of a byte slice. Go's `bytes` trimming half.

Nine functions, none of which allocates: every one of them returns a span into
its argument, read-only for the reason `split.mojo` gives at length. Trimming
is choosing two offsets, and the bytes between them are the caller's already.

The cutset functions — `trim`, `trim_left`, `trim_right` — take a set of runes
written as UTF-8, not a set of bytes and not a substring. `trim(s, "xy")` takes
`x` and `y` off both ends in any order and any number; it is `trim_prefix` and
`trim_suffix` that take a sequence. Getting those two confused is the classic
Go bug of writing `strings.Trim(name, ".txt")` and losing the `t` off the front
of the file name, and the names here are Go's so the bug ports too. The
docstrings say which is which at every one of them.

Go builds a 256 bit table for an all-ASCII cutset and looks bytes up in it.
This scans the cutset instead. A cutset is a handful of characters written as a
literal at the call site — `" \\t\\n"`, `"/"`, `"0"` — and scanning four bytes
beats building thirty two of them; the table wins on a cutset long enough that
nobody writes one by hand.
"""

from core.io import Byte
from core.unicode import is_space
from core.unicode.utf8 import RUNE_SELF, decode_last_rune, decode_rune

from .compare import has_prefix, has_suffix


def trim_left_func[
    o: Origin, //, f: def(Int32) capturing[_] -> Bool
](s: Span[Byte, o]) -> Span[Byte, o].Immutable:
    """`s` without the leading runes satisfying `f`. Go's `TrimLeftFunc`."""
    var v = s.as_imm()
    var i = 0
    while i < len(v):
        var r, width = decode_rune(v[i : len(v)])
        if not f(r):
            break
        i += width
    return v[i : len(v)]


def trim_right_func[
    o: Origin, //, f: def(Int32) capturing[_] -> Bool
](s: Span[Byte, o]) -> Span[Byte, o].Immutable:
    """`s` without the trailing runes satisfying `f`. Go's `TrimRightFunc`."""
    var v = s.as_imm()
    var i = len(v)
    while i > 0:
        var r, width = decode_last_rune(v[0:i])
        if not f(r):
            break
        i -= width
    return v[0:i]


def trim_func[
    o: Origin, //, f: def(Int32) capturing[_] -> Bool
](s: Span[Byte, o]) -> Span[Byte, o].Immutable:
    """`s` without the leading and trailing runes satisfying `f`. Go's `TrimFunc`.
    """
    return trim_right_func[f](trim_left_func[f](s))


def trim_prefix[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], prefix: Span[Byte, o2]) -> Span[Byte, o1].Immutable:
    """`s` without `prefix` if it starts with it. Go's `bytes.TrimPrefix`.

    A sequence, not a set: this takes off those bytes in that order, once, or
    nothing. `cut_prefix` is the same thing with the answer to whether it did.
    """
    var v = s.as_imm()
    if has_prefix(v, prefix):
        return v[len(prefix) : len(v)]
    return v


def trim_suffix[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], suffix: Span[Byte, o2]) -> Span[Byte, o1].Immutable:
    """`s` without `suffix` if it ends with it. Go's `bytes.TrimSuffix`.

    ```mojo
    from core.bytes import trim_suffix

    var whole = String("notes.txt")
    var name = trim_suffix(whole.as_bytes(), String(".txt").as_bytes())
    print(String(from_utf8=name))  # => notes
    ```
    """
    var v = s.as_imm()
    if has_suffix(v, suffix):
        return v[0 : len(v) - len(suffix)]
    return v


def _cutset_has[o: Origin](cutset: Span[Byte, o], r: Int32) -> Bool:
    """Whether `r` is one of the runes `cutset` spells out."""
    var i = 0
    while i < len(cutset):
        var c, width = decode_rune(cutset[i : len(cutset)])
        if c == r:
            return True
        i += width
    return False


def trim_left[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], cutset: Span[Byte, o2]) -> Span[Byte, o1].Immutable:
    """`s` without any leading rune in `cutset`. Go's `bytes.TrimLeft`.

    A set of runes, in any order, taken off until a rune that is not in it. An
    empty cutset takes nothing.
    """
    var v = s.as_imm()
    if len(cutset) == 0:
        return v
    var i = 0
    while i < len(v):
        var r, width = decode_rune(v[i : len(v)])
        if not _cutset_has(cutset, r):
            break
        i += width
    return v[i : len(v)]


def trim_right[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], cutset: Span[Byte, o2]) -> Span[Byte, o1].Immutable:
    """`s` without any trailing rune in `cutset`. Go's `bytes.TrimRight`."""
    var v = s.as_imm()
    if len(cutset) == 0:
        return v
    var i = len(v)
    while i > 0:
        var r, width = decode_last_rune(v[0:i])
        if not _cutset_has(cutset, r):
            break
        i -= width
    return v[0:i]


def trim[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], cutset: Span[Byte, o2]) -> Span[Byte, o1].Immutable:
    """`s` without any leading or trailing rune in `cutset`. Go's `bytes.Trim`.

    ```mojo
    from core.bytes import trim

    var stars = String("**bold**")
    var bare = trim(stars.as_bytes(), String("*").as_bytes())
    print(String(from_utf8=bare))  # => bold
    ```

    A set, so `trim(s, "abc")` takes `a`, `b` and `c` off either end in any
    order. To take a whole word off the front, `trim_prefix`.
    """
    return trim_right(trim_left(s, cutset), cutset)


def _ascii_space(c: Byte) -> Bool:
    """Whether `c` is one of the six ASCII space bytes. Go's `asciiSpace`."""
    return (
        c == Byte(ord(" "))
        or c == Byte(0x09)
        or c == Byte(0x0A)
        or c == Byte(0x0B)
        or c == Byte(0x0C)
        or c == Byte(0x0D)
    )


def trim_space[o: Origin](s: Span[Byte, o]) -> Span[Byte, o].Immutable:
    """`s` without leading or trailing white space. Go's `bytes.TrimSpace`.

    White space is `unicode.is_space`, so a non-breaking space is not trimmed
    and an ideographic space is. The loop below walks ASCII bytes directly and
    only decodes when it meets one that is not ASCII, which is Go's shape and
    means the common case never touches the Unicode tables.
    """
    var v = s.as_imm()
    var lo = 0
    while lo < len(v):
        if Int(v[lo]) >= RUNE_SELF:

            @parameter
            def space(r: Int32) -> Bool:
                return is_space(r)

            return trim_func[space](v[lo : len(v)])
        if not _ascii_space(v[lo]):
            break
        lo += 1
    var hi = len(v)
    while hi > lo:
        if Int(v[hi - 1]) >= RUNE_SELF:

            @parameter
            def space_right(r: Int32) -> Bool:
                return is_space(r)

            return trim_right_func[space_right](v[lo:hi])
        if not _ascii_space(v[hi - 1]):
            break
        hi -= 1
    return v[lo:hi]
