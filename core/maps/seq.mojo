"""Between a `Dict` and a sequence. Go's `maps.All`, `Keys`, `Values`, `Insert` and `Collect`.

Go's five are three producers returning an `iter.Seq` and two consumers taking
one. Here the producers return a `List` and the consumers take a `Span`, and
both halves of that are decisions rather than translations.

The producers return a list because a `Dict` already has iterators. `d.keys()`,
`d.values()` and `d.items()` are Mojo's own, they borrow rather than copy, and a
`keys` here that handed back one of them would be a second name for something
that exists. What does not exist is the thing a Go programmer writes
`slices.Collect(maps.Keys(m))` for, so that is what these are. Each has an
`_into` sibling that appends to a list you already have, for the caller who does
not want the allocation or who is gathering keys from several dicts:

```mojo
from core.maps import keys, keys_into

var ages = {"ana": 31, "bo": 27}
var names = keys(ages)          # a new list
keys_into(ages, names)          # appended to one you own
```

The order is the order the `Dict` iterates in and nothing here promises what
that is. Go randomises map order deliberately so that no program can come to
depend on it, and a caller who needs a fixed order sorts the list, which is one
call and says so at the call site.

One thing about the order is promised, because it is worth having and costs
nothing: with no mutation in between, `keys`, `values` and `all` walk the dict
the same way, so `keys(d)[i]` and `values(d)[i]` are one entry. Go promises the
opposite, since each of its iterators randomises separately, and the effect
there is that parallel lists have to come out of `All` and be unpacked.

The consumers take a `Span[Tuple[K, V], o]` rather than the `core.iter.Cursor`
that `slices.collect` takes, and that is forced. A cursor's element type is an
associated `comptime Element`, and there is no way to say "and that element is a
`Tuple[K, V]`" in a way the compiler will take apart again: `where C.Element ==
Tuple[K, V]` parses, and `pair[0]` on the result is still an error, because
`C.Element` is not subscriptable no matter what the clause says.
`tools/probe/probes/pair_cursor.mojo` pins it. So a fallible source is drained
with `slices.collect` first and the resulting list is what comes here, which
costs a line and a copy of the pairs.
"""

from std.hashlib import Hasher


def all[
    K: KeyElement & Copyable & Deinitable,
    V: Copyable & Deinitable,
    H: Hasher,
    //,
](d: Dict[K, V, H]) -> List[Tuple[K, V]]:
    """Every key and value in `d`, as pairs, in the order `d` iterates.

    ```mojo
    from core.maps import all

    var ages = {"ana": 31}
    for pair in all(ages):
        print(pair[0], pair[1])  # => ana 31
    ```

    This shadows the builtin `all` for the rest of this module, which is why
    nothing below calls it. Go's name, and `core.slices` pays the same price
    for the same reason.
    """
    var out = List[Tuple[K, V]](capacity=len(d))
    all_into(d, out)
    return out^


def all_into[
    K: KeyElement & Copyable & Deinitable,
    V: Copyable & Deinitable,
    H: Hasher,
    //,
](d: Dict[K, V, H], mut into: List[Tuple[K, V]]):
    """Appends every key and value in `d` to `into`, as pairs."""
    into.reserve(len(into) + len(d))
    for entry in d.items():
        into.append((entry.key.copy(), entry.value.copy()))


def keys[
    K: KeyElement & Copyable & Deinitable,
    V: Copyable & Deinitable,
    H: Hasher,
    //,
](d: Dict[K, V, H]) -> List[K]:
    """Every key in `d`, in the order `d` iterates."""
    var out = List[K](capacity=len(d))
    keys_into(d, out)
    return out^


def keys_into[
    K: KeyElement & Copyable & Deinitable,
    V: Copyable & Deinitable,
    H: Hasher,
    //,
](d: Dict[K, V, H], mut into: List[K]):
    """Appends every key in `d` to `into`."""
    into.reserve(len(into) + len(d))
    for key in d.keys():
        into.append(key.copy())


def values[
    K: KeyElement & Copyable & Deinitable,
    V: Copyable & Deinitable,
    H: Hasher,
    //,
](d: Dict[K, V, H]) -> List[V]:
    """Every value in `d`, in the order `d` iterates.

    Values are not deduplicated, so the length is `len(d)` even when two keys
    hold the same value. That is Go's behaviour and the useful one: a caller
    counting occurrences needs the repeats.
    """
    var out = List[V](capacity=len(d))
    values_into(d, out)
    return out^


def values_into[
    K: KeyElement & Copyable & Deinitable,
    V: Copyable & Deinitable,
    H: Hasher,
    //,
](d: Dict[K, V, H], mut into: List[V]):
    """Appends every value in `d` to `into`."""
    into.reserve(len(into) + len(d))
    for value in d.values():
        into.append(value.copy())


def insert[
    K: KeyElement & Copyable & Deinitable,
    V: Copyable & Deinitable,
    H: Hasher,
    o: Origin,
    //,
](mut d: Dict[K, V, H], pairs: Span[Tuple[K, V], o]):
    """Puts every pair in `pairs` into `d`, later pairs winning over earlier ones.

    ```mojo
    from core.maps import insert

    var ages = {"ana": 31}
    var more: List[Tuple[String, Int]] = [("bo", 27), ("ana", 32)]
    insert(ages, Span(more))
    print(ages["ana"])  # => 32
    ```

    A key already in `d` is overwritten, which is what assigning to it would
    do and what Go's `Insert` does. The pairs are copied rather than moved,
    because a span is a view and cannot give its elements away.
    """
    for i in range(len(pairs)):
        d[pairs[i][0].copy()] = pairs[i][1].copy()


def collect[
    K: KeyElement & Copyable & Deinitable,
    V: Copyable & Deinitable,
    o: Origin,
    //,
](pairs: Span[Tuple[K, V], o]) -> Dict[K, V]:
    """A new dict holding every pair in `pairs`, later pairs winning over earlier ones.

    The result uses the default hasher. A dict with another hasher is built
    empty and filled with `insert`, because the hasher is a parameter of the
    result and there is nothing in the argument to infer it from.
    """
    var out = Dict[K, V](capacity=len(pairs))
    insert(out, pairs)
    return out^
