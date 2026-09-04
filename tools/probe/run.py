#!/usr/bin/env python3
"""Check the language assumptions this library is built on.

The design in docs/design.md rests on ten properties of Mojo. Some of them are
limitations we work around, and a limitation that gets lifted is good news that
nobody will notice unless something is watching. Others are behaviours we rely
on, and one of those changing is a silent correctness problem.

Each probe is a real Mojo file under probes/ with a header saying what is
supposed to happen to it. It compiles and prints a particular thing, or the
compiler refuses it with a particular message. The header also names the
section of docs/design.md the probe pins, and this checks that the section
still exists, so a rewrite that drops a heading does not leave a probe pinning
nothing.

This runs in the nightly job separately from the suite, so that a failure names
the assumption that moved rather than showing up as a hundred broken tests.

A probe failing is not necessarily bad news. It means go and read the section
it names, because the reasoning there now has a different answer.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.cold import environment
from lib.tree import ROOT, report

PROBES = Path(__file__).parent / "probes"
DESIGN = ROOT / "docs" / "design.md"

# The prefix every compile time complaint in this library carries, so that the
# warnings tool can tell ours from anything the compiler says. The two probes
# about section 10 count these.
MARKER = "core:"

HEADER = re.compile(r"^#\s*([A-Z]+):\s?(.*)$")


@dataclass
class Probe:
    """One probe file and what its header says should happen to it."""

    path: Path
    pins: str = ""
    expect: str = ""
    output: str = ""
    errors: list[str] = field(default_factory=list)
    warnings: int | None = None
    why: list[str] = field(default_factory=list)
    # Set when a probe only applies to some compiler versions, which happens
    # when the thing it pins is spelled differently across a release. Matched
    # against what mojo --version prints.
    toolchain: str = ""

    @property
    def name(self) -> str:
        return self.path.stem


def read(path: Path) -> Probe | str:
    """Parse one probe's header, or say what is wrong with it."""
    probe = Probe(path=path)
    for line in path.read_text().splitlines():
        if not line.startswith("#"):
            break
        found = HEADER.match(line)
        if not found:
            continue
        key, value = found.group(1), found.group(2).strip()
        if key == "PINS":
            probe.pins = value
        elif key == "EXPECT":
            probe.expect = value
        elif key == "OUTPUT":
            probe.output = value
        elif key == "ERROR":
            probe.errors.append(value)
        elif key == "WARNINGS":
            probe.warnings = int(value)
        elif key == "WHY":
            probe.why.append(value)
        elif key == "TOOLCHAIN":
            probe.toolchain = value

    if probe.expect not in ("runs", "rejected"):
        return f"{probe.name} has no EXPECT line saying runs or rejected"
    if not probe.pins:
        return f"{probe.name} does not say which section of design.md it pins"
    if not probe.why:
        return f"{probe.name} does not say what it means if it fails"
    if probe.expect == "runs" and not probe.output:
        return f"{probe.name} is supposed to run and does not say what it prints"
    if probe.expect == "rejected" and not probe.errors:
        return f"{probe.name} is supposed to be refused and does not say with what"
    return probe


def sections() -> set[str]:
    """Every heading in docs/design.md, so a probe cannot pin one that is gone."""
    return {
        line.lstrip("#").strip()
        for line in DESIGN.read_text().splitlines()
        if line.startswith("## ")
    }


def run(probe: Probe, mojo: str) -> str | None:
    """Build and maybe run one probe. Gives back a problem, or None."""
    with tempfile.TemporaryDirectory() as scratch:
        binary = Path(scratch) / probe.name
        # Compiled against an empty cache. Our compile time complaints are
        # prints from the interpreter, and a compile the compiler serves from
        # its cache does not run the interpreter, so a probe counting them
        # would count zero on its second run. See tools/lib/cold.py.
        built = subprocess.run(
            [mojo, "build", "-o", str(binary), str(probe.path)],
            capture_output=True,
            text=True,
            env=environment(Path(scratch) / "cache"),
        )
        diagnostics = built.stdout + built.stderr

        if probe.expect == "rejected":
            if built.returncode == 0:
                return (
                    f"{probe.name} compiles now, and it is not supposed to. "
                    + " ".join(probe.why)
                )
            for wanted in probe.errors:
                if wanted not in diagnostics:
                    return (
                        f"{probe.name} is still refused but no longer says "
                        f"{wanted!r}, so the reason changed"
                    )
            return None

        if built.returncode != 0:
            first = next(
                (l for l in diagnostics.splitlines() if "error:" in l), "no output"
            )
            return f"{probe.name} no longer compiles: {first.strip()}"

        if probe.warnings is not None:
            seen = sum(1 for line in diagnostics.splitlines() if MARKER in line)
            if seen != probe.warnings:
                return (
                    f"{probe.name} produced {seen} marked warnings and expects "
                    f"{probe.warnings}. " + " ".join(probe.why)
                )

        ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)

    if ran.returncode != 0:
        return f"{probe.name} built and then failed at run time: {ran.stderr.strip()}"
    if probe.output not in ran.stdout:
        got = ran.stdout.strip().replace("\n", " ")
        return f"{probe.name} printed {got!r} and expects {probe.output!r}"
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("probe", nargs="?", help="run one probe by name")
    args = parser.parse_args()

    files = sorted(PROBES.glob("*.mojo"))
    if args.probe:
        files = [p for p in files if p.stem == args.probe]
        if not files:
            print(f"probe: no probe named {args.probe}", file=sys.stderr)
            return 1
    if not files:
        print("probe: there are no probes, which cannot be right", file=sys.stderr)
        return 1

    problems: list[str] = []
    probes: list[Probe] = []
    for path in files:
        parsed = read(path)
        if isinstance(parsed, str):
            problems.append(parsed)
        else:
            probes.append(parsed)

    known = sections()
    for probe in probes:
        if probe.pins not in known:
            problems.append(
                f"{probe.name} pins {probe.pins!r}, which is not a heading in "
                "docs/design.md any more"
            )

    mojo = shutil.which("mojo")
    if mojo is None:
        print("probe: mojo is not on PATH", file=sys.stderr)
        return 1
    version = subprocess.run([mojo, "--version"], capture_output=True, text=True).stdout.strip()
    print(f"probe: against {version or 'an unknown mojo'}")

    # A probe pinned to another compiler version is skipped and said out loud.
    # Silently skipping is how a suite ends up proving nothing, and every skip
    # here is a spelling that changed and will need cleaning up later.
    ran = []
    for probe in probes:
        if probe.toolchain and probe.toolchain not in version:
            print(f"probe: {probe.name} is for {probe.toolchain}, skipped")
            continue
        ran.append(probe)
        print(f"probe: {probe.name} pins design.md section {probe.pins}")
        failure = run(probe, mojo)
        if failure:
            problems.append(failure)

    return report("probe", len(ran), "language assumptions", problems)


if __name__ == "__main__":
    raise SystemExit(main())
