"""Copying, filtering and comparing dicts. Go's `maps.Clone`, `Copy`, `DeleteFunc`, `Equal` and `EqualFunc`.

Nothing here is surprising and that is the point: these five are the reason
Go's `maps` package exists, since every one of them is a loop somebody would
otherwise write again slightly differently.
"""

from std.hashlib import Hasher


def clone[
    K: KeyElement & Copyable & Deinitable,
    V: Copyable & Deinitable,
    H: Hasher,
    //,
](d: Dict[K, V, H]) -> Dict[K, V, H]:
    """A new dict with the same keys and values as `d`.

    Shallow, as Go's is: a value that is itself a container is copied by
    whatever its own copy does, which for a `List` is a new list of copies and
    for a handle is a second handle to the same thing.
    """
    return d.copy()


def copy[
    K: KeyElement & Copyable & Deinitable,
    V: Copyable & Deinitable,
    H: Hasher,
    //,
](mut dst: Dict[K, V, H], src: Dict[K, V, H]):
    """Puts every key and value of `src` into `dst`, overwriting keys they share.

    ```mojo
    from core.maps import copy

    var into = {"ana": 31}
    var from_ = {"bo": 27}
    copy(into, from_)
    print(len(into))  # => 2
    ```

    Go's `Copy` takes two map types so that a `map[K]V` and a named type over
    it can be mixed. There are no named types over a `Dict` here, so both sides
    are the same type, which also means the hasher matches and each entry's
    cached hash can be reused.
    """
    dst.update(src)


def delete_func[
    K: KeyElement & Copyable & Deinitable,
    V: Copyable & Deinitable,
    H: Hasher,
    //,
    f: def(K, V) capturing[_] -> Bool,
](mut d: Dict[K, V, H]):
    """Deletes every entry of `d` that `f` answers `True` for.

    ```mojo
    from core.maps import delete_func

    var ages = {"ana": 31, "bo": 27}

    @parameter
    def young(name: String, age: Int) -> Bool:
        return age < 30

    delete_func[young](ages)
    print(len(ages))  # => 1
    ```

    The keys to delete are gathered first and deleted afterwards, so `f` sees
    every entry exactly once. Go's version deletes as it iterates, which its
    specification allows for maps and which nothing here promises about a
    `Dict`, and gathering costs one list of keys against a rule that would
    otherwise be about the implementation rather than about this function.
    """
    var doomed = List[K]()
    for entry in d.items():
        if f(entry.key, entry.value):
            doomed.append(entry.key.copy())
    for i in range(len(doomed)):
        try:
            _ = d.pop(doomed[i])
        except:
            # Unreachable: every key came out of `d` a moment ago and nothing
            # between here and there can remove one. Caught rather than
            # propagated so that this function does not raise for a case that
            # cannot happen, which would put a `try` at every call site.
            pass


def equal[
    K: KeyElement & Copyable & Deinitable,
    V: Copyable & Deinitable & Equatable,
    H: Hasher,
    //,
](a: Dict[K, V, H], b: Dict[K, V, H]) -> Bool:
    """Whether `a` and `b` have the same keys holding equal values.

    Order does not enter into it, as it does not in Go. Values are compared
    with `==`, so two NaNs are not equal and a dict holding one is not equal
    to itself; `core.cmp.compare`'s total order is the other rule and it is
    for sorting rather than for this.
    """

    @parameter
    def same(x: V, y: V) -> Bool:
        return x == y

    return equal_func[same](a, b)


def equal_func[
    K: KeyElement & Copyable & Deinitable,
    V1: Copyable & Deinitable,
    V2: Copyable & Deinitable,
    H1: Hasher,
    H2: Hasher,
    //,
    eq: def(V1, V2) capturing[_] -> Bool,
](a: Dict[K, V1, H1], b: Dict[K, V2, H2]) -> Bool:
    """Whether `a` and `b` have the same keys and `eq` accepts every pair of values.

    The two dicts may hold different value types and use different hashers,
    which is what makes this worth having over `equal`: comparing a
    `Dict[String, Int]` against a `Dict[String, String]` needs a function that
    knows both. The key type has to match, because a key of another type could
    not be looked up.

    `eq` is called at most once per key, with `a`'s value first, and not at all
    once a key is found missing.
    """
    if len(a) != len(b):
        return False
    for entry in a.items():
        var other = b.find(entry.key)
        if not other:
            return False
        if not eq(entry.value, other.value()):
            return False
    return True
