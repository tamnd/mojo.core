"""Readers, writers and the fast paths between them. Go's `io`.

Two ways to hold a reader, because Mojo's traits are constraints and not
values. Code that knows its reader's concrete type is generic over `Reader` and
gets a direct call; code that genuinely does not holds an `AnyReader`, which is
a boxed value and a table of function pointers. Both satisfy `Reader`, so
`copy` covers every combination of the two without knowing which it has.

`iface.mojo` has the traits and explains the capability bits that replace Go's
type assertion for optional interfaces. `erased.mojo` has the tables and the
rule about views. `copy.mojo` is `io.Copy`.

```mojo
from core.io import AnyReader, AnyWriter, copy


def drain(var src: AnyReader, var dst: AnyWriter) raises -> Int64:
    return copy(dst, src)
```

End of input is `EOF` raised with a count of zero, and a read that moved bytes
returns them rather than raising. That is stricter than Go, which allows both
at once; `deviations.md` says why.
"""

from core.errors.codes import EOF, ErrNoProgress, ErrShortWrite

from .copy import BUFFER, copy
from .erased import AnyReader, AnyWriter, ReaderView, WriterView
from .iface import Byte, READER_FROM, Reader, WRITER_TO, Writer
