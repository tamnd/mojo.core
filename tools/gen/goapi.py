#!/usr/bin/env python3
"""Condense Go's API manifests into the index the parity tool reads.

Go ships `$GOROOT/api/go1*.txt`, one file per release, listing every exported
symbol added by that release. Together they are the complete exported surface of
the standard library, and they are the only description of it that is machine
readable and maintained by Go itself. That makes them the parity contract.

The full set is around nine megabytes and most of it is `syscall` constants for
eleven platforms we do not target, so it is not checked in. This condenses it to
one line per symbol, which is small enough to read in a diff and to commit.

Two things happen on the way. The `(platform)` qualifier is dropped, so a
constant that exists on eleven platforms is one symbol rather than eleven. And
the trailing `#12345` proposal number is dropped, because it says when a symbol
arrived and not what it is.

A symbol here is a top level declaration or a member of one: a function, a type,
a constant, a variable, a method, an exported struct field, or an interface
method. Struct fields are in because a type with the right methods and the wrong
fields is not a port of anything.

Every package also gets a line of its own, from `go list std`, so that a package
which exports nothing is still in the index. Without that there is no way to
tell `time/tzdata`, which is real and exports nothing, from a package name
somebody mistyped into a PACKAGE.toml.

Needs Go on PATH. Without it this skips loudly and leaves the checked in index
alone, so working offline is fine and CI still checks it: the oracle
environment pins Go in pixi.lock and runs `generated-check` against it.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

INDEX = "tools/parity/goapi.txt"

# `pkg net/http (windows-386), const Foo = 1 #12345`
LINE = re.compile(r"^pkg (\S+?)(?: \(([^)]*)\))?, (.+)$")
ISSUE = re.compile(r"\s*#\d+\s*$")
# `method (*Buffer) Len() int`, and the receiver may be generic.
METHOD = re.compile(r"^method (?:\[[^]]*\] )?\(([^)]+)\) (\w+)")
# `func Index[$0 interface{ ~[]$1 }, $1 comparable](...) int`
FUNC = re.compile(r"^func (\w+)")
DECL = re.compile(r"^(const|var) (\w+)")
TYPE = re.compile(r"^type (\w+)(.*)$")
MEMBER = re.compile(r"^(struct|interface), (\w+)")
# Go's own word for the packages this project is not modelled on.
PRIVATE = re.compile(r"(^|/)(internal|vendor)(/|$)")


def goroot() -> Path | None:
    """Where Go keeps its manifests, or None when Go is not installed."""
    if not shutil.which("go"):
        return None
    out = subprocess.run(["go", "env", "GOROOT"], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    api = Path(out.stdout.strip()) / "api"
    return api if api.is_dir() else None


def version() -> str:
    """The Go release the index was built from, recorded in its header.

    Only the release, not the host triple, because the manifests are the same
    on every host and a header that changed with the machine would make the
    diff check fail for the wrong reason.
    """
    out = subprocess.run(["go", "env", "GOVERSION"], capture_output=True, text=True)
    return out.stdout.strip() or "unknown"


def undecorate(rest: str) -> str:
    """What is left of a declaration after its type parameter list.

    `type Null[$0 interface{}] struct, Valid bool` is a field on `Null`, and
    finding that out means stepping over the brackets. Counting them rather
    than matching to the last one, because a constraint can hold a slice type
    and bring a second closing bracket with it.
    """
    if not rest.startswith("["):
        return rest.lstrip()
    depth = 0
    for position, character in enumerate(rest):
        depth += (character == "[") - (character == "]")
        if depth == 0:
            return rest[position + 1 :].lstrip()
    return ""


def symbol(body: str) -> tuple[str, str] | None:
    """One manifest entry as a kind and a name, or None if it declares nothing.

    Members are named `Owner.Member` so that the owner is recoverable without
    a second field, and so that sorting the index groups a type with its
    methods and fields.
    """
    match = METHOD.match(body)
    if match:
        recv = match.group(1).lstrip("*").split("[")[0]
        return "method", f"{recv}.{match.group(2)}"

    match = FUNC.match(body)
    if match:
        return "func", match.group(1)

    match = DECL.match(body)
    if match:
        return match.group(1), match.group(2)

    match = TYPE.match(body)
    if match:
        name, rest = match.group(1), undecorate(match.group(2) or "")
        member = MEMBER.match(rest)
        if member:
            # `type File interface, unexported methods` describes something we
            # cannot see and cannot be asked to provide.
            kind = "field" if member.group(1) == "struct" else "method"
            return kind, f"{name}.{member.group(2)}"
        return "type", name

    return None


def read(api: Path) -> dict[str, set[tuple[str, str]]]:
    """Every symbol in every manifest, by Go package."""
    found: dict[str, set[tuple[str, str]]] = {}
    for path in sorted(api.glob("go1*.txt")):
        for line in path.read_text().splitlines():
            match = LINE.match(line)
            if not match:
                continue
            body = ISSUE.sub("", match.group(3))
            entry = symbol(body)
            if entry is not None:
                found.setdefault(match.group(1), set()).add(entry)
    return found


def std() -> list[str]:
    """Every standard library package that is not internal or vendored.

    The same 176 that docs/packages.md has a row for. Internal packages are
    Go's own plumbing and are not part of anybody's contract, and the vendored
    ones are copies of golang.org/x that Go builds against.
    """
    out = subprocess.run(["go", "list", "std"], capture_output=True, text=True)
    if out.returncode != 0:
        return []
    return sorted(p for p in out.stdout.split() if not PRIVATE.search(p))


def generate() -> dict[str, str]:
    api = goroot()
    if api is None:
        print("gen: go is not on PATH, so the Go API index is left as it is")
        return {}

    found = read(api)
    packages = std()
    if not found or not packages:
        print("gen: found no symbols in Go's manifests, which cannot be right")
        return {}

    for package in packages:
        found.setdefault(package, set())

    lines = []
    for package in sorted(found):
        if package not in packages:
            # A manifest entry for something `go list std` does not report is
            # from a package Go has since made internal or removed, and it is
            # not owed by anybody.
            continue
        lines.append(f"{package}\tpackage\t-")
        for kind, name in sorted(found[package]):
            lines.append(f"{package}\t{kind}\t{name}")

    total = sum(len(found[p]) for p in packages)
    header = [
        "# Go's exported API, condensed from the api/go1*.txt manifests that ship with Go.",
        "# Generated by tools/gen/goapi.py. Do not edit by hand, run `pixi run gen` with Go on PATH.",
        "#",
        "# One line per symbol: Go package, kind, name. Members are Owner.Member.",
        "# Platform qualifiers and proposal numbers are stripped, so a constant that",
        "# exists on eleven platforms appears once.",
        "#",
        "# The `package` kind is the package itself, so that one which exports nothing",
        "# is still here to be looked up.",
        "#",
        f"# {version()}",
        f"# {len(packages)} packages, {total} symbols",
        "",
    ]
    return {INDEX: "\n".join(header + lines) + "\n"}


if __name__ == "__main__":
    for rel, text in generate().items():
        print(rel, len(text.splitlines()), "lines")
