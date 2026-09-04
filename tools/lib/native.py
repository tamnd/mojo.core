"""The two places this repository needs a C compiler.

One is `pixi run baseline`, which asks the platform's own headers what a
structure's layout is. The other is the two shims, which are the only C in the
library and which are C because neither of them can be written in Mojo: the
thread local slot core.errors is built on needs global mutable state, which
Mojo does not have at all, and the wrappers core.syscall calls need a fixed C
prototype for a variadic function, which `external_call` cannot emit. Each shim
has a README next to it saying that at length.

Neither uses a compiler from the environment lockfile, because both want the
answer the host itself would give. A conda toolchain would answer for its own
headers, which is precisely the wrong question for the baseline and a
gratuitous couple of hundred megabytes for fifty lines of C.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from lib.tree import CORE

# In order of preference. `cc` is whatever the host calls its system compiler,
# which is the one whose headers the baseline is asking about.
CANDIDATES = ("cc", "clang", "gcc")

# Every C file in the library, and the object each becomes. Both go on the link
# line of every binary the tools build, because core.errors is tier zero and
# core.syscall is reached by nearly everything above it, so working out which
# of the two a given test needs would cost more than linking an object nothing
# calls.
SHIMS = (
    CORE / "errors" / "shim" / "slot.c",
    CORE / "syscall" / "shim" / "varargs.c",
)


def compiler() -> str | None:
    """A C compiler, or None when the host has none."""
    for name in CANDIDATES:
        found = shutil.which(name)
        if found:
            return found
    return None


def shim(into: Path) -> list[Path] | str:
    """Compile the shims into a directory. Gives back a problem, or the objects.

    Built fresh every time rather than cached. Compiling fifty lines of C takes
    less time than deciding whether a cached copy is stale, and a cache keyed on
    the wrong thing is a class of bug that is very hard to see: the build keeps
    working while linking an object from a compiler or a platform that is no
    longer the one in front of you.
    """
    cc = compiler()
    if cc is None:
        return (
            "there is no C compiler here, and this library needs one to build "
            "its two shims. See "
            + " and ".join(
                f"{s.parent.relative_to(CORE.parent)}/README.md" for s in SHIMS
            )
        )
    objects = []
    for source in SHIMS:
        obj = into / (source.stem + ".o")
        built = subprocess.run(
            [cc, "-c", "-O2", "-o", str(obj), str(source)],
            capture_output=True,
            text=True,
        )
        if built.returncode != 0:
            where = source.relative_to(CORE.parent)
            return f"{where} did not compile:\n{built.stderr.strip()}"
        objects.append(obj)
    return objects


def link_flags(objects: list[Path]) -> list[str]:
    """The objects as `mojo build` arguments.

    `-Xlinker` takes one value, so a list of objects is a list of pairs rather
    than one flag with several. Written here so that the five tools that build
    a binary do not each have to know that.
    """
    out: list[str] = []
    for obj in objects:
        out += ["-Xlinker", str(obj)]
    return out
