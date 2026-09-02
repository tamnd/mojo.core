"""The two places this repository needs a C compiler.

One is `pixi run baseline`, which asks the platform's own headers what a
structure's layout is. The other is the thread local slot that core.errors is
built on, which cannot be written in Mojo because Mojo has no global mutable
state at all.

Neither uses a compiler from the environment lockfile, because both want the
answer the host itself would give. A conda toolchain would answer for its own
headers, which is precisely the wrong question for the baseline and a
gratuitous couple of hundred megabytes for fifteen lines of C.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from lib.tree import CORE

# In order of preference. `cc` is whatever the host calls its system compiler,
# which is the one whose headers the baseline is asking about.
CANDIDATES = ("cc", "clang", "gcc")

SHIM = CORE / "errors" / "shim" / "slot.c"


def compiler() -> str | None:
    """A C compiler, or None when the host has none."""
    for name in CANDIDATES:
        found = shutil.which(name)
        if found:
            return found
    return None


def shim(into: Path) -> Path | str:
    """Compile the core.errors slot into a directory. Gives back a problem, or the object.

    Built fresh every time rather than cached. Compiling fifteen lines of C
    takes less time than deciding whether a cached copy is stale, and a cache
    keyed on the wrong thing is a class of bug that is very hard to see: the
    build keeps working while linking an object from a compiler or a platform
    that is no longer the one in front of you.
    """
    cc = compiler()
    if cc is None:
        return (
            "there is no C compiler here, and core.errors needs one to build its "
            f"thread local slot. See {SHIM.parent.relative_to(CORE.parent)}/README.md"
        )
    obj = into / "slot.o"
    built = subprocess.run(
        [cc, "-c", "-O2", "-o", str(obj), str(SHIM)], capture_output=True, text=True
    )
    if built.returncode != 0:
        return f"the core.errors slot did not compile:\n{built.stderr.strip()}"
    return obj
