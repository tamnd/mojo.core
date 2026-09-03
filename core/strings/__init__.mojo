"""Searching and rewriting text, a builder and a reader. Go's `strings`.

Eighty two symbols, and almost none of the work happens here. A Mojo `String`
lends its bytes through `as_bytes()` without copying, so every function in this
package hands the question to the matching one in `core.bytes` and puts the
answer back into the right type. Go cannot do that: `[]byte(s)` copies the
whole string, so Go carries two implementations of `Index`, two of `Fields`,
two of everything, and they have to be kept in step by hand. Here there is one
implementation and one set of tests for it, and this package is the part of the
job that is about text rather than about bytes.

## What is a view and what is a copy

The functions that carve a string up — `trim`, `cut`, `split`, `fields` —
return a `StringSlice` into the argument, so they cost nothing and allocate
nothing. They work by asking `core.bytes` for byte offsets and cutting with
`s[byte=i:j]`, which is the standard library's own slicing operator and which
aborts if either end is not a rune boundary. That check is the safety net under
this whole package, and it can never fire from here: a search for valid text
inside valid text can only land on a boundary.

The functions that build something new — `join`, `repeat`, `replace`, `map`,
`to_upper` — return an owned `String`, because none of them produce a
subsequence of the input.

Nothing in the carving half raises, and nothing in the building half raises
either apart from `join` and `repeat`, which can be asked for a result too
large to hold. So this package reads like Go's.

## Every function takes an immutable slice

The parameter bound is `ImmOrigin` throughout, not `Origin`. That is one word
per signature and it buys `trim(s, s)`: two spans over the same mutable origin
cannot both be passed to one call, so with `Origin` bounds a caller who wants
to trim a string of its own leading characters has to fight the compiler.
Nothing here needs to write through what it is given, so nothing here asks for
the right to.

## Counting

There is no `len`. Go's `len(s)` counts bytes and reads like it counts
characters, which is the single most common Unicode bug in Go programs. This
package has three functions with three names — `count_bytes`, `count_runes`,
`count_graphemes` — and on a string with a family emoji in it they answer 28, 9
and 3. Whoever writes the call has to say which one they meant.

## Builder and Reader

`Builder` puts a string together in one allocation instead of the quadratic
`s += piece`. It is not `Copyable`, which turns the mistake Go catches with a
run time panic into a compile error.

`Reader` presents a string as an `io.Reader` and does it by forwarding to
`core.bytes.Reader`, since the bytes are already there to be read.

`Replacer` runs many replacements in a single pass, so that what one
replacement writes is never seen by the next.
"""

from core.io import Byte

from .builder import Builder
from .casing import (
    to_lower,
    to_lower_special,
    to_title,
    to_title_special,
    to_upper,
    to_upper_special,
)
from .compare import compare, equal_fold, has_prefix, has_suffix
from .counting import count_bytes, count_graphemes, count_runes
from .edit import (
    clone,
    join,
    map,
    repeat,
    replace,
    replace_all,
    to_valid_utf8,
)
from .reader import Reader, new_reader
from .replacer import Replacer, new_replacer
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
