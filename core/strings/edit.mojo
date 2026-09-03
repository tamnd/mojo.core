"""Building a new string out of an old one. Go's `strings` rewriting half.

Seven functions, and every one of them returns an owned `String` rather than a
view, because every one of them can produce something that is not a subsequence
of the input. Go's versions return a `string` that is sometimes the argument
and sometimes a fresh allocation, and a caller cannot tell which; here it is
always fresh, which costs a copy in the cases Go gets away with and buys a
return type somebody can reason about.

The `String` is built with `from_utf8_lossy` for the reason `casing.mojo`
gives: the input is valid text, every transformation here takes valid text to
valid text, and the substitution therefore cannot fire. What it buys is that
these functions do not raise, so they read like Go's. `repeat` is the one
exception and it raises for a real reason, which is a length that overflows.
"""

import core.bytes.edit as be
from core.io import Byte


def clone[o: ImmOrigin](s: StringSlice[o]) -> String:
    """A copy of `s` that owns its bytes. Go's `strings.Clone`.

    In Go this exists to cut a small string loose from a large backing array
    that it is keeping alive, which is a real leak in a program that slices one
    field out of a megabyte and holds it. Here the leak is not possible: a
    `StringSlice` cannot outlive what it borrows, so the compiler makes the
    caller take a copy before the source goes rather than letting them hold a
    view they should not have. The function is still worth having, because
    turning a borrowed slice into an owned `String` is a thing callers do all
    day, and this is the name Go gives it.
    """
    return String(s)


def join[
    o1: ImmOrigin, o2: ImmOrigin
](pieces: List[StringSlice[o1]], sep: StringSlice[o2]) raises -> String:
    """The pieces run together with `sep` between them. Go's `strings.Join`.

    ```mojo
    from core.strings import join, split

    print(join(split("a,b,c", ","), "-"))  # => a-b-c
    ```

    Raises when the total length overflows, which Go panics on. No pieces gives
    the empty string and one piece gives that piece, so the separator appears
    `len(pieces) - 1` times and never on an end.

    The pieces are handed to `core.bytes.join` as a list of byte spans, which
    is one small allocation of pointer and length pairs and no copying of text.
    """
    var spans = List[Span[Byte, o1]](capacity=len(pieces))
    for p in pieces:
        spans.append(p.as_bytes())
    return String(from_utf8_lossy=Span(be.join(spans, sep.as_bytes())))


def repeat[o: ImmOrigin](s: StringSlice[o], n: Int) raises -> String:
    """`s` written out `n` times. Go's `strings.Repeat`.

    Raises on a negative count and on a result too large to hold, both of which
    Go panics on. A count of zero gives the empty string and is not an error,
    because a loop that repeats a thing zero times is a normal loop.
    """
    return String(from_utf8_lossy=Span(be.repeat(s.as_bytes(), n)))


def replace[
    o1: ImmOrigin, o2: ImmOrigin, o3: ImmOrigin
](
    s: StringSlice[o1], old: StringSlice[o2], new: StringSlice[o3], n: Int
) -> String:
    """`s` with the first `n` copies of `old` replaced by `new`. Go's `Replace`.

    A negative `n` replaces every copy, which is what `replace_all` is. A zero
    `n` replaces nothing and still returns a copy, so the return value is owned
    either way and a caller does not have to know whether anything matched.

    An empty `old` inserts `new` before every rune and once at the end, which
    is Go's rule and is the same counting `count(s, "")` uses.
    """
    return String(
        from_utf8_lossy=Span(
            be.replace(s.as_bytes(), old.as_bytes(), new.as_bytes(), n)
        )
    )


def replace_all[
    o1: ImmOrigin, o2: ImmOrigin, o3: ImmOrigin
](s: StringSlice[o1], old: StringSlice[o2], new: StringSlice[o3]) -> String:
    """`s` with every copy of `old` replaced by `new`. Go's `ReplaceAll`."""
    return replace(s, old, new, -1)


def map[
    o: ImmOrigin, //, f: def(Int32) capturing[_] -> Int32
](s: StringSlice[o]) -> String:
    """`s` with every rune passed through `f`. Go's `strings.Map`.

    A rune `f` maps to a negative number is dropped, which is Go's way of
    saying delete this one and is why the result can be shorter than the input.
    It can also be longer, because a one byte rune can map to a four byte one.
    A rune mapped past U+10FFFF becomes U+FFFD rather than being an error,
    since there is nothing else a writer could put down.
    """
    return String(from_utf8_lossy=Span(be.map[f](s.as_bytes())))


def to_valid_utf8[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], replacement: StringSlice[o2]) -> String:
    """`s` with each run of invalid bytes replaced. Go's `ToValidUTF8`.

    In Go this earns its place, because a Go `string` is arbitrary bytes and
    one read off a socket routinely is not text. A Mojo `StringSlice` is
    validated when it is built, so on any input this package can be handed the
    answer is a copy of the input and nothing is replaced. It is kept, and it
    delegates rather than shortcutting, so that code ported from Go keeps
    compiling and so that a slice built through the unchecked constructor is
    still repaired rather than passed through.

    A run of bad bytes becomes one copy of `replacement`, not one per byte.
    """
    return String(
        from_utf8_lossy=Span(
            be.to_valid_utf8(s.as_bytes(), replacement.as_bytes())
        )
    )
