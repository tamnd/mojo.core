"""Looking for something inside a byte slice. Go's `bytes` search half.

Fourteen functions, and between them they are what the package is for. Every
one of them answers a byte offset or -1, never a rune offset, which is worth
saying once here rather than in fourteen docstrings: `index_rune` finds a rune
and reports where its first byte is, and adding the result to a slice bound is
always correct.

`index` is Rabin-Karp over a rolling hash, which is Go's fallback algorithm
rather than its fast one. Go dispatches to an assembly routine on amd64 and to
a tuned Boyer-Moore variant elsewhere, and neither is available here; what is
available is a rolling hash that is linear in the common case and does not
degrade to quadratic on the input that defeats the naive loop, which is a
period of the needle repeated across the haystack. The naive loop is still the
right thing for a short needle and this file uses it there, with the crossover
where Go puts it.

The whole file is written against `Span[Byte, o]` and nothing in it allocates,
so `core.strings` can call these directly on `String.as_bytes()` when it lands.
That is the shared implementation issue #15 asks for, and it costs nothing here
because a Mojo `String` already holds UTF-8 and lends its bytes without a copy.
Go cannot do this — `[]byte(s)` copies — which is why Go has two of everything
and this library will not.
"""

from core.io import Byte
from core.unicode import MAX_RUNE, REPLACEMENT_CHAR
from core.unicode.utf8 import (
    RUNE_ERROR,
    RUNE_SELF,
    UTF_MAX,
    decode_last_rune,
    decode_rune,
    encode_rune,
    valid_rune,
)

from .compare import equal

comptime _PRIME_RK = UInt32(16777619)
"""The multiplier for the Rabin-Karp rolling hash. Go's `primeRK`.

The FNV prime, which is what Go uses and is only a choice about how the bits
mix. Any odd multiplier gives a hash that can be rolled; this one is the same
as Go's so that a divergence in behaviour cannot be a divergence in the hash.
"""

comptime _NAIVE_MAX = 32
"""Needles up to this long are searched with the naive loop.

Below it the rolling hash costs more to set up than the loop costs to run, and
above it the loop's worst case starts to matter. Go's cutoff for the portable
implementation is in the same place.
"""


def index_byte[o: Origin](s: Span[Byte, o], c: Byte) -> Int:
    """The first offset of `c` in `s`, or -1. Go's `bytes.IndexByte`."""
    for i in range(len(s)):
        if s[i] == c:
            return i
    return -1


def last_index_byte[o: Origin](s: Span[Byte, o], c: Byte) -> Int:
    """The last offset of `c` in `s`, or -1. Go's `bytes.LastIndexByte`."""
    for i in reversed(range(len(s))):
        if s[i] == c:
            return i
    return -1


def _hash_str[o: Origin](sep: Span[Byte, o]) -> Tuple[UInt32, UInt32]:
    """The rolling hash of `sep` and the multiplier that removes its first byte.

    Go's `hashStr`. The second value is `_PRIME_RK` raised to the power of
    `len(sep)`, which is what a byte leaving the window has to be multiplied by
    to be subtracted out.
    """
    var hash = UInt32(0)
    for i in range(len(sep)):
        hash = hash * _PRIME_RK + UInt32(Int(sep[i]))
    var pow = UInt32(1)
    var sq = _PRIME_RK
    var i = len(sep)
    while i > 0:
        if i & 1 != 0:
            pow *= sq
        sq *= sq
        i >>= 1
    return (hash, pow)


def _index_rabin_karp[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], sep: Span[Byte, o2]) -> Int:
    """`index` for a needle long enough to be worth hashing. Go's `indexRabinKarp`.

    A hash match is a candidate and is still checked byte by byte, so a hash
    collision costs a comparison and never a wrong answer.
    """
    var want, pow = _hash_str(sep)
    var n = len(sep)
    var hash = UInt32(0)
    for i in range(n):
        hash = hash * _PRIME_RK + UInt32(Int(s[i]))
    if hash == want and equal(s[0:n], sep):
        return 0
    var i = n
    while i < len(s):
        hash *= _PRIME_RK
        hash += UInt32(Int(s[i]))
        hash -= pow * UInt32(Int(s[i - n]))
        i += 1
        if hash == want and equal(s[i - n : i], sep):
            return i - n
    return -1


def index[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], sep: Span[Byte, o2]) -> Int:
    """The first offset of `sep` in `s`, or -1. Go's `bytes.Index`.

    ```mojo
    from core.bytes import index

    print(index(String("chicken").as_bytes(), String("ken").as_bytes()))
    # => 4
    ```

    An empty needle is found at 0, which is Go's answer and the one that makes
    `s[:index] + sep + s[index+len(sep):]` reconstruct `s` for every needle.
    """
    var n = len(sep)
    if n == 0:
        return 0
    if n == 1:
        return index_byte(s, sep[0])
    if n > len(s):
        return -1
    if n > _NAIVE_MAX:
        return _index_rabin_karp(s, sep)
    var first = sep[0]
    var last = len(s) - n
    var offset = 0
    while offset <= last:
        var at = index_byte(s[offset : len(s)], first)
        if at < 0:
            return -1
        offset += at
        if offset > last:
            return -1
        if equal(s[offset : offset + n], sep):
            return offset
        offset += 1
    return -1


def last_index[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], sep: Span[Byte, o2]) -> Int:
    """The last offset of `sep` in `s`, or -1. Go's `bytes.LastIndex`.

    An empty needle is found at `len(s)`, not at 0, which is the mirror of
    `index`'s answer and is again Go's.
    """
    var n = len(sep)
    if n == 0:
        return len(s)
    if n == 1:
        return last_index_byte(s, sep[0])
    if n > len(s):
        return -1
    for offset in reversed(range(len(s) - n + 1)):
        if equal(s[offset : offset + n], sep):
            return offset
    return -1


def index_rune[o: Origin](s: Span[Byte, o], r: Int32) -> Int:
    """The first offset of the encoding of `r` in `s`. Go's `bytes.IndexRune`.

    `RUNE_ERROR` is the one rune that is not looked for as bytes. It finds the
    first byte sequence that does not decode, as well as a real U+FFFD, because
    those two are indistinguishable to anything downstream that decodes: a
    caller asking where the damage starts is asking about both. Go documents
    exactly this.

    A rune that is not a code point at all — negative, above `MAX_RUNE`, or a
    surrogate — is never found, because no valid input encodes it. That is Go's
    answer too, and it is the one that keeps `index_rune` from claiming a slice
    of good UTF-8 contains a surrogate.
    """
    if r < RUNE_SELF and r >= 0:
        return index_byte(s, Byte(Int(r)))
    if r == RUNE_ERROR:
        var i = 0
        while i < len(s):
            var got, width = decode_rune(s[i : len(s)])
            if got == RUNE_ERROR:
                return i
            i += width
        return -1
    if not valid_rune(r):
        return -1
    var buf = List[Byte](length=UTF_MAX, fill=0)
    var n = encode_rune(Span(buf), r)
    return index(s, Span(buf)[0:n])


def index_any[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], chars: Span[Byte, o2]) -> Int:
    """The first offset in `s` of any rune in `chars`, or -1. Go's `IndexAny`.

    `chars` is a set of runes written as UTF-8, not a set of bytes, so a
    multibyte rune in it is one member and not two or three. That is the
    difference between this and `index_byte` over a loop, and it is why an
    invalid byte in `s` matches an invalid byte in `chars` only through
    `RUNE_ERROR`.
    """
    if len(chars) == 0 or len(s) == 0:
        return -1
    var i = 0
    while i < len(s):
        var r, n = decode_rune(s[i : len(s)])
        var j = 0
        while j < len(chars):
            var c, cn = decode_rune(chars[j : len(chars)])
            if c == r:
                return i
            j += cn
        i += n
    return -1


def last_index_any[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], chars: Span[Byte, o2]) -> Int:
    """The last offset in `s` of any rune in `chars`, or -1. Go's `LastIndexAny`.
    """
    if len(chars) == 0:
        return -1
    var i = len(s)
    while i > 0:
        var r, n = decode_last_rune(s[0:i])
        i -= n
        var j = 0
        while j < len(chars):
            var c, cn = decode_rune(chars[j : len(chars)])
            if c == r:
                return i
            j += cn
    return -1


def index_func[
    o: Origin, //, f: def(Int32) capturing[_] -> Bool
](s: Span[Byte, o]) -> Int:
    """The first offset of a rune satisfying `f`, or -1. Go's `bytes.IndexFunc`.

    The predicate is a compile time parameter rather than a value, for the
    reason `core.slices` gives: there are no closures that can be stored, and
    a parameter monomorphizes so there is nothing to store.
    """
    var i = 0
    while i < len(s):
        var r, n = decode_rune(s[i : len(s)])
        if f(r):
            return i
        i += n
    return -1


def last_index_func[
    o: Origin, //, f: def(Int32) capturing[_] -> Bool
](s: Span[Byte, o]) -> Int:
    """The last offset of a rune satisfying `f`, or -1. Go's `LastIndexFunc`."""
    var i = len(s)
    while i > 0:
        var r, n = decode_last_rune(s[0:i])
        i -= n
        if f(r):
            return i
    return -1


def contains[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], sub: Span[Byte, o2]) -> Bool:
    """Whether `sub` is inside `s`. Go's `bytes.Contains`."""
    return index(s, sub) >= 0


def contains_any[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], chars: Span[Byte, o2]) -> Bool:
    """Whether any rune of `chars` is in `s`. Go's `bytes.ContainsAny`."""
    return index_any(s, chars) >= 0


def contains_rune[o: Origin](s: Span[Byte, o], r: Int32) -> Bool:
    """Whether `r` is in `s`. Go's `bytes.ContainsRune`."""
    return index_rune(s, r) >= 0


def contains_func[
    o: Origin, //, f: def(Int32) capturing[_] -> Bool
](s: Span[Byte, o]) -> Bool:
    """Whether any rune of `s` satisfies `f`. Go's `bytes.ContainsFunc`."""
    return index_func[f](s) >= 0


def count[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], sep: Span[Byte, o2]) -> Int:
    """How many non-overlapping copies of `sep` are in `s`. Go's `bytes.Count`.

    An empty needle counts the positions between runes plus one, so
    `count(s, "")` is `rune_count(s) + 1`. That is Go's rule and it is not an
    accident: it is the number of places a `split` on an empty separator would
    cut, which is what makes `count` and `split` agree.
    """
    if len(sep) == 0:
        var runes = 1
        var i = 0
        while i < len(s):
            var _r, n = decode_rune(s[i : len(s)])
            i += n
            runes += 1
        return runes
    var found = 0
    var offset = 0
    while offset <= len(s) - len(sep):
        var at = index(s[offset : len(s)], sep)
        if at < 0:
            break
        found += 1
        offset += at + len(sep)
    return found
