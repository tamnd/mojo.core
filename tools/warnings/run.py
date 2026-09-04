#!/usr/bin/env python3
"""Check that the compile time diagnostics still fire.

A compile time fact in Mojo cannot be raised as an error, and cannot be raised
as a warning either. What it can do is print, from the interpreter that folds
`comptime` bindings while the program is built, so every compile time check in
this library is a print carrying a marker prefix. That makes the mechanism load
bearing, and load bearing things get tested.

Each file under tests/warnings/ is expected to complain. The count, the message
text and what the program prints when it runs are all asserted, from a header
the file carries itself:

    # EXPECT: 2
    # EXPECT-TEXT: buffer size must be a power of two
    # EXPECT-OUTPUT: %!d(string=hi)

The output lines are here rather than in tests/fmt because a program that uses
a format string wrongly complains while it builds, and the suite build treats
any complaint of ours as a failure. So the wrong calls live in one place that
expects them, and that place checks both halves: what the compiler said, and
that the program then behaved exactly like Go.

If the mechanism stops firing, which is a plausible thing for a compiler
release to change, those files start compiling quietly and this fails. Without
it, every compile time check in the library would silently stop working and
nothing would say so.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.cold import environment
from lib.native import link_flags, shim
from lib.tree import ROOT, report

CASES = ROOT / "tests" / "warnings"

# The prefix every compile time check in this library puts on its message, so
# that our complaints can be told apart from anything the compiler says.
MARKER = "core:"

COUNT = re.compile(r"^#\s*EXPECT:\s*(\d+)\s*$", re.M)
TEXT = re.compile(r"^#\s*EXPECT-TEXT:\s*(.+?)\s*$", re.M)
OUTPUT = re.compile(r"^#\s*EXPECT-OUTPUT:\s*(.*?)\s*$", re.M)


def diagnostics(path: Path) -> tuple[list[str], str, str]:
    """Build one case and give back our complaints, plus everything it said.

    A whole program, not an object file. The checks are folded by the compile
    time interpreter, and the interpreter only folds a call that some program
    makes, so a case is a `main` that makes the wrong calls on purpose. The
    two shims are linked in for the same reason they are linked into the suite:
    a case that reaches any of the library needs them, and one link line
    everywhere is worth the few hundred bytes.

    Compiled against an empty cache. A build served from the compiler's cache
    does not re-run the interpreter and so says nothing, and a check that
    passes because the compiler stayed quiet is not a check.

    Then it is run, because half of what a case asserts is that a program the
    compiler complained about still behaves the way Go does.
    """
    with tempfile.TemporaryDirectory() as scratch:
        where = Path(scratch)
        objects = shim(where)
        if isinstance(objects, str):
            return [], objects, ""
        binary = where / "case"
        out = subprocess.run(
            ["mojo", "build", "-I", str(ROOT), "-o", str(binary),
             *link_flags(objects), str(path)],
            capture_output=True,
            text=True,
            env=environment(where / "cache"),
        )
        combined = out.stdout + out.stderr
        if out.returncode != 0:
            return [], combined, ""
        ran = subprocess.run(
            [str(binary)], capture_output=True, text=True, timeout=120
        )
    ours = [line for line in combined.splitlines() if MARKER in line]
    return ours, combined, ran.stdout


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

        ours, combined, printed = diagnostics(path)
        expected = int(want_count.group(1))
        if len(ours) != expected:
            problems.append(
                f"{rel} produced {len(ours)} of our complaints and expects {expected}. "
                "If the count is zero the compile time check has stopped firing."
            )
        for text in want_texts:
            if text not in combined:
                problems.append(f"{rel} expects a complaint saying {text!r} and none said it")
        for line in OUTPUT.findall(source):
            if line not in printed:
                problems.append(
                    f"{rel} expects to print {line!r} and printed "
                    f"{printed.strip()!r} instead"
                )

    return report("warnings", len(cases), "cases", problems)


if __name__ == "__main__":
    raise SystemExit(main())
