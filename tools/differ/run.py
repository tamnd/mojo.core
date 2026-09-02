#!/usr/bin/env python3
"""Run this library and an oracle against the same input, and compare.

Go's tests check the cases Go's authors thought of. This checks the cases
nobody thought of, by feeding two implementations identical generated input and
comparing byte for byte.

The parity tool checks that a symbol exists. This checks that it behaves. A
package can be at 100 percent parity and wrong, which is why the README carries
both numbers and why the divergence count is the honest one.

Areas are declared in cases.toml, one per area, naming the Mojo driver, the
oracle command and the generator. Needs a second toolchain, so it is
`pixi run -e oracle differ` and it is nightly rather than part of every commit.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT, report

CASES = Path(__file__).parent / "cases.toml"


def areas() -> dict[str, dict]:
    """The declared areas. See the table in docs/testing.md for what each finds."""
    if not CASES.is_file():
        return {}
    with CASES.open("rb") as fh:
        return tomllib.load(fh).get("area", {})


def missing_tools(area: dict) -> list[str]:
    """Oracles this host does not have. Not having one is a skip, not a failure."""
    return [name for name in area.get("needs", []) if not shutil.which(name)]


def run_area(name: str, area: dict, count: int, seed: int) -> tuple[int, list[str]]:
    """Run one area. Gives back how many inputs were compared, and the divergences."""
    mine = subprocess.run(
        [*area["mojo"], "--count", str(count), "--seed", str(seed)],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    theirs = subprocess.run(
        [*area["oracle"], "--count", str(count), "--seed", str(seed)],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    if mine.returncode != 0:
        return 0, [f"{name}: our side exited {mine.returncode}"]
    if theirs.returncode != 0:
        return 0, [f"{name}: the oracle exited {theirs.returncode}"]

    ours = mine.stdout.splitlines()
    other = theirs.stdout.splitlines()
    divergences = []
    for index, (a, b) in enumerate(zip(ours, other)):
        if a != b:
            divergences.append(f"{name} case {index} with seed {seed}: we say {a!r}, oracle says {b!r}")
    if len(ours) != len(other):
        divergences.append(f"{name}: we produced {len(ours)} lines and the oracle {len(other)}")
    return min(len(ours), len(other)), divergences


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("area", nargs="?", help="run one area")
    parser.add_argument("--count", type=int, default=10000, help="inputs per area")
    parser.add_argument("--seed", type=int, default=1, help="the seed, so a finding reproduces")
    args = parser.parse_args()

    declared = areas()
    if args.area:
        declared = {k: v for k, v in declared.items() if k == args.area}
        if not declared:
            print(f"differ: no area named {args.area}", file=sys.stderr)
            return 1
    if not declared:
        print("differ: no areas declared yet, nothing to compare")
        return 0

    compared = 0
    divergences = []
    for name, area in sorted(declared.items()):
        absent = missing_tools(area)
        if absent:
            print(f"differ: skipping {name}, this host has no {' or '.join(absent)}")
            continue
        count, found = run_area(name, area, args.count, args.seed)
        compared += count
        divergences.extend(found)

    return report("differ", compared, "inputs", divergences)


if __name__ == "__main__":
    raise SystemExit(main())
