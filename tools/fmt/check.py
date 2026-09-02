#!/usr/bin/env python3
"""Check formatting without changing anything the caller can see.

`mojo format` has no check mode, so this copies the tree to a scratch
directory, formats the copy, and compares. Formatting in place and then asking
git what moved would work too, but it fails badly for anyone running this with
a dirty tree, and CI should not be the only place a tool is correct.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT, mojo_sources, report


def main() -> int:
    sources = mojo_sources()
    if not sources:
        return report("format-check", 0, "source files", [])
    if not shutil.which("mojo"):
        print("format-check: mojo is not on PATH", file=sys.stderr)
        return 1

    problems = []
    with tempfile.TemporaryDirectory() as scratch:
        for src in sources:
            copy = Path(scratch) / src.relative_to(ROOT)
            copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, copy)
            before = copy.read_bytes()
            out = subprocess.run(
                ["mojo", "format", "-q", str(copy)], capture_output=True, text=True
            )
            if out.returncode != 0:
                problems.append(f"{src.relative_to(ROOT)} could not be formatted")
                continue
            if copy.read_bytes() != before:
                problems.append(f"{src.relative_to(ROOT)} is not formatted, run `pixi run format`")

    return report("format-check", len(sources), "source files", problems)


if __name__ == "__main__":
    raise SystemExit(main())
