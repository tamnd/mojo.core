#!/usr/bin/env python3
"""Build each package against only what it declares.

A library that only ever builds as a whole has a dependency graph nobody has
tested. Every package here is supposed to be usable on its own, so this builds
each one in a scratch tree containing that package and its transitive
dependencies and nothing else. An import the manifest did not declare fails to
resolve, which is exactly what should happen.

With no argument it does every package, which is what CI runs. With a name it
does one: `pixi run pkg core.json`.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import CORE, ROOT, Package, packages, report


def closure(pkg: Package, by_name: dict[str, Package]) -> list[Package] | str:
    """Everything pkg needs, or the name of a dependency that does not exist."""
    seen: dict[str, Package] = {}
    queue = [pkg]
    while queue:
        current = queue.pop()
        if current.name in seen:
            continue
        seen[current.name] = current
        for name in current.deps:
            if name not in by_name:
                return name
            queue.append(by_name[name])
    return sorted(seen.values(), key=lambda p: p.name)


def build(pkg: Package, by_name: dict[str, Package]) -> str | None:
    """Build one package alone. Gives back a problem, or None."""
    needed = closure(pkg, by_name)
    if isinstance(needed, str):
        return f"{pkg.name} declares {needed}, which is not a package in this tree"

    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch)
        for dep in needed:
            shutil.copytree(dep.path, root / dep.path.relative_to(ROOT))
        out = subprocess.run(
            ["mojo", "package", str(root / pkg.path.relative_to(ROOT)),
             "-I", str(root), "-o", str(root / f"{pkg.name}.mojopkg")],
            capture_output=True,
            text=True,
        )
    if out.returncode != 0:
        detail = (out.stdout + out.stderr).strip().splitlines()
        first = detail[0] if detail else "no output"
        return f"{pkg.name} does not build with only its {len(needed) - 1} declared deps: {first}"
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", nargs="?", help="build one package")
    args = parser.parse_args()

    if not CORE.is_dir():
        print("pkg: no packages yet")
        return 0
    pkgs = packages()
    by_name = {p.name: p for p in pkgs}
    if args.package:
        if args.package not in by_name:
            print(f"pkg: no package named {args.package}", file=sys.stderr)
            return 1
        pkgs = [by_name[args.package]]
    if not pkgs:
        print("pkg: no packages yet")
        return 0
    if not shutil.which("mojo"):
        print("pkg: mojo is not on PATH", file=sys.stderr)
        return 1

    problems = []
    for pkg in pkgs:
        failure = build(pkg, by_name)
        if failure:
            problems.append(failure)
        else:
            print(f"pkg: {pkg.name} builds standalone")

    return report("pkg", len(pkgs), "packages", problems)


if __name__ == "__main__":
    raise SystemExit(main())
