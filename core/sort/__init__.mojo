"""Sorting and binary search. Go's `sort`.

```mojo
from core.sort import ints, search_ints

var values = [5, 2, 9, 1]
ints(Span(values))                    # 1, 2, 5, 9
print(search_ints(Span(values), 5))   # 2
```

Three ways in, and they are the same sort underneath:

- `sort`, `stable` and `is_sorted` take an `Interface`, which is Go's three
  methods as a trait. Use it when the elements are not in one span: parallel
  arrays, a file, a database cursor.
- `slice`, `slice_stable` and `slice_is_sorted` take a span and a comparator.
  Use it for everything else.
- `ints`, `float64s`, `strings` and the `*_are_sorted` trio are the two-word
  spellings of the common cases.

`search` and `find` are binary search over a count and a predicate, and they
look at no collection at all, so the same four lines search a slice, a file or
the integers.

**This is a port, not a wrapper, and the reason is memory safety.**
`std.builtin.sort` hands the comparator elements from outside the span it was
given when the comparator is inconsistent — McIlroy's antiquicksort adversary
gets 645 of them out of a 1000 element range, which without padding around the
data is an out of range index and a dead process. Go's sort does not, at any
size, stable or not. A caller who gets the ordering wrong should get a wrong
order, not a crash, and that guarantee is most of the reason to want Go's sort.
So `pdq.mojo` and `stable.mojo` are Go's pdqsort and SymMerge, ported.
`docs/deviations.md` has the measurement and issue #16 has the reproducer.

**A comparator is a compile time parameter, not a value.** Go's `sort.Slice`
takes a closure and `sort.Interface` takes a dynamic value; here both become
parameters that monomorphize, so there is nothing to store and nothing to
indirect through. What a Go closure would capture, a `@parameter` closure
captures. `tools/probe/probes/comparator_capture_list.mojo` pins the one
subtlety, which is that the parameter must be spelled `capturing [_]` and that
spelling it `capturing` compiles and silently loses the capture.

**`sort.Slice`'s reflection is gone.** Go passes the slice as `any` and uses
reflection to swap elements. The element type is a parameter here, so the swap
is generated and design.md section 8 stays true.

`Reverse` holds a pointer rather than a value, because holding a value would
sort a copy and hand the caller back an unchanged slice with no error.

`pdq.mojo` is the unstable sort, `stable.mojo` the stable one, `interface.mojo`
the trait and the wrappers Go ships with it, `slice.mojo` the span entry points
and `search.mojo` the binary searches.
"""

from .interface import (
    Float64Slice,
    IntSlice,
    Interface,
    Reverse,
    StringSlice,
    is_sorted,
    sort,
    stable,
)
from .search import find, search, search_float64s, search_ints, search_strings
from .slice import (
    float64s,
    float64s_are_sorted,
    ints,
    ints_are_sorted,
    slice,
    slice_is_sorted,
    slice_stable,
    strings,
    strings_are_sorted,
)
