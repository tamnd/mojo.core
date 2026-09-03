"""Cutting a byte slice into pieces. Go's `bytes` splitting half.

Every piece is a span into the original, never a copy, which is what Go does
and what makes splitting a megabyte into a thousand fields cost one list of
spans rather than a megabyte of allocation. The origin travels with each piece,
so the compiler knows the pieces borrow the input and a piece cannot outlive
what it points into by accident.

## The pieces are read-only

A piece is a `Span[Byte, o].Immutable` even when the input was writable, and
that is a language rule rather than a preference. Mojo's exclusivity checker
refuses to let two writable spans into the same origin sit in one value, so
`cut` — which returns the two halves together — cannot hand back writable
halves at all. Given that, everything that carves returns a read-only view,
because `cut` read-only and `split` writable would be a distinction nobody
could remember. A caller who wants to write into the input can have the offsets
instead: `index`, `index_byte` and their kin answer those and cost nothing.

## Two shapes for the same cut

`split` returns a `List` of spans and `split_seq` returns an iterator over the
same spans. Go added the `Seq` forms in 1.24 for the case where the list is
built and immediately walked, and they matter more here than there, because the
list of spans has to be allocated and the iterator does not.

The iterators are ordinary Mojo iterators and a `for` loop over one is correct.
Walking a span cannot fail, so there is no error for the loop to swallow, which
is the rule `core/iter/cursor.mojo` sets out and `core.slices` follows for the
same reason.

## The empty separator

`split(s, "")` splits after every rune, not after every byte, so an eight byte
slice of two Chinese characters gives two pieces. `split(s, sep)` with a
non-empty separator gives `count(s, sep) + 1` pieces, always, including when
`s` is empty: splitting nothing gives one empty piece and not zero pieces. Both
of those are Go's rules and both are the ones that make `join(split(s, sep),
sep)` reconstruct `s`.
"""

from core.io import Byte
from core.unicode import is_space
from core.unicode.utf8 import decode_rune

from .search import count, index

comptime _AFTER = 1
"""`_gen_split` keeps the separator on the piece before it. Go's `sepSave`."""

comptime _DROP = 0
"""`_gen_split` throws the separator away."""


def cut[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], sep: Span[Byte, o2]) -> Tuple[
    Span[Byte, o1].Immutable, Span[Byte, o1].Immutable, Bool
]:
    """`s` around the first `sep`: before, after, and whether it was there.

    Go's `bytes.Cut`, and the function to reach for instead of `index` followed
    by two slice expressions, which is where off-by-one errors live. When `sep`
    is absent the answer is all of `s`, an empty slice, and `False`.
    """
    var v = s.as_imm()
    var at = index(s, sep)
    if at < 0:
        return (v, v[len(v) : len(v)], False)
    return (v[0:at], v[at + len(sep) : len(v)], True)


def cut_prefix[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], prefix: Span[Byte, o2]) -> Tuple[
    Span[Byte, o1].Immutable, Bool
]:
    """`s` without `prefix`, and whether it had one. Go's `bytes.CutPrefix`.

    An empty prefix is present, so this returns `s` and `True`, which differs
    from `trim_prefix` in nothing but being able to say so.
    """
    var v = s.as_imm()
    if len(prefix) > len(v):
        return (v, False)
    for i in range(len(prefix)):
        if v[i] != prefix[i]:
            return (v, False)
    return (v[len(prefix) : len(v)], True)


def cut_suffix[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], suffix: Span[Byte, o2]) -> Tuple[
    Span[Byte, o1].Immutable, Bool
]:
    """`s` without `suffix`, and whether it had one. Go's `bytes.CutSuffix`."""
    var v = s.as_imm()
    if len(suffix) > len(v):
        return (v, False)
    var base = len(v) - len(suffix)
    for i in range(len(suffix)):
        if v[base + i] != suffix[i]:
            return (v, False)
    return (v[0:base], True)


def _explode[
    o: Origin
](s: Span[Byte, o], n: Int) -> List[Span[Byte, o].Immutable]:
    """`s` cut after every rune, at most `n` pieces. Go's `explode`.

    The last piece holds everything left when the count runs out, which is what
    makes `split_n` with a small `n` and an empty separator behave like every
    other `split_n`.
    """
    var v = s.as_imm()
    var out = List[Span[Byte, o].Immutable]()
    var i = 0
    var made = 0
    while i < len(v):
        if n >= 0 and made == n - 1:
            break
        var _r, width = decode_rune(v[i : len(v)])
        out.append(v[i : i + width])
        i += width
        made += 1
    if i < len(v):
        out.append(v[i : len(v)])
    return out^


def _gen_split[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], sep: Span[Byte, o2], keep: Int, n: Int) -> List[
    Span[Byte, o1].Immutable
]:
    """The one loop behind all four splitters. Go's `genSplit`.

    `keep` is `_AFTER` to leave the separator on the end of the piece before it
    and `_DROP` to discard it, and `n` is the piece limit with -1 for no limit.
    """
    var v = s.as_imm()
    var out = List[Span[Byte, o1].Immutable]()
    if n == 0:
        return out^
    if len(sep) == 0:
        return _explode(s, n)
    var want = n
    if want < 0:
        want = count(s, sep) + 1
    var start = 0
    var made = 0
    while made < want - 1:
        var at = index(v[start : len(v)], sep)
        if at < 0:
            break
        out.append(v[start : start + at + len(sep) * keep])
        start += at + len(sep)
        made += 1
    out.append(v[start : len(v)])
    return out^


def split[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], sep: Span[Byte, o2]) -> List[Span[Byte, o1].Immutable]:
    """`s` cut around every `sep`, with the separators dropped. Go's `Split`.

    ```mojo
    from core.bytes import split

    var parts = split(String("a,b,c").as_bytes(), String(",").as_bytes())
    print(len(parts))  # => 3
    ```
    """
    return _gen_split(s, sep, _DROP, -1)


def split_n[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], sep: Span[Byte, o2], n: Int) -> List[
    Span[Byte, o1].Immutable
]:
    """`split` with at most `n` pieces, the last one unsplit. Go's `SplitN`.

    A negative `n` means no limit and a zero `n` means no pieces at all, which
    is Go's `nil` and is an empty list here. Zero is not the same as one: one
    piece is the whole of `s`, and no pieces is a caller asking for nothing.
    """
    return _gen_split(s, sep, _DROP, n)


def split_after[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], sep: Span[Byte, o2]) -> List[Span[Byte, o1].Immutable]:
    """`s` cut after every `sep`, keeping the separators. Go's `SplitAfter`.

    The pieces concatenate back to `s` exactly, which is what this is for: a
    line splitter that keeps its newlines can put the text back together.
    """
    return _gen_split(s, sep, _AFTER, -1)


def split_after_n[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], sep: Span[Byte, o2], n: Int) -> List[
    Span[Byte, o1].Immutable
]:
    """`split_after` with at most `n` pieces. Go's `SplitAfterN`."""
    return _gen_split(s, sep, _AFTER, n)


struct _Split[o1: Origin, o2: Origin, keep: Int](IterableOwned, Iterator):
    """What `split_seq` and `split_after_seq` return.

    The same cut as `_gen_split` made one piece at a time, so a caller that
    walks the pieces once and throws them away never builds the list.
    """

    comptime Element = Span[Byte, Self.o1].Immutable
    comptime IteratorOwnedType = Self

    var _s: Span[Byte, Self.o1].Immutable
    var _sep: Span[Byte, Self.o2]
    var _at: Int
    var _done: Bool

    def __init__(out self, s: Span[Byte, Self.o1], sep: Span[Byte, Self.o2]):
        self._s = s.as_imm()
        self._sep = sep
        self._at = 0
        self._done = False

    def __iter__(var self) -> Self.IteratorOwnedType:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        if self._done:
            raise StopIteration()
        if len(self._sep) == 0:
            # An empty separator cuts after each rune, and the sequence ends
            # when the bytes do rather than with a trailing empty piece.
            if self._at >= len(self._s):
                raise StopIteration()
            var _r, width = decode_rune(self._s[self._at : len(self._s)])
            var piece = self._s[self._at : self._at + width]
            self._at += width
            return piece
        var found = index(self._s[self._at : len(self._s)], self._sep)
        if found < 0:
            self._done = True
            return self._s[self._at : len(self._s)]
        var end = self._at + found + len(self._sep) * Self.keep
        var piece = self._s[self._at : end]
        self._at += found + len(self._sep)
        return piece


def split_seq[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], sep: Span[Byte, o2]) -> _Split[o1, o2, _DROP]:
    """`split` one piece at a time. Go's `bytes.SplitSeq`.

    ```mojo
    from core.bytes import split_seq

    for field in split_seq(String("a,b").as_bytes(), String(",").as_bytes()):
        print(len(field))
    ```
    """
    return _Split[o1, o2, _DROP](s, sep)


def split_after_seq[
    o1: Origin, o2: Origin
](s: Span[Byte, o1], sep: Span[Byte, o2]) -> _Split[o1, o2, _AFTER]:
    """`split_after` one piece at a time. Go's `bytes.SplitAfterSeq`."""
    return _Split[o1, o2, _AFTER](s, sep)


struct _Lines[o: Origin](IterableOwned, Iterator):
    """What `lines` returns: the newline stays on the line it ended."""

    comptime Element = Span[Byte, Self.o].Immutable
    comptime IteratorOwnedType = Self

    var _s: Span[Byte, Self.o].Immutable
    var _at: Int

    def __init__(out self, s: Span[Byte, Self.o]):
        self._s = s.as_imm()
        self._at = 0

    def __iter__(var self) -> Self.IteratorOwnedType:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        if self._at >= len(self._s):
            raise StopIteration()
        var start = self._at
        while self._at < len(self._s):
            var end = self._at
            self._at += 1
            if self._s[end] == Byte(0x0A):
                break
        return self._s[start : self._at]


def lines[o: Origin](s: Span[Byte, o]) -> _Lines[o]:
    """The lines of `s`, each with its newline still on it. Go's `bytes.Lines`.

    Keeping the newline is Go's choice and it is the right one: it makes the
    lines concatenate back to `s`, and it lets a caller tell a final line that
    ended from one that ran out. A slice that does not end in a newline yields
    a last line without one; an empty slice yields nothing at all.

    Only `\\n` ends a line. A `\\r` before it stays on the line, which is what
    `bufio.Scanner` strips and this does not, because a byte slice is not a
    stream and the caller can see what they have.
    """
    return _Lines[o](s)


def _fields_impl[
    o: Origin, //, f: def(Int32) capturing[_] -> Bool
](s: Span[Byte, o]) -> List[Span[Byte, o].Immutable]:
    """The one loop behind `fields` and `fields_func`.

    Two passes: the first counts the fields so the list is allocated once at
    the right size, the second fills it. Go does the same, and on a line with
    a hundred fields the second walk over the bytes costs less than the six
    reallocations it saves.
    """
    var v = s.as_imm()
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

    var out = List[Span[Byte, o].Immutable](capacity=found)
    var start = -1
    i = 0
    while i < len(v):
        var at = i
        var r, width = decode_rune(v[i : len(v)])
        i += width
        if f(r):
            if start >= 0:
                out.append(v[start:at])
                start = -1
        elif start < 0:
            start = at
    if start >= 0:
        out.append(v[start : len(v)])
    return out^


def fields[o: Origin](s: Span[Byte, o]) -> List[Span[Byte, o].Immutable]:
    """`s` split around runs of white space. Go's `bytes.Fields`.

    ```mojo
    from core.bytes import fields

    print(len(fields(String("  a  b ").as_bytes())))  # => 2
    ```

    A run of spaces is one separator, leading and trailing space produce no
    empty fields, and an all-space slice gives no fields at all. That is the
    difference between this and `split` on a single space, and it is why a
    command line is parsed with this and a CSV row is not.

    White space is `unicode.is_space`, so a non-breaking space does not
    separate fields and an ideographic space does.
    """

    @parameter
    def space(r: Int32) -> Bool:
        return is_space(r)

    return _fields_impl[space](s)


def fields_func[
    o: Origin, //, f: def(Int32) capturing[_] -> Bool
](s: Span[Byte, o]) -> List[Span[Byte, o].Immutable]:
    """`s` split around runs of runes satisfying `f`. Go's `bytes.FieldsFunc`.

    Go documents that it makes no guarantee about the order in which `f` is
    called and may call it several times per rune. This calls it once per rune,
    left to right, twice over: once to count the fields and once to cut them.
    A predicate with side effects is still a bad idea; this makes it a defined
    bad idea rather than an undefined one.
    """
    return _fields_impl[f](s)


def _field_bounds[
    o: Origin, //, f: def(Int32) capturing[_] -> Bool
](s: Span[Byte, o], at: Int) -> Tuple[Int, Int]:
    """The start and end of the next field at or after `at`.

    Both are `len(s)` when there is no field left, and a field is never empty,
    so `start == end` is the end of the sequence and nothing else.
    """
    var i = at
    while i < len(s):
        var r, width = decode_rune(s[i : len(s)])
        if not f(r):
            break
        i += width
    var start = i
    while i < len(s):
        var r, width = decode_rune(s[i : len(s)])
        if f(r):
            break
        i += width
    return (start, i)


struct _FieldsFunc[o: Origin, f: def(Int32) capturing[_] -> Bool]:
    """What `fields_func_seq` returns.

    It does not declare `IterableOwned` and `Iterator`, and it is the one
    iterator in this library that does not. A struct with a closure parameter
    has every method typed `capturing thin`, and both traits declare their
    methods `thin`, so the conformance cannot be written. A `for` loop over
    this still works — the loop finds `__iter__` and `__next__` on the type
    itself — and what is lost is passing one of these to something generic
    over `Iterator`. `_Fields` below is the same iterator with the predicate
    fixed to `is_space`, and it conforms, which is why the common case is not
    the one paying for this.
    """

    comptime Element = Span[Byte, Self.o].Immutable
    comptime IteratorOwnedType = Self

    var _s: Span[Byte, Self.o].Immutable
    var _at: Int

    def __init__(out self, s: Span[Byte, Self.o]):
        self._s = s.as_imm()
        self._at = 0

    def __iter__(var self) -> Self.IteratorOwnedType:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        var start, end = _field_bounds[Self.f](self._s, self._at)
        if start == end:
            raise StopIteration()
        self._at = end
        return self._s[start:end]


struct _Fields[o: Origin](IterableOwned, Iterator):
    """What `fields_seq` returns.

    A second struct rather than `_FieldsFunc` with `is_space` bound, because a
    plain function is not a capturing closure and Mojo will not convert one
    into the other at a parameter. The scan itself is `_field_bounds` and is
    written once; what is duplicated here is the four lines around it.
    """

    comptime Element = Span[Byte, Self.o].Immutable
    comptime IteratorOwnedType = Self

    var _s: Span[Byte, Self.o].Immutable
    var _at: Int

    def __init__(out self, s: Span[Byte, Self.o]):
        self._s = s.as_imm()
        self._at = 0

    def __iter__(var self) -> Self.IteratorOwnedType:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        @parameter
        def space(r: Int32) -> Bool:
            return is_space(r)

        var start, end = _field_bounds[space](self._s, self._at)
        if start == end:
            raise StopIteration()
        self._at = end
        return self._s[start:end]


def fields_seq[o: Origin](s: Span[Byte, o]) -> _Fields[o]:
    """`fields` one field at a time. Go's `bytes.FieldsSeq`."""
    return _Fields[o](s)


def fields_func_seq[
    o: Origin, //, f: def(Int32) capturing[_] -> Bool
](s: Span[Byte, o]) -> _FieldsFunc[o, f]:
    """`fields_func` one field at a time. Go's `bytes.FieldsFuncSeq`."""
    return _FieldsFunc[o, f](s)
