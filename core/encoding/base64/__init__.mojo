"""Base64 as RFC 4648 defines it. Go's `encoding/base64`.

```mojo
from core.encoding.base64 import std_encoding

def main():
    var enc = std_encoding()
    print(enc.encode_to_string("hello".as_bytes()))  # aGVsbG8=
    print(String(from_utf8=enc.decode_string("aGVsbG8=")))  # hello
```

Four encodings, all of them the same table driven `Encoding` with two switches
set differently. `std_encoding` is the one RFC 4648 section 4 defines and the
one almost everything means by base64. `url_encoding` swaps the last two
symbols for `-` and `_` so the output can go in a URL or a file name.
`raw_std_encoding` and `raw_url_encoding` are those two without the `=` padding
on the end, which is what a format that already knows its own lengths wants.

Go keeps the four as package variables and these are functions, because there
is no package level `var` here, design.md section 3. Building one is a fill of
two tables and no allocation. `base64.mojo` says the rest.

## Doing it a piece at a time

`new_encoder` and `new_decoder` put an encoding over a writer and a reader, for
data that does not fit in memory or has not all arrived. The encoder holds up
to two bytes back until it has a group of three, so **an encoder has to be
closed** or the last group is never written. The decoder skips newlines, which
is what makes it able to read the base64 in a PEM file or a MIME body.

## What comes back when it is wrong

A decode that meets a byte that is not in the alphabet raises with
`ErrCorruptBase64` and the offset of that byte on the record, which
`CorruptInputError.of` reads back to give Go's `CorruptInputError` and its
message. Whatever decoded before the failure is already in the destination and
`errors.partial` says how much of it there is.

## What differs from Go

Five things, and every one of them is on the deviations page with its reasons.
Go's four encodings are package variables and these are functions. Go panics in
five places, three in `NewEncoding` and two in `WithPadding`, and all five raise
`ErrBadAlphabet` here, because an alphabet can come out of a configuration file
and a library this far down does not get to end the process over one. `Encode`
returns the number of characters it wrote where Go's returns nothing.
`append_encode` and `append_decode` grow a list the caller owns and return a
count, where Go's return the grown slice. And `Decode` raises rather than
returning a count beside an error, with the count on `errors.partial`, which is
what every call in this library that has both does.
"""

from .base64 import (
    Encoding,
    NO_PADDING,
    STD_PADDING,
    new_encoding,
    raw_std_encoding,
    raw_url_encoding,
    std_encoding,
    url_encoding,
)
from .corrupt import CorruptInputError
from .stream import Decoder, Encoder, new_decoder, new_encoder
