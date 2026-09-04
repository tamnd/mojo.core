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
import tempfile
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.native import link_flags, shim
from lib.tree import ROOT, report

CASES = Path(__file__).parent / "cases.toml"

SHOWN = 10
"""How many divergences an area prints before it only counts them."""

COUNT = 10000
"""Inputs per area, for an area that does not say what it wants."""


def areas() -> dict[str, dict]:
    """The declared areas. See the table in docs/testing.md for what each finds."""
    if not CASES.is_file():
        return {}
    with CASES.open("rb") as fh:
        return tomllib.load(fh).get("area", {})


def missing_tools(area: dict) -> list[str]:
    """Oracles this host does not have. Not having one is a skip, not a failure."""
    return [name for name in area.get("needs", []) if not shutil.which(name)]


def our_command(name: str, area: dict, scratch: Path) -> tuple[list[str], list[str]]:
    """The command that runs our side. Gives back the command, and the problems.

    An area whose driver touches `core.errors` or `core.syscall` cannot be
    `mojo run`, because the two shims those packages are built on are C that has
    to be linked in. Such an area declares `build` rather than `mojo` and this
    compiles the shims and the driver into a scratch directory first. The same
    thing `tools/mojotest/run.py` does for the test suite, for the same reason.
    """
    source = area.get("build")
    if source is None:
        return area["mojo"], []
    objects = shim(scratch)
    if isinstance(objects, str):
        return [], [f"{name}: {objects}"]
    binary = scratch / Path(source).stem
    built = subprocess.run(
        [
            "mojo",
            "build",
            "-I",
            str(ROOT),
            "-o",
            str(binary),
            *link_flags(objects),
            str(ROOT / source),
        ],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    if built.returncode != 0:
        return [], [f"{name}: our side did not build:\n{built.stderr.strip()}"]
    return [str(binary)], []


def run_area(
    name: str, area: dict, count: int, seed: int, shown: int, ours: list[str]
) -> tuple[int, list[str]]:
    """Run one area. Gives back how many inputs were compared, and the divergences.

    Both sides are started before either is waited on. They do not depend on
    each other and the exhaustive float32 area takes hours, so running them one
    after the other would spend a night doing what an evening can do.

    Each side writes to a temporary file rather than a pipe. A pipe holds a page
    or two and a program whose pipe is full stops until somebody reads it, so
    the faster side would sit blocked until the slower one finished and the two
    would be back in step.
    """
    sinks = [tempfile.TemporaryFile() for _ in range(4)]
    try:
        started = [
            subprocess.Popen(
                [*command, "--count", str(count), "--seed", str(seed)],
                stdout=sinks[index],
                stderr=sinks[index + 2],
                cwd=ROOT,
            )
            for index, command in enumerate((ours, area["oracle"]))
        ]
        codes = [process.wait() for process in started]
        for sink in sinks:
            sink.seek(0)
        written = [sink.read().decode(errors="replace") for sink in sinks]
    finally:
        for sink in sinks:
            sink.close()

    for index, side in enumerate(("our side", "the oracle")):
        if codes[index] != 0:
            return 0, [f"{name}: {side} exited {codes[index]}\n{written[index + 2].strip()}"]

    mine = written[0].splitlines()
    other = written[1].splitlines()
    divergences = []
    found = 0
    for index, (a, b) in enumerate(zip(mine, other)):
        if a != b:
            found += 1
            # One wrong table is a million wrong lines and a scrolled off
            # terminal tells you less than ten lines and a count does. The
            # first ones are the ones worth reading anyway, because a
            # divergence is usually a boundary and boundaries come in order.
            if found <= shown:
                divergences.append(
                    f"{name} case {index} with seed {seed}: we say {a!r}, oracle says {b!r}"
                )
    if found > shown:
        divergences.append(f"{name}: and {found - shown} more divergences not shown")
    if len(mine) != len(other):
        divergences.append(f"{name}: we produced {len(mine)} lines and the oracle {len(other)}")
    return min(len(mine), len(other)), divergences


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("area", nargs="?", help="run one area")
    # No default here, so that an area can declare its own and still be
    # narrowed by hand. `unicode-runes` wants every code point there is and
    # would be a much weaker check at ten thousand, but reproducing a
    # divergence means running a hundred of them.
    parser.add_argument("--count", type=int, help="inputs, overriding the area's own")
    parser.add_argument("--seed", type=int, default=1, help="the seed, so a finding reproduces")
    parser.add_argument(
        "--show", type=int, default=SHOWN, help="divergences to print before counting"
    )
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
    with tempfile.TemporaryDirectory() as tmp:
        scratch = Path(tmp)
        for name, area in sorted(declared.items()):
            absent = missing_tools(area)
            if absent:
                print(f"differ: skipping {name}, this host has no {' or '.join(absent)}")
                continue
            ours, problems = our_command(name, area, scratch)
            if problems:
                divergences.extend(problems)
                continue
            wanted = args.count if args.count is not None else area.get("count", COUNT)
            count, found = run_area(name, area, wanted, args.seed, args.show, ours)
            compared += count
            divergences.extend(found)

    return report("differ", compared, "inputs", divergences)


if __name__ == "__main__":
    raise SystemExit(main())
