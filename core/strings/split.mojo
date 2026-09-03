"""Cutting a string into pieces. Go's `strings` splitting half.

Fourteen functions and not one allocation of text. Every piece is a
`StringSlice` into the original, so `split` of a megabyte into a thousand
fields allocates one list of a thousand slice headers and copies no characters,
which is what Go does too and is the reason `strings.Split` is not a
performance mistake in either language.

The work is `core.bytes` and this file is offsets. `index` finds where the
separator is, `s[byte=i:j]` cuts there, and the standard library asserts that
both bounds land on a code point boundary. That assertion is never going to
fire and it is worth having anyway: it is the machine checking the claim this
whole package rests on, which is that a valid needle cannot match starting in
the middle of a character. UTF-8 is self synchronising, so a continuation byte
can never be mistaken for a lead byte, and the claim is a theorem rather than a
hope. Nothing here is `raises` for that reason.

`_field_bounds` is imported from `core.bytes.split` under its private name and
is the one place in this package that reaches for something Go does not have a
symbol for. The alternative was a second copy of the field scanner, which is
the duplication issue #15 and issue #20 both exist to avoid.

## Which splitter

`split` drops the separator, `split_after` keeps it on the piece before it, and
`fields` treats a run of white space as one separator and produces no empty
pieces. That last difference is the whole reason both exist: a command line is
parsed with `fields` and a CSV row is not, because `split("a,,b", ",")` has to
give three pieces and `fields("a  b")` has to give two.

The `_seq` forms are the same cuts one piece at a time, for a caller that walks
the pieces once and never wants the list.
"""

import core.bytes.search as bs
import core.bytes.split as bsp
from core.unicode import is_space
from core.unicode.utf8 import decode_rune

comptime _AFTER = 1
"""`_gen_split` keeps the separator on the piece before it. Go's `sepSave`."""

comptime _DROP = 0
"""`_gen_split` throws the separator away."""


def cut[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], sep: StringSlice[o2]) -> Tuple[
    StringSlice[o1].Immutable, StringSlice[o1].Immutable, Bool
]:
    """`s` around the first `sep`: before, after, and whether it was there.

    ```mojo
    from core.strings import cut

    var key, value, found = cut("name=value", "=")
    print(key, value, found)  # => name value True
    ```

    Go's `strings.Cut`, and the function to reach for instead of `index`
    followed by two slice expressions, which is where off-by-one errors live.
    When `sep` is absent the answer is all of `s`, an empty slice, and `False`.
    """
    var n = s.byte_length()
    var at = bs.index(s.as_bytes(), sep.as_bytes())
    if at < 0:
        return (s[byte=0:n], s[byte=n:n], False)
    return (s[byte=0:at], s[byte = at + sep.byte_length() : n], True)


def cut_prefix[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], prefix: StringSlice[o2]) -> Tuple[
    StringSlice[o1].Immutable, Bool
]:
    """`s` without `prefix`, and whether it had one. Go's `CutPrefix`.

    An empty prefix is present, so this returns `s` and `True`, which differs
    from `trim_prefix` in nothing but being able to say so.
    """
    var n = s.byte_length()
    var rest, had = bsp.cut_prefix(s.as_bytes(), prefix.as_bytes())
    return (s[byte = n - len(rest) : n], had)


def cut_suffix[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], suffix: StringSlice[o2]) -> Tuple[
    StringSlice[o1].Immutable, Bool
]:
    """`s` without `suffix`, and whether it had one. Go's `CutSuffix`."""
    var rest, had = bsp.cut_suffix(s.as_bytes(), suffix.as_bytes())
    return (s[byte = 0 : len(rest)], had)


def _explode[
    o: ImmOrigin
](s: StringSlice[o], n: Int) -> List[StringSlice[o].Immutable]:
    """`s` cut after every rune, at most `n` pieces. Go's `explode`.

    The last piece holds everything left when the count runs out, which is what
    makes `split_n` with a small `n` and an empty separator behave like every
    other `split_n`.
    """
    var v = s.as_bytes()
    var out = List[StringSlice[o].Immutable]()
    var i = 0
    var made = 0
    while i < len(v):
        if n >= 0 and made == n - 1:
            break
        var _r, width = decode_rune(v[i : len(v)])
        out.append(s[byte = i : i + width])
        i += width
        made += 1
    if i < len(v):
        out.append(s[byte = i : len(v)])
    return out^


def _gen_split[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], sep: StringSlice[o2], keep: Int, n: Int) -> List[
    StringSlice[o1].Immutable
]:
    """The one loop behind all four splitters. Go's `genSplit`.

    `keep` is `_AFTER` to leave the separator on the end of the piece before it
    and `_DROP` to discard it, and `n` is the piece limit with -1 for no limit.
    """
    var v = s.as_bytes()
    var width = sep.byte_length()
    var out = List[StringSlice[o1].Immutable]()
    if n == 0:
        return out^
    if width == 0:
        return _explode(s, n)
    var want = n
    if want < 0:
        want = bs.count(v, sep.as_bytes()) + 1
    var start = 0
    var made = 0
    while made < want - 1:
        var at = bs.index(v[start : len(v)], sep.as_bytes())
        if at < 0:
            break
        out.append(s[byte = start : start + at + width * keep])
        start += at + width
        made += 1
    out.append(s[byte = start : len(v)])
    return out^


def split[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], sep: StringSlice[o2]) -> List[StringSlice[o1].Immutable]:
    """`s` cut around every `sep`, with the separators dropped. Go's `Split`.

    ```mojo
    from core.strings import split

    print(len(split("a,b,c", ",")))  # => 3
    ```

    An empty separator cuts between every rune, which is Go's rule and is how
    `split(s, "")` gives the characters of `s` rather than its bytes.
    """
    return _gen_split(s, sep, _DROP, -1)


def split_n[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], sep: StringSlice[o2], n: Int) -> List[
    StringSlice[o1].Immutable
]:
    """`split` with at most `n` pieces, the last one unsplit. Go's `SplitN`.

    A negative `n` means no limit and a zero `n` means no pieces at all, which
    is Go's `nil` and is an empty list here. Zero is not one: one piece is the
    whole of `s`, and no pieces is a caller asking for nothing.
    """
    return _gen_split(s, sep, _DROP, n)


def split_after[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], sep: StringSlice[o2]) -> List[StringSlice[o1].Immutable]:
    """`s` cut after every `sep`, keeping the separators. Go's `SplitAfter`.

    The pieces concatenate back to `s` exactly, which is what this is for: a
    line splitter that keeps its newlines can put the text back together.
    """
    return _gen_split(s, sep, _AFTER, -1)


def split_after_n[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], sep: StringSlice[o2], n: Int) -> List[
    StringSlice[o1].Immutable
]:
    """`split_after` with at most `n` pieces. Go's `SplitAfterN`."""
    return _gen_split(s, sep, _AFTER, n)


struct _Split[o1: ImmOrigin, o2: ImmOrigin, keep: Int](IterableOwned, Iterator):
    """What `split_seq` and `split_after_seq` return.

    The same cut as `_gen_split` made one piece at a time, so a caller that
    walks the pieces once and throws them away never builds the list.
    """

    comptime Element = StringSlice[Self.o1].Immutable
    comptime IteratorOwnedType = Self

    var _s: StringSlice[Self.o1].Immutable
    var _sep: StringSlice[Self.o2]
    var _at: Int
    var _done: Bool

    def __init__(out self, s: StringSlice[Self.o1], sep: StringSlice[Self.o2]):
        self._s = s
        self._sep = sep
        self._at = 0
        self._done = False

    def __iter__(var self) -> Self.IteratorOwnedType:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        if self._done:
            raise StopIteration()
        var v = self._s.as_bytes()
        var width = self._sep.byte_length()
        if width == 0:
            # An empty separator cuts after each rune, and the sequence ends
            # when the bytes do rather than with a trailing empty piece.
            if self._at >= len(v):
                raise StopIteration()
            var _r, w = decode_rune(v[self._at : len(v)])
            var piece = self._s[byte = self._at : self._at + w]
            self._at += w
            return piece
        var found = bs.index(v[self._at : len(v)], self._sep.as_bytes())
        if found < 0:
            self._done = True
            return self._s[byte = self._at : len(v)]
        var end = self._at + found + width * Self.keep
        var piece = self._s[byte = self._at : end]
        self._at += found + width
        return piece


def split_seq[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], sep: StringSlice[o2]) -> _Split[o1, o2, _DROP]:
    """`split` one piece at a time. Go's `strings.SplitSeq`.

    ```mojo
    from core.strings import split_seq

    for field in split_seq("a,b", ","):
        print(field)
    ```
    """
    return _Split[o1, o2, _DROP](s, sep)


def split_after_seq[
    o1: ImmOrigin, o2: ImmOrigin
](s: StringSlice[o1], sep: StringSlice[o2]) -> _Split[o1, o2, _AFTER]:
    """`split_after` one piece at a time. Go's `strings.SplitAfterSeq`."""
    return _Split[o1, o2, _AFTER](s, sep)


struct _Lines[o: ImmOrigin](IterableOwned, Iterator):
    """What `lines` returns: the newline stays on the line it ended."""

    comptime Element = StringSlice[Self.o].Immutable
    comptime IteratorOwnedType = Self

    var _s: StringSlice[Self.o].Immutable
    var _at: Int

    def __init__(out self, s: StringSlice[Self.o]):
        self._s = s
        self._at = 0

    def __iter__(var self) -> Self.IteratorOwnedType:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        var v = self._s.as_bytes()
        if self._at >= len(v):
            raise StopIteration()
        var start = self._at
        while self._at < len(v):
            var end = self._at
            self._at += 1
            if Int(v[end]) == 0x0A:
                break
        return self._s[byte = start : self._at]


def lines[o: ImmOrigin](s: StringSlice[o]) -> _Lines[o]:
    """The lines of `s`, each with its newline still on it. Go's `Lines`.

    Keeping the newline is Go's choice and it is the right one: it makes the
    lines concatenate back to `s`, and it lets a caller tell a final line that
    ended from one that ran out. A string that does not end in a newline yields
    a last line without one; an empty string yields nothing at all.

    Only `\\n` ends a line. A `\\r` before it stays on the line, which is what
    `bufio.Scanner` strips and this does not, because a string is not a stream
    and the caller can see what they have.
    """
    return _Lines[o](s)


def _fields_impl[
    o: ImmOrigin, //, f: def(Int32) capturing[_] -> Bool
](s: StringSlice[o]) -> List[StringSlice[o].Immutable]:
    """The one loop behind `fields` and `fields_func`.

    Two passes: the first counts the fields so the list is allocated once at
    the right size, the second fills it. Go does the same, and on a line with a
    hundred fields the second walk over the bytes costs less than the six
    reallocations it saves.
    """
    var v = s.as_bytes()
    var found = 0
    var in_field = False
    var i = 0
    while i < len(v):
        var r, width = decode_rune(v[i : len(v)])
        i += width
        if f(r):
            in_field = False
        elif not in_field:
            in_field = True
            found += 1

    var out = List[StringSlice[o].Immutable](capacity=found)
    var start = -1
    i = 0
    while i < len(v):
        var at = i
        var r, width = decode_rune(v[i : len(v)])
        i += width
        if f(r):
            if start >= 0:
                out.append(s[byte=start:at])
                start = -1
        elif start < 0:
            start = at
    if start >= 0:
        out.append(s[byte = start : len(v)])
    return out^


def fields[o: ImmOrigin](s: StringSlice[o]) -> List[StringSlice[o].Immutable]:
    """`s` split around runs of white space. Go's `strings.Fields`.

    ```mojo
    from core.strings import fields

    print(len(fields("  a  b ")))  # => 2
    ```

    A run of spaces is one separator, leading and trailing space produce no
    empty fields, and an all-space string gives no fields at all. That is the
    difference between this and `split` on a single space.

    White space is `unicode.is_space`, so a non-breaking space does separate
    fields and U+200B ZERO WIDTH SPACE does not.
    """

    @parameter
    def space(r: Int32) -> Bool:
        return is_space(r)

    return _fields_impl[space](s)


def fields_func[
    o: ImmOrigin, //, f: def(Int32) capturing[_] -> Bool
](s: StringSlice[o]) -> List[StringSlice[o].Immutable]:
    """`s` split around runs of runes satisfying `f`. Go's `FieldsFunc`.

    Go documents that it makes no guarantee about the order in which `f` is
    called and may call it several times per rune. This calls it once per rune,
    left to right, twice over: once to count the fields and once to cut them. A
    predicate with side effects is still a bad idea; this makes it a defined
    bad idea rather than an undefined one.
    """
    return _fields_impl[f](s)


struct _FieldsFunc[o: ImmOrigin, f: def(Int32) capturing[_] -> Bool]:
    """What `fields_func_seq` returns.

    It does not declare `IterableOwned` and `Iterator`, for the reason
    `core.bytes.split._FieldsFunc` gives: a struct with a closure parameter has
    every method typed `capturing thin`, both traits declare theirs `thin`, and
    the conformance cannot be written. A `for` loop over this still works.
    """

    comptime Element = StringSlice[Self.o].Immutable
    comptime IteratorOwnedType = Self

    var _s: StringSlice[Self.o].Immutable
    var _at: Int

    def __init__(out self, s: StringSlice[Self.o]):
        self._s = s
        self._at = 0

    def __iter__(var self) -> Self.IteratorOwnedType:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        var start, end = bsp._field_bounds[Self.f](self._s.as_bytes(), self._at)
        if start == end:
            raise StopIteration()
        self._at = end
        return self._s[byte=start:end]


struct _Fields[o: ImmOrigin](IterableOwned, Iterator):
    """What `fields_seq` returns.

    A second struct rather than `_FieldsFunc` with `is_space` bound, because a
    plain function is not a capturing closure and Mojo will not convert one
    into the other at a parameter. The scan itself is `_field_bounds` in
    `core.bytes` and is written once.
    """

    comptime Element = StringSlice[Self.o].Immutable
    comptime IteratorOwnedType = Self

    var _s: StringSlice[Self.o].Immutable
    var _at: Int

    def __init__(out self, s: StringSlice[Self.o]):
        self._s = s
        self._at = 0

    def __iter__(var self) -> Self.IteratorOwnedType:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        @parameter
        def space(r: Int32) -> Bool:
            return is_space(r)

        var start, end = bsp._field_bounds[space](self._s.as_bytes(), self._at)
        if start == end:
            raise StopIteration()
        self._at = end
        return self._s[byte=start:end]


def fields_seq[o: ImmOrigin](s: StringSlice[o]) -> _Fields[o]:
    """`fields` one field at a time. Go's `strings.FieldsSeq`."""
    return _Fields[o](s)


def fields_func_seq[
    o: ImmOrigin, //, f: def(Int32) capturing[_] -> Bool
](s: StringSlice[o]) -> _FieldsFunc[o, f]:
    """`fields_func` one field at a time. Go's `strings.FieldsFuncSeq`."""
    return _FieldsFunc[o, f](s)
