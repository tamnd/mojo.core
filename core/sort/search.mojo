"""Binary search over an index range, and the three wrappers Go ships.

Nothing here looks at a collection. `search` is handed a count and a predicate
and the predicate knows where the data is, which is what lets the same four
lines search a slice, a file, a database or the integers.
"""


def search[f: def(Int) capturing[_] -> Bool](n: Int) -> Int:
    """The smallest `i` in `[0, n)` where `f(i)` is true, or `n` if there is none.

    ```mojo
    from core.sort import search

    var data = [1, 3, 5, 7]
    var wanted = 5

    @parameter
    def at_least(i: Int) -> Bool:
        return data[i] >= wanted

    var where = search[at_least](len(data))  # 2
    ```

    `f` has to be false over a prefix of `[0, n)` and true over the rest.
    Anything else is not a question binary search can answer and the result is
    unspecified, though it is always in `[0, n]`.

    Not-found is `n`, not -1. That is Go's choice and it is the useful one: `n`
    is where the value would be inserted, so the caller who wants to insert has
    the answer and the caller who wants to know whether it was there compares
    `i < n` and checks the element.

    `f` is called only for `i` in `[0, n)`, so it may index without checking.
    """
    var i = 0
    var j = n
    while i < j:
        # Halfway, without the overflow that `(i + j) // 2` has near the top of
        # the range. Go writes it the same way.
        var h = Int(UInt(i + j) >> 1)
        if not f(h):
            i = h + 1
        else:
            j = h
    return i


def find[cmp: def(Int) capturing[_] -> Int](n: Int) -> Tuple[Int, Bool]:
    """The smallest `i` in `[0, n)` where `cmp(i) <= 0`, and whether it is 0 there.

    `cmp(i)` answers how a target compares against element `i`: positive before
    it, zero at it, negative after it. So the range has to look like a run of
    positives, then a run of zeros, then a run of negatives, any of which may
    be empty.

    The pair is Go's, and the second half is the reason to reach for this over
    `search`: `search` tells you where a value would go and leaves you to check
    whether it is there, and this does both.
    """
    var i = 0
    var j = n
    while i < j:
        var h = Int(UInt(i + j) >> 1)
        if cmp(h) > 0:
            i = h + 1
        else:
            j = h
    return (i, i < n and cmp(i) == 0)


def search_ints[o: Origin](a: Span[Int, o], x: Int) -> Int:
    """Where `x` is, or would be inserted, in an ascending span of `Int`."""

    @parameter
    def at_least(i: Int) -> Bool:
        return a[i] >= x

    return search[at_least](len(a))


def search_float64s[o: Origin](a: Span[Float64, o], x: Float64) -> Int:
    """Where `x` is, or would be inserted, in an ascending span of `Float64`.

    `>=` rather than `core.cmp`, because that is what Go's `SearchFloat64s`
    uses. On a span sorted the way `Float64Slice` sorts one, with NaNs at the
    front, a NaN target answers 0 and any other target skips over them, which
    is the same answer Go gives.
    """

    @parameter
    def at_least(i: Int) -> Bool:
        return a[i] >= x

    return search[at_least](len(a))


def search_strings[o: Origin](a: Span[String, o], x: String) -> Int:
    """Where `x` is, or would be inserted, in an ascending span of `String`."""

    @parameter
    def at_least(i: Int) -> Bool:
        return a[i] >= x

    return search[at_least](len(a))
