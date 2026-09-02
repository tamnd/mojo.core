"""Go's `sort.Interface`, the three sorts over it, and the wrappers Go ships.

Go's `Interface` is a dynamic interface value. Here it is a trait taken as a
generic parameter, because design.md section 1 says there are no trait objects,
and the difference shows up in one place: `Reverse` holds a pointer to the data
rather than a copy of an interface value, so that sorting through it moves the
caller's elements and not a clone of them.
"""

from core.cmp import less as cmp_less

from .pdq import _sort_range
from .search import search_float64s, search_ints, search_strings
from .stable import _stable_range


trait Interface(Sized):
    """A collection this package can sort, addressed by index.

    Three methods, as in Go: how many elements there are, whether one sorts
    before another, and how to exchange two. Nothing here needs to know what
    the elements are or where they live, which is why a pair of parallel
    arrays, a slice of structs and a memory-mapped file can all be sorted by
    the same code.

    ```mojo
    from core.sort import Interface, sort


    struct ByLength[o: MutOrigin](Interface):
        var words: Span[String, Self.o]

        def __init__(out self, words: Span[String, Self.o]):
            self.words = words

        def __len__(self) -> Int:
            return len(self.words)

        def less(self, i: Int, j: Int) -> Bool:
            return self.words[i].byte_length() < self.words[j].byte_length()

        def swap(mut self, i: Int, j: Int):
            var held = self.words[i].copy()
            self.words[i] = self.words[j].copy()
            self.words[j] = held^
    ```

    `Len` is `__len__` rather than a method called `len`, so that `len(data)`
    works and there is not a second spelling of the language's own question.
    `parity/renames.toml` records it.

    None of the three may raise. Go's cannot either, and the reason is the same
    one `core.iter` gives about `__next__`: a failure in the middle of a sort
    leaves the data in a state nobody can describe, so the right place to fail
    is before the sort starts.
    """

    def less(self, i: Int, j: Int) -> Bool:
        """Whether the element at `i` must sort before the one at `j`.

        This has to be a strict weak ordering, which in practice means three
        things: `less(i, i)` is false, `less(i, j)` and `less(j, i)` are never
        both true, and if neither holds for `i, j` and neither holds for
        `j, k`, then neither holds for `i, k`.

        `<` on floats is not one, because a NaN answers false to everything and
        so is neither less than nor equal to any value. `core.cmp.less` is, and
        `Float64Slice` below uses it. An ordering that is not a strict weak
        ordering gives an unspecified result here, never an out of range index:
        that is the guarantee `docs/deviations.md` records this package as
        being a port rather than a wrapper in order to keep.
        """
        ...

    def swap(mut self, i: Int, j: Int):
        """Exchanges the elements at `i` and `j`."""
        ...


def sort[D: Interface](mut data: D):
    """Sorts `data` in ascending order by its own `less`. Not stable.

    ```mojo
    from core.sort import IntSlice, sort

    var values = [3, 1, 2]
    var view = IntSlice(Span(values))
    sort(view)
    ```

    One call to `len`, then n log n calls to `less` and `swap`, on every input
    including the ones written to make a quicksort quadratic. `pdq.mojo` says
    how.

    Equal elements come out in an unspecified order. `stable` below keeps them
    in the order they arrived, and costs a log n factor of swaps for it.
    """

    @parameter
    def less(i: Int, j: Int) -> Bool:
        return data.less(i, j)

    @parameter
    def swap(i: Int, j: Int):
        data.swap(i, j)

    _sort_range[less, swap](len(data))


def stable[D: Interface](mut data: D):
    """Sorts `data` in ascending order, keeping equal elements in their order.

    n log n calls to `less` and n log squared n calls to `swap`, with no extra
    array. `stable.mojo` says how, and `tests/sort/test_stable.mojo` proves the
    stability rather than observing it.
    """

    @parameter
    def less(i: Int, j: Int) -> Bool:
        return data.less(i, j)

    @parameter
    def swap(i: Int, j: Int):
        data.swap(i, j)

    _stable_range[less, swap](len(data))


def is_sorted[D: Interface](data: D) -> Bool:
    """Whether `data` is already in ascending order by its own `less`.

    Walks backwards, as Go does, so that the first inversion found is the one
    nearest the end and the loop reads the same way as the check inside the
    sort.
    """
    var i = len(data) - 1
    while i > 0:
        if data.less(i, i - 1):
            return False
        i -= 1
    return True


struct Reverse[T: Interface, o: MutOrigin](Interface):
    """`data` with its ordering turned around, so a sort of it descends.

    ```mojo
    from core.sort import IntSlice, Reverse, sort

    var values = [3, 1, 2]
    var view = IntSlice(Span(values))
    var backwards = Reverse(view)
    sort(backwards)  # values is now 3, 2, 1
    ```

    Go returns an `Interface` that embeds the original and overrides `Less`.
    There is no embedding here and no interface value to hold, so this holds a
    pointer at the data instead. That is not a detail: holding a `T` by value
    would sort a copy, and a caller who wrote `sort(Reverse(view))` would get
    back an unchanged slice and no error.

    Reversing twice is the identity and costs two levels of call, which is what
    Go does too.
    """

    var inner: Pointer[Self.T, Self.o]

    def __init__(out self, ref[Self.o] data: Self.T):
        """Points at `data`. Nothing is copied and nothing is owned."""
        self.inner = Pointer(to=data)

    def __len__(self) -> Int:
        return len(self.inner[])

    def less(self, i: Int, j: Int) -> Bool:
        """The inner `less` with its arguments the other way round.

        Not `not inner.less(i, j)`. Negating would make equal elements compare
        as ordered, which breaks the strict weak ordering and would make
        `stable` unstable.
        """
        return self.inner[].less(j, i)

    def swap(mut self, i: Int, j: Int):
        self.inner[].swap(i, j)


struct IntSlice[o: MutOrigin](Interface):
    """`Interface` over a span of `Int`, ascending.

    Go's is `type IntSlice []int`, a named slice type. A `Span` is the same
    idea: a view, so sorting one sorts the caller's list.
    """

    var values: Span[Int, Self.o]

    def __init__(out self, values: Span[Int, Self.o]):
        self.values = values

    def __len__(self) -> Int:
        return len(self.values)

    def less(self, i: Int, j: Int) -> Bool:
        return self.values[i] < self.values[j]

    def swap(mut self, i: Int, j: Int):
        var held = self.values[i]
        self.values[i] = self.values[j]
        self.values[j] = held

    def sort(mut self):
        """Convenience for `sort(self)`, as Go's method is."""
        var view = Self(self.values)
        sort(view)

    def search(self, x: Int) -> Int:
        """Convenience for `search_ints(self.values, x)`."""
        return search_ints(self.values, x)


struct Float64Slice[o: MutOrigin](Interface):
    """`Interface` over a span of `Float64`, ascending, NaN first.

    `less` is `core.cmp.less`, not `<`. A NaN answers false to `<`, `>` and
    `==` at once, so a sort given `<` on a slice containing one is being told
    that two elements are each neither before nor after the other and also not
    equal, and there is no ordering that satisfies that. Go puts NaN first for
    the same reason and documents it in the same place.
    """

    var values: Span[Float64, Self.o]

    def __init__(out self, values: Span[Float64, Self.o]):
        self.values = values

    def __len__(self) -> Int:
        return len(self.values)

    def less(self, i: Int, j: Int) -> Bool:
        return cmp_less(self.values[i], self.values[j])

    def swap(mut self, i: Int, j: Int):
        var held = self.values[i]
        self.values[i] = self.values[j]
        self.values[j] = held

    def sort(mut self):
        """Convenience for `sort(self)`, as Go's method is."""
        var view = Self(self.values)
        sort(view)

    def search(self, x: Float64) -> Int:
        """Convenience for `search_float64s(self.values, x)`."""
        return search_float64s(self.values, x)


struct StringSlice[o: MutOrigin](Interface):
    """`Interface` over a span of `String`, ascending by byte order.

    Sorting this costs two string copies and a move per swap, because the safe
    way to exchange two elements of one span is to go through a temporary: a
    borrow of both at once is refused, and the checked exchange raises where
    `Interface.swap` may not. `docs/deviations.md` has the row. Sorting an
    index list with `slice` avoids it when the strings are long.
    """

    var values: Span[String, Self.o]

    def __init__(out self, values: Span[String, Self.o]):
        self.values = values

    def __len__(self) -> Int:
        return len(self.values)

    def less(self, i: Int, j: Int) -> Bool:
        return self.values[i] < self.values[j]

    def swap(mut self, i: Int, j: Int):
        var held = self.values[i].copy()
        self.values[i] = self.values[j].copy()
        self.values[j] = held^

    def sort(mut self):
        """Convenience for `sort(self)`, as Go's method is."""
        var view = Self(self.values)
        sort(view)

    def search(self, x: String) -> Int:
        """Convenience for `search_strings(self.values, x)`."""
        return search_strings(self.values, x)
