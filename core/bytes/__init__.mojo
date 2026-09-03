"""Searching and rewriting byte slices, and a growable buffer. Go's `bytes`.

Ninety nine symbols. Most of them take a `Span[Byte, o]` and answer a question
about it, and those port from Go with nothing lost: a Go `[]byte` is a Mojo
`Span[UInt8, o]` with the ownership written down, and a function that reads one
and returns an offset reads the same in both languages.

## What is a copy and what is a view

The functions that carve a slice up — `trim`, `cut`, `split`, `fields` — return
spans into their argument, exactly as Go returns subslices. That is safe and it
is free: the caller owns the bytes, this package borrowed them for the length
of the call, and the origin travels with the result so the compiler knows where
they came from.

The functions that build something new — `clone`, `join`, `repeat`, `replace`,
`to_upper`, `map` — return an owned `List[Byte]`. Go returns a `[]byte` that is
sometimes the argument and sometimes a fresh allocation; here it is always
fresh, because a return type that is sometimes a view is a return type nobody
can reason about.

`Buffer` is where this gets a rule rather than a preference. **A method never
hands out a view into the buffer's own storage.** `bytes()` returns owned bytes
and there is no view-returning accessor beside it under any name. Go documents
`Buffer.Bytes` as valid only until the next write, and in Go a program that
breaks the rule reads stale bytes out of a live allocation; here it would read
freed memory, because the next write can reallocate. `probes/
span_outlives_its_owner.mojo` pins that the compiler will not stop it.
`deviations.md` has the row, alongside the same four in `core.bufio`.

The copy is real and `Buffer` is a hot type, so there are three ways not to pay
it: `len()` and `write_to` cover reading the whole thing out, `Buffer` is an
`io.Reader` so `read` fills a span the caller already owns, and `string()`
builds the `String` directly rather than through a `List[Byte]` first.

## Rune functions and byte functions

Anything named `..._byte` works on one byte. Everything else that mentions a
character works on runes decoded from UTF-8, and always answers a byte offset.
`index_rune` finds a rune and reports where its first byte is, so the result
can be used as a slice bound without conversion. Invalid input decodes a byte
at a time as `RUNE_ERROR`, which is `core.unicode.utf8`'s rule and means none
of these functions can fail.

## The same code as core.strings

Nothing here allocates to read, and a Mojo `String` lends its bytes through
`as_bytes()` without a copy, so `core.strings` calls these functions rather
than having its own. Go has two of everything because `[]byte(s)` copies.
"""

from core.errors.codes import ErrTooLarge
from core.io import Byte

from .buffer import Buffer, MIN_READ, new_buffer, new_buffer_string
from .casing import (
    to_lower,
    to_lower_special,
    to_title,
    to_title_special,
    to_upper,
    to_upper_special,
)
from .compare import compare, equal, equal_fold, has_prefix, has_suffix
from .edit import (
    clone,
    join,
    map,
    repeat,
    replace,
    replace_all,
    runes,
    to_valid_utf8,
)
from .reader import Reader, new_reader
from .search import (
    contains,
    contains_any,
    contains_func,
    contains_rune,
    count,
    index,
    index_any,
    index_byte,
    index_func,
    index_rune,
    last_index,
    last_index_any,
    last_index_byte,
    last_index_func,
)
from .split import (
    cut,
    cut_prefix,
    cut_suffix,
    fields,
    fields_func,
    fields_func_seq,
    fields_seq,
    lines,
    split,
    split_after,
    split_after_n,
    split_after_seq,
    split_n,
    split_seq,
)
from .trim import (
    trim,
    trim_func,
    trim_left,
    trim_left_func,
    trim_prefix,
    trim_right,
    trim_right_func,
    trim_space,
    trim_suffix,
)
