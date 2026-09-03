"""Taking runes off the ends of a string. Go's `strings` trimming half.

Nine functions, none of which allocates or copies. Every one returns a
`StringSlice` into its argument, which is what Go's `[]byte` returning
counterparts do and what Go's `strings` functions do too, since a Go string
slice expression shares the backing array.

Every one of them is `core.bytes` doing the work and this file doing
arithmetic. A trim is a choice of two offsets, `core.bytes.trim_left` and
friends already choose them, and the length of what they kept says where those
offsets were: a left trim keeps a suffix, so the start is the length lost, and
a right trim keeps a prefix, so the end is the length kept. That is why the
bodies below are two lines each and why there is no second copy of the rune
decoding loop anywhere in this package.

The slicing is `s[byte=i:j]`, which is checked: the standard library asserts
that both bounds fall on a code point boundary. Every offset handed to it here
is one by construction, because UTF-8 is self synchronising and a valid needle
cannot match starting inside a character, and the assertion is what says so out
loud rather than in a comment.

The cutset functions — `trim`, `trim_left`, `trim_right` — take a set of runes,
not a substring. `trim(name, ".txt")` takes any of `.`, `t` and `x` off both
ends and is the classic Go bug; `trim_suffix` is the one that takes a word off.
The names are Go's, so the bug ports too, and the docstrings say which is which
at every one of them.
"""

import core.bytes.trim as bt
from core.unicode import is_space


def trim_left_func[
    o: ImmOrigin, //, f: def(Int32) capturing[_] -> Bool
](s: StringSlice[o]) -> StringSlice[o].Immutable:
    """`s` without the leading runes satisfying `f`. Go's `TrimLeftFunc`."""
    var kept = len(bt.trim_left_func[f](s.as_bytes()))
    return s[byte = s.byte_length() - kept : s.byte_length()]


def trim_right_func[
    o: ImmOrigin, //, f: def(Int32) capturing[_] -> Bool
](s: StringSlice[o]) -> StringSlice[o].Immutable:
    """`s` without the trailing runes satisfying `f`. Go's `TrimRightFunc`."""
    return s[byte = 0 : len(bt.trim_right_func[f](s.as_bytes()))]


def trim_func[
    o: ImmOrigin, //, f: def(Int32) capturing[_] -> Bool
](s: StringSlice[o]) -> StringSlice[o].Immutable:
    """`s` without the leading and trailing runes satisfying `f`. Go's
    `TrimFunc`."""
    return trim_right_func[f](trim_left_func[f](s))


def trim_prefix[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], prefix: StringSlice[o2]) -> StringSlice[o1].Immutable:
    """`s` without `prefix` if it starts with it. Go's `strings.TrimPrefix`.

    ```mojo
    from core.strings import trim_prefix

    print(trim_prefix("core.strings", "core."))  # => strings
    ```

    A sequence, not a set: those bytes in that order, once, or nothing at all.
    `cut_prefix` is the same function with the answer to whether it fired.
    """
    var kept = len(bt.trim_prefix(s.as_bytes(), prefix.as_bytes()))
    return s[byte = s.byte_length() - kept : s.byte_length()]


def trim_suffix[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], suffix: StringSlice[o2]) -> StringSlice[o1].Immutable:
    """`s` without `suffix` if it ends with it. Go's `strings.TrimSuffix`.

    ```mojo
    from core.strings import trim_suffix

    print(trim_suffix("notes.txt", ".txt"))  # => notes
    ```
    """
    return s[byte = 0 : len(bt.trim_suffix(s.as_bytes(), suffix.as_bytes()))]


def trim_left[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], cutset: StringSlice[o2]) -> StringSlice[o1].Immutable:
    """`s` without any leading rune in `cutset`. Go's `strings.TrimLeft`.

    A set of runes, in any order, taken off until a rune that is not in it. An
    empty cutset takes nothing.
    """
    var kept = len(bt.trim_left(s.as_bytes(), cutset.as_bytes()))
    return s[byte = s.byte_length() - kept : s.byte_length()]


def trim_right[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], cutset: StringSlice[o2]) -> StringSlice[o1].Immutable:
    """`s` without any trailing rune in `cutset`. Go's `strings.TrimRight`."""
    return s[byte = 0 : len(bt.trim_right(s.as_bytes(), cutset.as_bytes()))]


def trim[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], cutset: StringSlice[o2]) -> StringSlice[o1].Immutable:
    """`s` without any leading or trailing rune in `cutset`. Go's `Trim`.

    ```mojo
    from core.strings import trim

    print(trim("**bold**", "*"))  # => bold
    ```

    A set, so `trim(s, "abc")` takes `a`, `b` and `c` off either end in any
    order and any number. To take a whole word off the front, `trim_prefix`.
    """
    return trim_right(trim_left(s, cutset), cutset)


def trim_space[o: ImmOrigin](s: StringSlice[o]) -> StringSlice[o].Immutable:
    """`s` without leading or trailing white space. Go's `strings.TrimSpace`.

    White space is `unicode.is_space`, which is the Unicode White_Space
    property and not the six ASCII bytes. A non-breaking space is white space
    and is trimmed, U+3000 IDEOGRAPHIC SPACE is trimmed, and U+200B ZERO WIDTH
    SPACE is not, because it is a formatting character rather than a space.
    Both of the first two surprise people and both are Go's answer.
    """

    @parameter
    def space(r: Int32) -> Bool:
        return is_space(r)

    return trim_func[space](s)
