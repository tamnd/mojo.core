#!/usr/bin/env python3
"""Decide what a codec for a package would look like, or why there is not one.

This is the half of the generator that has opinions. It takes what `docjson`
read out of a package and works out, field by field, what JSON each one turns
into, refusing anything it cannot do rather than emitting code that compiles
and is wrong. `emit.py` then writes out what this decided, and has no
judgement in it at all.

A struct opts in with `codec:"json"` in its own docstring. Nothing is generated
for a struct that has not asked, because a package full of structs is mostly
structs that are nobody's wire format, and generating a codec for all of them
would turn every field of every internal type into a compatibility promise.

The refusals are the interesting part, and each one is a case where Go does
something quietly:

- a private field, which `mojo doc` does not report at all. Go encodes the
  exported fields and leaves the rest at their zero value on the way back. Mojo
  has no zero value, so a decoder here would have to invent one.
- a struct with no `@fieldwise_init`, which is a struct this cannot construct.
- a generic struct. There is one codec per struct here and a generic struct is
  a family of them.
- a field whose type has no JSON to be. A function, a pointer, a struct from
  another package that has no codec of its own.
- a field type this generator has not got to yet, which is refused by name so
  that the list is a to do list rather than a mystery.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from codec import tags as tagging
from docjson.read import Index, Struct, TypeRef, tags

# The integer types, and the bit width to read them at. `Int` and `UInt` are 0,
# which is how `core.strconv` spells "as wide as a machine word here" and is
# the only spelling that is still right on a platform where that is not 64.
SIGNED = {"Int": 0, "Int8": 8, "Int16": 16, "Int32": 32, "Int64": 64}
UNSIGNED = {"UInt": 0, "UInt8": 8, "UInt16": 16, "UInt32": 32, "UInt64": 64}
FLOATING = {"Float32": 32, "Float64": 64}

# `@fieldwise_init` on the struct, which is what says its fields can be passed
# to it in the order they are declared. Decorators stack, so this looks at the
# run of them above the declaration rather than only at the line before it.
DECORATED = re.compile(r"((?:^@\w+[^\n]*\n)*)^struct\s+(\w+)", re.MULTILINE)

# How a struct docstring asks for a codec. A list, because XML and the binary
# formats land later and a struct will want to say `codec:"json,binary"`.
OPT_IN = "codec"

# The field types with an empty value that nobody has to invent: no value, no
# elements, no entries. A document is allowed not to carry one of these, and a
# field of any other type that the document does not carry is an error.
#
# This is the one place the generator is stricter than Go on purpose. Go leaves
# a missing field at its zero value, which is why a Go program cannot tell a
# `count` of nought from a `count` that was never sent, and why so many Go
# structs end up full of pointers to say so. Mojo has no zero value to leave a
# field at, which turns that design question into a question with an answer:
# either the type says it can be empty or the key has to be there.
#
# `omitempty` follows from the same rule. A field left out when it is empty has
# to be a field that can be read back when it is missing, so the option is
# refused anywhere else rather than quietly breaking the round trip.
ABSENT = ("optional", "list", "dict")


@dataclass(frozen=True)
class Encoding:
    """What one type turns into on the wire, and how to spell it in Mojo.

    `spell` is the type as the generated file has to write it, which is not
    always how the field was written: a field declared through a renaming
    import is spelled here by the name the generated file imports it under.
    """

    kind: str
    spell: str
    bits: int = 0
    func: str = ""
    args: tuple[Encoding, ...] = ()

    @property
    def composite(self) -> bool:
        """Whether reading one takes statements rather than an expression."""
        return self.kind in ("list", "dict", "optional")

    def walk(self):
        """This encoding and every one inside it."""
        yield self
        for arg in self.args:
            yield from arg.walk()


@dataclass
class Member:
    """One field of a struct, and what the codec does with it."""

    name: str
    json: str
    encoding: Encoding
    omitempty: bool = False
    skip: bool = False


@dataclass
class Codec:
    """One struct that gets a codec."""

    name: str
    module: str
    func: str
    members: list[Member] = field(default_factory=list)

    @property
    def path(self) -> str:
        return f"{self.module}.{self.name}"

    @property
    def encoded(self) -> list[Member]:
        """The fields that go on the wire, in declaration order."""
        return [m for m in self.members if not m.skip]

    @property
    def decodable(self) -> bool:
        """Whether a decoder can be written.

        A skipped field is a field the document does not carry, and a value
        cannot be constructed without one. Go fills it in with the zero value;
        there is nothing to fill it in with here, so the struct encodes and
        does not decode. That is a real thing to want: a summary written out
        for a log has no reader.
        """
        return all(not m.skip for m in self.members)


@dataclass
class Plan:
    """Every codec in one package, and everything refused along the way."""

    package: str
    codecs: list[Codec] = field(default_factory=list)
    imports: list[tuple[str, str]] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)
    considered: int = 0


def snake(name: str) -> str:
    """`HTTPHeader` as `http_header`, for the name of a generated function."""
    out = re.sub(r"(.)([A-Z][a-z]+)", r"\1_\2", name)
    return re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", out).lower()


def wants(struct: Struct) -> bool:
    """Whether a struct asked for a JSON codec."""
    asked = tags("\n\n".join(part for part in (struct.summary, struct.description) if part))
    return "json" in [part.strip() for part in asked.get(OPT_IN, "").split(",")]


def fieldwise(source: str | None) -> set[str]:
    """The structs in a source file that carry `@fieldwise_init`."""
    if source is None:
        return set()
    return {
        name for decorators, name in DECORATED.findall(source) if "@fieldwise_init" in decorators
    }


def encoding(ref: TypeRef, where: Index, known: dict[str, Codec | None]) -> Encoding | str:
    """What a field type turns into, or why it cannot turn into anything."""
    if ref.kind == "callable":
        return "a function, which has no JSON to be"
    if not ref.resolved:
        return f"`{ref.text}`, which the reader could not resolve to one type"

    name = ref.name
    if name == "Bool":
        return Encoding("bool", "Bool")
    if name in SIGNED:
        return Encoding("int", name, bits=SIGNED[name])
    if name in UNSIGNED:
        return Encoding("uint", name, bits=UNSIGNED[name])
    if name in FLOATING:
        return Encoding("float", name, bits=FLOATING[name])
    if name == "String":
        return Encoding("string", "String")

    if name in ("Optional", "List") and len(ref.args) == 1:
        inner = encoding(ref.args[0], where, known)
        if isinstance(inner, str):
            return inner
        kind = "optional" if name == "Optional" else "list"
        return Encoding(kind, f"{name}[{inner.spell}]", args=(inner,))

    if name == "Dict" and len(ref.args) == 2:
        if ref.args[0].name != "String":
            return f"`{ref.text}`, and a JSON object is keyed by strings"
        inner = encoding(ref.args[1], where, known)
        if isinstance(inner, str):
            return inner
        return Encoding(
            "dict",
            f"Dict[String, {inner.spell}]",
            args=(Encoding("string", "String"), inner),
        )

    nested = where.resolve(ref)
    if nested is not None:
        if nested.path not in known:
            return (
                f"`{ref.text}`, which has no codec. Put `codec:\"json\"` in its "
                "docstring to give it one"
            )
        return Encoding("struct", nested.name, func=snake(nested.name))
    if ref.kind == "imported":
        return f"`{ref.text}`, which is in another package and so needs its own codec there"
    return f"`{ref.text}`, which this generator has no JSON for"


def one(struct: Struct, where: Index, known: dict[str, Codec | None], built: set[str]) -> Codec | list[str]:
    """Plan one struct, or say everything that is wrong with it."""
    problems: list[str] = []
    if struct.generic:
        problems.append("it is generic, and a codec is written for one type rather than a family")
    if not struct.complete:
        hidden = ", ".join(struct.hidden)
        problems.append(
            f"it has private fields ({hidden}) that `mojo doc` does not report, so a "
            "decoder could not construct one"
        )
    if struct.name not in built:
        problems.append("it has no `@fieldwise_init`, so there is no way to construct one")

    codec = Codec(name=struct.name, module=struct.module, func=snake(struct.name))
    named: list[tuple[str, str]] = []
    for entry in struct.fields:
        tag, wrong = tagging.read(entry.name, entry.docstring)
        problems += wrong
        if tag.skip:
            codec.members.append(Member(entry.name, "", Encoding("skip", ""), skip=True))
            continue
        found = encoding(entry.type, where, known)
        if isinstance(found, str):
            problems.append(f"{entry.name} is {found}")
            continue
        if tag.omitempty and found.kind not in ABSENT:
            problems.append(
                f"{entry.name} is tagged `omitempty` and is `{found.spell}`, which has "
                "no empty value to leave out or to read back. Make it "
                f"`Optional[{found.spell}]`, which is how a field says it may be missing"
            )
        named.append((entry.name, tag.name))
        codec.members.append(Member(entry.name, tag.name, found, omitempty=tag.omitempty))
    problems += tagging.collide(named)
    return codec if not problems else problems


def plan(where: Index) -> Plan:
    """Every codec in a package, in a stable order."""
    out = Plan(package=where.package)
    modules = sorted(where.modules, key=lambda m: m.name)
    asked = [(m, s) for m in modules for s in m.structs if wants(s)]
    out.considered = len(asked)

    # Two passes, because a struct may hold another that has not been planned
    # yet, including itself. The first says which structs are meant to have a
    # codec so that the second can resolve a field to one.
    known: dict[str, Codec | None] = {s.path: None for _, s in asked}
    reasons: dict[str, list[str]] = {}

    # One generated file per package holds every codec in it, so two structs
    # with the same name in two modules would need the same name imported
    # twice. That is a rename in the package rather than something a generator
    # can work around.
    for _, struct in asked:
        twins = [s.path for _, s in asked if s.name == struct.name]
        if len(twins) > 1:
            reasons[struct.path] = [
                "another module in this package declares a struct called "
                f"{struct.name} as well ({', '.join(p for p in twins if p != struct.path)})"
            ]

    for module, struct in asked:
        if struct.path in reasons:
            continue
        built = fieldwise(module.source.read_text() if module.source else None)
        result = one(struct, where, known, built)
        if isinstance(result, Codec):
            known[struct.path] = result
        else:
            reasons[struct.path] = result

    # A struct that holds a refused one cannot be written either, and the one
    # holding that cannot either, so this runs until nothing more falls out.
    while True:
        gone = [
            path
            for path, codec in known.items()
            if codec is not None
            and any(
                e.kind == "struct" and known.get(nested_path(e, known)) is None
                for m in codec.members
                for e in m.encoding.walk()
            )
        ]
        if not gone:
            break
        for path in gone:
            codec = known[path]
            assert codec is not None
            missing = sorted(
                {
                    e.spell
                    for m in codec.members
                    for e in m.encoding.walk()
                    if e.kind == "struct" and known.get(nested_path(e, known)) is None
                }
            )
            reasons[path] = [f"it holds {', '.join(missing)}, which was refused"]
            known[path] = None

    for _, struct in asked:
        codec = known.get(struct.path)
        if codec is None:
            for reason in reasons.get(struct.path, ["it was refused"]):
                out.problems.append(f"{struct.path}: {reason}")
            continue
        out.codecs.append(codec)

    out.imports = sorted({(c.module, c.name) for c in out.codecs})
    return out


def nested_path(encoding: Encoding, known: dict[str, Codec | None]) -> str:
    """The path of the struct a nested encoding names.

    Encodings carry the struct's own name rather than its path, because that is
    what the generated file writes. There is one struct per name in a package
    with a codec, since two modules that both declare a `Point` cannot both be
    imported into one generated file anyway, so the name is enough to find it
    again here.
    """
    for path in known:
        if path.rsplit(".", 1)[-1] == encoding.spell:
            return path
    return encoding.spell
