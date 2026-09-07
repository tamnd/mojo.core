"""Numbers as bytes. Go's `encoding/binary`.

Two halves that share nothing but a package name. Fixed width numbers, where
the width is known and the only question is which end goes first, and varints,
where the width is whatever the number needs. A format usually picks one: TCP
headers and DER lengths are fixed width, protocol buffers and the Go compiler's
own export data are varints.

```mojo
from core.encoding.binary import BigEndian, append_uvarint


def frame(mut out: List[Byte], id: UInt32, length: UInt64):
    BigEndian().append_uint32(out, id)
    _ = append_uvarint(out, length)
```

`order.mojo` is the first half: a `ByteOrder` trait, an `AppendByteOrder` trait
and the three orders Go has, `LittleEndian`, `BigEndian` and `NativeEndian`.
`varint.mojo` is the second: the appending, writing and reading forms of both
the unsigned encoding and the zig zag signed one, and the two that read a
number off a `ByteReader` rather than out of a span.

Go's third half is `Read`, `Write`, `Size`, `Encode`, `Decode` and `Append`,
which take an `any` and walk its type while the program runs to work out how
many bytes it is and where each one goes. There is no such walk here, so those
six arrive as generated code, one encoder per struct, with issue 33.
"""

from .order import (
    AppendByteOrder,
    BigEndian,
    ByteOrder,
    LittleEndian,
    NativeEndian,
)
from .varint import (
    MAX_VARINT_LEN16,
    MAX_VARINT_LEN32,
    MAX_VARINT_LEN64,
    append_uvarint,
    append_varint,
    put_uvarint,
    put_varint,
    read_uvarint,
    read_varint,
    uvarint,
    varint,
)
