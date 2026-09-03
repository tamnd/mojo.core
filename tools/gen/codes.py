#!/usr/bin/env python3
"""Number the library's sentinel errors.

`core/errors/codes.toml` lists every sentinel, keyed by the package that owns
it. This assigns each one an integer and writes `core/errors/codes.mojo`.

The reason it is generated rather than written is uniqueness. A sentinel here
is a number on the error record, because Mojo has no comparable error value to
hold and no global mutable state to keep a run time counter in. Two packages
picking the same constant by hand makes `errors.matches(e, io.EOF)` quietly
true for an `os` error, which never crashes and is wrong. Assigning from a
position in one list makes that impossible rather than unlikely.

The numbers move when a line is inserted, which is safe only because a code
never leaves the process. `codes.toml` says so at length and `Code`'s docstring
repeats it to the person who would otherwise serialise one.
"""

from __future__ import annotations

import sys
import textwrap
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT

SOURCE = ROOT / "core" / "errors" / "codes.toml"
TARGET = "core/errors/codes.mojo"

HEADER = '''"""Every sentinel error in this library, numbered.

Generated from `codes.toml` by `tools/gen/codes.py`. Do not edit: add a line to
the TOML and run `pixi run gen`. `pixi run generated-check` fails on a diff.

The package that owns a sentinel re-exports it under its own name, so a reader
writes `io.EOF` rather than reaching in here. This module exists so that the
numbers come from one place and cannot collide.

A code is meaningless outside the process that produced it. See `Code`.
"""

from .record import Code

'''


def entries() -> list[tuple[str, str, str, str]]:
    """Every sentinel as owner, name, Go symbol and documentation, in file order.

    TOML preserves the order of the tables and of the keys inside them, which
    is what makes the numbering reproducible from the file a human edits.
    """
    with SOURCE.open("rb") as fh:
        data = tomllib.load(fh)
    out = []
    for owner, sentinels in data.items():
        for name, entry in sentinels.items():
            # `go` is optional: a sentinel this library has and Go does not
            # leaves it out rather than naming a symbol that is not there.
            out.append((owner, name, entry.get("go", ""), entry["doc"]))
    return out


def generate() -> dict[str, str]:
    """The one generated file, ready to be written or diffed."""
    lines = [HEADER]
    # One rather than zero, because `Code(0)` is how `code` reports an error
    # that was never tagged and a sentinel that compared equal to that would
    # match every untagged error in the library.
    for number, (owner, name, go, doc) in enumerate(entries(), start=1):
        lines.append(f"\ncomptime {name} = Code({number})\n")
        # Wrapped here rather than left long, because `mojo format` does not
        # reflow a docstring and a generated file that fails format-check is a
        # generated file somebody edits by hand.
        lines.append('"""' + "\n".join(textwrap.wrap(doc, width=79)) + "\n\n")
        # A sentinel with no `go` is one this library has and Go does not, so
        # there is nothing to point at and saying so is better than an empty
        # pair of backticks.
        if go:
            lines.append(f"Owned by `{owner}`, answering for Go's `{go}`.\n")
        else:
            lines.append(f"Owned by `{owner}`. Go has no sentinel for it.\n")
        lines.append('"""\n')
    return {TARGET: "".join(lines)}
