"""Comma separated values. Go's `encoding/csv`.

```mojo
from core.bytes import new_buffer_string
from core.encoding.csv import new_reader

def main():
    var r = new_reader(new_buffer_string('a,b\\n"c,d",e\\n'))
    var rows = r.read_all()
    print(len(rows))  # 2
    print(rows[1][0])  # c,d
```

CSV has no specification anybody agreed to before the fact. RFC 4180 was
written in 2005 to describe what programs were already doing, and it says so in
its own introduction. What this package implements is the RFC, with one
departure Go made and this keeps: records are written ending in a newline
rather than a carriage return and a newline, unless `use_crlf` is set.

A file is records separated by newlines and fields separated by commas. A field
holding a comma, a quote or a line ending is written inside quotes, and a quote
inside a quoted field is doubled. That is the whole format, and everything else
in this package is either a setting for a file that does not quite follow it or
a number saying where one stopped following it.

## What the reader forgives

Whitespace is part of a field unless `trim_leading_space` is set. A blank line
is skipped, but a line holding only spaces is not blank and is a record with
one field. A carriage return before a newline is removed, everywhere, including
inside a quoted field, so a file written on Windows and the same file written
on Linux give the same records. A bare carriage return with no newline after it
is data.

A record may span lines, because a quoted field may hold a newline. That is why
a failure reports two line numbers: `start_line` is where the record began and
`line` is where the reader gave up, and on a normal record they are the same.

## Settings

`comma` is the delimiter and may be any rune that is not a quote, a line ending
or the replacement character; a tab separated file is one assignment. `comment`
skips lines beginning with a character, and it has to begin the line, so a hash
after a space is data. `fields_per_record` is a shape check, positive to demand
a count, zero to take the count from the first record, negative for no check at
all. `lazy_quotes` takes a stray quote literally instead of refusing the file.

## What differs from Go

`read` raises rather than returning a record and an error together, so the
record Go hands back alongside `ErrFieldCount` is left on the reader and
`last_record` returns it.

`records()` is the other addition. Go's loop is a `read` and a comparison
against `io.EOF`, and leaving the comparison out ends the loop on the first
malformed row and reports nothing. `records()` hands back a `core.iter.Cursor`,
so the failure comes out of `has_next` or `next` and cannot be dropped.

`reuse_record` is not implemented and is on the deviations page. It asks for
the returned slice to share storage with the previous one, and a record here is
an owned `List[String]` handed to the caller, so there is nothing to share.
`trailing_comma` and `ErrTrailingComma` are not here either, and Go's own
documentation says both are deprecated and no longer used.

A field that is not valid UTF-8 raises `ErrNotText`. Go builds fields with
`string(b)`, which takes any bytes at all, so a Go program reading a file
written in Latin-1 gets fields it can count and compare and only notices when
it prints them. A Mojo `String` says it is UTF-8, so there is no honest way to
make one out of arbitrary bytes.

`Writer.flush` raises where Go's returns nothing and leaves the failure for
`Error` to report. `error` is still here and still answers.
"""

from core.errors.codes import ErrBareQuote, ErrFieldCount, ErrQuote

from .parse_error import ParseError
from .reader import Reader, Records, new_reader
from .writer import Writer, new_writer
