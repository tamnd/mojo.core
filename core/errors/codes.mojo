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
