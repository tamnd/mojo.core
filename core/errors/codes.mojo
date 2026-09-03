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

comptime ErrBufferFull = Code(8)
"""A delimiter was not found and the buffer is full, so `read_slice` cannot make
progress without a bigger one. The bytes stay buffered and a caller can retry
with `read_bytes`, which grows instead.

Owned by `core.bufio`, answering for Go's `bufio.ErrBufferFull`.
"""

comptime ErrInvalidUnreadByte = Code(9)
"""`unread_byte` was called when the last operation was not a successful
`read_byte`. There is nothing to put back, and quietly moving the position
instead would corrupt the stream for the next reader.

Owned by `core.bufio`, answering for Go's `bufio.ErrInvalidUnreadByte`.
"""

comptime ErrInvalidUnreadRune = Code(10)
"""`unread_rune` was called when the last operation was not a successful
`read_rune`. The same rule as `ErrInvalidUnreadByte`, kept separate because the
width to put back is different.

Owned by `core.bufio`, answering for Go's `bufio.ErrInvalidUnreadRune`.
"""

comptime ErrNegativeCount = Code(11)
"""A count that has to be zero or more was negative. `peek` and `discard` raise
this rather than treating it as zero, because a negative count is arithmetic
that went wrong somewhere above.

Owned by `core.bufio`, answering for Go's `bufio.ErrNegativeCount`.
"""

comptime ErrTooLong = Code(12)
"""A scanner token grew past the maximum it was allowed. The default ceiling is
`MAX_SCAN_TOKEN_SIZE`, and `Scanner.buffer` raises it for input that
legitimately needs more; the ceiling exists so that a stream with no delimiter
in it cannot be turned into an allocation the size of the stream.

Owned by `core.bufio`, answering for Go's `bufio.ErrTooLong`.
"""

comptime ErrNegativeAdvance = Code(13)
"""A split function asked the scanner to move backwards. That is a bug in the
split function, and it is reported rather than clamped because clamping turns
it into an infinite loop.

Owned by `core.bufio`, answering for Go's `bufio.ErrNegativeAdvance`.
"""

comptime ErrAdvanceTooFar = Code(14)
"""A split function asked the scanner to move past the end of the data it was
given. Also a bug in the split function, and also fatal rather than clamped.

Owned by `core.bufio`, answering for Go's `bufio.ErrAdvanceTooFar`.
"""

comptime ErrBadReadCount = Code(15)
"""A reader returned more bytes than the span it was handed could hold. Nothing
can be done with that answer except refuse it: the bytes are already somewhere
they do not belong, and believing the count would read past the buffer.

Owned by `core.bufio`, answering for Go's `bufio.ErrBadReadCount`.
"""

comptime ErrTooLarge = Code(16)
"""A `Buffer` was asked to grow past what can be allocated. Go panics with this
value; here it is raised, because a buffer that has run out of memory is a
condition the caller can report and the caller is the only one who knows
whether the input that caused it was theirs or somebody else's.

Owned by `core.bytes`, answering for Go's `bytes.ErrTooLarge`.
"""

comptime ErrRange = Code(17)
"""A number was well formed but too big or too small for the type it was asked
for. Go returns the clamped value alongside this, the largest magnitude the bit
size can hold with the right sign, and a raise cannot carry a value, so the
caller computes it from the bit size and the sign if they want it.

Owned by `core.strconv`, answering for Go's `strconv.ErrRange`.
"""

comptime ErrSyntax = Code(18)
"""A string was not a number of the kind that was asked for. This is the only
failure that means the input was wrong rather than merely out of reach, so it
is the one to report back to whoever supplied the text.

Owned by `core.strconv`, answering for Go's `strconv.ErrSyntax`.
"""

comptime ErrBase = Code(19)
"""A base outside 0 and 2 through 36 was asked for. Go raises this from its
internal package and then throws the sentinel away, so a caller cannot tell an
impossible base from a malformed number without reading the message. This keeps
the number, because the two failures have different culprits: the base came
from the program and the digits came from its input.

Owned by `core.strconv`. Go has no sentinel for it.
"""

comptime ErrBitSize = Code(20)
"""A bit size below 0 or above 64 was asked for. Kept for the same reason as
`ErrBase`, and it means the same thing: the argument is wrong, not the text.

Owned by `core.strconv`. Go has no sentinel for it.
"""

comptime ErrDivideByZero = Code(21)
"""A divisor was zero. Go's `Div` and `Rem` panic with the runtime's `integer
divide by zero` here, and a package this far down cannot be the one that ends
the process, so it raises instead. The three `div` functions and the three
`rem` functions are the only places in the package that can fail at all.

Owned by `core.math.bits`. Go has no sentinel for it.
"""

comptime ErrOverflow = Code(22)
"""A quotient did not fit the width it was asked for. `div64(hi, lo, y)` raises
this when `y <= hi`, which is Go's `integer overflow` panic and means the
answer needs more than 64 bits. No `rem` raises it, because a remainder always
fits, which is the whole reason Go has `Rem` beside `Div`.

Owned by `core.math.bits`. Go has no sentinel for it.
"""

comptime ErrInvalidArgument = Code(23)
"""A bound was not a bound. Every `n` function needs a range with something in it,
so `int64_n` and its siblings want a positive argument and `uint64_n` and its
siblings want a non zero one, `shuffle` and `perm` want a count that is not
negative, and `new_zipf` wants `s` above one and `v` at least one. Go panics on
all of these and returns nil for the last, and this raises, because a library
at this depth does not get to end the process and a nil no caller checks is
worse than a raise.

Owned by `core.math.rand`. Go has no sentinel for it.
"""

comptime ErrInvalidEncoding = Code(24)
"""A marshalled generator state was not one this can read back. The length is
wrong, the tag at the front is wrong, or the counter in it is past where a
counter can be. Go has this as two unexported error values, one per generator,
and neither is reachable from outside the package, so one sentinel covers both
here and the message says which generator refused.

Owned by `core.math.rand`. Go has no sentinel for it.
"""
