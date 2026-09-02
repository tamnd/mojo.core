#!/usr/bin/env python3
"""Check the vendored test corpora against their recorded digests.

The corpora are other people's data: Go's test files, the Unicode database, the
web platform URL tests, JSONTestSuite. Every one of them is pinned by SHA256 in
tests/data/LOCK.toml along with where it came from and what licence it carries.

Fetching is a separate deliberate step, run with --fetch. The build only ever
checks, because a build that reaches the network is a build that fails on a bad
day for reasons that have nothing to do with the code.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import tomllib
from pathlib import Path
from urllib.request import urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT, report

DATA = ROOT / "tests" / "data"
LOCK = DATA / "LOCK.toml"


def entries() -> dict[str, dict]:
    """Every pinned corpus, keyed by its path under tests/data."""
    if not LOCK.is_file():
        return {}
    with LOCK.open("rb") as fh:
        return tomllib.load(fh).get("corpus", {})


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(name: str, entry: dict) -> str | None:
    """Download one corpus and write it where the lock file says it goes."""
    target = DATA / name
    target.parent.mkdir(parents=True, exist_ok=True)
    with urlopen(entry["url"]) as response:
        target.write_bytes(response.read())
    got = digest(target)
    if got != entry["sha256"]:
        return f"{name} downloaded with digest {got}, lock file says {entry['sha256']}"
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch", action="store_true", help="download anything missing")
    args = parser.parse_args()

    pinned = entries()
    problems = []
    for name, entry in sorted(pinned.items()):
        missing = [f for f in ("url", "sha256", "licence") if f not in entry]
        if missing:
            problems.append(f"{name} has no {' or '.join(missing)} in the lock file")
            continue
        target = DATA / name
        if not target.is_file():
            if args.fetch:
                failure = fetch(name, entry)
                if failure:
                    problems.append(failure)
                continue
            problems.append(f"{name} is missing, run `pixi run vendor-check --fetch`")
            continue
        got = digest(target)
        if got != entry["sha256"]:
            problems.append(f"{name} has digest {got}, lock file says {entry['sha256']}")

    # The other direction. A corpus file nobody pinned has no recorded licence,
    # and a core library that vendors somebody else's data without attribution
    # is a legal problem for everyone who ships it.
    if DATA.is_dir():
        for path in sorted(DATA.rglob("*")):
            if not path.is_file() or path == LOCK:
                continue
            name = str(path.relative_to(DATA))
            if name not in pinned:
                problems.append(f"{name} is not in the lock file, so it has no recorded licence")

    return report("vendor-check", len(pinned), "corpora", problems)


if __name__ == "__main__":
    raise SystemExit(main())
