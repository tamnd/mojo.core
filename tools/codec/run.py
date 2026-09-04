#!/usr/bin/env python3
"""Generate JSON encoders and decoders for a package.

    pixi run codec core.encoding.json          a package in this tree
    pixi run codec ~/src/myapp/inventory       any package anywhere

Point it at a directory and it writes `json_codec.mojo` into it, holding one
encoder and one decoder for every struct in the package whose docstring says
`codec:"json"`. Nothing else in the package is touched, and deleting the
generated file leaves a package that still builds.

There is no reflection in Mojo, so this is how a struct gets a wire format
without hand writing one. It reads what `mojo doc` says about the package
through `tools/docjson`, decides what each field turns into in `plan.py`, and
writes it out in `emit.py`.

It refuses rather than guesses. A misspelled struct tag, an option that only Go
has, two fields that would collide under one JSON name, a field whose type has
no JSON to be: all of them stop the run with a message naming the field, and
nothing is written. That is the point of generating a codec at build time
rather than reflecting over the struct at run time, and it is most of the
difference between this and Go's `encoding/json`.

`--selftest` runs the generator over a fixture package in testdata, checks that
what it writes is what is checked in there byte for byte, builds the result
outside this repository with the compiler and runs it. Every fact this depends
on is a fact about a compiler that is still being written, so none of it is
recorded and replayed.
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

from codec import tags as tagging
from codec.emit import emit
from codec.plan import plan, snake
from docjson.read import index
from lib.native import shim
from lib.tree import ROOT, packages, report

TESTDATA = Path(__file__).resolve().parent / "testdata"

OUTPUT = "json_codec.mojo"

# What a compiler warning looks like in a build log, so that "compiles with no
# warnings" is checked rather than claimed. Generated code nobody reads is
# exactly the code a warning goes unnoticed in.
WARNING = re.compile(r"^.*: warning: ", re.MULTILINE)


def where(target: str, includes: list[str]) -> tuple[Path, list[Path]] | str:
    """The directory to read and the include path to read it with.

    A package of this library can be named rather than pointed at, because
    `pixi run codec core.encoding.json` is what somebody in this tree will
    type. Anything else is a path, and its parent goes on the include path so
    that the package can be imported by its own name.
    """
    directory = Path(target).expanduser()
    if not directory.exists() and "/" not in target:
        named = [p for p in packages() if p.name == target]
        if not named:
            return f"there is no package called {target}, and no directory either"
        directory = named[0].path
    if not directory.is_dir():
        return f"{target} is not a directory"
    directory = directory.resolve()
    roots = [Path(i).expanduser().resolve() for i in includes]
    if ROOT not in roots:
        roots.append(ROOT)
    if directory.parent not in roots:
        roots.append(directory.parent)
    return directory, roots


def build(directory: Path, includes: list[Path]) -> tuple[str, list[str]]:
    """The codec for one package, and everything that stopped it being written."""
    read = index(directory, includes)
    if isinstance(read, str):
        return "", [read]
    decided = plan(read)
    if decided.problems:
        return "", decided.problems
    if not decided.codecs:
        return "", []
    return emit(decided), []


def generate(target: str, includes: list[str], check: bool) -> tuple[int, list[str]]:
    """Write or check one package's codec. Gives back structs done and problems."""
    found = where(target, includes)
    if isinstance(found, str):
        return 0, [found]
    directory, roots = found
    text, problems = build(directory, roots)
    if problems:
        return 0, problems
    path = directory / OUTPUT
    if not text:
        return 0, [
            f"no struct in {directory.name} asked for a codec. Put `codec:\"json\"` in "
            "the docstring of one and run this again"
        ]
    current = path.read_text() if path.is_file() else None
    if check:
        if current != text:
            verb = "is not what" if current is not None else "is missing next to"
            return 0, [f"{path} {verb} the generator writes, run `pixi run codec {target}`"]
    elif current != text:
        path.write_text(text)
        print(f"codec: wrote {path}")
    return text.count("\ndef marshal_json("), []


def compile_and_run(home: Path, driver: Path) -> list[str]:
    """Build a program against a generated codec and run it.

    Nothing here is mocked. The codec is generated into a copy of the fixture
    outside this repository, built by the compiler with warnings showing, and
    run, which is the only evidence that any of it works that is worth having.
    """
    slot = shim(home)
    if isinstance(slot, str):
        return [slot]
    binary = home / "driver"
    built = subprocess.run(
        [
            "mojo",
            "build",
            "-I",
            str(ROOT),
            "-I",
            str(home),
            "-o",
            str(binary),
            "-Xlinker",
            str(slot),
            str(driver),
        ],
        capture_output=True,
        text=True,
    )
    log = built.stdout + built.stderr
    if built.returncode != 0:
        return [f"the generated codec did not build:\n{log.strip()}"]
    if WARNING.search(log):
        return [f"the generated codec built with warnings:\n{log.strip()}"]
    ran = subprocess.run([str(binary)], capture_output=True, text=True)
    if ran.returncode != 0:
        return [f"the generated codec is wrong:\n{(ran.stdout + ran.stderr).strip()}"]
    print(f"codec selftest: {ran.stdout.strip()}")
    return []


def unformatted(text: str) -> list[str]:
    """Whether `mojo format` would rewrite what the generator just wrote.

    Two files that have to be identical cannot be one file the formatter
    changes: somebody runs the formatter over the package, the codec moves, and
    the next run of the generator undoes it. So the emitter writes what the
    formatter writes, and this is what says so.
    """
    with tempfile.TemporaryDirectory() as scratch:
        path = Path(scratch) / OUTPUT
        path.write_text(text)
        done = subprocess.run(
            ["mojo", "format", "-q", str(path)], capture_output=True, text=True
        )
        if done.returncode != 0:
            return [f"the formatter would not read the generated codec:\n{done.stderr.strip()}"]
        if path.read_text() != text:
            return ["`mojo format` rewrites the generated codec, so it cannot stay identical"]
    return []


def outside() -> list[str]:
    """Generate, build and run the fixture somewhere else entirely.

    The issue this generator answers asks for a struct outside this repository
    to get a working codec from one command, so the check for it happens
    outside this repository rather than in a fixture that quietly enjoys being
    next door to the library.
    """
    if not shutil.which("cc") and not shutil.which("clang"):
        return ["there is no C compiler here, so the driver cannot be linked"]
    with tempfile.TemporaryDirectory() as scratch:
        home = Path(scratch).resolve()
        shutil.copytree(TESTDATA / "inventory", home / "inventory")
        shutil.copy(TESTDATA / "driver.mojo", home / "driver.mojo")
        # Generated from nothing, so that what is being built is what this run
        # wrote rather than what was checked in beside the fixture.
        (home / "inventory" / OUTPUT).unlink(missing_ok=True)
        done, problems = generate(str(home / "inventory"), [str(home)], check=False)
        if problems:
            return problems
        if done == 0:
            return ["the fixture generated no codecs at all"]
        return compile_and_run(home, home / "driver.mojo")


def selftest() -> int:
    """Check the generator against the fixtures."""
    failures: list[str] = []
    ran = 0

    def check(what: str, got, want) -> None:
        nonlocal ran
        ran += 1
        if got != want:
            failures.append(f"{what}: got {got!r}, wanted {want!r}")

    # The tag reader on its own. Every one of these is a mistake Go accepts and
    # this refuses, so each is a line somebody would otherwise be debugging.
    check("a plain tag", tagging.read("count", '`json:"n"`')[0], tagging.Tag(name="n"))
    check("no tag at all", tagging.read("count", "how many")[0], tagging.Tag(name="count"))
    check("an empty name", tagging.read("count", '`json:",omitempty"`')[0],
          tagging.Tag(name="count", omitempty=True))
    check("a skipped field", tagging.read("count", '`json:"-"`')[0], tagging.Tag(skip=True))
    check("a field called minus", tagging.read("count", '`json:"-,"`')[0], tagging.Tag(name="-"))
    check("an unknown option", tagging.read("c", '`json:"n,omitEmpty"`')[1],
          ["c has `omitEmpty` in its tag, which this generator does not implement. "
           "It knows `omitempty`"])
    check("a stray comma", len(tagging.read("c", '`json:"n,,omitempty"`')[1]), 1)
    check("the same option twice", len(tagging.read("c", '`json:"n,omitempty,omitempty"`')[1]), 1)
    check("a name Go would throw away", len(tagging.read("c", '`json:"a\\"b"`')[1]), 1)
    check("a tag with a space in it", len(tagging.read("c", '`json: "n"`')[1]), 1)
    check("a tag with no quotes", len(tagging.read("c", "`json:n`")[1]), 1)
    check("prose about a field", tagging.read("c", "the `json` of it")[1], [])
    check("two fields under one name", tagging.collide([("a", "n"), ("b", "n")]),
          ['a and b are both encoded as "n"'])

    check("a name for a function", snake("HTTPHeader"), "http_header")
    check("and a plain one", snake("Item"), "item")

    if not shutil.which("mojo"):
        return report("codec selftest", ran, "checks", failures + ["mojo is not on PATH"])

    # What the generator writes, against what is checked in beside the fixture.
    # This is the byte for byte rerun the issue asks for, and it is also how a
    # change to the emitter is reviewed: the diff is in the repository.
    text, problems = build(TESTDATA / "inventory", [ROOT, TESTDATA])
    failures += problems
    checked_in = TESTDATA / "inventory" / OUTPUT
    if not problems:
        ran += 1
        if not checked_in.is_file():
            failures.append(f"{checked_in} is missing, run `pixi run codec {checked_in.parent}`")
        elif checked_in.read_text() != text:
            failures.append(
                f"{checked_in.relative_to(ROOT)} is not what the generator writes, "
                "run `pixi run codec tools/codec/testdata/inventory`"
            )
        ran += 1
        failures += unformatted(text)

    # And the refusals, which are the reason to prefer a generator to a
    # reflector. Each one is a struct that must not get a codec, checked by the
    # first few words of the message rather than the whole of it.
    read = index(TESTDATA / "refuse", [ROOT, TESTDATA])
    if isinstance(read, str):
        failures.append(read)
    else:
        said = plan(read).problems
        for want in REFUSALS:
            ran += 1
            if not any(want in problem for problem in said):
                failures.append(f"nothing in the refusals said {want!r}, they say {said!r}")
        ran += 1
        if len(said) != len(REFUSALS):
            failures.append(f"the refusals are {len(said)} and the checks are {len(REFUSALS)}")

    ran += 1
    failures += outside()
    return report("codec selftest", ran, "checks", failures)


# One line of each refusal the fixture package is supposed to produce. Written
# out rather than counted, because the point of a refusal is what it tells
# somebody, and a count would go on passing while the messages turned to
# nonsense.
REFUSALS = (
    "Generic: it is generic",
    "Hidden: it has private fields (_secret)",
    "Bare: it has no `@fieldwise_init`",
    "Funcy: run is a function, which has no JSON to be",
    "Typo: name: `json: \"name\"` is not a struct tag, and looks like one",
    "Option: count has `omitEmpty` in its tag",
    'Clash: first and second are both encoded as "a"',
    "Wrong: count is tagged `omitempty` and is `Int`",
    "Foreign: into is `Builder`, which is in another package",
    "Holder: what is `Ignored`, which has no codec",
    "Chained: it holds Hidden, which was refused",
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", nargs="?", help="a package name, or a path to one")
    parser.add_argument("-I", "--include", action="append", default=[], help="an import root")
    parser.add_argument("--check", action="store_true", help="fail on a diff instead of writing")
    parser.add_argument("--selftest", action="store_true", help="check the generator")
    args = parser.parse_args()

    if args.selftest:
        return selftest()
    if not args.package:
        return report("codec", 0, "structs", ["say which package to generate a codec for"])
    if not shutil.which("mojo"):
        return report("codec", 0, "structs", ["mojo is not on PATH"])

    done, problems = generate(args.package, args.include, args.check)
    return report("codec", done, "structs", problems)


if __name__ == "__main__":
    raise SystemExit(main())
