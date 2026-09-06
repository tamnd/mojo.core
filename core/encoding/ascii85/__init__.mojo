"""Four bytes to five characters, base 85. Go's `encoding/ascii85`.

```mojo
from core.encoding.ascii85 import decode, encode, max_encoded_len

def main():
    var data = "hello".as_bytes()
    var out = List[UInt8](length=max_encoded_len(len(data)), fill=0)
    var n = encode(Span(out), data)
    print(String(from_utf8=Span(out)[0:n]))  # BOu!rDZ

    var back = List[UInt8](length=8, fill=0)
    var written = 0
    var used = 0
    written, used = decode(Span(back), Span(out)[0:n], True)
    print(String(from_utf8=Span(back)[0:written]))  # hello
    print(used)  # 7, every character of the input
```

The densest of the three encodings in this directory. Eighty five to the fifth
power is a little over two hundred and fifty six to the fourth, so five
printable characters carry four bytes, where base64 spends six on three and
base32 spends eight on five. PostScript and PDF embed binary this way and the
old `btoa` tool did before them.

The alphabet is every character from `!` to `u` in value order, plus one
shorthand: four zero bytes are written `z`, because long runs of zeros are the
one pattern common enough in binary to be worth a rule. The decoder skips space
and every control character, so a document wrapped at any width reads back.

## Doing it a piece at a time

`new_encoder` and `new_decoder` put the encoding over a writer and a reader.
The encoder holds up to three bytes back waiting for a group of four, so **an
encoder has to be closed** or the last group is never written.

## What comes back when it is wrong

A decode that meets a character outside the alphabet raises with
`ErrCorruptAscii85` and the offset of that character on the record, which
`CorruptInputError.of` reads back to give Go's `CorruptInputError` and its
message. A final group of a single character is refused the same way: one
character is all overhead and spells no byte at all.

Unlike base32 and base64, nothing is in the destination when a decode is
refused, because Go's `Decode` reports zero for both of its counts in that
case, so no count goes on `errors.partial` either.

## What differs from Go

Two things, both on the deviations page. `Decode` raises rather than returning
a count beside an error. And neither `Encode` nor `Decode` handles the `<~` and
`~>` fence that ascii85 usually arrives wrapped in, which is not a difference
from Go at all, Go says the same, but it is the first thing a caller coming
from a PDF asks and it belongs where they will read it.

There is no `EncodeToString` or `DecodeString` here because there is none in
Go. The `z` shorthand makes the encoded length depend on the data, so the
convenience those would offer, sizing a buffer for you, is the part that is not
convenient.
"""

from .ascii85 import decode, encode, max_encoded_len
from .corrupt import CorruptInputError
from .stream import Decoder, Encoder, new_decoder, new_encoder
