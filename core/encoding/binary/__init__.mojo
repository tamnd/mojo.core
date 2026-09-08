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

`fixed.mojo` is the third: `read`, `write`, `size`, `encode`, `decode` and
`append`, which move a whole value or a whole run of them and take the width
from the type rather than from the name of the call. Go works the width out by
walking the type while the program runs; here the type is a parameter and the
walk happens while the program is built, which is the same set of values Go's
own fast path handles without reflection. Structs are the part reflection was
doing for Go, and a caller with one writes the calls a field at a time or
generates them, which is the division `core.encoding.json` makes as well.
"""

from .fixed import append, decode, encode, read, size, write
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
