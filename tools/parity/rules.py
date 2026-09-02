#!/usr/bin/env python3
"""Turn a Go name into the Mojo name this library is expected to give it.

Port means Go's API shape in Mojo's spelling, and this is the whole of what
"Mojo's spelling" means as far as names go. Applying it mechanically is what
lets the parity tool say a symbol is missing rather than merely unrecognised.

Three rules, and they are short on purpose:

  Types, constants and variables keep Go's name. Go already spells them in a
  form Mojo accepts and renaming them would make every page of Go's
  documentation harder to read against ours for no gain.

  Functions and methods become snake case, because that is what every function
  in Mojo's own standard library is.

  Members are written `Owner.member`, on both sides, so a method cannot satisfy
  the contract by existing on the wrong type.

Anything these rules get wrong goes in renames.toml with the name it should
have. That file existing is not an admission of defeat, it is where the cases
live that a rule cannot reach: `Buffer.Len` is `Buffer.__len__` here because
Mojo spells length as an operator, and no rule about capital letters was ever
going to work that out.
"""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path

RENAMES = Path(__file__).parent / "renames.toml"

# `HTMLEscape` splits before `Escape`, `ParseURL` splits after `Parse`. Between
# them these two cover every shape Go's names come in except the ones where a
# capital run is a word on its own, and those are in renames.toml.
BEFORE_WORD = re.compile(r"(.)([A-Z][a-z]+)")
AFTER_LOWER = re.compile(r"([a-z0-9])([A-Z])")

# Kinds that keep Go's name, against kinds that become snake case.
KEEP = ("type", "const", "var")


def snake(name: str) -> str:
    """Go's CamelCase as Mojo's snake_case."""
    return AFTER_LOWER.sub(r"\1_\2", BEFORE_WORD.sub(r"\1_\2", name)).lower()


def renames() -> dict[str, str]:
    """Symbols whose Mojo name the rules could not derive.

    Keyed by the Go package and symbol together, because `Reader.Read` means
    something different in `io` than it does in `csv` and the two do not have
    to be spelled the same here.
    """
    if not RENAMES.is_file():
        return {}
    with RENAMES.open("rb") as fh:
        data = tomllib.load(fh)
    out: dict[str, str] = {}
    for package, entries in data.items():
        if not isinstance(entries, dict):
            continue
        for go, mojo in entries.items():
            out[f"{package}.{go}"] = mojo
    return out


def mojo_name(package: str, kind: str, name: str, overrides: dict[str, str]) -> str:
    """The name this library is expected to export for one Go symbol."""
    override = overrides.get(f"{package}.{name}")
    if override is not None:
        return override
    if kind in KEEP:
        return name
    if "." in name:
        owner, member = name.split(".", 1)
        return f"{owner}.{snake(member)}"
    return snake(name)


if __name__ == "__main__":
    # `python tools/parity/rules.py ReadAll` answers what a name becomes, which
    # is the question anybody porting a package asks first.
    for argument in sys.argv[1:]:
        print(f"{argument} -> {snake(argument)}")
