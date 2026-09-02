#!/usr/bin/env python3
"""The linter.

Four checks, each defending something that a convention alone will not. Every
one of them exists because of a specific way this library can go wrong, and the
reasons are written next to the checks rather than in a commit message.

Run with --selftest to check the checks. A lint that has stopped matching
anything reports success forever, so each check is also run against a fixture
that is supposed to fail, and the linter fails if the fixture passes.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT, Package, mojo_sources, packages, report

# Operations that only a package declaring itself unsafe may name.
UNSAFE_NAMES = ("Pointer", "external_call", "unsafe_bitcast", "unsafe_take_allocation")

# The machines the longer suites run on are private. Their names live in an
# environment file that is not checked in, and this is the check that they have
# not been pasted into the tree by accident. The patterns come from the same
# environment file when it is present, so this repository never has to contain
# the thing it is looking for.
SECRET_ENV = ROOT / ".fleet.env"

IMPORT = re.compile(r"^\s*(?:from|import)\s+(core(?:\.[a-z_0-9]+)*)", re.M)
FALLIBLE_NEXT = re.compile(r"^\s*def\s+__next__\s*\([^)]*\)[^:]*\braises\b", re.M)
MUST_CALL = re.compile(r"\b(must_[a-z_0-9]+)\s*\(\s*([^)]*)\)")


def check_layering(pkgs: list[Package]) -> list[str]:
    """Every import declared, and every declaration used.

    Both directions, because a stale declaration is how a dependency graph
    quietly becomes wrong: nothing breaks, and the manifest stops describing
    the code it is supposed to describe.
    """
    problems = []
    known = {p.name for p in pkgs}
    for pkg in pkgs:
        declared = set(pkg.deps)
        used = set()
        for src in pkg.sources:
            for name in IMPORT.findall(src.read_text()):
                # An import of a subpackage counts as an import of the package.
                owner = max((k for k in known if name.startswith(k)), key=len, default=name)
                if owner != pkg.name:
                    used.add(owner)
        for name in sorted(used - declared):
            problems.append(f"{pkg.name} imports {name} without declaring it")
        for name in sorted(declared - used):
            problems.append(f"{pkg.name} declares {name} and never imports it")
        for name in sorted(declared):
            dep = next((p for p in pkgs if p.name == name), None)
            if dep and dep.tier > pkg.tier:
                problems.append(
                    f"{pkg.name} is tier {pkg.tier} and depends on {name} at tier {dep.tier}"
                )
    return problems


def check_unsafe(pkgs: list[Package]) -> list[str]:
    """Raw pointers and foreign calls only where they are declared.

    The count of unsafe packages is reported rather than merely allowed,
    because that number going up is a thing to notice.
    """
    problems = []
    unsafe_count = 0
    for pkg in pkgs:
        if pkg.unsafe:
            unsafe_count += 1
            continue
        for src in pkg.sources:
            text = src.read_text()
            for name in UNSAFE_NAMES:
                if re.search(rf"\b{name}\b", text):
                    rel = src.relative_to(ROOT)
                    problems.append(f"{rel} names {name} in a package that is not unsafe")
    if pkgs:
        print(f"lint: {unsafe_count} of {len(pkgs)} packages declare unsafe")
    return problems


def check_iteration(sources: list[Path]) -> list[str]:
    """No __next__ that raises.

    A Mojo for loop silently drops an error raised out of __next__, so an
    iterator that can fail reports a clean end of input and the program carries
    on with half the data. Fallible iteration is has_next and next instead.
    """
    problems = []
    for src in sources:
        if FALLIBLE_NEXT.search(src.read_text()):
            rel = src.relative_to(ROOT)
            problems.append(
                f"{rel} has a __next__ that raises. Use has_next and next, "
                "because a for loop swallows that error."
            )
    return problems


def check_must_calls(sources: list[Path]) -> list[str]:
    """A must_ call on anything other than a literal.

    A must_ function aborts, and a Mojo program cannot catch an abort. On a
    literal that is a constant the programmer has asserted. On a variable it is
    a crash waiting for the right input, and there is a fallible sibling.
    """
    problems = []
    for src in sources:
        for line_no, line in enumerate(src.read_text().splitlines(), 1):
            for name, arg in MUST_CALL.findall(line):
                arg = arg.strip()
                if arg and not (arg.startswith('"') or arg.startswith("'")):
                    rel = src.relative_to(ROOT)
                    problems.append(
                        f"{rel}:{line_no} calls {name} on something that is not a "
                        "literal. Use the fallible sibling."
                    )
    return problems


def check_no_private_hostnames() -> list[str]:
    """The private machine names are not in the tree.

    The patterns are read from an environment file that is not checked in, so
    that this repository never contains the thing it is looking for. With no
    such file present there is nothing to check, which is the normal case for
    anybody who is not running the private fleet.
    """
    if not SECRET_ENV.is_file():
        return []
    needles = [
        line.split("=", 1)[1].strip().strip("\"'")
        for line in SECRET_ENV.read_text().splitlines()
        if "=" in line and not line.lstrip().startswith("#")
    ]
    needles = [n for n in needles if len(n) >= 4]
    problems = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or ".git/" in str(path) or path == SECRET_ENV:
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for needle in needles:
            if needle in text:
                problems.append(f"{path.relative_to(ROOT)} contains a private host name")
    return problems


def selftest() -> int:
    """Run each check against a fixture that is supposed to fail.

    Without this, a check whose regular expression stopped matching would
    report success forever and nobody would find out.
    """
    fixtures = ROOT / "tests" / "lint"
    if not fixtures.is_dir():
        print("lint selftest: no fixtures yet, nothing to prove")
        return 0
    failures = []
    cases = {
        "fallible_next": check_iteration,
        "must_on_variable": check_must_calls,
    }
    for name, check in cases.items():
        path = fixtures / f"{name}.mojo"
        if not path.is_file():
            failures.append(f"missing fixture {path.relative_to(ROOT)}")
            continue
        if not check([path]):
            failures.append(f"{name} fixture was accepted, so that check is dead")
    return report("lint selftest", len(cases), "checks", failures)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true", help="check the checks")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    pkgs = packages()
    sources = mojo_sources()
    problems = (
        check_layering(pkgs)
        + check_unsafe(pkgs)
        + check_iteration(sources)
        + check_must_calls(sources)
        + check_no_private_hostnames()
    )
    return report("lint", len(sources), "source files", problems)


if __name__ == "__main__":
    raise SystemExit(main())
