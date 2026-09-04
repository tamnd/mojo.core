#!/usr/bin/env python3
"""Keep the checked in JSON codec beside its fixture package current.

`tools/codec` writes a codec next to the structs it is generated from, and the
one under `tools/codec/testdata/inventory` is checked in so that a reader can
see what the generator writes without running it. That copy is only worth
having if it cannot fall behind the emitter, which is what this is for: `pixi
run gen` rewrites it and `pixi run generated-check` fails on a diff.

The fixture is the only package here with a checked in codec. Nothing in `core`
has one yet, and when something does it goes in the list below rather than
anywhere else.

Needs the compiler, because the whole generator is built on what `mojo doc`
says about a package. Without it this prints a line and generates nothing,
which is how `goapi.py` handles a missing Go and means `pixi run check` still
works on a machine that has neither.

Called `jsoncodec` rather than `codec` because the runner puts this directory on
the import path, and a module here called `codec` is found before the `codec`
package next door that it is trying to import.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from codec.run import OUTPUT, build
from lib.tree import ROOT

# Every package whose codec is checked in, as a path relative to the root.
PACKAGES = ("tools/codec/testdata/inventory",)


def generate() -> dict[str, str]:
    if not shutil.which("mojo"):
        print("codec: no mojo on PATH, so the generated codecs are left alone")
        return {}
    out: dict[str, str] = {}
    for package in PACKAGES:
        directory = ROOT / package
        text, problems = build(directory, [ROOT, directory.parent])
        if problems:
            raise RuntimeError(f"{package}: " + "; ".join(problems))
        out[f"{package}/{OUTPUT}"] = text
    return out


if __name__ == "__main__":
    for path, text in generate().items():
        print(path, len(text.splitlines()), "lines")
