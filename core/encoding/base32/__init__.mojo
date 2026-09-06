"""Base32 as RFC 4648 defines it. Go's `encoding/base32`.

```mojo
from core.encoding.base32 import std_encoding

def main():
    var enc = std_encoding()
    print(enc.encode_to_string("hello".as_bytes()))  # NBSWY3DP
    print(String(from_utf8=enc.decode_string("NBSWY3DP")))  # hello
```

Two encodings, both of them the same table driven `Encoding` with a different
alphabet. `std_encoding` is the one RFC 4648 section 6 defines, twenty six
letters and the digits two to seven, which is what a TOTP secret and a SASL
identifier are written in. `hex_encoding` is the extended hex alphabet of
section 7, whose symbols sort in the same order as the values behind them, and
it is what DNSSEC names an NSEC3 record with.

Base32 costs a fifth more space than base64 and buys back a symbol set that
survives being read out loud, typed by hand, or put in a case insensitive file
name. That is the whole trade and it is why it is still around.

Go keeps the two as package variables and these are functions, because there is
no package level `var` here, design.md section 3. Building one is a fill of two
tables and no allocation. `base32.mojo` says the rest.

## Doing it a piece at a time

`new_encoder` and `new_decoder` put an encoding over a writer and a reader, for
data that does not fit in memory or has not all arrived. The encoder holds up
to four bytes back until it has a group of five, so **an encoder has to be
closed** or the last group is never written. The decoder skips newlines and
refuses anything that turns up after a padded quantum has closed the document.

## What comes back when it is wrong

A decode that meets a byte that is not in the alphabet raises with
`ErrCorruptBase32` and the offset of that byte on the record, which
`CorruptInputError.of` reads back to give Go's `CorruptInputError` and its
message. Whatever decoded before the failure is already in the destination and
`errors.partial` says how much of it there is.

Padding is where base32 refuses more than base64 does. A group is eight
characters and only five lengths of it carry whole bytes, so an input whose last
group holds one, three or six symbols is refused rather than rounded down.

## What differs from Go

Five things, and every one of them is on the deviations page with its reasons.
Go's two encodings are package variables and these are functions. Go panics in
five places, three in `NewEncoding` and two in `WithPadding`, and all five raise
`ErrBadAlphabet` here, because an alphabet can come out of a configuration file
and a library this far down does not get to end the process over one. `Encode`
returns the number of characters it wrote where Go's returns nothing.
`append_encode` and `append_decode` grow a list the caller owns and return a
count, where Go's return the grown slice. And `Decode` raises rather than
returning a count beside an error, with the count on `errors.partial`, which is
what every call in this library that has both does.
"""

from .base32 import (
    Encoding,
    NO_PADDING,
    STD_PADDING,
    hex_encoding,
    new_encoding,
    std_encoding,
)
from .corrupt import CorruptInputError
from .stream import Decoder, Encoder, new_decoder, new_encoder
