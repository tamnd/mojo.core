"""Blocks of base64 between two dashed lines. Go's `encoding/pem`.

```mojo
from core.encoding.pem import decode

def main():
    var doc = String(
        "-----BEGIN MESSAGE-----\n"
        "aGVsbG8gd29ybGQ=\n"
        "-----END MESSAGE-----\n"
    )
    var got = decode(doc.as_bytes())
    if got[0]:
        print(got[0].value().type)  # MESSAGE
        print(String(from_utf8=Span(got[0].value().bytes)))  # hello world
    print(len(got[1]))  # 0, there was nothing after the block
```

PEM is the wrapper almost every TLS key and certificate arrives in, and the
only reason it exists is that binary does not survive being pasted into a mail
message or a configuration file. It came out of Privacy Enhanced Mail, a 1993
standard nobody deployed, and RFC 1421 is still the document that describes it.

The block and the rest come back as a pair rather than as two names, because a
`Block` holds a list and this library does not copy one of those without being
asked: `got[0]` is the block, `got[1]` is what follows it.

There are three symbols and one type here, which is the whole of Go's package.
It is a container format and not a parser: what comes out of a block is bytes,
and turning those bytes into a key or a certificate is somebody else's job.

## Reading a file with more than one block

`decode` finds the first block and hands back everything after it, so a
certificate chain is a loop rather than a split:

```mojo
from core.encoding.pem import decode

def main():
    var document = String(
        "-----BEGIN A-----\nQQ==\n-----END A-----\n"
        "-----BEGIN B-----\nQg==\n-----END B-----\n"
    )
    var rest = document.as_bytes().as_imm()
    while True:
        var got = decode(rest)
        rest = got[1]
        if not got[0]:
            break
        print(got[0].value().type)  # A, then B
```

Anything that is not a block is skipped: text before the first one, text
between two of them, and text after the last one. That is deliberate and it is
what lets a certificate be pasted into the middle of an email and still be
found. A block that cannot be read, because its closing line names a different
type or its base64 is corrupt, is skipped the same way, and the search carries
on after it rather than stopping.

## What comes back when it is wrong

`decode` never fails. A document with no readable block in it gives nothing and
hands the whole document back, which is the condition the loop above stops on.

`encode` and `encode_to_memory` refuse one thing, a header key with a colon in
it, and raise `ErrHeaderKeyColon`. A header line is a key, a colon, a space and
a value, so such a key would be read back as a shorter key with a longer value.
The check happens before a byte is written, so a writer is never left holding
half a block.

## What differs from Go

Two things, both on the deviations page. `encode_to_memory` raises where Go
returns nil, which removes the case Go's own documentation tells callers to use
`Encode` to diagnose. And a type line or a header that is not valid UTF-8 makes
the block unreadable here, where Go builds a string holding those bytes,
because a Mojo `String` is UTF-8 by construction. The block is skipped, not
refused, so a document holding one is read exactly as if the block were damaged
in any other way.

Headers are written with `Proc-Type` first and everything else sorted by key,
which is what Go does and is not part of the format. It is there so that
encoding the same block twice gives the same bytes.
"""

from .pem import Block, decode, encode, encode_to_memory
