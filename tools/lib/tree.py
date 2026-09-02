"""Shared helpers for the tools.

Everything here answers questions about the shape of the repository rather than
about the code in it, so that each tool can be about its own job.
"""

from __future__ import annotations

import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "core"


@dataclass
class Package:
    """One package, as described by its PACKAGE.toml."""

    name: str
    path: Path
    tier: int = 0
    deps: list[str] = field(default_factory=list)
    unsafe: bool = False

    @property
    def sources(self) -> list[Path]:
        return sorted(self.path.rglob("*.mojo"))


def packages() -> list[Package]:
    """Every package in the tree, in name order.

    A directory under core/ without a PACKAGE.toml is not a package, it is a
    mistake, and the linter is the thing that says so. This just skips it.
    """
    found = []
    if not CORE.is_dir():
        return found
    for manifest in sorted(CORE.rglob("PACKAGE.toml")):
        with manifest.open("rb") as fh:
            data = tomllib.load(fh)
        pkg = data.get("package", {})
        found.append(
            Package(
                name=pkg.get("name", ""),
                path=manifest.parent,
                tier=int(pkg.get("tier", 0)),
                deps=list(pkg.get("deps", [])),
                unsafe=bool(pkg.get("unsafe", False)),
            )
        )
    return sorted(found, key=lambda p: p.name)


def mojo_sources() -> list[Path]:
    """Every Mojo source file that is ours, including the tests.

    tests/lint holds files that are supposed to fail the linter, so linting
    them is not the point and would fail every run. tools/lint --selftest runs
    the checks against them on purpose.
    """
    skip = ROOT / "tests" / "lint"
    out: list[Path] = []
    for base in (CORE, ROOT / "tests"):
        if base.is_dir():
            out.extend(p for p in sorted(base.rglob("*.mojo")) if skip not in p.parents)
    return out


def report(tool: str, checked: int, unit: str, problems: list[str]) -> int:
    """Print what was checked and what was wrong, and give back an exit code.

    Printing the count even when it is zero is deliberate. A tool that says
    nothing when it finds nothing is indistinguishable from a tool that is not
    running, and this repository will spend a while with very little in it.
    """
    for problem in problems:
        print(f"{tool}: {problem}", file=sys.stderr)
    if problems:
        print(f"{tool}: {len(problems)} problem(s) in {checked} {unit}", file=sys.stderr)
        return 1
    print(f"{tool}: {checked} {unit} checked, no problems")
    return 0
