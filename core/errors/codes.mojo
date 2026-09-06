"""Every sentinel error in this library, numbered.

Generated from `codes.toml` by `tools/gen/codes.py`. Do not edit: add a line to
the TOML and run `pixi run gen`. `pixi run generated-check` fails on a diff.

The package that owns a sentinel re-exports it under its own name, so a reader
writes `io.EOF` rather than reaching in here. This module exists so that the
numbers come from one place and cannot collide.

A code is meaningless outside the process that produced it. See `Code`.
"""

from .record import Code


comptime ErrUnsupported = Code(1)
"""The operation is not supported. Go's sentinel for a method that exists so a
type satisfies an interface and then declines, such as a read only filesystem's
write.

Owned by `core.errors`, answering for Go's `errors.ErrUnsupported`.
"""

comptime EOF = Code(2)
"""No more input. Go returns this as an error and this library raises it, and in
both the meaning is an orderly end rather than a failure: a reader that has
been read to the end reports it every time from then on. A read that moved
bytes returns the count instead of raising, so this always arrives with a count
of zero. See `core.io` for why that rule is stricter than Go's.

Owned by `core.io`, answering for Go's `io.EOF`.
"""

comptime ErrShortWrite = Code(3)
"""A write accepted fewer bytes than it was given and did not say why. The count
it did accept is on `errors.partial`.

Owned by `core.io`, answering for Go's `io.ErrShortWrite`.
"""

comptime ErrNoProgress = Code(4)
"""A reader returned zero bytes without raising, from a buffer with room in it,
more than once. Go raises this after a hundred such calls; this raises on the
first, because a reader that reports no progress and no reason has a bug and
looping is not going to fix it.

Owned by `core.io`, answering for Go's `io.ErrNoProgress`.
"""

comptime ErrShortBuffer = Code(5)
"""A read needed a longer buffer than it was given. `read_at_least` raises this
when the span it was handed is smaller than the minimum it was asked to reach,
which is a caller mistake and is reported before any reading happens.

Owned by `core.io`, answering for Go's `io.ErrShortBuffer`.
"""

comptime ErrUnexpectedEOF = Code(6)
"""Input ended in the middle of something that was supposed to be whole.
`read_full` raises this when it has read some bytes and then hit the end, and
`EOF` when it read none, which is the distinction that lets a caller tell an
empty stream from a truncated one.

Owned by `core.io`, answering for Go's `io.ErrUnexpectedEOF`.
"""

comptime ErrClosedPipe = Code(7)
"""The pipe was closed at the other end. Reserved now so that the number exists
where the rest of the io sentinels are; the pipe itself waits for `core.sync`
in M4, per issue #112.

Owned by `core.io`, answering for Go's `io.ErrClosedPipe`.
"""

comptime ErrInvalid = Code(8)
"""An argument was not usable: a nil file, a name with a NUL in it, a negative
offset. It says the call was wrong rather than that the file system refused, so
it is the one of these five that never comes from a failed system call.

Owned by `core.io.fs`, answering for Go's `fs.ErrInvalid`.
"""

comptime ErrPermission = Code(9)
"""The caller is not allowed to do this. `EACCES` when the file's own bits or a
directory along the way said no, and `EPERM` when the operation is reserved to
a privileged process whatever the bits say. Ask with `is_permission` rather
than comparing an errno, since which of the two arrives depends on the
operation.

Owned by `core.io.fs`, answering for Go's `fs.ErrPermission`.
"""

comptime ErrExist = Code(10)
"""Something is already there. `EEXIST` for a create that was told not to
overwrite, and `ENOTEMPTY` for a remove or a rename that would have had to
destroy a directory's contents to succeed. Both mean the file system declined
rather than failed, and `is_exist` is the question.

Owned by `core.io.fs`, answering for Go's `fs.ErrExist`.
"""

comptime ErrNotExist = Code(11)
"""Nothing is there. `ENOENT`, which covers a missing final element and a missing
directory anywhere along the path. The commonest failure in the package and the
one `is_not_exist` exists for, because a caller who wants to create a file when
it is absent has to be able to tell this from every other reason an open can
fail.

Owned by `core.io.fs`, answering for Go's `fs.ErrNotExist`.
"""

comptime ErrClosed = Code(12)
"""The file was already closed. Not a system call failure: the descriptor is gone,
so there was nothing to call, and this is raised before anything reaches the
kernel. Reaching a closed file is a bug in the caller rather than a condition
of the file system, and saying so plainly is better than passing a stale
descriptor down and reporting whatever `EBADF` the kernel invents for it.

Owned by `core.io.fs`, answering for Go's `fs.ErrClosed`.
"""

comptime SkipDir = Code(13)
"""Do not go into this directory. Raised by a walk callback rather than by a walk,
and it is an instruction and not a failure, so the walk swallows it and carries
on with the next name. A callback that was handed a file rather than a
directory and raises this skips the rest of the directory the file is in, which
is Go's rule and is the one thing about it that surprises people. No function
in this library ever raises it at a caller.

Owned by `core.io.fs`, answering for Go's `fs.SkipDir`.
"""

comptime SkipAll = Code(14)
"""Stop the walk now, with nothing wrong. The callback is not called again and the
walk returns as though it had reached the end, so a caller who has found what
they came for does not have to invent a failure to get out. Go added it for
that reason, because before it existed every early exit from a walk looked like
an error to whoever read the code afterwards.

Owned by `core.io.fs`, answering for Go's `fs.SkipAll`.
"""

comptime ErrBufferFull = Code(15)
"""A delimiter was not found and the buffer is full, so `read_slice` cannot make
progress without a bigger one. The bytes stay buffered and a caller can retry
with `read_bytes`, which grows instead.

Owned by `core.bufio`, answering for Go's `bufio.ErrBufferFull`.
"""

comptime ErrInvalidUnreadByte = Code(16)
"""`unread_byte` was called when the last operation was not a successful
`read_byte`. There is nothing to put back, and quietly moving the position
instead would corrupt the stream for the next reader.

Owned by `core.bufio`, answering for Go's `bufio.ErrInvalidUnreadByte`.
"""

comptime ErrInvalidUnreadRune = Code(17)
"""`unread_rune` was called when the last operation was not a successful
`read_rune`. The same rule as `ErrInvalidUnreadByte`, kept separate because the
width to put back is different.

Owned by `core.bufio`, answering for Go's `bufio.ErrInvalidUnreadRune`.
"""

comptime ErrNegativeCount = Code(18)
"""A count that has to be zero or more was negative. `peek` and `discard` raise
this rather than treating it as zero, because a negative count is arithmetic
that went wrong somewhere above.

Owned by `core.bufio`, answering for Go's `bufio.ErrNegativeCount`.
"""

comptime ErrTooLong = Code(19)
"""A scanner token grew past the maximum it was allowed. The default ceiling is
`MAX_SCAN_TOKEN_SIZE`, and `Scanner.buffer` raises it for input that
legitimately needs more; the ceiling exists so that a stream with no delimiter
in it cannot be turned into an allocation the size of the stream.

Owned by `core.bufio`, answering for Go's `bufio.ErrTooLong`.
"""

comptime ErrNegativeAdvance = Code(20)
"""A split function asked the scanner to move backwards. That is a bug in the
split function, and it is reported rather than clamped because clamping turns
it into an infinite loop.

Owned by `core.bufio`, answering for Go's `bufio.ErrNegativeAdvance`.
"""

comptime ErrAdvanceTooFar = Code(21)
"""A split function asked the scanner to move past the end of the data it was
given. Also a bug in the split function, and also fatal rather than clamped.

Owned by `core.bufio`, answering for Go's `bufio.ErrAdvanceTooFar`.
"""

comptime ErrBadReadCount = Code(22)
"""A reader returned more bytes than the span it was handed could hold. Nothing
can be done with that answer except refuse it: the bytes are already somewhere
they do not belong, and believing the count would read past the buffer.

Owned by `core.bufio`, answering for Go's `bufio.ErrBadReadCount`.
"""

comptime ErrTooLarge = Code(23)
"""A `Buffer` was asked to grow past what can be allocated. Go panics with this
value; here it is raised, because a buffer that has run out of memory is a
condition the caller can report and the caller is the only one who knows
whether the input that caused it was theirs or somebody else's.

Owned by `core.bytes`, answering for Go's `bytes.ErrTooLarge`.
"""

comptime ErrRange = Code(24)
"""A number was well formed but too big or too small for the type it was asked
for. Go returns the clamped value alongside this, the largest magnitude the bit
size can hold with the right sign, and a raise cannot carry a value, so the
caller computes it from the bit size and the sign if they want it.

Owned by `core.strconv`, answering for Go's `strconv.ErrRange`.
"""

comptime ErrSyntax = Code(25)
"""A string was not a number of the kind that was asked for. This is the only
failure that means the input was wrong rather than merely out of reach, so it
is the one to report back to whoever supplied the text.

Owned by `core.strconv`, answering for Go's `strconv.ErrSyntax`.
"""

comptime ErrBase = Code(26)
"""A base outside 0 and 2 through 36 was asked for. Go raises this from its
internal package and then throws the sentinel away, so a caller cannot tell an
impossible base from a malformed number without reading the message. This keeps
the number, because the two failures have different culprits: the base came
from the program and the digits came from its input.

Owned by `core.strconv`. Go has no sentinel for it.
"""

comptime ErrBitSize = Code(27)
"""A bit size below 0 or above 64 was asked for. Kept for the same reason as
`ErrBase`, and it means the same thing: the argument is wrong, not the text.

Owned by `core.strconv`. Go has no sentinel for it.
"""

comptime ErrDivideByZero = Code(28)
"""A divisor was zero. Go's `Div` and `Rem` panic with the runtime's `integer
divide by zero` here, and a package this far down cannot be the one that ends
the process, so it raises instead. The three `div` functions and the three
`rem` functions are the only places in the package that can fail at all.

Owned by `core.math.bits`. Go has no sentinel for it.
"""

comptime ErrOverflow = Code(29)
"""A quotient did not fit the width it was asked for. `div64(hi, lo, y)` raises
this when `y <= hi`, which is Go's `integer overflow` panic and means the
answer needs more than 64 bits. No `rem` raises it, because a remainder always
fits, which is the whole reason Go has `Rem` beside `Div`.

Owned by `core.math.bits`. Go has no sentinel for it.
"""

comptime ErrInvalidArgument = Code(30)
"""A bound was not a bound. Every `n` function needs a range with something in it,
so `int64_n` and its siblings want a positive argument and `uint64_n` and its
siblings want a non zero one, `shuffle` and `perm` want a count that is not
negative, and `new_zipf` wants `s` above one and `v` at least one. Go panics on
all of these and returns nil for the last, and this raises, because a library
at this depth does not get to end the process and a nil no caller checks is
worse than a raise.

Owned by `core.math.rand`. Go has no sentinel for it.
"""

comptime ErrInvalidEncoding = Code(31)
"""A marshalled generator state was not one this can read back. The length is
wrong, the tag at the front is wrong, or the counter in it is past where a
counter can be. Go has this as two unexported error values, one per generator,
and neither is reachable from outside the package, so one sentinel covers both
here and the message says which generator refused.

Owned by `core.math.rand`. Go has no sentinel for it.
"""

comptime ErrNaN = Code(32)
"""An operation on `Float` values has no answer: adding infinities of opposite
signs, subtracting two infinities of the same sign, multiplying an infinity by
a zero, dividing zero by zero or infinity by infinity, or taking the square
root of a negative number. Go panics with an `ErrNaN` value and documents that
`Float` has no NaN, so that a program which wants one has to catch the panic;
this raises with the same meaning, and nothing here ever produces a NaN by
returning it.

Owned by `core.math.big`, answering for Go's `big.ErrNaN`.
"""

comptime ErrBadPattern = Code(33)
"""A pattern handed to `match` was malformed: a character class with nothing in
it, one that was never closed, a backslash at the very end with nothing to
escape, or a byte in a class that is not the start of a character. It says the
pattern is wrong rather than that the name failed to match, which is why
`match` reports it even when the name had already stopped agreeing. Go's
`path/filepath` shares this value, and so does `core.path.filepath`.

Owned by `core.path`, answering for Go's `path.ErrBadPattern`.
"""

comptime ErrRelPath = Code(34)
"""There is no relative route from one path to the other that can be worked out by
reading the two strings. That is `rel("..", ".")`, where the answer depends on
what the working directory is called, and `rel("/a", "a")`, where one path
starts at the root and the other does not, so nothing lexical can say how far
apart they are. Go returns an `errors.New` naming both paths and this raises
with both of them on the record, because a caller who gets this has usually
mixed an absolute path with a relative one and wants to see which is which.

Owned by `core.path.filepath`. Go has no sentinel for it.
"""

comptime ErrInvalidPath = Code(35)
"""A slash separated name will not become a path on this host. Either it is not a
name `core.io.fs.valid_path` accepts, which means it is empty, absolute,
uncleaned or not valid UTF-8, or it holds a byte the host cannot have in a file
name, which here is NUL and on Windows would be a backslash or a colon. Go has
this as the unexported `errInvalidPath` behind `filepath.Localize` and it is
the whole failure mode of that function: a name that arrived from an archive or
an untrusted request is refused rather than turned into something that names a
different file.

Owned by `core.path.filepath`. Go has no sentinel for it.
"""

comptime ErrBadLocationName = Code(36)
"""A name handed to `load_location` is not one it will look up. No IANA zone name
contains two dots in a row and none begins with a slash or a backslash, so a
name that does is a path someone assembled rather than a zone, and the lookup
would turn it into a read of a file nobody meant to name. Refused before any
source is consulted, which is what Go does with the same three tests and its
unexported `errLocation`.

Owned by `core.time`. Go has no sentinel for it.
"""

comptime ErrUnknownZone = Code(37)
"""No source had a zone by that name. Every directory in the search was consulted
and every one of them said the file was not there, which is the ordinary answer
for a misspelt name and for a host with no zone database at all. A source that
failed for some other reason raises that failure instead, so this one means the
search finished and found nothing.

Owned by `core.time`. Go has no sentinel for it.
"""

comptime ErrZoneFileTooLarge = Code(38)
"""A file in the zone search was larger than ten megabytes and was abandoned
rather than read into memory. No real zone file is within three orders of
magnitude of that, so this means the name resolved to something that is not
one: a directory of the same name, a device, or a path assembled from the wrong
pieces. Go stops at the same size with an unexported error type.

Owned by `core.time`. Go has no sentinel for it.
"""

comptime ErrBadZoneData = Code(39)
"""The bytes handed to `load_location_from_tz_data` are not a compiled zone file
this can read. The magic is wrong, the version byte is one this does not know,
a count in the header runs past the end of the data, an index names a zone the
file does not contain, or the file declares no zones at all. Go has this as an
unexported value and returns it from every one of those cases, and the split is
kept here: a caller who passed the wrong bytes cannot act on which field ran
out, and a caller who passed the right bytes never sees it.

Owned by `core.time`. Go has no sentinel for it.
"""

comptime ErrParseTime = Code(40)
"""A string did not say what the layout it was read with said it would. The text
between the pieces was not there, a piece was not a number where a number was
wanted, a name was not a month or a weekday, a field was outside its range, the
date does not exist, or there was text left over at the end. Go returns a
`*ParseError` naming which piece of the layout and which characters of the
value, and that record is here as `ParseError` and is read back with
`ParseError.of`, so this code is the question `errors.matches` answers and the
record is the detail behind it.

Owned by `core.time`. Go has no sentinel for it.
"""

comptime ErrMarshalTime = Code(41)
"""An instant cannot be written in the form that was asked for. RFC 3339 wants a
year of exactly four digits, so an instant before the year 0 or after 9999 has
no spelling in it, and it wants a zone offset whose hour is under 24, which a
fixed zone built with a whole day in it does not have. The binary form has its
own limit, a zone offset that is not between -32768 and 32767 minutes and is
not the value that marks UTC. Go returns these as three unexported errors from
`MarshalText`, `MarshalJSON` and `MarshalBinary`, and every one of them is a
fact about the instant rather than about the caller's buffer.

Owned by `core.time`. Go has no sentinel for it.
"""

comptime ErrUnmarshalTime = Code(42)
"""The bytes handed to one of the unmarshalling methods are not an instant this
can read. For the binary form that is no data at all, a version byte this does
not know, or a length that does not match the version. For the JSON form it is
a value that is not a quoted string. It is not raised for text that is a quoted
string and then fails to be RFC 3339, because that is `ErrParseTime` and the
caller wants to know which of the two went wrong.

Owned by `core.time`. Go has no sentinel for it.
"""

comptime ErrParseDuration = Code(43)
"""A string handed to `parse_duration` was not a duration. It was empty, it had a
number with no unit after it, it had a unit this does not know, or the total
did not fit. Go has this as an unexported error type whose message says which
of those it was, and the message here says the same. It is separate from
`ErrParseTime` because a duration and an instant are read by different rules,
and a caller who asked for one never wanted the other.

Owned by `core.time`. Go has no sentinel for it.
"""

comptime ErrProcessDone = Code(44)
"""The process has already finished, so there is nothing left to signal. A process
id is reused by the operating system once the entry for the old one has been
collected, so a signal sent to a process that has been waited for would
eventually reach somebody else's program. `Process` therefore remembers that it
has been collected and refuses rather than making the call, which is what Go
does with the same sentinel.

Owned by `core.os`, answering for Go's `os.ErrProcessDone`.
"""

comptime ErrNotFound = Code(45)
"""No executable of that name was found. `look_path` raises it when the name has
no slash in it and no directory on `PATH` holds a file that can be run, and
when the name does have a slash and the file it names cannot be run. The
failure is about the search rather than about one file, which is why it is a
sentinel and not the `ENOENT` of the last directory that was looked in.

Owned by `core.os.exec`, answering for Go's `exec.ErrNotFound`.
"""

comptime ErrDot = Code(46)
"""The executable was found in the current directory because `PATH` said to look
there. Running it is almost never what was meant: a directory whose contents
somebody else can write is a directory where a program named `ls` can be
waiting. Go started refusing this in 1.19 and this refuses too, and a caller
who really did mean the file in front of them says so by putting a `./` on the
front of the name, which is a path and not a search.

Owned by `core.os.exec`, answering for Go's `exec.ErrDot`.
"""

comptime ErrExit = Code(47)
"""The program ran and did not exit with zero. Go has no sentinel for this and
returns an `*exec.ExitError` instead, which a caller type asserts; there is
nothing to assert against here, so the status goes on the record and
`ExitError.of` reads it back. It means the command was found, started and
finished, which is the thing that tells it apart from every other failure this
package raises.

Owned by `core.os.exec`. Go has no sentinel for it.
"""

comptime ErrCorruptBase64 = Code(48)
"""A string was not base64. Go has this as `base64.CorruptInputError`, an integer
holding the offset of the byte that stopped the decode, which a caller reads
with a type assertion. There is nothing to assert against here, so the offset
goes on the record and `CorruptInputError.of` reads it back, and this is the
code `errors.matches` answers. Whatever was decoded before the failure is still
written to the destination and `errors.partial` says how much of it there is,
because a caller who wanted the good prefix of a bad document should not have
to decode it twice to get it.

Owned by `core.encoding.base64`. Go has no sentinel for it.
"""

comptime ErrBadAlphabet = Code(49)
"""An encoding was built out of something that is not an alphabet. Sixty four
bytes are needed, all different, none of them a carriage return or a line feed,
and a padding character that is a single byte and is not already a symbol. Go
panics on all five of those and this raises, because an alphabet can come from
a configuration file as easily as from a literal and a library this far down
does not get to end the process over one. `core.encoding.base32` raises it for
the same five, where the count is thirty two rather than sixty four.

Owned by `core.encoding.base64`. Go has no sentinel for it.
"""

comptime ErrCorruptBase32 = Code(50)
"""A string was not base32. The same thing `ErrCorruptBase64` says about the
offset, `CorruptInputError.of` and `errors.partial` applies here, and the two
are separate codes for the reason Go keeps two types: a caller decoding base32
never wanted base64, and a failure that names the wrong one names the wrong
bug. Base32 refuses in one place base64 has no equivalent for, which is a final
group of one, three or six symbols, because RFC 4648 section 6 lists the five
padding lengths that exist and those three are not among them.

Owned by `core.encoding.base32`. Go has no sentinel for it.
"""

comptime ErrLength = Code(51)
"""A hex string had an odd number of characters. Two characters spell one byte, so
the last one spells half of one, and there is no byte it could be. Go has this
as an exported sentinel and so is this, which is why a caller writing a parser
can tell a truncated string apart from a corrupt one without reading the
message. The streaming decoder raises `ErrUnexpectedEOF` in the same situation
instead, because a stream that stopped in the middle of a pair may simply not
have finished arriving, and that is Go's rule too.

Owned by `core.encoding.hex`, answering for Go's `hex.ErrLength`.
"""

comptime ErrInvalidHexByte = Code(52)
"""A byte in a hex string was not a hex digit. Go has this as
`hex.InvalidByteError`, a byte holding the offending character, which a caller
reads with a type assertion. There is nothing to assert against here, so the
byte goes on the record and `InvalidByteError.of` reads it back, and this is
the code `errors.matches` answers. Whatever was decoded before the failure is
still written to the destination and `errors.partial` says how much of it there
is. The byte is on the error rather than its offset, which is the opposite of
what the base64 and base32 codes carry, because that is what Go's two types
carry and a caller who wants the other number has the input in front of them.

Owned by `core.encoding.hex`. Go has no sentinel for it.
"""

comptime ErrDumperClosed = Code(53)
"""A hex dumper was written to after it was closed. The closing line of a dump is
written by `close`, so a write afterwards would put bytes after the end of the
dump, and the offsets in it would no longer be the offsets of anything. Go
returns an unexported error here with the same meaning and this raises. Closing
twice is not a failure on either side; only writing after closing is.

Owned by `core.encoding.hex`. Go has no sentinel for it.
"""

comptime ErrCorruptAscii85 = Code(54)
"""A string was not ascii85. The same thing `ErrCorruptBase64` says about the
offset and `CorruptInputError.of` applies here, and this is the third of the
three for the reason Go keeps three types: a caller decoding ascii85 never
wanted base64. Nothing goes on `errors.partial`, because Go's `Decode` returns
zero for both of its counts when it refuses, so a caller is told that nothing
was decoded rather than that a prefix was. Two things are refused: a character
outside the range `!` to `u` that is not whitespace, and a final group holding
a single character, which carries no whole byte because the encoding needs one
character more than the bytes it spells.

Owned by `core.encoding.ascii85`. Go has no sentinel for it.
"""

comptime ErrHeaderKeyColon = Code(55)
"""A block was handed to `encode` with a colon in one of its header keys. A header
line is a key, a colon, a space and a value, so a key with a colon in it would
be read back as a shorter key with a longer value, and the block would not
survive a round trip. Go returns an unexported error from `Encode` here and
returns nil from `EncodeToMemory`, and both are refused before a single byte is
written, so a writer that has already been written to is never left holding
half a block.

Owned by `core.encoding.pem`. Go has no sentinel for it.
"""

comptime ErrBareQuote = Code(56)
"""A quote appeared inside a field that did not start with one. `a"b` is not a
quoted field and it is not a field holding a quote either, because there is no
rule that would say which, so it is refused. Setting `lazy_quotes` on the
reader says take it literally and this is never raised. Go has this as an
exported sentinel carried inside a `*ParseError` and so is this: the code is on
the raise and `ParseError.of` reads the line and column back off it.

Owned by `core.encoding.csv`, answering for Go's `csv.ErrBareQuote`.
"""

comptime ErrQuote = Code(57)
"""A quoted field held a quote that was not doubled, or never closed. Inside
quotes a quote means one of two things, the end of the field when what follows
is a comma or a line ending, and a literal quote when it is doubled; anything
else is neither. The unterminated field at the end of the input is the same
failure, since the field ended without the quote that would have closed it.
`lazy_quotes` takes both literally instead. Go has this as an exported sentinel
inside a `*ParseError` and so is this.

Owned by `core.encoding.csv`, answering for Go's `csv.ErrQuote`.
"""

comptime ErrFieldCount = Code(58)
"""A record had a different number of fields than the ones before it. Only raised
when `fields_per_record` is positive, either because the caller set it or
because the first record set it, and never when it is negative. Go returns the
record alongside this error, which a raise cannot do, so the record is left on
the reader and `last_record` hands it back; that call is the whole reason the
method exists, since a caller who set a field count usually wants to see the
row that broke it.

Owned by `core.encoding.csv`, answering for Go's `csv.ErrFieldCount`.
"""

comptime ErrInvalidDelim = Code(59)
"""A reader or a writer was given a field or comment delimiter it cannot use. A
delimiter may not be zero, a quote, a carriage return, a newline or the
replacement character, and it may not be an invalid code point; a reader's
comment may not equal its comma either. Go has this unexported, so a Go caller
can only read the message, and it is a code here because a caller who builds a
delimiter from configuration wants to tell a bad setting apart from a bad file.

Owned by `core.encoding.csv`. Go has no sentinel for it.
"""

comptime ErrNotText = Code(60)
"""A field held bytes that are not valid UTF-8. Go builds its fields with
`string(b)`, which takes any bytes at all, so a Go program reading a file
written in Latin-1 gets fields it can count and compare and only notices when
it tries to print them. A Mojo `String` says it is UTF-8, so there is no honest
way to make one out of arbitrary bytes and the read is refused instead.
`bufio.Reader.read_string` is stricter than Go for the same reason and says the
same thing about the two alternatives, substituting U+FFFD or asserting the
encoding without checking, neither of which this library does on a caller's
behalf. The bytes are consumed either way, since the line that failed has
already been read.

Owned by `core.encoding.csv`. Go has no sentinel for it.
"""
