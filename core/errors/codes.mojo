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
