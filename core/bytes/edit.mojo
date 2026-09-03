"""Building a new byte slice out of an old one. Go's `bytes` rewriting half.

Everything here allocates, and everything here returns an owned `List[Byte]`.
Go returns a `[]byte` that is sometimes the argument and sometimes fresh —
`Replace` with nothing to replace hands back a copy, `Repeat` with a count of
one hands back a fresh slice, `Clone` of a nil slice hands back nil — and a
caller has to read the source to know which. Here the answer is always fresh,
because a return type that is sometimes a view into the argument is a return
type nobody can reason about, and because the caller owns what comes back and
can grow it.

The two functions Go says panic — `Repeat` on a negative count and `Join` on a
length that overflows — raise instead. That is the library's rule: nothing
aborts for a condition the caller could have checked, and both of these are
checks the caller could have made. `deviations.md` has the row.
"""

from core.errors import Report
from core.io import Byte
from core.unicode.utf8 import (
    RUNE_SELF,
    append_rune,
    decode_rune,
    rune_count,
)

from .search import count, index


def clone[o: Origin](b: Span[Byte, o]) -> List[Byte]:
    """A fresh copy of `b`. Go's `bytes.Clone`.

    ```mojo
    from core.bytes import clone

    var mine = clone(String("hello").as_bytes())
    mine[0] = 72
    ```

    Go's version answers nil for a nil argument and an empty non-nil slice for
    an empty one, a distinction this library does not have and does not want:
    an empty input gives an empty list. The point of the function survives —
    it is how a caller turns a borrowed span into bytes they own and may keep
    past the lifetime of what they borrowed it from.
    """
    var out = List[Byte](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def join[
    o1: Origin, o2: Origin
](pieces: List[Span[Byte, o1]], sep: Span[Byte, o2]) raises -> List[Byte]:
    """The pieces run together with `sep` between them. Go's `bytes.Join`.

    ```mojo
    from core.bytes import join, split

    var comma = String(",").as_bytes()
    var parts = split(String("a,b,c").as_bytes(), comma)
    var back = join(parts, comma)  # a,b,c again
    ```

    The inverse of `split` for every input, which is the property worth having
    and the reason `split` returns an empty piece rather than nothing when
    there is nothing between two separators. No pieces gives no bytes; one
    piece gives a copy of it and the separator is never used.

    Go panics if the total length overflows. There is one allocation here and
    the size is computed before it, so an overflow raises with the length it
    was asked for.
    """
    var total = 0
    for piece in pieces:
        total += len(piece)
    if len(pieces) > 1:
        total += len(sep) * (len(pieces) - 1)
    if total < 0:
        raise Report("bytes: join output length overflow").error()
    var out = List[Byte](capacity=total)
    var first = True
    for piece in pieces:
        if not first:
            for i in range(len(sep)):
                out.append(sep[i])
        first = False
        for i in range(len(piece)):
            out.append(piece[i])
    return out^


def repeat[o: Origin](b: Span[Byte, o], n: Int) raises -> List[Byte]:
    """`b` written out `n` times. Go's `bytes.Repeat`.

    Raises on a negative count and on a result too large to hold, both of which
    Go panics on. A count of zero gives no bytes and is not an error, because
    a loop that repeats a thing zero times is a normal loop.

    The copy doubles: the first `len(b)` bytes are the argument and everything
    after is copied from what is already there, so a long result is built with
    a few large copies rather than `n` small ones. Go does the same and caps
    the chunk at eight kilobytes to stay inside the data cache; the cap is here
    too, and on a short repeat neither of us reaches it.
    """
    if n < 0:
        raise Report("bytes: negative repeat count").error()
    if n == 0 or len(b) == 0:
        return List[Byte]()
    var total = len(b) * n
    if total < 0 or total // n != len(b):
        raise Report("bytes: repeat output length overflow").error()

    var chunk_max = total
    var limit = 8 * 1024
    if chunk_max > limit:
        chunk_max = limit // len(b) * len(b)
        if chunk_max == 0:
            chunk_max = len(b)

    var out = List[Byte](capacity=total)
    for i in range(len(b)):
        out.append(b[i])
    while len(out) < total:
        var chunk = len(out)
        if chunk > chunk_max:
            chunk = chunk_max
        if chunk > total - len(out):
            chunk = total - len(out)
        for i in range(chunk):
            var byte = out[i]
            out.append(byte)
    return out^


def replace[
    o1: Origin, o2: Origin, o3: Origin
](s: Span[Byte, o1], old: Span[Byte, o2], new: Span[Byte, o3], n: Int) -> List[
    Byte
]:
    """`s` with the first `n` copies of `old` replaced by `new`. Go's `Replace`.

    A negative `n` replaces every copy, which is what `replace_all` is. A zero
    `n` replaces nothing and still returns a copy, so the return value is owned
    either way and a caller does not have to know whether anything matched.

    An empty `old` inserts `new` before every rune and once after the last one,
    so `replace(s, "", "-", -1)` on three runes gives four dashes. That is Go's
    rule and it is the one that makes the count agree with `count(s, "")`.
    """
    var found = 0
    if n != 0:
        found = count(s, old)
    if found == 0:
        return clone(s)
    var limit = n
    if limit < 0 or found < limit:
        limit = found

    var out = List[Byte](capacity=len(s) + limit * (len(new) - len(old)))
    var start = 0
    if len(old) > 0:
        for _ in range(limit):
            var at = start + index(s[start : len(s)], old)
            for i in range(start, at):
                out.append(s[i])
            for i in range(len(new)):
                out.append(new[i])
            start = at + len(old)
    else:
        for i in range(len(new)):
            out.append(new[i])
        for _ in range(limit - 1):
            var _r, width = decode_rune(s[start : len(s)])
            for i in range(start, start + width):
                out.append(s[i])
            for i in range(len(new)):
                out.append(new[i])
            start += width
    for i in range(start, len(s)):
        out.append(s[i])
    return out^


def replace_all[
    o1: Origin, o2: Origin, o3: Origin
](s: Span[Byte, o1], old: Span[Byte, o2], new: Span[Byte, o3]) -> List[Byte]:
    """`s` with every copy of `old` replaced by `new`. Go's `bytes.ReplaceAll`.
    """
    return replace(s, old, new, -1)


def map[
    o: Origin, //, f: def(Int32) capturing[_] -> Int32
](s: Span[Byte, o]) -> List[Byte]:
    """`s` with every rune passed through `f`. Go's `bytes.Map`.

    A rune `f` maps to a negative number is dropped, which is Go's way of
    saying delete this one and is why the result can be shorter than the input.
    It can also be longer: a one byte rune can map to a four byte one.

    Runes are decoded left to right and `f` is called exactly once per rune,
    which Go relies on in its own `Title` even though it does not promise it.
    Invalid input decodes as `RUNE_ERROR` a byte at a time, so `f` sees the
    replacement character and the result is valid UTF-8 whatever went in.
    """
    var out = List[Byte](capacity=len(s))
    var i = 0
    while i < len(s):
        var r, width = decode_rune(s[i : len(s)])
        var mapped = f(r)
        if mapped >= 0:
            _ = append_rune(out, mapped)
        i += width
    return out^


def runes[o: Origin](s: Span[Byte, o]) -> List[Int32]:
    """The code points of `s`, decoded. Go's `bytes.Runes`.

    The one function in this package whose result is not bytes. It costs four
    bytes per rune and it is what a caller indexing by character wants, which
    is the only good reason to leave UTF-8: everything else in this library
    works on the encoded form and answers byte offsets.
    """
    var out = List[Int32](capacity=rune_count(s))
    var i = 0
    while i < len(s):
        var r, width = decode_rune(s[i : len(s)])
        out.append(r)
        i += width
    return out^


def to_valid_utf8[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], replacement: Span[Byte, o2]) -> List[Byte]:
    """`s` with each run of invalid bytes replaced. Go's `bytes.ToValidUTF8`.

    A run of bad bytes becomes one copy of `replacement`, not one per byte,
    which is the difference between this and decoding through `map`. An empty
    replacement deletes them. The result is valid UTF-8 as long as
    `replacement` is.
    """
    var out = List[Byte](capacity=len(s) + len(replacement))
    var invalid = False
    var i = 0
    while i < len(s):
        var c = s[i]
        if Int(c) < RUNE_SELF:
            out.append(c)
            invalid = False
            i += 1
            continue
        var _r, width = decode_rune(s[i : len(s)])
        if width == 1:
            i += 1
            if not invalid:
                invalid = True
                for j in range(len(replacement)):
                    out.append(replacement[j])
            continue
        invalid = False
        for j in range(i, i + width):
            out.append(s[j])
        i += width
    return out^
