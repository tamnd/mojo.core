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
