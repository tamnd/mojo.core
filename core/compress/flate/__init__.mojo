"""DEFLATE, the compressed format of RFC 1951. Go's `compress/flate`.

DEFLATE is what almost everything compressed is made of. `gzip` is a header, a
DEFLATE stream and a CRC. `zlib` is a smaller header, the same stream and an
Adler-32. A `.zip` entry is the same stream again with a directory around it. A
PNG image is its pixels filtered and then run through zlib. So this package is
the floor four others stand on, and it comes first in the milestone for that
reason: a half finished dependency makes four sets of tests meaningless.

## What is here and what is not

The reader is here and the writer is not yet. `new_reader` and
`new_reader_dict` hand back a `Decompressor`, which is a `core.io.Reader` and a
`core.io.Closer`, and a stream that goes wrong raises a `CorruptInputError`
saying how far it got. `InternalError` is Go's other error type and covers the
one state the decompressor has no branch for. `Reader` is Go's interface for
what a decompressor reads out of, a reader that can also hand over a single
byte.

`Writer`, `new_writer`, `new_writer_dict` and the five compression levels
arrive with the other half of issue number 37.

Two of Go's symbols are waived rather than owed and both are for the same
reason. `ReadError` and `WriteError` are marked deprecated in Go's own
documentation with the note "No longer returned", and nothing in Go's package
builds one, so nothing here could hand one back either.

## Reading is the security sensitive half

A decompressor reads bytes somebody else produced and turns them into more
bytes, so the two things that matter are that it cannot be made to allocate
without bound and that it cannot be made to hang. Neither is left to chance
here. The window is one buffer of thirty two kilobytes allocated once, the two
code length arrays are fixed size, and the overflow tables of a Huffman code
are bounded by the code's own maximum length of fifteen bits. Every loop
consumes either a bit or a byte of input. A stream that stops in the middle of
anything raises `ErrUnexpectedEOF` rather than waiting for more, and a stream
that is not DEFLATE at all raises on the first thing that does not parse.

The output is not bounded, and cannot be: a DEFLATE stream a few hundred bytes
long can name a gigabyte of output, which is the whole point of compression and
also the shape of a decompression bomb. `core.io.limit_reader` around the
decompressor is the answer, exactly as it is in Go, and it is the caller's
choice because only the caller knows what a reasonable size is.
"""

from .corrupt import CorruptInputError, InternalError
from .inflate import Decompressor, Reader, new_reader, new_reader_dict
