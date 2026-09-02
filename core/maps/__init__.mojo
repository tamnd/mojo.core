"""Operations on dicts. Go's `maps`.

```mojo
from core.maps import keys, delete_func

var ages = {"ana": 31, "bo": 27}
print(len(keys(ages)))  # => 2
```

`seq.mojo` converts between a dict and a sequence, `ops.mojo` copies, filters
and compares. The whole package is loops that would otherwise be written again
in every program, which is what Go's `maps` is for.

Two things here are not Go's. The three producers return a `List` rather than
an iterator, because a `Dict` already has iterators and what a Go programmer
writes `slices.Collect(maps.Keys(m))` for is a list; each has an `_into`
sibling for the caller who already owns one. And the two consumers take a span
of pairs rather than a `core.iter.Cursor`, because a cursor's element type
cannot be taken apart into a key and a value.  `seq.mojo` explains both and
`docs/deviations.md` has the rows.
"""

from .ops import clone, copy, delete_func, equal, equal_func
from .seq import (
    all,
    all_into,
    collect,
    insert,
    keys,
    keys_into,
    values,
    values_into,
)
