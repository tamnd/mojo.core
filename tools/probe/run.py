#!/usr/bin/env python3
"""Check the language assumptions this library is built on.

The design in docs/design.md rests on ten properties of Mojo. Some of them are
limitations we work around, and a limitation that gets lifted is good news that
nobody will notice unless something is watching. Others are behaviours we rely
on, and one of those changing is a silent correctness problem.

Each probe is a small program plus a statement of what is supposed to happen to
it. Compiles, does not compile, or runs and prints a particular thing. This is
run in the nightly job separately from the suite, so that a failure names the
assumption that moved rather than showing up as a hundred broken tests.

A probe failing is not necessarily bad. It means go and read the entry in
docs/design.md, because the reasoning there now has a different answer.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import report


@dataclass
class Probe:
    name: str
    expect: str  # "compiles" or "rejected"
    why: str
    source: str


PROBES = [
    Probe(
        name="for_swallows_raise",
        expect="compiles",
        why=(
            "A for loop accepts an iterator whose __next__ raises, and silently ends "
            "the loop when it does. This compiling is the whole reason for the "
            "has_next and next rule the linter enforces. If it stops compiling, the "
            "rule can be relaxed and the linter check should go."
        ),
        source="""
struct Fallible(Copyable, Movable):
    var n: Int

    fn __iter__(self) -> Self:
        return self

    fn __next__(mut self) raises -> Int:
        if self.n == 0:
            raise Error("stop")
        self.n -= 1
        return self.n

    fn __has_next__(self) -> Bool:
        return True

def main():
    for value in Fallible(3):
        print(value)
""",
    ),
    Probe(
        name="compile_time_error",
        expect="rejected",
        why=(
            "A compile time fact still cannot be raised as a compile error, which is "
            "why every compile time check in this library is a deprecation warning "
            "with a marker prefix instead. If this starts compiling, the checks can "
            "become real errors and tests/warnings/ can go away."
        ),
        source="""
fn check[n: Int]():
    @parameter
    if n < 0:
        compile_error["n must not be negative"]()

def main():
    check[1]()
""",
    ),
    Probe(
        name="raises_through_fn_pointer",
        expect="compiles",
        why=(
            "A raising function survives being stored as a plain function pointer. "
            "This is what the error mechanism and every callback in this library are "
            "built on, so it is relied upon rather than merely worked around."
        ),
        source="""
fn might_fail(x: Int) raises -> Int:
    if x < 0:
        raise Error("negative")
    return x

def main():
    var f: fn (Int) raises -> Int = might_fail
    print(f(1))
""",
    ),
    Probe(
        name="storable_closure",
        expect="rejected",
        why=(
            "A closure that captures cannot be stored in a struct field. This is why "
            "the callback shapes in this library take an explicit context argument "
            "rather than capturing. If it starts working, a lot of signatures get "
            "simpler."
        ),
        source="""
struct Holder:
    var f: fn () escaping -> Int

    fn __init__(out self, owned f: fn () escaping -> Int):
        self.f = f

def main():
    var captured = 7
    var h = Holder(fn () -> Int: return captured)
    print(h.f())
""",
    ),
    Probe(
        name="recursive_struct",
        expect="rejected",
        why=(
            "A struct cannot contain itself, even behind a pointer field with an "
            "origin. Every tree in this library is an arena with integer indices "
            "because of this, which is a real cost in readability."
        ),
        source="""
struct Node:
    var value: Int
    var next: Node

def main():
    print(1)
""",
    ),
]


def run(probe: Probe, mojo: str) -> str | None:
    """Build one probe and say whether it did what it was supposed to."""
    with tempfile.TemporaryDirectory() as scratch:
        path = Path(scratch) / f"{probe.name}.mojo"
        path.write_text(probe.source.lstrip())
        out = subprocess.run(
            [mojo, "build", "-o", str(Path(scratch) / "out"), str(path)],
            capture_output=True,
            text=True,
        )
    compiled = out.returncode == 0
    if compiled and probe.expect == "compiles":
        return None
    if not compiled and probe.expect == "rejected":
        return None
    became = "compiles now" if compiled else "no longer compiles"
    return f"{probe.name} {became}. {probe.why}"


def main() -> int:
    mojo = shutil.which("mojo")
    if mojo is None:
        print("probe: mojo is not on PATH", file=sys.stderr)
        return 1
    version = subprocess.run([mojo, "--version"], capture_output=True, text=True)
    print(f"probe: against {version.stdout.strip() or 'an unknown mojo'}")

    problems = [p for p in (run(probe, mojo) for probe in PROBES) if p]
    return report("probe", len(PROBES), "language assumptions", problems)


if __name__ == "__main__":
    raise SystemExit(main())
