"""Ordering, and the three questions Go's `cmp` answers about it."""


comptime Ordered = Comparable
"""Go's `cmp.Ordered`, which is Mojo's `Comparable` under Go's name.

Go writes this as a type set, `~int | ~float64 | ~string | ...`, because Go
generics have no other way to say "supports `<`". Mojo does: `Comparable` is
exactly that constraint and every builtin ordered type already conforms, so a
new trait here would be a worse version of one that exists and would leave
`Int` outside it. The name is kept because `sort` and `slices` spell their
bounds `T: Ordered` in Go and code that reads across should read the same.

`Comparable` brings `<`, `<=`, `>`, `>=`, `==` and `!=` together, which is more
than Go's set promises and never less. The one thing it does not bring is a
zero value, which is why `first_non_zero` below has a longer bound than this.
"""


def compare[T: Ordered](a: T, b: T) -> Int:
    """-1 if `a` sorts before `b`, +1 if after, 0 if neither.

    ```mojo
    from core.cmp import compare

    print(compare(1, 2))  # -1
    ```

    The NaN rules are Go's and they are not the IEEE ones. A NaN sorts before
    every non-NaN and two NaNs compare equal, so that a slice of floats has a
    total order and a sort over it terminates. IEEE says a NaN compares
    unordered with everything including itself, which makes `a < b`, `a > b`
    and `a == b` all false at once; a partition loop handed that answer three
    times about the same pair has no invariant left and runs off the end of the
    array, which is a real failure mode and not a hypothetical one.

    `a != a` is the NaN test, as it is in Go. It needs nothing from `T` beyond
    what `Ordered` already gives, and on a type with no NaN the compiler folds
    it away.

    Negative and positive zero compare equal here because they compare equal
    under `==`, which is also Go's documented answer.
    """
    if a != a:
        return 0 if b != b else -1
    if b != b:
        return 1
    if a < b:
        return -1
    if a > b:
        return 1
    return 0


def less[T: Ordered](a: T, b: T) -> Bool:
    """Whether `a` sorts before `b`, with `compare`'s NaN rules.

    Not `a < b`. A NaN on the left is less than everything, which `<` says is
    false, and a sort given `<` on floats containing a NaN is the case
    `compare` above exists to prevent.
    """
    return (a != a and b == b) or a < b


def first_non_zero[
    T: Defaultable & Equatable & Copyable & Deinitable
](*values: T) -> T:
    """The first argument that is not `T()`, or `T()` if they all are.

    Go calls this `cmp.Or`, and `or` is a Mojo keyword. The rename follows
    `errors.Is` becoming `matches`: pick the words the call already reads as
    rather than decorating the keyword. `first_non_zero(a, b)` says what it
    does at two arguments and keeps saying it at five, which `or_else` stops
    doing after two.

    ```mojo
    from core.cmp import first_non_zero

    var name = first_non_zero(String(""), String("anonymous"))
    ```

    Go's bound is `comparable`, which in Go implies a zero value because every
    Go type has one. Mojo has no such implication, so `Defaultable` is spelled
    out and `T()` is what "zero" means here. A type whose `T()` is not the
    thing a caller would call empty should not be passed to this.

    Every argument is evaluated, because Mojo has no lazy arguments and Go's
    version does not short circuit either.
    """
    var zero = T()
    for value in values:
        if value != zero:
            return value.copy()
    return zero^
