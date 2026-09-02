# PINS: 3. There are no closures that can be stored
# EXPECT: runs
# OUTPUT: sorted by the captured keys 1 2 0
# WHY: Section 3 says a comparison known at compile time becomes a parameter
# WHY: that monomorphizes. It does, and `core.sort` and `core.slices` are built
# WHY: on it, but only when the parameter is declared with a capture list.
# WHY: `std.builtin.sort` prints its own signature as
# WHY: `cmp_fn: def(T, T) capturing thin -> Bool`, and a wrapper that copies
# WHY: that spelling verbatim compiles and is silently wrong: the capture is
# WHY: dropped, so `by_order` below stops seeing `order` and the answer comes
# WHY: back `1 0 2` instead of `1 2 0`. No error, no warning at that spelling,
# WHY: and `@always_inline` does not rescue it. With a capture that owns heap
# WHY: memory the same shape aborts on an out of range index instead.
# WHY:
# WHY: This probe is the working half, which is the half that has to keep
# WHY: working: `capturing [_]`, forwarded through one wrapper and through two.
# WHY: The broken half is not written here because a dropped capture is
# WHY: undefined behaviour and a probe should not be. If this ever stops
# WHY: compiling or stops printing the sorted order, every comparator
# WHY: parameter in `core.sort` and `core.slices` is wrong and the package
# WHY: goes back to a comparison function pointer plus an explicit context.

from std.builtin.sort import sort


def by_less[
    T: Copyable, o: MutOrigin, //, less: def (T, T) capturing [_] -> Bool
](span: Span[T, o]):
    """One level of wrapper, which is what `core.sort` is."""
    sort[less](span)


def by_less_twice[
    T: Copyable, o: MutOrigin, //, less: def (T, T) capturing [_] -> Bool
](span: Span[T, o]):
    """Two levels, which is what `core.slices` calling `core.sort` is."""
    by_less[less](span)


def main():
    # The context a closure would capture. Sorting the indices below by these
    # keys gives 1, 2, 0, and there is no way to get that answer without
    # reading `order`, which is what makes the capture observable.
    var order = [2, 0, 1]

    @parameter
    def by_order(a: Int, b: Int) -> Bool:
        return order[a] < order[b]

    var indices = [0, 1, 2]
    by_less_twice[by_order](Span(indices))
    print(
        "sorted by the captured keys", indices[0], indices[1], indices[2]
    )
