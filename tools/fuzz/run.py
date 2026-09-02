#!/usr/bin/env python3
"""Run the fuzz targets.

Every parser that reads bytes it did not produce is a target, and the list is
not short. The assertion for all of them is the same and it is weaker than it
looks: any input either parses or raises. Never aborts, never allocates without
bound, never loops forever.

Mojo's bounds checking makes a memory safety finding unlikely, which moves the
value here to resource exhaustion and to the differential oracle, where a
divergence is a finding even when neither side misbehaved.

Corpora live under tests/fuzz/<target>/ and are checked in, seeded from Go's. A
crash becomes a regression test with the input and a comment saying what it
did, which is the only way a fuzzer finding stays fixed.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT, report

TARGETS = ROOT / "tests" / "fuzz"


def targets(only: str | None) -> list[Path]:
    """Every fuzz target source, which is a file named fuzz_*.mojo."""
    if not TARGETS.is_dir():
        return []
    found = sorted(TARGETS.rglob("fuzz_*.mojo"))
    if only:
        found = [p for p in found if p.stem == f"fuzz_{only}" or p.stem == only]
    return found


def corpus(target: Path) -> Path:
    """The checked in corpus for a target, which may not exist yet."""
    return target.parent / target.stem.removeprefix("fuzz_")


def run(target: Path, seconds: int, scratch: Path) -> str | None:
    """Build and run one target under libFuzzer for a fixed time."""
    binary = scratch / target.stem
    built = subprocess.run(
        ["mojo", "build", "-I", str(ROOT), "--sanitize", "fuzzer", "-o", str(binary), str(target)],
        capture_output=True,
        text=True,
    )
    if built.returncode != 0:
        detail = (built.stdout + built.stderr).strip().splitlines()
        return f"{target.stem} did not build: {detail[0] if detail else 'no output'}"

    seeds = corpus(target)
    command = [str(binary), f"-max_total_time={seconds}", "-print_final_stats=1"]
    if seeds.is_dir():
        command.append(str(seeds))
    out = subprocess.run(command, capture_output=True, text=True, cwd=scratch)
    print(out.stderr.strip()[-2000:])
    if out.returncode != 0:
        # libFuzzer writes the reproducer next to where it ran. Keep it, because
        # the input is the whole finding.
        kept = []
        for found in scratch.glob("crash-*"):
            destination = seeds if seeds.is_dir() else target.parent
            shutil.copyfile(found, destination / found.name)
            kept.append(str((destination / found.name).relative_to(ROOT)))
        where = ", ".join(kept) if kept else "no reproducer was written"
        return f"{target.stem} found a crash. Reproducer: {where}"
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", nargs="?", help="run one target")
    parser.add_argument("--seconds", type=int, default=60, help="time per target")
    args = parser.parse_args()

    found = targets(args.target)
    if not found:
        print("fuzz: no targets yet")
        return 0
    if not shutil.which("mojo"):
        print("fuzz: mojo is not on PATH", file=sys.stderr)
        return 1

    problems = []
    with tempfile.TemporaryDirectory() as scratch:
        for target in found:
            failure = run(target, args.seconds, Path(scratch))
            if failure:
                problems.append(failure)

    return report("fuzz", len(found), "targets", problems)


if __name__ == "__main__":
    raise SystemExit(main())
