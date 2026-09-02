#!/usr/bin/env python3
"""Check that the compile time diagnostics still fire.

A compile time fact in Mojo cannot be raised as an error, only as a deprecation
warning, so every compile time check in this library is a warning carrying a
marker prefix. That makes the warning mechanism load bearing, and load bearing
things get tested.

Each file under tests/warnings/ is expected to produce warnings. The count and
the message text are both asserted, from a header the file carries itself:

    # EXPECT: 2
    # EXPECT-TEXT: buffer size must be a power of two

If the mechanism stops firing, which is a plausible thing for a compiler
release to change, those files start compiling cleanly and this fails. Without
it, every compile time check in the library would silently stop working and
nothing would say so.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT, report

CASES = ROOT / "tests" / "warnings"

# The prefix every compile time check in this library puts on its message, so
# that our diagnostics can be told apart from the compiler's own.
MARKER = "core:"

COUNT = re.compile(r"^#\s*EXPECT:\s*(\d+)\s*$", re.M)
TEXT = re.compile(r"^#\s*EXPECT-TEXT:\s*(.+?)\s*$", re.M)


def diagnostics(path: Path) -> tuple[list[str], str]:
    """Build one file and give back our warnings, plus anything unexpected."""
    out = subprocess.run(
        ["mojo", "build", "--emit", "object", "-o", "/dev/null", str(path)],
        capture_output=True,
        text=True,
    )
    combined = out.stdout + out.stderr
    ours = [line for line in combined.splitlines() if MARKER in line]
    return ours, combined


def main() -> int:
    if not CASES.is_dir():
        print("warnings: no cases yet, nothing to prove")
        return 0
    cases = sorted(CASES.glob("*.mojo"))
    if not cases:
        print("warnings: no cases yet, nothing to prove")
        return 0
    if not shutil.which("mojo"):
        print("warnings: mojo is not on PATH", file=sys.stderr)
        return 1

    problems = []
    for path in cases:
        rel = path.relative_to(ROOT)
        source = path.read_text()
        want_count = COUNT.search(source)
        want_texts = TEXT.findall(source)
        if not want_count:
            problems.append(f"{rel} has no EXPECT header, so it asserts nothing")
            continue

        ours, combined = diagnostics(path)
        expected = int(want_count.group(1))
        if len(ours) != expected:
            problems.append(
                f"{rel} produced {len(ours)} of our warnings and expects {expected}. "
                "If the count is zero the compile time check has stopped firing."
            )
        for text in want_texts:
            if text not in combined:
                problems.append(f"{rel} expects a warning saying {text!r} and none said it")

    return report("warnings", len(cases), "cases", problems)


if __name__ == "__main__":
    raise SystemExit(main())
