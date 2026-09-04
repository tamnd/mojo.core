"""Compiling with a cache the compiler has never used.

Mojo caches what it has already worked out, and a compile served from that
cache does not re-run the compile time interpreter. Every compile time check in
this library is a print from that interpreter, so the second compile of an
unchanged call says nothing at all. That is fine for a person waiting on a
build and wrong for a tool asserting on what the build said: the tool would
pass because the compiler stayed quiet rather than because the code is right.

The cache is keyed on the work rather than on the file, so a copy under a new
name with a comment on the end of it lands on the same entry and stays quiet.
What does work is pointing the compiler at a cache directory that is empty,
which `MODULAR_CACHE_DIR` does. On this machine that costs nothing measurable,
because the standard library arrives already compiled and the cache is only
holding our own work.
"""

from __future__ import annotations

import os
from pathlib import Path

VARIABLE = "MODULAR_CACHE_DIR"


def environment(scratch: Path) -> dict[str, str]:
    """The environment to compile in, with the cache pointed at `scratch`.

    Pass a directory that is thrown away afterwards, so that each run starts
    with nothing cached and every complaint is emitted again.
    """
    env = dict(os.environ)
    env[VARIABLE] = str(scratch)
    return env
