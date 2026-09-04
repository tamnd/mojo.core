#!/usr/bin/env python3
"""Run the test suite.

The whole suite is one binary. The runner finds every test function, generates
a main that calls all of them, builds it once and runs it, so the build time
tracks the size of the library rather than the number of tests. A library
heading for tens of thousands of test cases cannot afford a process per case.

That has a limit and we will hit it. When the suite takes longer to link than
to run, the answer is to split by package rather than to keep raising the
timeout.

A test is a `def test_something() raises:` in a `test_*.mojo` file under tests/.
The `raises` is required and the runner says so when it is missing, because a
test that cannot raise cannot fail an assertion and will pass forever.

Assertions come from `std.testing`, which already reports the file, the line
and both values. The runner's job is to catch that, say which test it came out
of, and make the paths relative so they are clickable.

  test: 1 of 12 tests failed
  FAIL tests/strings/test_index.test_index_finds
       tests/strings/test_index.mojo:4:17: AssertionError: `left == right`
       comparison failed:
          left: 4
         right: 5

Takes a package to run one package, `pixi run test core.strings`, and fails
rather than passing quietly when the name matches nothing. A filter that
silently matches no tests is how a suite stops running without anybody noticing.

Pass --short to skip the cases marked slow, which is what a local run wants and
what CI does not do. A case is marked by a `# slow: why` comment on the line
above it, so the decision lives in the test rather than in a list here.

Pass --race to build the same suite under the thread sanitiser. Refcounts and
locks are the two things in this library whose bugs do not show up as a failing
assertion, and a suite that passes is not evidence about either of them. The
sanitiser is a build flag rather than a separate suite so that whatever tests
exist are the tests it runs. It works on macOS and not on Linux, for a reason
that is somebody else's and is recorded next to RACE_UNAVAILABLE below.

There is one false report to know about before writing a threaded test. The
Mojo runtime serves every `List`, `String` and `Dict` out of its own allocator,
which the sanitiser does not intercept, so the sanitiser never learns that a
block one thread freed is the same block another thread was later handed. A
worker that allocates and frees in a loop therefore reports a race on recycled
memory whatever it is doing, and a file with nothing in it but a `List` built
inside a thread reproduces it. Threaded tests here keep their workers free of
allocation for that reason; tests/math/rand/test_concurrent.mojo says so where
it does it. A race reported at an address several threads have allocated at is
this, and a race on a value the test itself declared is real.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.cold import environment
from lib.native import shim
from lib.tree import ROOT, report

TESTS = ROOT / "tests"
MAIN = TESTS / "_generated_main.mojo"

# What the thread sanitiser prints when it finds something. It reports and then
# lets the program carry on with its exit code untouched, so this string is the
# only thing standing between a data race and a green suite.
RACE_FOUND = "WARNING: ThreadSanitizer"

# What a sanitised binary prints on Linux instead of running. The Mojo runtime
# links tcmalloc, which assumes a 48-bit address space, and the sanitiser takes
# that range for its shadow memory, so the allocator dies before main. There is
# no flag to build without tcmalloc. Recognised by name so that `pixi run race`
# on Linux says what actually happened rather than reporting a suite failure
# and sending somebody looking for a bug in their own code.
RACE_UNAVAILABLE = "TCMalloc assumes a 48-bit virtual address space"

# The prefix every compile time check in this library puts on its message. The
# checks are prints from the compile time interpreter, so they are heard while
# a program is built rather than while a package is compiled, and the suite is
# the program that reaches our own code. A line carrying this while the suite
# builds means some call in the library or its tests is wrong.
MARKER = "core:"

# tests/lint holds files that are supposed to fail the linter and tests/mojotest
# holds files that are supposed to fail this. Neither belongs in the suite.
FIXTURES = TESTS / "mojotest"
EXCLUDED = (TESTS / "lint", FIXTURES)

# The one fixture that is not a failing test but a wrong format string, kept in
# a directory of its own because it has to be built on its own. It is what
# proves the marker check above can fail, and it is skipped by every run that
# is not asking for it by name, including the selftest's other two.
MARKED = FIXTURES / "marked"

# Go's convention, kept, because a reader coming from Go already knows it and
# because the harvested tests arrive with these names.
TEST_FN = re.compile(r"^def\s+(test_[a-z_0-9]*)\s*\(\s*\)(\s+raises)?\s*:")
SLOW = re.compile(r"^#\s*slow:\s*(\S.*)$")


@dataclass
class Case:
    """One test function, and where it came from."""

    path: Path
    name: str
    slow: str = ""

    @property
    def module(self) -> str:
        """The dotted module path `mojo build -I ROOT` resolves."""
        return str(self.path.relative_to(ROOT).with_suffix("")).replace("/", ".")

    @property
    def label(self) -> str:
        return f"{self.module}.{self.name}"


def scan(path: Path) -> tuple[list[Case], list[str]]:
    """Every test in one file, and anything wrong with how it is declared.

    Line by line rather than one regular expression over the whole file,
    because a slow marker is a comment on the line above the test it marks and
    that relationship is the thing being read.
    """
    found: list[Case] = []
    problems: list[str] = []
    marker = ""
    for number, line in enumerate(path.read_text().splitlines(), 1):
        slow = SLOW.match(line)
        if slow:
            marker = slow.group(1).strip()
            continue
        match = TEST_FN.match(line)
        if match:
            where = f"{path.relative_to(ROOT)}:{number}"
            if not match.group(2):
                problems.append(
                    f"{where} declares {match.group(1)} without `raises`, so no assertion "
                    "in it can fail. Add `raises` to the signature"
                )
            found.append(Case(path, match.group(1), marker))
        if line.strip() and not line.lstrip().startswith("#"):
            # A marker only reaches past blank lines and other comments, so a
            # stray one at the top of a file does not silently mark whatever
            # test happens to come first.
            marker = ""
    return found, problems


def discover(where: Path, only: str | None) -> tuple[list[Case], list[str]]:
    """Every test under a directory, filtered to one package if asked."""
    if not where.is_dir():
        return [], []
    wanted = None
    if only:
        # `core.strings` is tests/strings, because the tests mirror the tree
        # they test. A bare path works too, for a directory that is not a
        # package yet.
        wanted = TESTS / only.removeprefix("core.").replace(".", "/")

    found: list[Case] = []
    problems: list[str] = []
    for path in sorted(where.rglob("test_*.mojo")):
        if where == TESTS and any(skip in path.parents for skip in EXCLUDED):
            continue
        if where != MARKED and MARKED in path.parents:
            continue
        if wanted and wanted != path.parent and wanted not in path.parents:
            continue
        cases, said = scan(path)
        found.extend(cases)
        problems.extend(said)
    return found, problems


def write_main(found: list[Case], target: Path) -> None:
    """Generate the one main that calls all of them.

    Every call is its own try, so one failing test does not stop the rest.
    That is the whole reason this is generated rather than written: the shape
    is identical every time and there will eventually be thousands of them.
    """
    lines = [
        "# Generated by tools/mojotest/run.py. Do not edit, and do not commit.",
        "",
        "from std.sys import exit",
        "",
    ]
    for module in sorted({case.module for case in found}):
        lines.append(f"import {module}")
    lines += ["", "", "def main():", "    var failed = 0"]
    for case in found:
        lines += [
            "    try:",
            f"        {case.module}.{case.name}()",
            "    except e:",
            "        failed += 1",
            f'        print("FAIL {case.label}")',
            '        print("    ", e)',
        ]
    lines += [
        f'    print("ran", {len(found)}, "tests,", failed, "failed")',
        "    if failed:",
        # exit rather than raise, so a failing suite reports a count and not an
        # unhandled exception on top of the failures it just printed.
        "        exit(1)",
        "",
    ]
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(lines))


def ignored(path: Path) -> bool:
    """Whether git is set up to never commit the generated main.

    Checked rather than assumed. The .gitignore entry is one line away from
    being deleted by somebody tidying up, and a generated file appearing in a
    commit is the kind of thing that is noticed a month later.
    """
    if not shutil.which("git"):
        return True
    out = subprocess.run(
        ["git", "check-ignore", "-q", str(path)], cwd=ROOT, capture_output=True
    )
    return out.returncode == 0


def build_and_run(scratch: Path, quiet: bool, race: bool = False) -> tuple[int, str, list[str]]:
    """Build the suite, run it, and give back its exit code, output and problems.

    Streamed rather than captured and printed at the end, so a suite that takes
    a while says what it is doing. Paths are made relative on the way past,
    because Mojo reports the absolute one and nothing in a terminal can be
    clicked when it is prefixed by somebody's home directory.

    The core.errors slot is linked into every suite, whether or not the suite
    touches core.errors. It is a few hundred bytes and it makes the link line
    the same everywhere, which is worth more than the bytes: a test that only
    fails when some other test happens to be in the same build is the kind of
    thing that costs a day.

    Quiet is for the selftest, whose fixtures are supposed to fail. Printing
    that failure would put the word FAIL in the log of a build that passed,
    and a log nobody can read for real failures is a log nobody reads.

    Race turns on the thread sanitiser. Its report goes to stderr, which is
    folded into stdout below, and it does not change the exit code on its own,
    so the caller has to read the output for it. That is deliberate on the
    sanitiser's part and it is why `suite` looks for the warning by name.

    This build is also where the compile time checks in the library are heard.
    A format string is checked while the interpreter folds the call that uses
    it, and nothing folds a call that no program makes, so the suite binary is
    the one build in this repository that reaches all of our own code. Any line
    carrying our marker is a problem here, and the cache is pointed somewhere
    empty so that a suite built twice says it twice. See tools/lib/cold.py and
    section 10 of docs/design.md.
    """
    slot = shim(scratch)
    if isinstance(slot, str):
        return 1, "", [slot]

    binary = scratch / "suite"
    flags = ["--sanitize", "thread"] if race else []
    built = subprocess.run(
        ["mojo", "build", "-I", str(ROOT), *flags, "-o", str(binary), "-Xlinker", str(slot), str(MAIN)],
        capture_output=True,
        text=True,
        env=environment(scratch / "cache"),
    )
    said = (built.stdout + built.stderr).replace(f"{ROOT}/", "")
    if built.returncode != 0:
        if not quiet:
            sys.stderr.write(said)
        return built.returncode, "", []
    marked = [line.strip() for line in said.splitlines() if MARKER in line]
    if marked:
        return 1, "", marked

    collected = []
    process = subprocess.Popen(
        [str(binary)], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    assert process.stdout is not None
    for line in process.stdout:
        line = line.replace(f"{ROOT}/", "")
        collected.append(line)
        if not quiet:
            sys.stdout.write(line)
    return process.wait(), "".join(collected), []


def suite(
    where: Path, only: str | None, short: bool, quiet: bool = False, race: bool = False
) -> tuple[int, int, str, list[str]]:
    """Find, build and run. Returns cases run, skipped, output and problems."""
    found, problems = discover(where, only)
    if problems:
        return 0, 0, "", problems
    if only and not found:
        return 0, 0, "", [f"no tests match {only}, so nothing ran"]

    skipped = [case for case in found if short and case.slow]
    for case in skipped:
        if not quiet:
            print(f"test: skipping {case.label}, {case.slow}")
    found = [case for case in found if case not in skipped]
    if not found:
        return 0, len(skipped), "", []

    if not shutil.which("mojo"):
        return 0, 0, "", ["mojo is not on PATH, so nothing can be built"]

    write_main(found, MAIN)
    if not ignored(MAIN):
        return 0, 0, "", [f"{MAIN.relative_to(ROOT)} is not ignored by git, fix .gitignore"]

    with tempfile.TemporaryDirectory() as scratch:
        code, output, problems = build_and_run(Path(scratch), quiet, race)
    if problems:
        return 0, 0, "", problems
    if code != 0 and not output:
        return len(found), len(skipped), output, ["the suite did not build"]

    # Both, rather than the first of the two. The sanitiser prints and carries
    # on with the exit code untouched, so reading the output is the only thing
    # that promotes a race to a failure, and a run that races usually fails an
    # assertion as well. Reporting only the assertion would leave the more
    # interesting half sitting in the log.
    said = []
    if RACE_UNAVAILABLE in output:
        return (
            len(found),
            len(skipped),
            output,
            ["the thread sanitiser does not work with this runtime's allocator, which is Linux"],
        )
    if RACE_FOUND in output:
        said.append(f"the thread sanitiser reported {output.count(RACE_FOUND)} race(s)")
    if code != 0:
        said.append("the suite reported failures")
    return len(found), len(skipped), output, said


def selftest() -> int:
    """Prove the runner reports a failure, and reports it usefully.

    A runner that swallows a failing test turns the whole suite into theatre
    and nothing else in the repository would notice. So the fixtures under
    tests/mojotest contain a test that is supposed to fail, and this asserts
    that it is reported, with the file, the line and both values, and that the
    slow one is skipped under --short.

    The third run is the other duty this runner has. The suite build is where a
    compile time complaint from this library becomes a failure, and a check
    that has never fired is a check nobody knows works. tests/mojotest/marked
    holds one wrong format string, and this asserts that building it is
    reported rather than passed over.
    """
    problems = []

    ran, skipped, output, said = suite(FIXTURES, None, short=False, quiet=True)
    if said != ["the suite reported failures"]:
        problems.append(f"the fixtures should have failed, instead got {said or 'a pass'}")
    for needle in (
        "FAIL tests.mojotest.test_failing.test_two_and_two",
        "tests/mojotest/test_failing.mojo:",
        "left: 4",
        "right: 5",
    ):
        if needle not in output:
            problems.append(f"a failure should report {needle!r}, and this one did not")
    if skipped:
        problems.append(f"a full run should skip nothing, and this one skipped {skipped}")

    short_ran, short_skipped, _, _ = suite(FIXTURES, None, short=True, quiet=True)
    if short_skipped != 1:
        problems.append(f"--short should skip the one slow fixture, and it skipped {short_skipped}")
    if short_ran != ran - 1:
        problems.append(f"--short should run {ran - 1} of the fixtures, and it ran {short_ran}")

    _, _, _, complained = suite(MARKED, None, short=False, quiet=True)
    if not any(MARKER in line for line in complained):
        problems.append(
            "the marked fixture should have failed the build with a complaint, "
            f"instead got {complained or 'a pass'}"
        )

    return report("test-selftest", 3, "runs of the fixtures", problems)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", nargs="?", help="run one package: `pixi run test core.strings`")
    parser.add_argument("--short", action="store_true", help="skip the cases marked slow")
    parser.add_argument("--race", action="store_true", help="build under the thread sanitiser")
    parser.add_argument(
        "--selftest", action="store_true", help="check that the runner reports a failure"
    )
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    ran, skipped, _, problems = suite(TESTS, args.package, args.short, race=args.race)
    if not (ran or skipped or problems or args.package):
        print("test: no tests in the tree yet")
        return 0
    if skipped:
        print(f"test: {skipped} slow case(s) skipped, run without --short for all of them")
    return report("test", ran, "tests", problems)


if __name__ == "__main__":
    raise SystemExit(main())
