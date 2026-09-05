"""Shell style pattern matching over a slash path. Go's `path.Match`.

The syntax is the shell's, not a regular expression: `*` matches any run of
characters that are not slashes, `?` matches exactly one, `[abc]` and `[^abc]`
and `[a-z]` are character classes, and a backslash escapes whatever follows.
The whole name has to match, not part of it, so `is_match("*.go", "a/b.go")` is
false twice over: `*` will not cross the slash and the pattern was never
anchored to the end of an element.

Go calls it `Match`, and the mechanical spelling of that name in this library
would be `match`, which Mojo has taken as a keyword. So it is `is_match`, next
to `is_abs` in the same package, and this file is `pattern.mojo` rather than
`match.mojo` because a module of that name cannot be imported either. The
rename is written down in `tools/parity/renames.toml`, where `errors.Is`
becoming `matches` is written down for the same reason.

## Why this is bytes underneath

The functions here work on `Span[Byte]` where the rest of the package works on
`StringSlice`, because Go's matcher compares a pattern byte against a name byte
and then advances one byte, and a `StringSlice` cannot be cut in the middle of
a character. It never needs to be: a literal byte in the pattern only matches
the same byte in the name, so the two walk over the same characters together.
Cutting on bytes is what lets that be written the way Go writes it instead of
with a rune decode on every comparison.

The one place a rune is decoded is a character class, because `[a-ζ]` is a
range between two code points and the byte before `ζ` is not a character.
`?` decodes for the same reason: it matches one character, and one character
can be four bytes.

## The one error

`ErrBadPattern` is the only failure, and it means the pattern is malformed
rather than that the name did not match. Go checks for it even on a name that
has already failed to match, so that a bad pattern is reported whether or not
the input happened to rule it out first, and this does the same: the answer to
`is_match` does not depend on the name when the pattern is not a pattern.
"""

from core.errors import Report
from core.errors.codes import ErrBadPattern
from core.io import Byte
from core.unicode.utf8 import RUNE_ERROR, decode_rune

from .scan import _index_byte

comptime _SLASH = Byte(ord("/"))
comptime _STAR = Byte(ord("*"))
comptime _QUESTION = Byte(ord("?"))
comptime _BACKSLASH = Byte(ord("\\"))
comptime _OPEN = Byte(ord("["))
comptime _CLOSE = Byte(ord("]"))
comptime _CARET = Byte(ord("^"))
comptime _DASH = Byte(ord("-"))


def _bad_pattern() -> Error:
    """The one raise this file makes, carrying `ErrBadPattern`.

    Go's message, unchanged, so that a program logging it says what a Go
    program logging it says. What the pattern was is not on the record: the
    check that finds the fault is looking at one chunk of the pattern and not
    at the whole of it, and a field naming the chunk would be more misleading
    than no field at all.
    """
    return Report("syntax error in pattern").with_code(ErrBadPattern).error()


def is_match[
    o1: ImmOrigin, o2: ImmOrigin
](pattern: StringSlice[o1], name: StringSlice[o2]) raises -> Bool:
    """Whether `name` matches the shell pattern `pattern`. Go's `path.Match`.

    ```mojo
    from core.path import is_match

    print(is_match("*.go", "main.go"))  # => True
    ```

    The pattern is a sequence of these:

    - `*` matches any run of characters, stopping at a slash.
    - `?` matches one character, unless that character is a slash.
    - `[abc]` matches one of those characters, `[^abc]` matches one that is not
      one of them, and `[a-z]` matches one in that range. A class has to have
      something in it, so `[]` is not a pattern.
    - `\\` followed by anything matches that thing, which is how to match a
      literal `*`, `?` or `[`.
    - Anything else matches itself.

    All of `name` has to match, not a piece of it. Raises with `ErrBadPattern`
    when the pattern is malformed, which is the only failure there is.
    """
    var pat = pattern.as_bytes()
    var s = name.as_bytes()

    while len(pat) > 0:
        var star, chunk, rest = _scan_chunk(pat)
        pat = rest

        if star and len(chunk) == 0:
            # A trailing `*`, which takes whatever is left as long as it is
            # still one element.
            return _index_byte(s, _SLASH) < 0

        # Try the chunk where the name stands now. If the chunk is the last of
        # the pattern then it also has to reach the end of the name, since a
        # match that stops short would be a match on a prefix.
        var t, ok = _match_chunk(chunk, s)
        if ok and (len(t) == 0 or len(pat) > 0):
            s = t
            continue

        var moved = False
        if star:
            # Give the `*` in front of this chunk a byte at a time, and stop at
            # a slash because `*` does not cross one.
            var i = 0
            while i < len(s) and s[i] != _SLASH:
                var skipped, matched = _match_chunk(chunk, s[i + 1 : len(s)])
                if matched and not (len(pat) == 0 and len(skipped) > 0):
                    s = skipped
                    moved = True
                    break
                i += 1
        if moved:
            continue

        # No match. Go still reads the rest of the pattern before saying so, so
        # that `is_match("a[", "x")` is a bad pattern rather than a quiet false,
        # and so is every pattern whose fault is past the point where the name
        # stopped agreeing.
        while len(pat) > 0:
            var _star, tail, left = _scan_chunk(pat)
            pat = left
            _ = _match_chunk(tail, s[len(s) : len(s)])
        return False

    return len(s) == 0


def _scan_chunk[
    o: ImmOrigin
](pattern: Span[Byte, o]) -> Tuple[Bool, Span[Byte, o], Span[Byte, o]]:
    """The next run of the pattern with no `*` in it, and what came before it.

    Returns whether a star was skipped to get here, the chunk itself, and the
    rest of the pattern. A `*` inside a character class is a literal, which is
    why this tracks whether it is in one.
    """
    var p = pattern
    var star = False
    while len(p) > 0 and p[0] == _STAR:
        p = p[1 : len(p)]
        star = True

    var inrange = False
    var i = 0
    while i < len(p):
        var c = p[i]
        if c == _BACKSLASH:
            # Whatever follows is a literal. A backslash at the very end is a
            # malformed pattern, and `_match_chunk` is where that is reported.
            if i + 1 < len(p):
                i += 1
        elif c == _OPEN:
            inrange = True
        elif c == _CLOSE:
            inrange = False
        elif c == _STAR and not inrange:
            return (star, p[0:i], p[i : len(p)])
        i += 1
    return (star, p, p[len(p) : len(p)])


def _match_chunk[
    o1: ImmOrigin, o2: ImmOrigin
](chunk: Span[Byte, o1], s: Span[Byte, o2]) raises -> Tuple[
    Span[Byte, o2], Bool
]:
    """Whether `chunk` matches the front of `s`, and what is left of `s`.

    The chunk is all single character operators: literals, `?` and character
    classes, with no `*` anywhere in it. Once the match has failed the loop
    keeps going over the chunk without reading `s` any further, because the
    rest of the chunk still has to be well formed for the pattern to be one.
    """
    var rest = chunk
    var left = s
    var failed = False

    while len(rest) > 0:
        failed = failed or len(left) == 0
        var c = rest[0]

        if c == _OPEN:
            var r = Int32(0)
            if not failed:
                var decoded, width = decode_rune(left)
                r = decoded
                left = left[width : len(left)]
            rest = rest[1 : len(rest)]

            var negated = False
            if len(rest) > 0 and rest[0] == _CARET:
                negated = True
                rest = rest[1 : len(rest)]

            var inside = False
            var ranges = 0
            while True:
                if len(rest) > 0 and rest[0] == _CLOSE and ranges > 0:
                    rest = rest[1 : len(rest)]
                    break
                # `_get_esc` raises rather than returning an empty remainder,
                # so `rest` is never empty on the line below.
                var lo, after_lo = _get_esc(rest)
                rest = after_lo
                var hi = lo
                if rest[0] == _DASH:
                    var high, after_hi = _get_esc(rest[1 : len(rest)])
                    hi = high
                    rest = after_hi
                inside = inside or (lo <= r and r <= hi)
                ranges += 1
            failed = failed or (inside == negated)

        elif c == _QUESTION:
            if not failed:
                # One character, and a slash is not one of them: `?` is inside
                # an element the same way `*` is.
                failed = left[0] == _SLASH
                var _r, width = decode_rune(left)
                left = left[width : len(left)]
            rest = rest[1 : len(rest)]

        else:
            if c == _BACKSLASH:
                rest = rest[1 : len(rest)]
                if len(rest) == 0:
                    raise _bad_pattern()
            if not failed:
                failed = rest[0] != left[0]
                left = left[1 : len(left)]
            rest = rest[1 : len(rest)]

    if failed:
        return (s[len(s) : len(s)], False)
    return (left, True)


def _get_esc[
    o: ImmOrigin
](chunk: Span[Byte, o]) raises -> Tuple[Int32, Span[Byte, o]]:
    """One character of a class, and the chunk after it.

    A `-` or a `]` here is a class that ended where a character was expected,
    and so is a chunk that runs out: every class needs its closing bracket, so
    a character with nothing after it cannot be the last thing in a well formed
    one. Both raise `ErrBadPattern`, and so does a byte that is not the start
    of a character.
    """
    if len(chunk) == 0 or chunk[0] == _DASH or chunk[0] == _CLOSE:
        raise _bad_pattern()

    var rest = chunk
    if rest[0] == _BACKSLASH:
        rest = rest[1 : len(rest)]
        if len(rest) == 0:
            raise _bad_pattern()

    var r, width = decode_rune(rest)
    if r == RUNE_ERROR and width == 1:
        raise _bad_pattern()
    var after = rest[width : len(rest)]
    if len(after) == 0:
        raise _bad_pattern()
    return (r, after)
