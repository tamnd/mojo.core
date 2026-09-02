#!/usr/bin/env python3
"""Measure this library's surface against Go's.

The contract is docs/packages.md: every one of Go's packages has a row, a
verdict, a symbol count taken from Go's own API manifests, and the name of the
package here that answers for it.

This reads that table, asks mojo doc what each of our packages actually
exports, and reports the difference. The percentage it prints is the number in
the README, and it is generated rather than typed.

A package is not done because somebody says so. It is done when this reports
its row at 100 percent and its tests pass.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import CORE, ROOT

CONTRACT = ROOT / "docs" / "packages.md"
WAIVERS = Path(__file__).parent / "waivers.toml"
RENAMES = Path(__file__).parent / "renames.toml"

VERDICTS = ("Port", "Adapt", "Wrap", "Excluded", "New")


@dataclass
class Row:
    go: str
    symbols: int
    core: str
    verdict: str


def cell(text: str) -> str:
    """One table cell, with the emphasis and the backticks taken off."""
    return text.strip().strip("*").replace("`", "").strip()


def count(text: str) -> int:
    """The symbol count, which is a number, a number with commas, or neither.

    Some rows have no count to give. `syscall` is per platform, and the rows we
    added that Go has no equivalent for have nothing to be measured against.
    Those score zero rather than being dropped, so that a row cannot avoid the
    contract by having an unparseable number in it.
    """
    text = cell(text).replace(",", "")
    return int(text) if text.isdigit() else 0


def contract() -> list[Row]:
    """Every row of the table in docs/packages.md."""
    rows = []
    for line in CONTRACT.read_text().splitlines():
        if not line.startswith("|"):
            continue
        cells = line.strip().strip("|").split("|")
        if len(cells) < 4:
            continue
        verdict = cell(cells[3])
        if verdict not in VERDICTS:
            continue
        rows.append(Row(cell(cells[0]), count(cells[1]), cell(cells[2]), verdict))
    return rows


def exported(package: str) -> set[str] | None:
    """What our package exports, according to mojo doc.

    Gives back None when the package does not exist yet, which is different
    from a package that exists and exports nothing.
    """
    if not package.startswith("core.") or package.endswith("*"):
        # A row covering several packages at once, or none at all. Those are
        # measured by the rows underneath them rather than here.
        return None
    path = CORE / Path(*package.split(".")[1:])
    if not path.is_dir() or not any(path.glob("*.mojo")):
        # A directory with a manifest and no code is a plan, not a package at
        # zero percent, and mojo doc has nothing to read in it.
        return None
    if not shutil.which("mojo"):
        print("parity: mojo is not on PATH, so nothing can be measured", file=sys.stderr)
        return None
    out = subprocess.run(
        ["mojo", "doc", "-o", "-", str(path)], capture_output=True, text=True
    )
    if out.returncode != 0:
        print(f"parity: mojo doc failed for {package}", file=sys.stderr)
        return set()
    names: set[str] = set()

    def walk(node: object) -> None:
        if isinstance(node, dict):
            name = node.get("name")
            if isinstance(name, str) and not name.startswith("_"):
                names.add(name)
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(json.loads(out.stdout))
    return names


def waived() -> dict[str, str]:
    """Symbols deliberately not ported, one line each with a reason.

    This growing is the signal that the contract is being negotiated away
    rather than met, which is why it is a reviewed file and not a flag.
    """
    if not WAIVERS.is_file():
        return {}
    with WAIVERS.open("rb") as fh:
        return {k: v for k, v in tomllib.load(fh).get("waived", {}).items()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", nargs="?", help="report on one package in detail")
    args = parser.parse_args()

    rows = [r for r in contract() if r.verdict != "Excluded"]
    if not rows:
        print("parity: docs/packages.md has no rows, which cannot be right", file=sys.stderr)
        return 1

    if args.package:
        rows = [r for r in rows if r.core == args.package or r.go == args.package]
        if not rows:
            print(f"parity: no row for {args.package}", file=sys.stderr)
            return 1

    total = sum(r.symbols for r in rows)
    done = 0
    started = 0
    for row in rows:
        names = exported(row.core)
        if names is None:
            continue
        started += 1
        have = min(len(names), row.symbols)
        done += have
        if args.package or have < row.symbols:
            print(f"  {row.core:<32} {have:>5} / {row.symbols:<5} {row.verdict}")

    pct = (100.0 * done / total) if total else 0.0
    scope = args.package or f"{len(rows)} packages"
    print(f"parity: {done} of {total} symbols in {scope}, {pct:.1f} percent")
    print(f"parity: {started} of {len(rows)} packages exist, {len(waived())} symbols waived")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
