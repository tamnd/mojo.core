#!/usr/bin/env python3
"""What `mojo doc` says about a package, as this library reads it.

`pixi run docjson core.math.big` prints every public struct in a package with
its fields, the resolved type of each one and any struct tags in its docstring.
That is the whole of the reflection substitute, and printing it is how somebody
finds out why a generated codec came out the way it did without reading the
generator.

With no argument it reads every package in the tree, which is slow and is not
part of `pixi run check`. What is part of `check` is `--selftest`, which runs
the reader over a fixture package in testdata and asserts what comes back.
Every fact the reader depends on is a fact about a compiler that is still being
written, so the fixture is compiled on every run rather than checked in as
JSON: a change to how `mojo doc` renders a type has to fail here, loudly, and
not months later in a generator.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from docjson.read import Index, as_rendered, document, index, read, tags
from lib.tree import ROOT, packages, report

TESTDATA = Path(__file__).resolve().parent / "testdata"


def show(where: Index) -> list[str]:
    """Print a package and give back what could not be resolved."""
    problems: list[str] = []
    print(f"{where.package}: {len(where.structs)} struct(s)")
    for struct in where.structs:
        marks = []
        if struct.generic:
            marks.append("[" + ", ".join(p.name for p in struct.parameters) + "]")
        if not struct.complete:
            marks.append(f"incomplete, {len(struct.hidden)} private field(s)")
        suffix = "  " + ", ".join(marks) if marks else ""
        print(f"  {struct.path}{suffix}")
        for entry in struct.fields:
            tag = "  " + " ".join(f'{k}:"{v}"' for k, v in entry.tags.items())
            print(f"    {entry.name}: {entry.type.text}  [{entry.type.kind}]{tag.rstrip()}")
            for ref in entry.type.walk():
                if ref.kind == "ambiguous":
                    problems.append(
                        f"{struct.path}.{entry.name}: `{ref.name}` could be "
                        + " or ".join(ref.candidates)
                    )
    return problems


def selftest() -> int:
    """Read the fixture package and check the answers.

    Each assertion below is a fact some generator is going to rely on. They are
    written out one at a time rather than compared against a recorded dump,
    because a dump tells you that something changed and this tells you what.
    """
    failures: list[str] = []
    ran = 0
    if not shutil.which("mojo"):
        return report("docjson selftest", 0, "checks", ["mojo is not on PATH"])

    where = index(TESTDATA / "fixture", [ROOT, TESTDATA])
    if isinstance(where, str):
        return report("docjson selftest", 0, "checks", [where])

    def check(what: str, got, want) -> None:
        nonlocal ran
        ran += 1
        if got != want:
            failures.append(f"{what}: got {got!r}, wanted {want!r}")

    check("the package name", where.package, "fixture")
    check("how many structs", len(where.structs), 4)

    point = where.find("fixture.shapes.Point")
    line = where.find("fixture.shapes.Line")
    boxed = where.find("fixture.shapes.Boxed")
    record = where.find("fixture.records.Record")
    for name, struct in (("Point", point), ("Line", line), ("Boxed", boxed), ("Record", record)):
        if struct is None:
            failures.append(f"{name} was not found at all")
    if None in (point, line, boxed, record):
        return report("docjson selftest", len(failures), "checks", failures)

    # A tag survives the round trip through the compiler byte for byte, which
    # is the whole premise: a tag is written in a docstring in Mojo because
    # there is nowhere else to write it, and it is only worth anything if what
    # comes back out is what went in.
    check("the tag on Point.x", point.fields[0].tags, {"json": "x"})
    check("the docstring Point.x was read from", point.fields[0].summary,
          'The distance right of the origin. `json:"x"`')

    # And a tag in a later paragraph, which `mojo doc` puts in a different
    # field of the JSON from the one above.
    check("the tags on Point.y", point.fields[1].tags, {"json": "y,omitempty", "xml": "Y"})
    check("where Point.y's tag was", point.fields[1].summary.count("json:"), 0)

    # Backticked prose is not a tag. Boxed.label has two backticked spans and
    # neither is one.
    check("tags on Boxed.label", boxed.fields[0].tags, {})

    # Nested: a field whose type is another struct in the same package.
    check("the type of Line.start", line.fields[0].type.kind, "local")
    check("what Line.start resolves to", line.fields[0].type.path, "fixture.shapes.Point")
    found = where.resolve(line.fields[0].type)
    check("the struct Line.start points at", found.path if found else None, "fixture.shapes.Point")
    check("the tag on Line.start", line.fields[0].tags, {"json": "from"})

    # Generic: a field whose type is the struct's own parameter.
    check("whether Boxed is generic", boxed.generic, True)
    check("Boxed's parameter", boxed.parameters[0].name, "T")
    check("its bound", boxed.parameters[0].bound, "Copyable & Deinitable")
    check("the type of Boxed.value", boxed.fields[1].type.kind, "parameter")
    check("what Boxed.value resolves to", where.resolve(boxed.fields[1].type), None)

    # A type parameterised twice over, split without splitting inside.
    counts = boxed.fields[2].type
    check("the head of Boxed.counts", counts.name, "Dict")
    check("how many arguments it has", len(counts.args), 2)
    check("the first", counts.args[0].name, "String")
    check("the second", counts.args[1].text, "List[Int]")
    check("and the one inside that", counts.args[1].args[0].name, "Int")
    check("all of them prelude", {r.kind for r in counts.walk()}, {"prelude"})

    # Another package: nothing in the JSON says where `Builder` came from, so
    # this is the import line being read.
    into = record.fields[2]
    check("the type of Record.into", into.type.kind, "imported")
    check("what Record.into resolves to", into.type.path, "core.strings.Builder")
    check("the tag on Record.into", into.tags, {"json": "-"})

    # An aliased import. `mojo doc` prints the declared name, so the JSON says
    # `Int` for a field written `BigInt`, and it is the source that settles it.
    total = record.fields[3]
    check("what mojo doc printed for Record.total", total.rendered, "Int")
    check("what the source says", total.type.text, "BigInt")
    check("the type of Record.total", total.type.kind, "imported")
    check("what it resolves to", total.type.path, "core.math.big.Int")

    # A function typed field, which resolves to nothing because there is
    # nothing to resolve, and is told apart from a name that could not be found.
    drop = record.fields[4]
    check("the kind of Record.drop", drop.type.kind, "callable")
    check("what mojo doc called it", drop.rendered, "def(Int) thin -> None")
    check("whether it counts as resolved", drop.type.resolved, False)

    # The private field, which is not in the JSON at all.
    check("what Record hides", record.hidden, ("_seed",))
    check("whether Record is complete", record.complete, False)
    check("whether Point is", point.complete, True)

    # Traits, including one declared in the fixture itself.
    check("whether Point is Named", point.has_trait("fixture.shapes.Named"), True)
    check("by its bare name too", point.has_trait("Named"), True)
    check("whether Line is", line.has_trait("Named"), False)
    check("a prelude conformance", point.has_trait("std.traits.copyable.Copyable"), True)

    # Everything above was settled by reading the source. The two things that
    # depend on that, and what is left without it, are pinned here rather than
    # left as a claim in a docstring.
    #
    # First the fallback: a field the source scan did not find falls back to the
    # name `mojo doc` printed, resolved under the shadowing rules. A plain
    # import shadows the prelude and is settled. A renaming import does not
    # shadow, so it collides with the prelude and both are reported.
    records = [m for m in where.modules if m.name == "records"][0]
    def rendered(name: str):
        return as_rendered(name, records, set())

    check("a plainly imported name", rendered("Builder").path, "core.strings.Builder")
    check("one imported from this package", rendered("Point").path, "fixture.shapes.Point")
    check("a renamed one", rendered("Int").kind, "ambiguous")
    check("what it might be", set(rendered("Int").candidates), {"core.math.big.Int", "Int"})
    check("a name nothing provides", rendered("Nowhere").kind, "unknown")

    # And the JSON with no source at all, which is the weakest reading there is:
    # no import lines to resolve against and no private fields to find. This is
    # what a generator would be working from if the source were not read, and it
    # is here so that the difference is a fact rather than an assertion.
    alone = document(TESTDATA / "fixture", [ROOT, TESTDATA])
    if isinstance(alone, str):
        return report("docjson selftest", ran, "checks", failures + [alone])
    thin = read(alone, "fixture").find("fixture.records.Record")
    if thin is None:
        return report("docjson selftest", ran, "checks", failures + ["Record was not found"])
    check("Record.into with no source", thin.fields[2].type.kind, "unknown")
    check("Record.total with no source", thin.fields[3].type.kind, "prelude")
    check("whether the private field is visible", thin.hidden, ())
    check("and so whether the struct looks complete", thin.complete, True)

    # The tag parser on its own, for the cases the fixture cannot reach: an
    # empty value, an escaped quote, and spans that are prose rather than tags.
    check("an empty tag value", tags('`json:""`'), {"json": ""})
    check("an escaped quote", tags(r'`json:"a\"b"`'), {"json": 'a"b'})
    check("prose", tags("see `Builder.write_string` and `json`"), {})
    check("a span that is nearly a tag", tags("`json: \"x\"`"), {})
    check("nothing at all", tags(""), {})

    return report("docjson selftest", ran, "checks", failures)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", nargs="?", help="a package name, such as core.math.big")
    parser.add_argument("--selftest", action="store_true", help="check the reader")
    args = parser.parse_args()

    if args.selftest:
        return selftest()
    if not shutil.which("mojo"):
        return report("docjson", 0, "packages", ["mojo is not on PATH"])

    wanted = [p for p in packages() if not args.package or p.name == args.package]
    if args.package and not wanted:
        return report("docjson", 0, "packages", [f"no package called {args.package}"])

    problems: list[str] = []
    read = 0
    for package in wanted:
        if not package.started:
            continue
        where = index(package.path, [ROOT])
        if isinstance(where, str):
            problems.append(f"{package.name}: {where}")
            continue
        problems += show(where)
        read += 1
    return report("docjson", read, "packages", problems)


if __name__ == "__main__":
    raise SystemExit(main())
