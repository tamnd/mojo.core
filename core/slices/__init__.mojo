"""Operations on spans and lists. Go's `slices`.

```mojo
from core.slices import index, sort

var values = [5, 2, 9]
sort(Span(values))            # 2, 5, 9
print(index(Span(values), 9)) # => 2
```

`find.mojo` compares and searches, `order.mojo` sorts and binary searches,
`edit.mojo` changes a list's length, and `seq.mojo` is the iteration half.
"""

from .edit import (
    clip,
    clone,
    compact,
    compact_func,
    concat,
    delete,
    delete_func,
    grow,
    insert,
    repeat,
    replace,
    reverse,
)
from .find import (
    compare,
    compare_func,
    contains,
    contains_func,
    equal,
    equal_func,
    index,
    index_func,
    max,
    max_func,
    min,
    min_func,
)
from .order import (
    binary_search,
    binary_search_func,
    is_sorted,
    is_sorted_func,
    sort,
    sort_func,
    sort_stable_func,
)
from .seq import (
    all,
    append_seq,
    backward,
    chunk,
    collect,
    sorted,
    sorted_func,
    sorted_stable_func,
    values,
)
