#!/usr/bin/env python3
"""The linter.

Each check defends something that a convention alone will not, and each one
exists because of a specific way this library can go wrong. The reasons are
written next to the checks rather than in a commit message, so that somebody
who finds a check inconvenient can read what it is for before deleting it.

Run with --selftest to check the checks. A lint that has stopped matching
anything reports success forever, so each check is also run against a fixture
that is supposed to fail, and the linter fails if the fixture passes.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT, Package, mojo_sources, packages, report

# Operations that only a package declaring itself unsafe may name. Raw
# pointers, foreign calls, reinterpretation and untracked allocation are the
# four ways a Mojo program stops being memory safe, and each of them is spelled
# with a name you can grep for, which is the whole reason this check is cheap.
#
# Pointer and UnsafePointer are both here because Mojo 1.0 renamed the second
# to the first and kept the old name working with a deprecation. A word
# boundary match on Pointer does not find UnsafePointer, so dropping either one
# would leave a hole.
UNSAFE_NAMES = (
    "Pointer",
    "UnsafePointer",
    "OpaquePointer",
    "external_call",
    "stack_allocation",
    "__mlir_op",
)

# Everything the standard library spells with an `unsafe_` prefix, matched as a
# family rather than named one at a time. There are fifty odd of them today and
# the set grows with the language, so a hand written list is a list that is
# quietly out of date, and the two that used to be on the list above by name are
# covered here instead.
#
# This is also the only thing that catches an unsafe operation reached through a
# safe type. `Span.unsafe_ptr` hands out a raw pointer and
# `as_unsafe_any_origin` forgets which region that pointer came from, and
# neither of them contains the word Pointer for the list above to find. Between
# them they are the whole erasure trick core.runtime.box is built out of, so
# without this a package could do that trick itself and still call itself safe.
UNSAFE_FAMILY = re.compile(r"\b(?:as_)?unsafe_[a-z_0-9]+\b")

# The machines the longer suites run on are private. Their names live in an
# environment file that is not checked in, and this is the check that they have
# not been pasted into the tree by accident. The patterns come from the same
# environment file when it is present, so this repository never has to contain
# the thing it is looking for.
SECRET_ENV = ROOT / ".fleet.env"

# The prefix every compile time check in this library puts on its message.
# Mojo cannot turn a compile time fact into an error, only into a deprecation
# warning, so the checks in fmt, the codecs and database/sql are all warnings
# carrying this prefix and the linter is what promotes them to build failures
# inside this repository. tools/warnings proves the same diagnostics still
# fire; this one proves none of them are left in our own code.
MARKER = "core:"

IMPORT = re.compile(r"^\s*(?:from|import)\s+(core(?:\.[a-z_0-9]+)*)", re.M)
FALLIBLE_NEXT = re.compile(r"^\s*def\s+__next__\s*\([^)]*\)[^:]*\braises\b", re.M)
MUST_CALL = re.compile(r"\b(must_[a-z_0-9]+)\s*\(\s*([^)]*)\)")


def check_graph(pkgs: list[Package]) -> list[str]:
    """The manifests describe a real graph.

    Every declared dependency names a package that exists, the graph has no
    cycle, the directory matches the name, and the recorded tier is one more
    than the deepest dependency. That last one makes the tier a fact about the
    graph rather than an opinion somebody typed, which is the only way the
    layering rule stays true as packages arrive.
    """
    problems = []
    by_name = {p.name: p for p in pkgs}
    for pkg in pkgs:
        where = pkg.path.relative_to(ROOT)
        if str(where) != "/".join(["core"] + pkg.name.split(".")[1:]):
            problems.append(f"{pkg.name} is declared in {where}, which is not where that name lives")
        for dep in pkg.deps:
            if dep not in by_name:
                problems.append(f"{pkg.name} declares {dep}, which is not a package in this tree")
        if pkg.deps != sorted(pkg.deps):
            problems.append(f"{pkg.name} lists its dependencies out of order")

    # Depth first, so a cycle is reported as the path that closes it rather
    # than as a set of names somebody then has to work out for themselves.
    depth: dict[str, int] = {}
    visiting: list[str] = []

    def walk(name: str) -> int:
        if name in depth:
            return depth[name]
        if name in visiting:
            problems.append("cycle: " + " -> ".join(visiting[visiting.index(name):] + [name]))
            return 0
        visiting.append(name)
        pkg = by_name[name]
        value = 1 + max((walk(d) for d in pkg.deps if d in by_name), default=-1)
        visiting.pop()
        depth[name] = value
        return value

    for pkg in pkgs:
        want = walk(pkg.name)
        if pkg.tier != want:
            problems.append(
                f"{pkg.name} records tier {pkg.tier} and its deepest dependency puts it at {want}"
            )
    if pkgs and not problems:
        print(f"lint: {len(pkgs)} packages over {max(depth.values()) + 1} tiers, no cycles")
    return problems


def check_layering(pkgs: list[Package]) -> list[str]:
    """Every import declared, and every declaration used.

    Both directions, because a stale declaration is how a dependency graph
    quietly becomes wrong: nothing breaks, and the manifest stops describing
    the code it is supposed to describe.

    A package with no code yet is a plan rather than a lie, so the second
    direction does not apply to it. The count of those is printed, because a
    number that is not going down is the interesting thing about this tree for
    a while.
    """
    problems = []
    known = {p.name for p in pkgs}
    unstarted = 0
    for pkg in pkgs:
        if not pkg.started:
            unstarted += 1
            continue
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
    if pkgs:
        print(f"lint: {len(pkgs) - unstarted} of {len(pkgs)} packages have code")
    return problems


def check_unsafe(pkgs: list[Package]) -> list[str]:
    """Raw pointers and foreign calls only where they are declared.

    The count of unsafe packages is reported by the caller rather than merely
    allowed, because that number going up is a thing to notice.
    """
    problems = []
    for pkg in pkgs:
        if pkg.unsafe:
            continue
        for src in pkg.sources:
            text = src.read_text()
            found = [n for n in UNSAFE_NAMES if re.search(rf"\b{n}\b", text)]
            found += sorted(set(UNSAFE_FAMILY.findall(text)))
            rel = src.relative_to(ROOT)
            for name in found:
                problems.append(f"{rel} names {name} in a package that is not unsafe")
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


def compile_for_diagnostics(directory: Path, out: Path) -> str:
    """Compile one package directory and give back everything the compiler said.

    This is a real compile rather than a grep, because the diagnostics being
    looked for are produced by instantiation and there is no way to see them
    without instantiating. It costs about what `pixi run pkg` costs, and it is
    a different question: that one asks whether a package builds against only
    its declared dependencies, this one asks what the compiler said while it
    did.
    """
    result = subprocess.run(
        ["mojo", "precompile", str(directory), "-I", str(ROOT), "-o", str(out)],
        capture_output=True,
        text=True,
    )
    return result.stdout + result.stderr


def check_diagnostics(pkgs: list[Package]) -> list[str]:
    """No compile time diagnostic of ours survives in our own code.

    A warning is all Mojo will give us for a compile time fact, so a format
    string with the wrong number of verbs, a codec field set that does not
    match, or a query with the wrong placeholder count all come out as
    warnings. Outside this repository that is all they can be. Inside it they
    are build failures, and this is the thing that makes them one.
    """
    started = [p for p in pkgs if p.started]
    if not started:
        print("lint: no package has code yet, so there are no diagnostics to check")
        return []
    if not shutil.which("mojo"):
        return ["mojo is not on PATH, so the diagnostics check cannot run"]

    problems = []
    with tempfile.TemporaryDirectory() as scratch:
        for pkg in started:
            said = compile_for_diagnostics(pkg.path, Path(scratch) / f"{pkg.name}.mojoc")
            for line in said.splitlines():
                if MARKER in line:
                    problems.append(f"{pkg.name}: {line.strip()}")
    if not problems:
        print(f"lint: {len(started)} packages compile with no marked diagnostics")
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
    failures = []
    fixtures = ROOT / "tests" / "lint"
    sources = {
        "fallible_next": check_iteration,
        "must_on_variable": check_must_calls,
        "unsafe_in_safe_package": None,
        "unsafe_family_in_safe_package": None,
    }
    for name, check in sources.items():
        path = fixtures / f"{name}.mojo"
        if not path.is_file():
            failures.append(f"missing fixture {path.relative_to(ROOT)}")
            continue
        if check is None:
            # The unsafe check reads a package rather than a list of files, so
            # it gets a package built around the fixture.
            fake = Package(name="core.fixture", path=path.parent, unsafe=False)
            if not [p for p in check_unsafe([fake]) if name in p]:
                failures.append(f"{name} fixture was accepted, so the unsafe check is dead")
            continue
        if not check([path]):
            failures.append(f"{name} fixture was accepted, so that check is dead")

    # The diagnostics check compiles a package rather than reading a file, so
    # its fixture gets assembled into a scratch package and built. This is the
    # only selftest that needs the compiler, and it says so rather than passing
    # quietly when the compiler is missing.
    marked = fixtures / "marked_diagnostic.mojo"
    if not marked.is_file():
        failures.append(f"missing fixture {marked.relative_to(ROOT)}")
    elif not shutil.which("mojo"):
        failures.append("mojo is not on PATH, so the diagnostics check is unproven")
    else:
        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "marked"
            package.mkdir()
            (package / "__init__.mojo").write_text("from .marked_diagnostic import use\n")
            (package / "marked_diagnostic.mojo").write_text(marked.read_text())
            said = compile_for_diagnostics(package, Path(scratch) / "marked.mojoc")
        if not [line for line in said.splitlines() if MARKER in line]:
            failures.append(
                "the marked_diagnostic fixture compiled without a marked warning, "
                "so either the diagnostics check or the warning mechanism is dead"
            )

    # The graph checks read manifests rather than source, so they are proved
    # against a graph built here instead of against a file on disk. A tree with
    # a real cycle in it would fail every other run as well.
    here = ROOT / "core"
    graphs = {
        "a cycle": [
            Package(name="core.a", path=here / "a", tier=0, deps=["core.b"]),
            Package(name="core.b", path=here / "b", tier=0, deps=["core.a"]),
        ],
        "a wrong tier": [
            Package(name="core.a", path=here / "a", tier=0, deps=[]),
            Package(name="core.b", path=here / "b", tier=7, deps=["core.a"]),
        ],
        "a dependency that does not exist": [
            Package(name="core.a", path=here / "a", tier=0, deps=["core.nowhere"]),
        ],
        "a name that does not match its directory": [
            Package(name="core.a", path=here / "elsewhere", tier=0, deps=[]),
        ],
    }
    for what, pkgs in graphs.items():
        if not check_graph(pkgs):
            failures.append(f"the graph check accepted {what}, so it is dead")

    return report("lint selftest", len(sources) + len(graphs) + 1, "checks", failures)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true", help="check the checks")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    pkgs = packages()
    sources = mojo_sources()
    if pkgs:
        print(f"lint: {sum(1 for p in pkgs if p.unsafe)} of {len(pkgs)} packages declare unsafe")
    problems = (
        check_graph(pkgs)
        + check_layering(pkgs)
        + check_unsafe(pkgs)
        + check_iteration(sources)
        + check_must_calls(sources)
        + check_diagnostics(pkgs)
        + check_no_private_hostnames()
    )
    return report("lint", len(sources), "source files", problems)


if __name__ == "__main__":
    raise SystemExit(main())
