#!/usr/bin/env python3
"""Measure this library's surface against Go's.

Go ships a machine readable list of its own exported API, one file per release
under `$GOROOT/api`, maintained by Go's authors and checked by Go's own build.
That is the contract this library is measured against, condensed into
goapi.txt by tools/gen/goapi.py.

For each package under core/ this takes the Go package its PACKAGE.toml names,
looks up every symbol Go exports from it, applies the naming rules in rules.py,
and asks `mojo doc` what we actually export. It prints what is missing, what is
extra, and what is present under a name the rules did not predict.

A package is not done because somebody says so. It is done when this reports it
at 100 percent and its tests pass.

Two escape hatches, both files rather than flags. waivers.toml lists symbols
deliberately not ported, with a reason each. renames.toml lists the names the
rules could not derive. Both are reviewed like code, and this prints the size
of the waivers file on every run so that it growing is visible.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).parent))

from lib.tree import ROOT, Package, packages, report
from rules import mojo_name, renames

INDEX = Path(__file__).parent / "goapi.txt"
WAIVERS = Path(__file__).parent / "waivers.toml"
README = ROOT / "README.md"

BEGIN = "<!-- parity:begin -->"
END = "<!-- parity:end -->"

# Members are Owner.Member, and a Mojo name that starts with one underscore is
# private. Two underscores is an operator, which is public surface.
PRIVATE = re.compile(r"^_[^_]")

# Whether we have already said Mojo is missing. Once is a warning, once per
# package is a hundred and thirty five lines of the same warning.
TOLD = False


@dataclass
class Symbol:
    """One thing Go exports, and what it is called here."""

    package: str
    kind: str
    go: str
    mojo: str
    renamed: bool = False
    waived: str = ""


@dataclass
class Result:
    """One of our packages, measured."""

    package: Package
    owed: list[Symbol] = field(default_factory=list)
    have: set[str] | None = None

    @property
    def wanted(self) -> list[Symbol]:
        return [s for s in self.owed if not s.waived]

    @property
    def present(self) -> list[Symbol]:
        return [s for s in self.wanted if self.have is not None and s.mojo in self.have]

    @property
    def missing(self) -> list[Symbol]:
        return [s for s in self.wanted if self.have is not None and s.mojo not in self.have]

    @property
    def extra(self) -> list[str]:
        if self.have is None:
            return []
        return sorted(self.have - {s.mojo for s in self.owed})


def index() -> dict[str, list[tuple[str, str]]]:
    """Go's exported API, by package, from the checked in index.

    A package with no symbols is still a key here, because `time/tzdata` is a
    real package that exports nothing and a mistyped package name is not.
    """
    if not INDEX.is_file():
        return {}
    found: dict[str, list[tuple[str, str]]] = {}
    for line in INDEX.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        package, kind, name = line.split("\t")
        found.setdefault(package, [])
        if kind != "package":
            found[package].append((kind, name))
    return found


def go_version() -> str:
    """The Go release the index was built from, for the summary line."""
    for line in INDEX.read_text().splitlines() if INDEX.is_file() else []:
        if line.startswith("# go1"):
            return line[2:].strip()
    return "an unrecorded Go release"


def waivers() -> dict[str, str]:
    """Symbols deliberately not ported, keyed by Go package and symbol."""
    if not WAIVERS.is_file():
        return {}
    with WAIVERS.open("rb") as fh:
        data = tomllib.load(fh)
    out: dict[str, str] = {}
    for package, entries in data.items():
        if isinstance(entries, dict):
            for name, reason in entries.items():
                out[f"{package}.{name}"] = reason
    return out


def declared(node: object, owner: str = "") -> set[str]:
    """Every public name in one `mojo doc` node, members qualified by owner.

    `mojo doc` nests functions and fields inside the struct or trait that owns
    them, and this keeps that: `Buffer.read` rather than a bare `read` that
    could have come from anywhere.
    """
    names: set[str] = set()
    if not isinstance(node, dict):
        return names

    name = node.get("name")
    kind = node.get("kind")
    if isinstance(name, str) and kind in ("struct", "trait", "function", "field", "alias"):
        if not PRIVATE.match(name):
            names.add(f"{owner}.{name}" if owner else name)
        if kind in ("struct", "trait"):
            owner = name

    for key in ("packages", "modules", "structs", "traits", "functions", "fields", "aliases"):
        children = node.get(key)
        if isinstance(children, list):
            for child in children:
                # A module is a file, not a namespace we hold anybody to, so
                # its children keep whatever owner it was reached with.
                names |= declared(child, "" if key in ("packages", "modules") else owner)
    return names


def exported(package: Package) -> set[str] | None:
    """What our package exports, according to `mojo doc`.

    None when there is nothing to ask about, which is different from a package
    that exists and exports nothing. A directory with a manifest and no code is
    a plan, not a package at zero percent.
    """
    if not package.started:
        return None
    if not shutil.which("mojo"):
        global TOLD
        if not TOLD:
            # Saying nothing here would make a machine without Mojo report zero
            # packages started and no problem, which reads exactly like a
            # library nobody has begun.
            print("parity: mojo is not on PATH, so nothing can be measured", file=sys.stderr)
            TOLD = True
        return None
    out = subprocess.run(
        ["mojo", "doc", "-o", "-", str(package.path)], capture_output=True, text=True
    )
    if out.returncode != 0:
        print(f"parity: mojo doc failed for {package.name}", file=sys.stderr)
        return set()
    return declared(json.loads(out.stdout).get("decl", {}))


def measure(go: dict[str, list[tuple[str, str]]]) -> tuple[list[Result], list[str]]:
    """Every package in the tree against its row in Go's manifests."""
    overrides = renames()
    waived = waivers()
    problems: list[str] = []
    results: list[Result] = []

    for package in packages():
        if package.go == "none":
            # core.sync.chan and core.runtime.sched answer for things Go spells
            # in the language rather than in a package. Nothing to measure.
            continue
        if package.go not in go:
            problems.append(
                f"{package.name} names go = \"{package.go}\", which is not a package in "
                f"Go's standard library. Check the spelling in {package.path.name}/PACKAGE.toml"
            )
            continue
        result = Result(package)
        for kind, name in sorted(go[package.go]):
            key = f"{package.go}.{name}"
            mojo = mojo_name(package.go, kind, name, overrides)
            result.owed.append(
                Symbol(package.go, kind, name, mojo, key in overrides, waived.get(key, ""))
            )
        result.have = exported(package)
        results.append(result)

    problems += stale(go, overrides, waived)
    return results, problems


def stale(
    go: dict[str, list[tuple[str, str]]], overrides: dict[str, str], waived: dict[str, str]
) -> list[str]:
    """Lines in the two escape hatch files that no longer point at anything.

    A waiver for a symbol Go has removed is a waiver that will never be read
    again, and a rename that agrees with the rule is a line somebody has to
    read and decide about for no reason. Both are checked, because these two
    files are the ones most likely to rot: nothing fails when they are wrong.
    """
    problems = []
    known = {f"{p}.{n}": (k, n) for p, symbols in go.items() for k, n in symbols}
    for key in sorted(set(overrides) | set(waived)):
        if key not in known:
            where = "renames.toml" if key in overrides else "waivers.toml"
            problems.append(f"{where} names {key}, which Go does not export. Remove the line")
    for key, name in sorted(overrides.items()):
        if key in known:
            kind, go_name = known[key]
            if mojo_name("", kind, go_name, {}) == name:
                problems.append(
                    f"renames.toml maps {key} to {name}, which is what the rule already "
                    "gives. Remove the line"
                )
    return problems


def detail(result: Result) -> None:
    """One package, symbol by symbol, for somebody about to port it."""
    package = result.package
    print(f"{package.name} answers for Go's {package.go}, {package.verdict}")
    if result.have is None:
        print("  no code here yet, so every symbol below is owed")

    for symbol in result.owed:
        if symbol.waived:
            status = "waived"
        elif result.have is None:
            status = "missing"
        else:
            status = "present" if symbol.mojo in result.have else "missing"
        note = " (renamed)" if symbol.renamed else ""
        print(f"  {status:<8} {symbol.mojo:<40} {symbol.kind} {symbol.go}{note}")
        if symbol.waived:
            print(f"           {symbol.waived}")

    for name in result.extra:
        print(f"  {'extra':<8} {name:<40} not in Go's {package.go}")


def block(results: list[Result], go: dict[str, list[tuple[str, str]]]) -> str:
    """The generated numbers that live in the README."""
    owed = sum(len(r.wanted) for r in results if r.package.go != "syscall")
    have = sum(len(r.present) for r in results if r.package.go != "syscall")
    started = sum(1 for r in results if r.have is not None)
    pct = (100.0 * have / owed) if owed else 0.0
    return "\n".join(
        [
            BEGIN,
            f"<!-- Generated by `pixi run parity --write` against {go_version()}. Do not edit. -->",
            "",
            "| | |",
            "| --- | --- |",
            f"| Go packages with a row | {len(go)} |",
            f"| Being implemented here | {len(results)} |",
            f"| Symbols owed | {owed:,} |",
            f"| Symbols present | {have:,} |",
            f"| Packages started | {started} |",
            f"| Parity | {pct:.1f} percent |",
            "",
            END,
        ]
    )


def readme(text: str, replacement: str) -> str | None:
    """The README with its generated block swapped, or None if it has none."""
    start = text.find(BEGIN)
    end = text.find(END)
    if start < 0 or end < 0:
        return None
    return text[:start] + replacement + text[end + len(END) :]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", nargs="?", help="report on one package, symbol by symbol")
    parser.add_argument(
        "--write", action="store_true", help="update the generated block in README.md"
    )
    args = parser.parse_args()

    go = index()
    if not go:
        print(
            "parity: goapi.txt is missing or empty. Run `pixi run gen` with Go on PATH",
            file=sys.stderr,
        )
        return 1

    results, problems = measure(go)
    if not results:
        problems.append("no package in core/ names a Go package, which cannot be right")

    if args.package:
        wanted = [r for r in results if args.package in (r.package.name, r.package.go)]
        if not wanted:
            print(f"parity: no package called {args.package}", file=sys.stderr)
            return 1
        for result in wanted:
            detail(result)

    text = block(results, go)
    current = README.read_text()
    updated = readme(current, text)
    if updated is None:
        problems.append(f"README.md has no {BEGIN} block")
    elif args.write:
        if not shutil.which("mojo"):
            # Writing zeroes over a real measurement because the machine has no
            # compiler is worse than not writing at all.
            problems.append("refusing to write the README block without Mojo to measure with")
        else:
            README.write_text(updated)
            print("parity: wrote the generated block in README.md")
    elif updated != current:
        problems.append(
            "the generated block in README.md is stale, run `pixi run parity --write`"
        )

    if not args.package:
        for result in sorted(results, key=lambda r: r.package.name):
            if result.have is not None and result.missing:
                have, owed = len(result.present), len(result.wanted)
                print(f"  {result.package.name:<32} {have:>5} / {owed:<5} {result.package.verdict}")

    for line in text.splitlines():
        if line.startswith("| ") and " --- " not in line and line.strip("| "):
            label, value = (c.strip() for c in line.strip("|").split("|")[:2])
            if label:
                print(f"parity: {label.lower()}, {value}")
    print(f"parity: {len(waivers())} symbols waived, {len(renames())} renamed by hand")

    return report("parity", len(results), "packages", problems)


if __name__ == "__main__":
    raise SystemExit(main())
