"""Comparing two spans, and looking through one. Go's `slices` search half.

Nothing here changes a span. Everything takes a read-only `Span` and answers a
question about it, which is why these are the functions that port with no
argument: Go's take a slice and so do these, and a Mojo `Span` is a Go slice
with the length and the ownership written down.

The `_func` variants take their comparator as a compile time parameter rather
than as a value, for the reason `core.sort` gives at length: there are no
closures that can be stored, and a parameter monomorphizes so there is nothing
to store. What a Go closure would capture, a `@parameter` closure captures.
"""

from core.cmp import Ordered, compare as cmp_compare, less as cmp_less


def equal[
    T: Equatable & Copyable, o1: Origin, o2: Origin, //
](a: Span[T, o1], b: Span[T, o2]) -> Bool:
    """Whether `a` and `b` are the same length and equal element by element.

    ```mojo
    from core.slices import equal

    var left = [1, 2, 3]
    var right = [1, 2, 3]
    print(equal(Span(left), Span(right)))  # => True
    ```

    Two empty spans are equal, and a span is equal to itself. Nothing here
    looks at where the elements live, so a span and a copy of it compare the
    same as a span and itself.
    """
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def equal_func[
    T1: Copyable,
    T2: Copyable,
    o1: Origin,
    o2: Origin,
    //,
    eq: def(T1, T2) capturing[_] -> Bool,
](a: Span[T1, o1], b: Span[T2, o2]) -> Bool:
    """Whether `a` and `b` are the same length and `eq` holds at every position.

    The element types may differ, as Go's may, which is what makes this the
    function for asking whether a span of records matches a span of keys.
    """
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if not eq(a[i], b[i]):
            return False
    return True


def compare[
    T: Ordered & Copyable, o1: Origin, o2: Origin, //
](a: Span[T, o1], b: Span[T, o2]) -> Int:
    """-1, 0 or 1 for `a` before, equal to, or after `b`, compared elementwise.

    The first position where they differ decides it. If one is a prefix of the
    other, the shorter one is first. That is Go's rule and it is the same rule
    as for strings, which is the point: a span of bytes compares here exactly
    as the string of those bytes compares.

    `core.cmp.compare`, so a NaN is before every number and two NaNs are equal.
    A comparison written with `<` and `>` would call two NaNs unordered and
    unequal at once, which no total order allows.
    """
    # Written out rather than `min(...)`, because this module defines a
    # function called `min` and it shadows the builtin for the whole file.
    var shorter = len(a) if len(a) < len(b) else len(b)
    for i in range(shorter):
        var c = cmp_compare(a[i], b[i])
        if c != 0:
            return c
    if len(a) < len(b):
        return -1
    if len(a) > len(b):
        return 1
    return 0


def compare_func[
    T1: Copyable,
    T2: Copyable,
    o1: Origin,
    o2: Origin,
    //,
    cmp: def(T1, T2) capturing[_] -> Int,
](a: Span[T1, o1], b: Span[T2, o2]) -> Int:
    """`compare`, with `cmp` deciding each pair. Length breaks the tie."""
    # Written out rather than `min(...)`, because this module defines a
    # function called `min` and it shadows the builtin for the whole file.
    var shorter = len(a) if len(a) < len(b) else len(b)
    for i in range(shorter):
        var c = cmp(a[i], b[i])
        if c != 0:
            return c
    if len(a) < len(b):
        return -1
    if len(a) > len(b):
        return 1
    return 0


def index[T: Equatable & Copyable, o: Origin, //](s: Span[T, o], v: T) -> Int:
    """The first position of `v` in `s`, or -1.

    -1 rather than `len(s)`, which is the opposite of `core.sort.search`, and
    both are Go's. The difference is that a search answers where a value would
    go and this answers whether it is there, so a not-found that looks like a
    position would be the wrong shape.
    """
    for i in range(len(s)):
        if s[i] == v:
            return i
    return -1


def index_func[
    T: Copyable, o: Origin, //, f: def(T) capturing[_] -> Bool
](s: Span[T, o]) -> Int:
    """The first position where `f` holds, or -1."""
    for i in range(len(s)):
        if f(s[i]):
            return i
    return -1


def contains[
    T: Equatable & Copyable, o: Origin, //
](s: Span[T, o], v: T) -> Bool:
    """Whether `v` is in `s`."""
    return index(s, v) >= 0


def contains_func[
    T: Copyable, o: Origin, //, f: def(T) capturing[_] -> Bool
](s: Span[T, o]) -> Bool:
    """Whether `f` holds for any element of `s`."""
    return index_func[f](s) >= 0


def min[
    T: Ordered & Copyable & Deinitable, o: Origin, //
](s: Span[T, o]) raises -> T:
    """The smallest element of `s`. Raises if `s` is empty.

    Go panics on an empty slice and this raises, which is the standing
    translation: there is no value to return and no zero value in this library
    to return instead.

    A NaN anywhere makes the answer NaN, which is Go's rule for its `min`
    builtin and therefore for this. It is not the same rule `core.cmp.less`
    follows, and the difference is deliberate: sorting has to put a NaN
    somewhere and the front is as good as anywhere, while a minimum over data
    containing a NaN has no meaningful answer and saying so is more useful than
    quietly picking one.
    """
    if len(s) == 0:
        raise Error("slices.min: empty span")
    var m = s[0].copy()
    if m != m:
        return m^
    for i in range(1, len(s)):
        if s[i] != s[i]:
            return s[i].copy()
        if cmp_less(s[i], m):
            m = s[i].copy()
    return m^


def min_func[
    T: Copyable & Deinitable,
    o: Origin,
    //,
    cmp: def(T, T) capturing[_] -> Int,
](s: Span[T, o]) raises -> T:
    """The smallest element of `s` by `cmp`, the first of them if several tie.

    First and not any, which is Go's documented rule and is worth keeping
    because a `cmp` that ignores part of the element makes the choice
    observable: sorting records by one field and asking for the minimum gives
    back a particular record, not an arbitrary one with the right key.
    """
    if len(s) == 0:
        raise Error("slices.min_func: empty span")
    var m = s[0].copy()
    for i in range(1, len(s)):
        if cmp(s[i], m) < 0:
            m = s[i].copy()
    return m^


def max[
    T: Ordered & Copyable & Deinitable, o: Origin, //
](s: Span[T, o]) raises -> T:
    """The largest element of `s`. Raises if `s` is empty. A NaN wins."""
    if len(s) == 0:
        raise Error("slices.max: empty span")
    var m = s[0].copy()
    if m != m:
        return m^
    for i in range(1, len(s)):
        if s[i] != s[i]:
            return s[i].copy()
        if cmp_less(m, s[i]):
            m = s[i].copy()
    return m^


def max_func[
    T: Copyable & Deinitable,
    o: Origin,
    //,
    cmp: def(T, T) capturing[_] -> Int,
](s: Span[T, o]) raises -> T:
    """The largest element of `s` by `cmp`, the first of them if several tie.

    The first, as `min_func` returns the first, so the two agree rather than
    picking from opposite ends. That is Go's rule for both.
    """
    if len(s) == 0:
        raise Error("slices.max_func: empty span")
    var m = s[0].copy()
    for i in range(1, len(s)):
        if cmp(s[i], m) > 0:
            m = s[i].copy()
    return m^
