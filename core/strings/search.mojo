"""Looking for something inside a string. Go's `strings` search half.

Fourteen functions and not one algorithm. Every one of them turns its arguments
into byte spans with `as_bytes`, which costs nothing because a Mojo `String`
already holds UTF-8, and calls the function of the same name in `core.bytes`.
Go has two copies of Rabin-Karp, two copies of the ASCII set scan and two
copies of the rune decoding loop, because in Go `[]byte(s)` allocates and
copies and writing the search twice is cheaper than paying for that at every
call. Here the conversion is a pointer and a length, so there is one copy of
each algorithm and this file is the adapter.

Every answer is a byte offset or -1, exactly as in Go, and never a rune index.
That is worth saying once rather than in fourteen docstrings: `index_rune`
finds a rune and reports where its first byte is, so the result can be used as
a bound in `s[byte=i:j]` without conversion. A rune index would be the wrong
answer for the thing people do with it, and computing one costs a scan.
"""

import core.bytes.search as bs
from core.io import Byte


def index[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], substr: StringSlice[o2]) -> Int:
    """The byte offset of the first `substr` in `s`, or -1. Go's `strings.Index`.

    ```mojo
    from core.strings import index

    print(index("chicken", "ken"))  # => 4
    ```

    An empty needle is found at 0, which is Go's answer and the one that keeps
    `s[byte=0:index(s, sep)]` meaningful for every separator.
    """
    return bs.index(s.as_bytes(), substr.as_bytes())


def last_index[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], substr: StringSlice[o2]) -> Int:
    """The byte offset of the last `substr` in `s`, or -1. Go's `LastIndex`."""
    return bs.last_index(s.as_bytes(), substr.as_bytes())


def index_byte[o: ImmOrigin](s: StringSlice[o], c: Byte) -> Int:
    """The offset of the first `c` in `s`, or -1. Go's `strings.IndexByte`.

    A byte and not a rune, so a value above 127 finds a UTF-8 continuation byte
    in the middle of a character. That is Go's behaviour and it is useful for
    exactly one thing, which is scanning for an ASCII delimiter; `index_rune`
    is what to reach for otherwise.
    """
    return bs.index_byte(s.as_bytes(), c)


def last_index_byte[o: ImmOrigin](s: StringSlice[o], c: Byte) -> Int:
    """The offset of the last `c` in `s`, or -1. Go's `LastIndexByte`."""
    return bs.last_index_byte(s.as_bytes(), c)


def index_rune[o: ImmOrigin](s: StringSlice[o], r: Int32) -> Int:
    """The offset of the first byte of the first `r` in `s`, or -1.

    Go's `strings.IndexRune`. A rune that is not a valid code point matches the
    encoding of U+FFFD, because that is what an invalid rune becomes when it is
    written out, so searching for one finds what writing one would have left.
    """
    return bs.index_rune(s.as_bytes(), r)


def index_any[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], chars: StringSlice[o2]) -> Int:
    """The offset of the first rune of `s` that is in `chars`, or -1.

    Go's `strings.IndexAny`. `chars` is a set of runes written as text, not a
    substring: `index_any(path, "/\\\\")` finds either separator.
    """
    return bs.index_any(s.as_bytes(), chars.as_bytes())


def last_index_any[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], chars: StringSlice[o2]) -> Int:
    """The offset of the last rune of `s` that is in `chars`, or -1.

    Go's `strings.LastIndexAny`.
    """
    return bs.last_index_any(s.as_bytes(), chars.as_bytes())


def index_func[
    o: ImmOrigin, //, f: def(Int32) capturing[_] -> Bool
](s: StringSlice[o]) -> Int:
    """The offset of the first rune satisfying `f`, or -1. Go's `IndexFunc`."""
    return bs.index_func[f](s.as_bytes())


def last_index_func[
    o: ImmOrigin, //, f: def(Int32) capturing[_] -> Bool
](s: StringSlice[o]) -> Int:
    """The offset of the last rune satisfying `f`, or -1. Go's `LastIndexFunc`.
    """
    return bs.last_index_func[f](s.as_bytes())


def contains[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], substr: StringSlice[o2]) -> Bool:
    """Whether `substr` is inside `s`. Go's `strings.Contains`."""
    return bs.contains(s.as_bytes(), substr.as_bytes())


def contains_any[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], chars: StringSlice[o2]) -> Bool:
    """Whether any rune of `chars` is in `s`. Go's `strings.ContainsAny`."""
    return bs.contains_any(s.as_bytes(), chars.as_bytes())


def contains_rune[o: ImmOrigin](s: StringSlice[o], r: Int32) -> Bool:
    """Whether `r` is in `s`. Go's `strings.ContainsRune`."""
    return bs.contains_rune(s.as_bytes(), r)


def contains_func[
    o: ImmOrigin, //, f: def(Int32) capturing[_] -> Bool
](s: StringSlice[o]) -> Bool:
    """Whether any rune of `s` satisfies `f`. Go's `strings.ContainsFunc`."""
    return bs.contains_func[f](s.as_bytes())


def count[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], substr: StringSlice[o2]) -> Int:
    """How many non-overlapping copies of `substr` are in `s`. Go's `Count`.

    An empty needle counts the gaps between runes plus one, so
    `count(s, "")` is `count_runes(s) + 1`. That is Go's rule and it is the
    number of pieces `split(s, "")` produces, which is what makes the two
    functions agree.
    """
    return bs.count(s.as_bytes(), substr.as_bytes())
