"""Ordering. Go's `cmp`.

Four symbols, and all four exist so that a sort has one answer to "which of
these comes first" instead of three.

```mojo
from core.cmp import compare, first_non_zero, less

print(compare(2, 1))                       # 1
print(less(Float64(1.0), Float64(2.0)))    # True
print(first_non_zero(0, 0, 9))             # 9
```

`Ordered` is Mojo's `Comparable` under Go's name rather than a new trait,
because a new one would exclude `Int`. `compare` and `less` differ from `<` on
exactly one input, a NaN, and that input is the reason they are here: IEEE says
a NaN is unordered with everything, so `a < b`, `a > b` and `a == b` are false
together and a partition loop told that about the same pair three times has no
invariant left. Go gives NaN a place in the order instead, first, and so do
these.

`Or` is `first_non_zero`, because `or` is a Mojo keyword.
`parity/renames.toml` records it next to `errors.Is` becoming `matches`, which
is the same trade: the keyword is gone and the call still reads as English.

This package depends on nothing, which is why the sort that needs it can sit
one tier up.
"""

from .compare import Ordered, compare, first_non_zero, less
