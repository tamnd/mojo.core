"""UTF-8, over bytes rather than over text. Go's `unicode/utf8`.

Eighteen functions and constants of arithmetic. No tables, no generator and no
dependency on the Unicode character database, which is why this is here in M2
rather than with the range tables in #19: three M2 packages need a decoder and
none of them can have one without it. `core/bufio/_rune.mojo` was a private
copy written to get around that, and it is gone.

The whole package works on `Span[UInt8]` and not on `String`, and that is the
point of it rather than an implementation detail. A `String` is already valid
UTF-8, so a decoder over one would have nothing to decide; the interesting
input is bytes that came off a socket or a disk and may be anything at all.
The four `_in_string` functions exist so a Go programmer finds the name they
looked for, and each is one line.

## The rule everything rests on

Input that is not valid UTF-8 decodes to `RUNE_ERROR` with a size of exactly
one, never zero and never the length of the malformed sequence. So a decode
loop always terminates, a stream of rubbish produces one replacement per byte,
and where to resynchronise stays the caller's decision. `decode.mojo` says why
that last part matters.

The corollary catches people: `RUNE_ERROR` is also an ordinary code point that
valid input can contain. `decode_rune` returning it does not mean the input was
bad. The size does — one means the decoder produced it, three means the input
did — and `valid` is written that way for exactly this reason.

## The files

- `limits.mojo`: the four constants and the surrogate range.
- `decode.mojo`: reading runes out of bytes, counting them, and validity.
- `encode.mojo`: writing them, and the two questions to ask first.
"""

from .decode import (
    decode_last_rune,
    decode_last_rune_in_string,
    decode_rune,
    decode_rune_in_string,
    full_rune,
    full_rune_in_string,
    rune_count,
    rune_count_in_string,
    rune_start,
    valid,
    valid_string,
)
from .encode import append_rune, encode_rune, rune_len, valid_rune
from .limits import MAX_RUNE, RUNE_ERROR, RUNE_SELF, UTF_MAX
