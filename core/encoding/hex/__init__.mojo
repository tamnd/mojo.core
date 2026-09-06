"""Hexadecimal encoding and decoding. Go's `encoding/hex`.

```mojo
from core.encoding.hex import decode_string, encode_to_string

def main():
    print(encode_to_string("hello".as_bytes()))  # 68656c6c6f
    print(String(from_utf8=decode_string("68656c6c6f")))  # hello
```

Two characters to the byte, high nibble first, lowercase on the way out and
either case accepted on the way in. There is no alphabet to choose and no
padding to decide, which makes this the smallest package in this directory and
the one whose length calculations cannot fail.

Mojo's standard library has `b16encode` and `b16decode` and neither is what Go
means by hex. They write and read uppercase, so a checksum printed through them
does not match the one `sha256sum` printed, and `b16encode` takes a `String`
rather than bytes, which rules out the arbitrary bytes hex exists to spell. So
this is a port, and the verdict in `docs/packages.md` changed from Wrap to Port
when the two were laid side by side.

## Doing it a piece at a time

`new_encoder` and `new_decoder` put hex over a writer and a reader. The encoder
has no `close`, because one byte is two characters and there is never a group
waiting to be completed, which makes it the one stream encoder here that cannot
be got wrong by forgetting to finish it.

## Dumps

`dump` gives the layout `hexdump -C` prints, sixteen bytes to the line with the
offset on the left and the printable characters on the right, and `dumper`
writes the same thing to a writer as the bytes arrive. A dumper does have to be
closed, since the last line is short unless the input was a multiple of sixteen.

## What comes back when it is wrong

Two things can be wrong and they are different codes. A character that is not a
hex digit raises `ErrInvalidHexByte` with the character on the record, which
`InvalidByteError.of` reads back to give Go's type and Go's message. An odd
number of characters raises `ErrLength`, Go's exported sentinel. A string that
is both is reported as the invalid character, because that comes first in the
input. Whatever decoded before the failure is already in the destination and
`errors.partial` says how much.

The stream decoder raises `ErrUnexpectedEOF` where the whole string form raises
`ErrLength`, because a stream that stopped between two characters may not have
finished arriving. That is Go's rule, documented on both sides of it there too.

## What differs from Go

Three things, all of them the shape this library uses everywhere. `InvalidByteError`
is read off a raised error with `of` rather than reached with a type assertion.
`append_encode` and `append_decode` grow a list the caller owns and return a
count, where Go's return the grown slice. And `decode` raises rather than
returning a count beside an error, with the count on `errors.partial`.
"""

from core.errors.codes import ErrLength

from .dump import Dumper, dump, dumper
from .hex import (
    append_decode,
    append_encode,
    decode,
    decode_string,
    decoded_len,
    encode,
    encode_to_string,
    encoded_len,
)
from .invalid import InvalidByteError
from .stream import Decoder, Encoder, new_decoder, new_encoder
