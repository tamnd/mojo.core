"""Changing what is in a list, and how much of it. Go's `slices` editing half.

Everything in `find.mojo` and `order.mojo` takes a `Span`, because a span is a
Go slice with the length written down and none of those functions change the
length. These do, and a span cannot: it is a view, it does not own the storage
and it cannot ask for more. So these take `mut s: List[T]` and return nothing.

That is the visible difference from Go, where `Insert`, `Delete`, `Replace`,
`Compact`, `Grow` and `Clip` all return the modified slice and the caller is
expected to write `s = slices.Delete(s, 0, 2)`. The reason that shape exists in
Go is that a slice header is a value: the function cannot change the caller's
length, so it hands back a new header and trusts the caller to assign it. The
bug it invites is famous — keep the old header as well and you have two names
for one array, one of them with a stale length.

Mojo has the thing Go is working around. `mut s: List[T]` changes the caller's
list, so there is nothing to return and no old name to keep. It is the same
reasoning `docs/deviations.md` already records for `utf8.AppendRune` becoming
`append_rune(mut dst, r)`.

`Clone`, `Concat` and `Repeat` build a new list rather than editing one, so
those return a `List[T]` and take their input by reading it.
"""


def insert[
    T: Copyable & Deinitable, o: Origin, //
](mut s: List[T], i: Int, values: Span[T, o]) raises:
    """Inserts `values` into `s` at `i`, shifting what was there up.

    ```mojo
    from core.slices import insert

    var values: List[Int] = [1, 4]
    var middle: List[Int] = [2, 3]
    insert(values, 1, Span(middle))  # 1, 2, 3, 4
    ```

    Raises if `i` is not in `[0, len(s)]`. Inserting nothing at a valid index
    is allowed and does nothing.

    Go's is variadic and this takes a span, which is the same call with the
    `...` spelled at the front. It cannot be a span into `s` itself: the borrow
    checker refuses to hand out a read of a list that is mutably borrowed here,
    so the overlap case Go documents and tests cannot be written.
    """
    if i < 0 or i > len(s):
        raise Error("slices.insert: index out of range")
    var m = len(values)
    if m == 0:
        return
    var old = len(s)
    s.reserve(old + m)
    for k in range(m):
        s.append(values[k].copy())

    # The new elements are at the end and belong at `i`, so rotate the region
    # from `i` onwards until they are. Three reversals, which moves each
    # element twice and needs no scratch space; Go's `Insert` rotates too.
    var tail = Span(s)[i:]
    reverse(tail[: old - i])
    reverse(tail[old - i :])
    reverse(tail)


def delete[T: Movable & Deinitable, //](mut s: List[T], i: Int, j: Int) raises:
    """Removes `s[i:j]`.

    ```mojo
    from core.slices import delete

    var values: List[Int] = [1, 2, 3, 4]
    delete(values, 1, 3)  # 1, 4
    ```

    Raises unless `0 <= i <= j <= len(s)`. Deleting an empty range does
    nothing.

    One call deleting a run is much cheaper than a call per element, as in Go:
    this is O(len(s) - i) however wide the range is.
    """
    if i < 0 or i > j or j > len(s):
        raise Error("slices.delete: index out of range")
    if i == j:
        return
    var n = len(s)
    # Swapped rather than assigned so that this works for a type that can only
    # be moved. The deleted elements end up in the tail and `shrink` destroys
    # them, which is where Go's `clear` of the obsolete elements went.
    for k in range(j, n):
        s.swap_elements(i + k - j, k)
    s.shrink(n - (j - i))


def delete_func[
    T: Copyable & Deinitable, //, f: def(T) capturing[_] -> Bool
](mut s: List[T]):
    """Removes every element of `s` for which `f` holds, keeping the rest in order.
    """
    var i = 0
    while i < len(s) and not f(s[i]):
        i += 1
    if i == len(s):
        return
    # Nothing moves until the first element to delete is found, so a call that
    # deletes nothing near the front does no work near the front.
    var j = i + 1
    while j < len(s):
        if not f(s[j]):
            s.swap_elements(i, j)
            i += 1
        j += 1
    s.shrink(i)


def replace[
    T: Copyable & Deinitable, o: Origin, //
](mut s: List[T], i: Int, j: Int, values: Span[T, o]) raises:
    """Replaces `s[i:j]` with `values`.

    ```mojo
    from core.slices import replace

    var values: List[Int] = [1, 2, 3, 4]
    var with_: List[Int] = [9]
    replace(values, 1, 3, Span(with_))  # 1, 9, 4
    ```

    Raises unless `0 <= i <= j <= len(s)`. The replacement need not be the same
    length as the range it replaces, which is the whole point of the function.
    """
    if i < 0 or i > j or j > len(s):
        raise Error("slices.replace: index out of range")
    # A delete and an insert rather than Go's single pass. Both are O(len(s))
    # and so is the pair, and the one-pass version is the part of Go's `slices`
    # with the most cases and the most tests for the cases it got wrong.
    delete(s, i, j)
    insert(s, i, values)


def compact[T: Equatable & Copyable & Deinitable, //](mut s: List[T]):
    """Replaces each run of consecutive equal elements with the first of them.

    ```mojo
    from core.slices import compact

    var values: List[Int] = [1, 1, 2, 2, 2, 3]
    compact(values)  # 1, 2, 3
    ```

    Consecutive, not equal anywhere: this is `uniq` and not `sort | uniq`. On a
    sorted list the two are the same thing, which is the usual reason to call
    it.
    """
    if len(s) < 2:
        return
    var k = 1
    for j in range(1, len(s)):
        # `s[j - 1]` is still the original element there. Every write below
        # goes to `k`, and `k` is at most `j - 1` at the time of the write,
        # which happens after this comparison. So the pair being compared is
        # always a pair of neighbours from the input, as Go's is.
        if s[j] != s[j - 1]:
            if k != j:
                var kept = s[j].copy()
                s[k] = kept^
            k += 1
    s.shrink(k)


def compact_func[
    T: Copyable & Deinitable, //, eq: def(T, T) capturing[_] -> Bool
](mut s: List[T]):
    """`compact`, with `eq` deciding which neighbours count as equal."""
    if len(s) < 2:
        return
    var k = 1
    for j in range(1, len(s)):
        if not eq(s[j], s[j - 1]):
            if k != j:
                var kept = s[j].copy()
                s[k] = kept^
            k += 1
    s.shrink(k)


def grow[T: Movable, //](mut s: List[T], n: Int) raises:
    """Makes room in `s` for `n` more elements without another allocation.

    Raises if `n` is negative, which Go panics on. Growing by zero is allowed
    and does nothing.

    This changes the capacity and not the length, so nothing about the contents
    of `s` changes and nothing here can be observed except by timing.
    """
    if n < 0:
        raise Error("slices.grow: negative count")
    s.reserve(len(s) + n)


def clip[T: Movable & Deinitable, //](mut s: List[T]):
    """Releases the capacity of `s` beyond its length.

    Go's `Clip` returns `s[:len(s):len(s)]`, and the reason it exists there is
    aliasing: a later append to the clipped slice is forced to allocate instead
    of writing into an array that something else may still be reading. A Mojo
    `List` owns its storage and cannot be aliased that way, so that hazard does
    not exist here and the only thing left of the function is the memory.

    It is kept because releasing memory is a real thing to want after a large
    list has been filtered down to a small one, and because a `slices` without
    a `Clip` would be a `slices` a reader has to check. The cost is one move
    per element, since capacity cannot be lowered in place.
    """
    if s.capacity() == len(s):
        return
    var out = List[T](capacity=len(s))
    while len(s) > 0:
        out.append(s.pop())
    out.reverse()
    s = out^


def clone[T: Copyable & Deinitable, o: Origin, //](s: Span[T, o]) -> List[T]:
    """A new list holding a copy of every element of `s`.

    Shallow, as Go's is: each element is copied by its own `copy`, and what
    that does for an element holding a pointer is that element's business.
    """
    var out = List[T](capacity=len(s))
    for i in range(len(s)):
        out.append(s[i].copy())
    return out^


def concat[T: Copyable & Deinitable, //](*parts: List[T]) -> List[T]:
    """A new list holding the elements of every list in `parts`, in order.

    ```mojo
    from core.slices import concat

    var a: List[Int] = [1, 2]
    var b: List[Int] = [3]
    var joined = concat(a, b)  # 1, 2, 3
    ```

    Variadic over lists rather than over spans, which Go's is, because a Mojo
    variadic binds one origin parameter for the whole call and two spans into
    two different lists have two origins. `concat(Span(a), Span(b))` does not
    compile and cannot be made to; `concat(a, b)` reads the same and does.
    """
    var total = 0
    for part in parts:
        total += len(part)
    var out = List[T](capacity=total)
    for part in parts:
        for i in range(len(part)):
            out.append(part[i].copy())
    return out^


def repeat[
    T: Copyable & Deinitable, o: Origin, //
](x: Span[T, o], count: Int) raises -> List[T]:
    """A new list holding `x` repeated `count` times.

    Raises if `count` is negative or if the result would be longer than an
    `Int` can count, both of which Go panics on. Repeating zero times gives an
    empty list.
    """
    if count < 0:
        raise Error("slices.repeat: negative count")
    if len(x) != 0 and count > Int.MAX // len(x):
        raise Error("slices.repeat: length overflows")
    var out = List[T](capacity=len(x) * count)
    for _ in range(count):
        for i in range(len(x)):
            out.append(x[i].copy())
    return out^


def reverse[T: Copyable & Deinitable, o: MutOrigin, //](s: Span[T, o]):
    """Reverses `s` in place.

    ```mojo
    from core.slices import reverse

    var values: List[Int] = [1, 2, 3]
    reverse(Span(values))  # 3, 2, 1
    ```

    A span and not a `mut List`, because this is the one function in this file
    that does not change the length. That means it works on a sub-range —
    `reverse(Span(values)[1:])` — which is what `insert` above needs.
    """
    var i = 0
    var j = len(s) - 1
    while i < j:
        # Three moves through a temporary, the same swap `core.sort` writes,
        # because `swap(s[i], s[j])` would form two mutable aliases into one
        # span and Mojo does not allow it.
        var held = s[i].copy()
        s[i] = s[j].copy()
        s[j] = held^
        i += 1
        j -= 1
