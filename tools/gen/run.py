#!/usr/bin/env python3
"""Run the code generators, or check that their output is current.

Generated code is checked in as well as generated. Checking it in means a
reader can see it, a reviewer can diff it and nobody needs a generator to
build. Regenerating it in CI and failing on a diff means it cannot quietly stop
matching its source, which is the failure mode that surfaces months later
somewhere apparently unrelated.

Each generator is a module under tools/gen with a `generate()` that returns a
mapping of repository relative path to file contents. Adding one is adding a
file here, not editing this runner.
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT, report

HERE = Path(__file__).parent


def generators() -> list[tuple[str, object]]:
    """Every generator module, in name order.

    The Unicode tables, the time zone data, the syscall bindings and the codecs
    land here as the milestones that need them arrive. See docs/roadmap.md.
    """
    found = []
    for path in sorted(HERE.glob("*.py")):
        if path.name in ("run.py", "__init__.py"):
            continue
        spec = importlib.util.spec_from_file_location(f"gen_{path.stem}", path)
        if spec is None or spec.loader is None:
            continue
        module = importlib.util.module_from_spec(spec)
        # Registered before it runs, because a module that defines a dataclass
        # needs to be able to find itself in sys.modules while the decorator is
        # running and a module loaded by path is not there unless it is put
        # there. Without this a generator can hold data classes and nothing
        # else, which is not a rule anybody would guess from the error.
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        if hasattr(module, "generate"):
            found.append((path.stem, module))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check", action="store_true", help="fail on a diff instead of writing"
    )
    args = parser.parse_args()

    problems = []
    written = 0
    for name, module in generators():
        try:
            output = module.generate()
        except Exception as err:  # a broken generator is a failure, not a crash
            problems.append(f"{name} raised {err.__class__.__name__}: {err}")
            continue
        for rel, contents in sorted(output.items()):
            path = ROOT / rel
            current = path.read_text() if path.is_file() else None
            written += 1
            if current == contents:
                continue
            if args.check:
                verb = "differs from" if current is not None else "is missing next to"
                problems.append(f"{rel} {verb} what {name} generates, run `pixi run gen`")
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
            print(f"gen: wrote {rel}")

    tool = "generated-check" if args.check else "gen"
    return report(tool, written, "generated files", problems)


if __name__ == "__main__":
    raise SystemExit(main())
