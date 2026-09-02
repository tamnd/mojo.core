"""Turning a span into a sequence, and a sequence into a list. Go's `slices/iter.go`.

Go splits these nine into producers, which return an `iter.Seq`, and
consumers, which take one. This file keeps that split and gives the two halves
different types, because in this library they are different problems.

The four producers walk a span. Nothing about walking a span can fail, so they
return ordinary Mojo iterators and a `for` loop over one is correct:

```mojo
from core.slices import values

var xs: List[Int] = [1, 2, 3]
var total = 0
for v in values(Span(xs)):
    total += v
```

The five consumers take a `core.iter.Cursor`, which is this library's fallible
iterator, and are written with the `while` loop that `Cursor` requires. That
is the asymmetry Go does not have, and it is deliberate: `core/iter/cursor.mojo`
says outright that "a `List` iterator is not a `Cursor` and should not be made
into one", because a `for` loop silently swallows an error raised out of
`__next__` and there is no error here to swallow. But the sequences people
actually collect from — csv records, bufio lines, sql rows, directory walks —
are all fallible, so a `collect` that only accepted infallible iterators would
be a `collect` nobody could use.

So: producing is infallible and reads like Mojo, consuming is fallible and
reads like `Cursor`. Feeding a producer into a consumer is not something this
file offers a shortcut for, because `clone` in `edit.mojo` already is that
shortcut.
"""

from core.cmp import Ordered
from core.iter import Cursor

from .order import sort, sort_func, sort_stable_func


struct _Pairs[T: Copyable & Deinitable, o: Origin, forward: Bool](
    IterableOwned, Iterator
):
    """Index and element, forwards or backwards. What `all` and `backward` return.
    """

    comptime Element = Tuple[Int, Self.T]
    comptime IteratorOwnedType = Self

    var _span: Span[Self.T, Self.o]
    var _next: Int

    def __init__(out self, span: Span[Self.T, Self.o]):
        self._span = span

        comptime if Self.forward:
            self._next = 0
        else:
            self._next = len(span) - 1

    def __iter__(var self) -> Self.IteratorOwnedType:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        if self._next < 0 or self._next >= len(self._span):
            raise StopIteration()
        var i = self._next

        comptime if Self.forward:
            self._next += 1
        else:
            self._next -= 1

        return (i, self._span[i].copy())

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        var left: Int

        comptime if Self.forward:
            left = len(self._span) - self._next
        else:
            left = self._next + 1

        return (left, {left})


struct _Values[T: Copyable & Deinitable, o: Origin](IterableOwned, Iterator):
    """Elements without their indices. What `values` returns."""

    comptime Element = Self.T
    comptime IteratorOwnedType = Self

    var _span: Span[Self.T, Self.o]
    var _next: Int

    def __init__(out self, span: Span[Self.T, Self.o]):
        self._span = span
        self._next = 0

    def __iter__(var self) -> Self.IteratorOwnedType:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        if self._next >= len(self._span):
            raise StopIteration()
        self._next += 1
        return self._span[self._next - 1].copy()

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        var left = len(self._span) - self._next
        return (left, {left})


struct _Chunks[T: Copyable & Deinitable, o: Origin](IterableOwned, Iterator):
    """Consecutive sub-spans of a fixed size. What `chunk` returns."""

    comptime Element = Span[Self.T, Self.o]
    comptime IteratorOwnedType = Self

    var _span: Span[Self.T, Self.o]
    var _size: Int
    var _next: Int

    def __init__(out self, span: Span[Self.T, Self.o], size: Int):
        self._span = span
        self._size = size
        self._next = 0

    def __iter__(var self) -> Self.IteratorOwnedType:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        if self._next >= len(self._span):
            raise StopIteration()
        var start = self._next
        var end = start + self._size
        if end > len(self._span):
            end = len(self._span)
        self._next = end
        return self._span[start:end]

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        var left = len(self._span) - self._next
        # Ceiling division: the last chunk is short unless the length divides.
        var chunks = (left + self._size - 1) // self._size
        return (chunks, {chunks})


def all[
    T: Copyable & Deinitable, o: Origin, //
](s: Span[T, o]) -> _Pairs[T, o, True]:
    """An iterator over `(index, element)` pairs of `s`, front to back.

    ```mojo
    from core.slices import all

    var xs: List[Int] = [7, 8]
    for i, v in all(Span(xs)):
        print(i, v)  # => 0 7 / 1 8
    ```

    This shadows the builtin `all` for the rest of this module, which is why
    nothing below calls it. Go's name, and the cost of keeping Go's name is
    one function this file cannot use.
    """
    return _Pairs[T, o, True](s)


def backward[
    T: Copyable & Deinitable, o: Origin, //
](s: Span[T, o]) -> _Pairs[T, o, False]:
    """An iterator over `(index, element)` pairs of `s`, back to front.

    The indices descend and they are indices into `s`, not into the reversed
    order, so the last pair is `(0, s[0])`.
    """
    return _Pairs[T, o, False](s)


def values[
    T: Copyable & Deinitable, o: Origin, //
](s: Span[T, o]) -> _Values[T, o]:
    """An iterator over the elements of `s`, front to back, without indices."""
    return _Values[T, o](s)


def chunk[
    T: Copyable & Deinitable, o: Origin, //
](s: Span[T, o], n: Int) raises -> _Chunks[T, o]:
    """An iterator over consecutive sub-spans of `s` of up to `n` elements.

    ```mojo
    from core.slices import chunk

    var xs: List[Int] = [1, 2, 3, 4, 5]
    for part in chunk(Span(xs), 2):
        print(len(part))  # => 2 / 2 / 1
    ```

    Every chunk but the last has exactly `n` elements. An empty `s` yields
    nothing at all rather than one empty chunk. Raises if `n` is less than one,
    which Go panics on.

    The chunks are spans into `s` and not copies, so they see later writes to
    `s` and cost nothing to produce. Go clips the capacity of each chunk so
    that appending to one cannot reach into the next; a span has no capacity
    and cannot be appended to, so there is nothing to clip.
    """
    if n < 1:
        raise Error("slices.chunk: size less than one")
    return _Chunks[T, o](s, n)


def append_seq[C: Cursor, //](mut c: C, mut into: List[C.Element]) raises:
    """Appends everything left in `c` to `into`.

    A failure part way through leaves `into` holding what was read before it,
    which is the only honest thing to do with values already moved out of the
    cursor. Go's version cannot fail and so does not have to say this.

    The cursor comes first and the destination second, which is the other way
    round from Go's `AppendSeq(s, seq)`. That is not a preference: `C` is
    inferred from the cursor and the destination's type is `List[C.Element]`,
    so with the destination first the compiler reaches it before `C` is
    resolved and refuses the call. Every other length-changing function in this
    package takes its destination first, and this one cannot.
    """
    # No `reserve` first. A `Cursor` has no length hint and cannot be given
    # one: a csv reader does not know how many records are left without
    # reading them, and a trait method that most implementations would have to
    # guess at is worse than the reallocations.
    while c.has_next():
        into.append(c.next())


def collect[C: Cursor, //](mut c: C) raises -> List[C.Element]:
    """A new list holding everything left in `c`.

    ```mojo
    from core.slices import collect
    from core.iter import Cursor


    def drain[C: Cursor](mut c: C) raises -> Int:
        var xs = collect(c)
        return len(xs)
    ```

    Raises if the cursor does, and then nothing is returned: the partial list
    is dropped. `append_seq` is the version that keeps what it read, and the
    difference between the two is the reason both exist.
    """
    var out = List[C.Element]()
    append_seq(c, out)
    return out^


# The three `sorted` functions below go through these two rather than calling
# `order.mojo` directly, and the reason is a limit in the compiler rather than
# anything about sorting.
#
# `C.Element` is declared `Deinitable & Movable` on the `Cursor` trait, and a
# `where conforms_to(C.Element, Copyable)` on the caller does narrow it — but
# only where the type is used on its own. Inferring `T` in `sort(s: Span[T, o])`
# from a `Span[C.Element, ...]` still sees the trait's declared bound and
# rejects the call. Binding `T` explicitly instead of inferring it works, and a
# function whose `T` is explicit is what these are.
#
# `tools/probe/probes/refined_associated_type.mojo` has the reduced case and
# `docs/design.md` records it. When the compiler infers through the refinement
# that probe starts compiling, these two go away, and the callers below go
# back to calling `order.mojo`.


def _sorted_ordered[
    T: Ordered & Copyable & Deinitable
](var xs: List[T]) -> List[T]:
    sort(Span(xs))
    return xs^


def _sorted_by[
    T: Copyable & Deinitable,
    stable: Bool,
    cmp: def(T, T) capturing[_] -> Int,
](var xs: List[T]) -> List[T]:
    comptime if stable:
        sort_stable_func[cmp](Span(xs))
    else:
        sort_func[cmp](Span(xs))
    return xs^


def sorted[
    C: Cursor, //
](mut c: C) raises -> List[C.Element] where conforms_to(
    C.Element, Ordered & Copyable
):
    """Everything left in `c`, collected and sorted ascending. Not stable."""
    return _sorted_ordered[C.Element](collect(c))


def sorted_func[
    C: Cursor, //, cmp: def(C.Element, C.Element) capturing[_] -> Int
](mut c: C) raises -> List[C.Element] where conforms_to(C.Element, Copyable):
    """Everything left in `c`, collected and sorted by `cmp`. Not stable."""
    return _sorted_by[C.Element, False, cmp](collect(c))


def sorted_stable_func[
    C: Cursor, //, cmp: def(C.Element, C.Element) capturing[_] -> Int
](mut c: C) raises -> List[C.Element] where conforms_to(C.Element, Copyable):
    """Everything left in `c`, collected and sorted by `cmp`, equal elements kept in order.

    The order kept is the order the cursor produced them in, which is the only
    order they ever had.
    """
    return _sorted_by[C.Element, True, cmp](collect(c))
