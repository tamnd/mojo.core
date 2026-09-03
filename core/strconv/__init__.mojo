"""Numbers to text and back, and Go quoted strings. Go's `strconv`.

Forty three symbols in four families: the parsers, `parse_bool`, `parse_int`,
`parse_uint`, `atoi` and `parse_float`; the formatters, `format_bool`,
`format_int`, `format_uint`, `itoa` and `format_float`; the quoting half, which
is `quote` and `unquote` and the variants that decide what an unprintable rune
turns into; and `NumError`, the record that says which call failed and on what
input.

```mojo
from core.strconv import format_float, parse_int

var n = parse_int("-42", 10, 64)
print(format_float(0.1 + 0.2, UInt8(ord("g")), -1, 64))
```

## Failure

Go returns a value and an error together, so a caller who ignores the error
still gets the clamped result. Here a failure is a raise, so there is no value
to hand back with it. The raise carries `ErrSyntax` when the text was not a
number of the kind asked for and `ErrRange` when it was one that does not fit,
and `NumError.of(e)` recovers the call, the input and the code from the error
record. A caller who wants Go's clamped value computes it from the bit size and
the sign, which is what Go does internally anyway.

`ErrBase` and `ErrBitSize` are additions. Go folds both into a message with no
sentinel behind it, which leaves a caller unable to tell an impossible base from
malformed digits. They are separate here because the culprits are different: the
base came from the program and the digits came from its input.

## The append forms

`append_int`, `append_float`, `append_quote` and the rest write onto the end of
a `List[UInt8]` and return how many bytes that took, rather than returning the
grown list the way Go does. The list is already the caller's and a second name
for it is the thing that goes stale.

## The floating point half

`parse_float` is Eisel-Lemire with an exact decimal fallback, and `format_float`
is Dragonbox for the shortest form that reads back, a fixed digit path for up to
eighteen digits, and the same big decimal as the parser for anything wider. All
three are ports of what Go's `internal/strconv` does as of go1.26.7, down to the
tables, so every input prints exactly what Go prints. The arithmetic they need
is in `math.mojo` rather than in `core.math`, for the same reason Go keeps its
own copy: this package sits below that one.

`parse_complex` and `format_complex` take and return Mojo's `ComplexFloat64`
where Go takes and returns its builtin `complex128`. That is a type from the
standard library rather than from `core.math.cmplx`, which sits above this
package and could not be depended on from here.
"""

from core.errors.codes import ErrBase, ErrBitSize, ErrRange, ErrSyntax

from .atob import append_bool, format_bool, parse_bool
from .atoc import parse_complex
from .atof import parse_float
from .atoi import atoi, parse_int, parse_uint
from .ctoa import format_complex
from .ftoa import append_float, format_float
from .itoa import (
    INT_SIZE,
    append_int,
    append_uint,
    format_int,
    format_uint,
    itoa,
)
from .num_error import NumError
from .quote import (
    append_quote,
    append_quote_bytes,
    append_quote_rune,
    append_quote_rune_to_ascii,
    append_quote_rune_to_graphic,
    append_quote_to_ascii,
    append_quote_to_graphic,
    can_backquote,
    is_graphic,
    is_print,
    quote,
    quote_bytes,
    quote_rune,
    quote_rune_to_ascii,
    quote_rune_to_graphic,
    quote_to_ascii,
    quote_to_graphic,
    quoted_prefix,
    unquote,
    unquote_bytes,
    unquote_char,
)
