"""Read `mojo doc` JSON and answer questions about structs.

There is no reflection in Mojo and there is not going to be, so everything in
this library that Go builds on runtime type information is built on this
instead: `mojo doc` emits JSON with every public struct, its fields, their
types, the traits it implements and the docstring attached to each field. That
last part is where struct tags live, because a Go tag written in backticks goes
in the field docstring and comes out of the JSON intact.

This module is the reader. It parses the JSON, models what is in it, resolves
the type names it finds, and hands the result to a generator. Six packages will
read the same output, so the questions it can be asked matter more than the
shape of the JSON underneath, and the shape of the JSON is not part of what it
promises.

Four facts about that JSON decided how this is written, and three of them are
awkward.

The good one first. A docstring arrives split in two, `summary` for the first
paragraph with its line wrapping already removed and `description` for the
rest, so a tag can be in either and both are searched.

A field type is a rendered string and nothing more. `List[Dict[String, Int]]`
arrives as those characters, with no path to any of the three names in it. So
the names are resolved here, against the imports of the module the field was
declared in.

The name it renders is the declared name and not the local one. A field written
`var total: BigInt` after `from core.math.big import Int as BigInt` prints as
`Int`, which is also the name of the ordinary machine integer, and a field
written `var reader: IoReader` prints as `Reader` in a module that also imports
a different `Reader` under its own name. Neither can be told apart from the
JSON alone.

Private fields are not in the JSON at all. A struct with a `var _hidden: Int`
looks exactly like a struct without one, and a decoder generated from that
would construct a value that cannot exist.

The last two are why this reads the module's source as well as the JSON. Not to
replace it, because the source does not carry the docstring split, the
conformances or the resolved parameter bounds, but to answer the two questions
the JSON cannot: which fields are missing from it, and what each field was
actually written as. A name as written is a name the compiler resolved in that
module's scope, so `IoReader` is one thing and `Reader` is another and there is
nothing left to guess at.

When the source is not there, the JSON's own names are resolved instead, under
the shadowing rules the compiler uses, and a name that could be two things is
reported as ambiguous rather than picked. A generator that guessed would emit a
codec for the wrong type and compile.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

# The names that are in scope everywhere without an import, checked against the
# compiler rather than guessed at: every one of these compiles in a file with no
# imports in it, and `Set`, `Stringable`, `Representable` and
# `EqualityComparable` are not here because they do not.
#
# A missing entry turns a resolved type into an unknown one, which a consumer
# can see and refuse, and a wrong entry would turn one into a lie, so this list
# is worth keeping short and worth keeping true.
PRELUDE = frozenset(
    """
    AnyType Bool Boolable Byte Codepoint Copyable DType Defaultable Deinitable
    Dict Error Float16 Float32 Float64 Hashable ImmOrigin ImmutableAnyOrigin
    InlineArray Int Int8 Int16 Int32 Int64 Intable List Movable MutOrigin MutableAnyOrigin
    OpaquePointer Optional Origin Pointer SIMD Sized Span StaticString String
    StringLiteral StringSlice Tuple UInt UInt8 UInt16 UInt32 UInt64
    UnsafePointer Writable Writer
    """.split()
)

# A struct tag, as Go writes it and as this library copies it: one or more
# `key:"value"` pairs inside a single pair of backticks. The docstrings in this
# tree are full of backticked names that are not tags, so the whole span has to
# match the grammar before any of it is read as one.
BACKTICKED = re.compile(r"`([^`]*)`")
TAG_PAIR = re.compile(r'(\w+):"((?:[^"\\]|\\.)*)"')
TAG_SPAN = re.compile(r'^\s*(?:\w+:"(?:[^"\\]|\\.)*"\s*)+$')

# A function type, which is a type and is not a name, so nothing is going to
# resolve it and a codec is never going to be written for it. `mojo doc` prints
# `def(Int) thin -> None` and the source says much the same, so both are caught
# by what they start with.
CALLABLE = re.compile(r"^(?:def|fn)\s*\(")

# `from core.strings import Builder`, in both spellings, since `mojo format`
# rewrites the one line form into the parenthesised one as soon as the names
# stop fitting on a line.
FROM_IMPORT = re.compile(r"^from\s+([\w.]+)\s+import\s+(?:\(([^)]*)\)|([^(\n]+))$", re.MULTILINE)
PLAIN_IMPORT = re.compile(r"^import\s+([\w.]+)(?:\s+as\s+(\w+))?\s*$", re.MULTILINE)

# A struct declaration and the fields inside it. This does not have to
# understand Mojo, only to agree with it about where a struct body starts and
# stops and what a field declaration looks like.
STRUCT_LINE = re.compile(r"^struct\s+(\w+)", re.MULTILINE)
TRAIT_LINE = re.compile(r"^trait\s+(\w+)", re.MULTILINE)
FIELD_LINE = re.compile(r"^(\s+)var\s+(\w+)\s*:\s*(.+?)\s*(?:=.*)?$")


@dataclass(frozen=True)
class TypeRef:
    """One field type, as written and as resolved.

    `text` is the spelling that was resolved, which is how the field was
    written when the source was there to read and what `mojo doc` printed when
    it was not. `Field.rendered` is always the second of those, for a caller
    that wants to show what the compiler said.

    `kind` is where it was found: `prelude`, `local` for the module it is in,
    `imported`, `parameter` for a compile time parameter of the struct itself,
    `callable` for a function type, which is a type that is not a name,
    `ambiguous` for a name that could be two things, and `unknown` for one that
    could be found nowhere.
    """

    text: str
    name: str
    args: tuple[TypeRef, ...] = ()
    path: str = ""
    kind: str = "unknown"
    candidates: tuple[str, ...] = ()

    @property
    def resolved(self) -> bool:
        """Whether the head name was pinned to exactly one thing."""
        return self.kind in ("prelude", "local", "imported", "parameter")

    def walk(self):
        """This reference and every one inside it, outermost first."""
        yield self
        for arg in self.args:
            yield from arg.walk()


@dataclass(frozen=True)
class Parameter:
    """A compile time parameter of a struct, such as the `T` in `List[T]`."""

    name: str
    bound: str


@dataclass
class Field:
    """One public field of a struct."""

    name: str
    type: TypeRef
    rendered: str = ""
    summary: str = ""
    description: str = ""
    tags: dict[str, str] = field(default_factory=dict)

    @property
    def docstring(self) -> str:
        """Both halves of the docstring, in the order they were written."""
        return "\n\n".join(part for part in (self.summary, self.description) if part)


@dataclass
class Struct:
    """One public struct, with everything a generator needs to write code for it."""

    name: str
    module: str
    package: str
    summary: str = ""
    description: str = ""
    fields: list[Field] = field(default_factory=list)
    parameters: list[Parameter] = field(default_factory=list)
    traits: tuple[str, ...] = ()
    hidden: tuple[str, ...] = ()

    @property
    def path(self) -> str:
        """The dotted path this struct is declared at."""
        return f"{self.module}.{self.name}"

    @property
    def complete(self) -> bool:
        """Whether every field the struct has is a field this can see.

        False means the struct has a private field, which `mojo doc` does not
        report. A generator has to refuse the struct rather than write a codec
        for the fields it can see, because the value that codec constructs is
        missing one.
        """
        return not self.hidden

    @property
    def generic(self) -> bool:
        """Whether the struct takes compile time parameters."""
        return bool(self.parameters)

    def has_trait(self, path: str) -> bool:
        """Whether the struct implements the named trait.

        Takes a dotted path such as `core.io.Writer`, or a bare name for the
        conformances `mojo doc` reports without one.
        """
        return path in self.traits or any(t.rsplit(".", 1)[-1] == path for t in self.traits)


@dataclass
class Scope:
    """The names a module's import lines put in front of it.

    Three maps of names rather than one, because the three spellings of an
    import behave differently and the difference is the whole of what makes a
    name resolvable.

    `names` is what the module can write: a plain `from x import Y` under `Y`,
    a renaming `from x import Y as Z` under `Z`. This is the map that settles a
    type read from the source.

    `declared` and `aliased` are the same imports keyed by the name they were
    declared with, which is the name `mojo doc` prints. A plain import shadows
    the prelude, so `declared` settles a type read from the JSON. A renaming
    import does not shadow anything, so `aliased` collides with the prelude
    instead, and that collision is what cannot be settled from the JSON.

    `modules` is `import x as y`, under `y`. A field written `y.Y` is resolved
    through it and one written `Y` is not, because claiming every loose name
    for the module would be a guess.
    """

    names: dict[str, str] = field(default_factory=dict)
    declared: dict[str, str] = field(default_factory=dict)
    aliased: dict[str, str] = field(default_factory=dict)
    modules: dict[str, str] = field(default_factory=dict)


@dataclass
class Module:
    """One source file, the names it can see, and what it declares."""

    name: str
    package: str
    source: Path | None = None
    scope: Scope = field(default_factory=Scope)
    structs: list[Struct] = field(default_factory=list)
    traits: list[str] = field(default_factory=list)
    declares: set[str] = field(default_factory=set)

    @property
    def path(self) -> str:
        """The dotted path of the module itself."""
        return f"{self.package}.{self.name}"


@dataclass
class Index:
    """Everything read out of one package."""

    package: str
    modules: list[Module] = field(default_factory=list)

    @property
    def structs(self) -> list[Struct]:
        """Every public struct in the package, in the order they were read."""
        return [s for m in self.modules for s in m.structs]

    def by_path(self) -> dict[str, Struct]:
        """Every struct keyed by the dotted path it is declared at."""
        return {s.path: s for s in self.structs}

    def find(self, name: str) -> Struct | None:
        """One struct by its dotted path or by its bare name.

        A bare name that two modules both declare gives back nothing, because
        answering with either of them would be a guess.
        """
        by_path = self.by_path()
        if name in by_path:
            return by_path[name]
        hits = [s for s in self.structs if s.name == name]
        return hits[0] if len(hits) == 1 else None

    def resolve(self, ref: TypeRef) -> Struct | None:
        """The struct a reference points at, when it is in this package.

        A reference resolved through an import carries the path it is imported
        by, and a package that re-exports a name from one of its own modules is
        imported by a shorter path than the one the struct is declared at:
        `core.math.big.Int` against `core.math.big.int.Int`. So a path that does
        not match exactly is tried again against the modules underneath it, and
        an answer comes back only when exactly one of them has the name.
        """
        if not ref.path:
            return None
        by_path = self.by_path()
        if ref.path in by_path:
            return by_path[ref.path]
        where, _, name = ref.path.rpartition(".")
        hits = [s for s in self.structs if s.name == name and s.module.startswith(f"{where}.")]
        return hits[0] if len(hits) == 1 else None


def tags(text: str) -> dict[str, str]:
    """The struct tags in a docstring.

    Go's convention exactly: `key:"value"` pairs, space separated, inside one
    pair of backticks. A backticked span that is not entirely pairs is prose
    about a name and is left alone, which is what most of the backticks in this
    tree are.
    """
    found: dict[str, str] = {}
    for span in BACKTICKED.findall(text):
        if not span.strip() or not TAG_SPAN.match(span):
            continue
        for key, value in TAG_PAIR.findall(span):
            # First one wins, the way Go's own reader takes the first match, so
            # a key repeated between the summary and the description does not
            # depend on which half was read first.
            found.setdefault(key, value.replace('\\"', '"').replace("\\\\", "\\"))
    return found


def split_type(text: str) -> tuple[str, list[str]]:
    """A type into its head name and its arguments.

    `Dict[String, List[Int]]` gives back `Dict` and the two arguments, with the
    nesting left as text for the caller to hand back here. Splitting on commas
    has to count brackets, since the arguments have commas of their own.
    """
    text = text.strip()
    # A field written `var value: Self.T` is printed as `T`, and inside the
    # struct that declares the parameter the qualified spelling is the only
    # legal one, so both arrive here and mean the same thing.
    if text.startswith("Self."):
        text = text[len("Self.") :]
    if not text.endswith("]") or "[" not in text:
        return text, []
    head, rest = text.split("[", 1)
    args: list[str] = []
    depth = 0
    current = ""
    for char in rest[:-1]:
        if char == "," and depth == 0:
            args.append(current)
            current = ""
            continue
        if char in "[(":
            depth += 1
        elif char in "])":
            depth -= 1
        current += char
    if current.strip():
        args.append(current)
    return head.strip(), [a.strip() for a in args]


def absolute(where: str, package: str) -> str:
    """A relative import target, spelled out.

    `from .x import Y` is from this package and `from ..x import Y` is from the
    one above it, the same as Python. Both are written in this tree.
    """
    if not where.startswith("."):
        return where
    dots = len(where) - len(where.lstrip("."))
    base = package.split(".")
    rest = where[dots:]
    return ".".join(base[: len(base) - dots + 1] + ([rest] if rest else []))


def scope_of(source: str, package: str) -> Scope:
    """What a module's import lines bring into scope. See `Scope`."""
    scope = Scope()
    for where, parenthesised, plain in FROM_IMPORT.findall(source):
        target = absolute(where, package)
        for entry in (parenthesised or plain).split(","):
            entry = entry.strip().strip("()")
            if not entry:
                continue
            declared, _, local = (part.strip() for part in entry.partition(" as "))
            if not declared:
                continue
            path = f"{target}.{declared}"
            scope.names[local or declared] = path
            (scope.aliased if local else scope.declared)[declared] = path
    for where, alias in PLAIN_IMPORT.findall(source):
        scope.modules[alias or where.rsplit(".", 1)[-1]] = where
    return scope


def declarations(source: str, struct: str) -> list[tuple[str, str]]:
    """Every field a struct declares, in order, as written.

    Both of the things the JSON cannot answer come from here: the fields it
    left out are the private ones, and the type each field was written with is
    the one the compiler resolved in this module's scope.
    """

    def open_brackets(text: str) -> int:
        return sum(text.count(c) for c in "[(") - sum(text.count(c) for c in "])")

    def is_whole(text: str) -> bool:
        return open_brackets(text) == 0 and text.rstrip().endswith(":")

    found: list[tuple[str, str]] = []
    inside = False
    header = ""
    pending = ""
    for line in source.split("\n"):
        # A struct with several parameters or several conformances has them one
        # to a line, and the brackets that close them sit at column zero, so
        # the body cannot be found by indentation until the declaration itself
        # has been read to its end.
        if header:
            header += " " + line
            if is_whole(header):
                header = ""
            continue
        declaration = STRUCT_LINE.match(line)
        if declaration:
            inside = declaration.group(1) == struct
            pending = ""
            header = "" if is_whole(line) else line
            continue
        if not inside:
            continue
        # A struct body is indented, so the first line that is neither blank nor
        # indented has ended it. Decorators sit at column zero as well.
        if line.strip() and not line.startswith((" ", "\t")):
            inside = False
            continue
        if pending:
            # A field whose type did not fit on one line. Keep taking lines
            # until the brackets balance.
            pending += " " + line.strip()
            if pending.count("[") <= pending.count("]"):
                found[-1] = (found[-1][0], pending.strip())
                pending = ""
            continue
        member = FIELD_LINE.match(line)
        if not member:
            continue
        _, name, written = member.groups()
        found.append((name, written))
        if written.count("[") > written.count("]"):
            pending = written
    return found


def as_written(text: str, module: Module, parameters: set[str]) -> TypeRef:
    """A type spelled the way the source spells it.

    This is the resolution that cannot go wrong, because the name being read is
    the name the compiler read: a parameter of the struct, then a name the
    module declares or imports under that spelling, then a module alias for the
    qualified form, then the prelude, which anything imported has shadowed by
    the time it gets here.
    """
    if CALLABLE.match(text.strip()):
        return TypeRef(text, text.strip(), kind="callable")

    name, raw_args = split_type(text)
    args = tuple(as_written(a, module, parameters) for a in raw_args)

    if name in parameters:
        return TypeRef(text, name, args, kind="parameter")
    if name in module.declares:
        return TypeRef(text, name, args, path=f"{module.path}.{name}", kind="local")
    if name in module.scope.names:
        return TypeRef(text, name, args, path=module.scope.names[name], kind="imported")
    head, _, rest = name.partition(".")
    if rest and head in module.scope.modules:
        path = f"{module.scope.modules[head]}.{rest}"
        return TypeRef(text, name, args, path=path, kind="imported")
    if name in PRELUDE:
        return TypeRef(text, name, args, path=name, kind="prelude")
    return TypeRef(text, name, args)


def as_rendered(text: str, module: Module, parameters: set[str]) -> TypeRef:
    """A type spelled the way `mojo doc` prints it, which is a weaker thing.

    Used when the source is not there to read. It follows the compiler as far
    as it can: a parameter first, then a name the module declares or imports
    under its own name, which shadows the prelude.

    A renaming import is where it stops. `from core.math.big import Int as
    BigInt` does not put `Int` in scope, and the JSON prints `Int` all the
    same, so a field printed `Int` in that module is either the prelude's
    integer or the renamed one. Both are reported and neither is picked.
    """
    if CALLABLE.match(text.strip()):
        return TypeRef(text, text.strip(), kind="callable")

    name, raw_args = split_type(text)
    args = tuple(as_rendered(a, module, parameters) for a in raw_args)

    if name in parameters:
        return TypeRef(text, name, args, kind="parameter")

    # What the name means locally, which shadows the prelude. Two of these at
    # once would not compile, so it is a list only to be able to say so.
    shadowing: list[tuple[str, str]] = []
    if name in module.declares:
        shadowing.append(("local", f"{module.path}.{name}"))
    if name in module.scope.declared:
        shadowing.append(("imported", module.scope.declared[name]))

    candidates = shadowing or ([("prelude", name)] if name in PRELUDE else [])
    if name in module.scope.aliased:
        candidates = candidates + [("imported", module.scope.aliased[name])]

    if len(candidates) > 1:
        return TypeRef(
            text, name, args, kind="ambiguous", candidates=tuple(p for _, p in candidates)
        )
    if candidates:
        kind, path = candidates[0]
        return TypeRef(text, name, args, path=path, kind=kind)
    return TypeRef(text, name, args)


def read_struct(node: dict, module: Module, source: str) -> Struct:
    """One struct out of the JSON, with its types resolved and its gaps found."""
    parameters = [
        Parameter(p.get("name", ""), p.get("type", ""))
        for p in node.get("parameters", [])
        if isinstance(p, dict)
    ]
    traits: list[str] = []
    for parent in node.get("parentTraits", []):
        if not isinstance(parent, dict):
            continue
        # Some conformances arrive with a name and no path. A bare name is less
        # than a path and it is what there is, so it is kept as one.
        path = parent.get("path", "")
        traits.append(path.strip("/").replace("/", ".") if path else parent.get("name", ""))

    struct = Struct(
        name=node.get("name", ""),
        module=module.path,
        package=module.package,
        summary=node.get("summary", ""),
        description=node.get("description", ""),
        parameters=parameters,
        traits=tuple(t for t in traits if t),
    )

    declared = declarations(source, struct.name) if source else []
    written = dict(declared)
    names = {p.name for p in parameters}
    for entry in node.get("fields", []):
        if not isinstance(entry, dict):
            continue
        summary = entry.get("summary", "")
        description = entry.get("description", "")
        rendered = entry.get("type", "")
        name = entry.get("name", "")
        # The source is better evidence when there is any. A field the source
        # scan did not find falls back to the JSON's own name rather than to
        # nothing, since a struct written in a way this cannot read is still a
        # struct somebody wants a codec for.
        spelled = written.get(name, "")
        struct.fields.append(
            Field(
                name=name,
                type=(
                    as_written(spelled, module, names)
                    if spelled
                    else as_rendered(rendered, module, names)
                ),
                rendered=rendered,
                summary=summary,
                description=description,
                tags=tags(f"{summary}\n{description}"),
            )
        )

    if declared:
        public = {f.name for f in struct.fields}
        struct.hidden = tuple(name for name, _ in declared if name not in public)
    return struct


def read(document: dict, package: str, directory: Path | None = None) -> Index:
    """A whole `mojo doc` document, as an index of one package.

    `package` is the dotted path the package is imported by, which the document
    does not carry: its own name is the last segment only, and a path built
    from that would say `big.float.Float` for something a caller imports as
    `core.math.big.float.Float`.

    `directory` is where the sources are. Without it this reads the JSON alone,
    which is a weaker reading and is the one the selftest pins separately.
    """
    index = Index(package=package)
    for node in document.get("decl", {}).get("modules", []):
        if not isinstance(node, dict):
            continue
        name = node.get("name", "")
        source = directory / f"{name}.mojo" if directory else None
        text = source.read_text() if source and source.is_file() else ""
        module = Module(
            name=name,
            package=package,
            source=source if text else None,
            scope=scope_of(text, package),
            traits=[t.get("name", "") for t in node.get("traits", []) if isinstance(t, dict)],
        )
        # The names this module declares are collected before any field is
        # resolved, so that a field whose type is declared further down the
        # same file resolves rather than coming out unknown.
        nodes = [n for n in node.get("structs", []) if isinstance(n, dict)]
        # Everything this module declares, which is not the same as everything
        # it publishes: a private struct is absent from the JSON and is still a
        # name a public field can be typed with, so the source is asked too.
        module.declares = (
            {n.get("name", "") for n in nodes}
            | set(module.traits)
            | set(STRUCT_LINE.findall(text))
            | set(TRAIT_LINE.findall(text))
        )
        module.structs = [read_struct(n, module, text) for n in nodes]
        index.modules.append(module)
    return index


def document(directory: Path, includes: Sequence[Path] = ()) -> dict | str:
    """Ask `mojo doc` about a directory. Gives back the JSON, or a problem."""
    command = ["mojo", "doc"]
    for include in includes:
        command += ["-I", str(include)]
    command += ["-o", "-", str(directory)]
    out = subprocess.run(command, capture_output=True, text=True)
    if out.returncode != 0:
        return out.stderr.strip() or "mojo doc failed"
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError as exc:
        return f"mojo doc emitted something that is not JSON: {exc}"


def package_name(directory: Path, includes: Sequence[Path]) -> str:
    """The dotted path a directory is imported by, from where it sits.

    Relative to the deepest include path the directory sits under, because that
    is the shortest path the package can be imported by and so the one the
    compiler prints in the JSON. Under none of them, it is its own name and
    nothing more.
    """
    here = directory.resolve()
    best: str | None = None
    for include in includes:
        try:
            name = ".".join(here.relative_to(include.resolve()).parts)
        except ValueError:
            continue
        if best is None or len(name) < len(best):
            best = name
    return best if best is not None else here.name


def index(directory: Path, includes: Sequence[Path] = ()) -> Index | str:
    """Everything this module knows about a package, or a problem as a string."""
    doc = document(directory, includes)
    if isinstance(doc, str):
        return doc
    return read(doc, package_name(directory, includes), directory)


if __name__ == "__main__":  # pragma: no cover
    print("this is the reader; tools/docjson/run.py is the entry point", file=sys.stderr)
    raise SystemExit(2)
