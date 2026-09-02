"""Buffered reading and writing. Go's `bufio`.

A buffer in front of a reader turns many small reads into few large ones, and a
buffer in front of a writer does the same for writes. That is the whole idea and
it is Go's; what is different here is what the buffered bytes are allowed to
escape as.

```mojo
from core.bufio import new_reader, new_scanner
from core.io import AnyReader


def count_lines(var src: AnyReader) raises -> Int:
    var lines = new_scanner(src^)
    var n = 0
    while lines.has_next():
        _ = lines.next()
        n += 1
    return n
```

There is no `for` loop over a scanner, deliberately. `core.iter` explains it:
a `for` swallows a raise out of `__next__`, so a read failure would end the
loop looking exactly like the end of the file.

**Nothing here returns a view into a buffer.** Go's `Peek`, `ReadSlice`,
`ReadLine` and `Scanner.Bytes` all hand back a slice of memory the next call
overwrites, and the documentation asks the caller to remember. That would be a
use after free here with nothing to catch it: a `Span` outlives a mutation of
what it points at and the compiler says nothing, which
`probes/span_outlives_its_owner.mojo` pins. So every one of them returns owned
bytes. It is a copy Go does not make, and it is on `deviations.md` as a cost.

**A `Scanner` is a `core.iter.Cursor`, so it has no `Err`.** Go's scanner ends
its loop the same way whether the input finished or the disk broke, and the
difference is in an `Err()` method somewhere after the loop that is easy to
leave out — `core.iter`'s docstring names this as the flaw it exists to remove.
Here the loop ends only at the end of the input, and anything else is raised
out of it. `Scan` becomes `has_next` and `Bytes` becomes what `next` returns,
which `parity/renames.toml` records.

**A split function is a `Splitter`, not a function pointer.** Go's
`bufio.SplitFunc` is a closure, and there are no closures here that can be
stored in a field. A trait with one method does the job and does it better: the
receiver is the state the closure would have captured, and the method can be
parametric over the origin of the bytes it is shown, which a function type
cannot be. `design.md`'s section 3 has the argument. `ScanLines`, `ScanWords`,
`ScanRunes` and `ScanBytes` are structs implementing it, and a stateful splitter
— one that counts, or that changes its mind partway through — is an ordinary
struct with fields rather than something that needs a different mechanism.

**A buffered writer writes nothing until `flush`.** Go's does too, and it is
the mistake everybody makes once. There is no destructor here that will save
it, because a destructor cannot raise and a write failure swallowed on the way
out of a scope is worse than one never attempted.

`read.mojo` is the reader, `write.mojo` the writer, `scan.mojo` the scanner and
its splitters, and `rw.mojo` joins a reader and a writer into one value.
`_rune.mojo` is a private UTF-8 decoder that goes when issue #19 lands
`core.unicode.utf8`.
"""

from core.errors.codes import (
    ErrAdvanceTooFar,
    ErrBadReadCount,
    ErrBufferFull,
    ErrInvalidUnreadByte,
    ErrInvalidUnreadRune,
    ErrNegativeAdvance,
    ErrNegativeCount,
    ErrTooLong,
)

from .read import Reader, new_reader, new_reader_size
from .rw import ReadWriter, new_read_writer
from .scan import (
    MAX_SCAN_TOKEN_SIZE,
    ScanBytes,
    ScanLines,
    ScanRunes,
    ScanWords,
    Scanner,
    Split,
    Splitter,
    new_scanner,
)
from .write import Writer, new_writer, new_writer_size
