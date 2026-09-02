#!/usr/bin/env python3
"""Keep the symbol counts in docs/packages.md derived rather than typed.

The counts in that table are the parity contract, so a number somebody typed
from memory is worse than no number: it looks like a measurement. This reads
them out of tools/parity/goapi.txt, which is Go's own manifest, and writes them
into the Symbols column, the totals line and the excluded total.

Nothing else in the file is touched. The verdicts, the notes and the prose are
written by people and stay that way.

The Go package column has four shapes and all four are resolved here rather
than being special cased in the parity tool, because they exist so that the
document reads well and not because the contract has group rows in it:

    strings                             one package
    net/rpc, net/rpc/jsonrpc            a list
    crypto/md5 sha1 sha256              a package and its siblings
    net/http and 7 subpackages          a package and everything under it

A row whose Symbols cell is not a number is left alone, which is how `syscall`
keeps saying per-platform and the two rows for things Go spells in the language
keep saying none.

The two totals do not come from the table. Most of the excluded packages are in
the prose at the end of the file rather than in a row, so counting rows would
undercount them. They come from the same place the parity tool gets them: a
package is implemented when some PACKAGE.toml names it, and excluded when none
does.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT, packages

DOC = "docs/packages.md"
INDEX = ROOT / "tools" / "parity" / "goapi.txt"

VERDICTS = ("Port", "Adapt", "Wrap", "Excluded", "New")
SUBPACKAGES = re.compile(r"^(\S+) and \d+ subpackages$")
TOTALS = re.compile(r"^Totals: \*\*\d+ implemented\*\* \(.*\), \*\*\d+ excluded\*\* \(.*\)\.$")
EXCLUDED_TOTAL = re.compile(r"^(\w+[- ]\w+ packages), [\d,]+ symbols\.")


def cell(text: str) -> str:
    """One table cell, with the emphasis and the backticks taken off."""
    return text.strip().strip("*").replace("`", "").strip()


def index() -> dict[str, int]:
    """How many symbols Go exports from each of its packages."""
    counts: dict[str, int] = {}
    for line in INDEX.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        package, kind, _ = line.split("\t")
        counts.setdefault(package, 0)
        if kind != "package":
            counts[package] += 1
    return counts


def resolve(text: str, counts: dict[str, int]) -> list[str]:
    """The Go packages one cell of the first column stands for."""
    text = cell(text)
    if text == "none":
        return []
    if ", " in text:
        return text.split(", ")
    match = SUBPACKAGES.match(text)
    if match:
        base = match.group(1)
        return [base] + [p for p in counts if p.startswith(f"{base}/")]
    if " " in text:
        head, *rest = text.split()
        parent = head.rsplit("/", 1)[0]
        return [head] + [f"{parent}/{name}" for name in rest]
    return [text]


def rows(lines: list[str]) -> list[tuple[int, list[str]]]:
    """Every contract row, as its line number and its cells."""
    found = []
    for number, line in enumerate(lines):
        if not line.startswith("|"):
            continue
        cells = line.strip().strip("|").split("|")
        if len(cells) >= 4 and cell(cells[3]) in VERDICTS:
            found.append((number, cells))
    return found


def generate() -> dict[str, str]:
    if not INDEX.is_file():
        print("gen: the Go API index is not there yet, so docs/packages.md is left as it is")
        return {}

    counts = index()
    path = ROOT / DOC
    lines = path.read_text().splitlines()

    problems = []
    for number, cells in rows(lines):
        names = resolve(cells[0], counts)
        for name in names:
            if name not in counts:
                problems.append(f"{DOC} line {number + 1} names {name}, which Go does not have")
        if cell(cells[1]).replace(",", "").isdigit():
            cells[1] = f" {sum(counts.get(name, 0) for name in names):,} "
            lines[number] = "|" + "|".join(cells) + "|"

    if problems:
        raise ValueError("; ".join(problems))

    ours = {p.go for p in packages() if p.go != "none"}
    theirs = set(counts)
    for name in sorted(ours - theirs):
        problems.append(f"a PACKAGE.toml names {name}, which Go does not have")
    if problems:
        raise ValueError("; ".join(problems))

    implemented = len(ours)
    excluded = len(theirs - ours)
    # `syscall` is generated per platform from the host headers, so Go's count
    # for it measures a different thing than ours would.
    implemented_symbols = sum(counts[p] for p in ours if p != "syscall")
    excluded_symbols = sum(counts[p] for p in theirs - ours)

    for number, line in enumerate(lines):
        if TOTALS.match(line):
            lines[number] = (
                f"Totals: **{implemented} implemented** ({implemented_symbols:,} symbols, "
                f"plus generated `syscall` bindings), **{excluded} excluded** "
                f"({excluded_symbols:,} symbols)."
            )
        match = EXCLUDED_TOTAL.match(line)
        if match:
            lines[number] = EXCLUDED_TOTAL.sub(
                f"{match.group(1)}, {excluded_symbols:,} symbols.", line
            )

    return {DOC: "\n".join(lines) + "\n"}


if __name__ == "__main__":
    for rel, text in generate().items():
        print(rel, len(text.splitlines()), "lines")
