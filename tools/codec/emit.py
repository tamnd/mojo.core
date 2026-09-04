#!/usr/bin/env python3
"""Write the Mojo file a plan describes.

Nothing here decides anything. `plan.py` has already refused everything it is
going to refuse, so this walks the plan and writes code, and every branch in it
is about how a thing is spelled rather than about whether it is allowed.

The output is one file per package holding every codec in it, plus a copy of
the runtime from `runtime.mojo`. One file rather than one per module because
the alternative is a private module of shared scanning code that every
generated module imports, which is a second file with a name that has to not
collide with anything in the user's package, for no gain.

Two shapes matter and both are forced by the language rather than chosen.

The encoder is `marshal_json(value)`, overloaded once per struct. Mojo
overloads on argument types, so every struct in the package can have the name
Go uses.

The decoder is `unmarshal_json_<struct>(data)`. It is told apart from the other
decoders only by the type it produces, and Mojo will not overload on that, so
the name carries the struct. It takes the result as an `out` argument, which
reads at the call site as a function that returns one and works on a struct
with no default value:

    var back: Item = unmarshal_json_item(text.as_bytes())
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from codec.plan import Codec, Encoding, Member, Plan

RUNTIME = Path(__file__).resolve().parent / "runtime.mojo"

RULE = "# " + "-" * 76

# What `mojo format` wraps at, followed here because a generated file that the
# formatter would rewrite is a file that cannot be checked for being byte
# identical.
WIDTH = 80


# The three field types that have an empty value nobody has to invent, and so
# the three that a document is allowed not to carry. Everything else missing
# from a document is an error rather than a zero. See `plan.py`.
ABSENT = ("optional", "list", "dict")

# What the encoder escapes, which is Go's set and not the JSON grammar's
# minimum. Kept here as well as in the runtime because a key is escaped once,
# now, rather than on every call.
ESCAPES = {
    ord('"'): '\\"',
    ord("\\"): "\\\\",
    ord("\n"): "\\n",
    ord("\r"): "\\r",
    ord("\t"): "\\t",
    ord("<"): "\\u003c",
    ord(">"): "\\u003e",
    ord("&"): "\\u0026",
    0x2028: "\\u2028",
    0x2029: "\\u2029",
}


# The kinds the compiler holds in a register. Handing one of these over with
# `^` copies it either way, and the compiler says the transfer has no effect,
# so a file that has to build without warnings cannot write one.
SCALAR = ("bool", "int", "uint", "float")


def moved(what: Encoding, name: str) -> str:
    """A value being handed over, transferred where transferring means anything."""
    return name if what.kind in SCALAR else name + "^"


def escaped(text: str) -> str:
    """A JSON name as it appears inside the quotes of a JSON string."""
    out = []
    for char in text:
        if ord(char) in ESCAPES:
            out.append(ESCAPES[ord(char)])
        elif ord(char) < 0x20:
            out.append(f"\\u{ord(char):04x}")
        else:
            out.append(char)
    return "".join(out)


def literal(text: str) -> str:
    """A Mojo string literal holding exactly `text`.

    The backslashes matter twice over: a JSON escape such as `\\u003c` is six
    characters that Mojo would otherwise read as one. Single quotes around a
    string holding double quotes, which is what `mojo format` writes and so
    what this has to write for the file to be one the formatter leaves alone.
    """
    body = text.replace("\\", "\\\\")
    if '"' in body and "'" not in body:
        return "'" + body + "'"
    return '"' + body.replace('"', '\\"') + '"'


def folded(line: str) -> list[str]:
    """One import, opened out onto several lines when it does not fit on one."""
    if len(line) <= WIDTH or " import " not in line:
        return [line]
    head, names = line.split(" import ", 1)
    return [f"{head} import ("] + [f"    {name}," for name in names.split(", ")] + [")"]


def runtime() -> tuple[list[str], list[str]]:
    """The runtime template as its imports and its body."""
    lines = RUNTIME.read_text().splitlines()
    imports = [line.split("# IMPORT ", 1)[1] for line in lines if line.startswith("# IMPORT ")]
    kept = lines[lines.index("# BEGIN") + 1 :]
    while kept and not kept[0].strip():
        kept.pop(0)
    return imports, kept


class Body:
    """Lines of Mojo, with the indentation kept for you."""

    def __init__(self) -> None:
        self.lines: list[str] = []
        self.depth = 0
        self.temporaries = 0

    def __call__(self, text: str = "") -> None:
        self.lines.append("    " * self.depth + text if text else "")

    def block(self, text: str) -> "Body":
        """A line that opens a block, such as `if`, `while` or `def`."""
        self(text)
        self.depth += 1
        return self

    def close(self) -> None:
        self.depth -= 1

    def fresh(self, stem: str) -> str:
        """A name nothing else in this function is using."""
        self.temporaries += 1
        return f"{stem}{self.temporaries}"

    def call(self, opening: str, arguments: list[str]) -> None:
        """A call, on one line where it fits and one argument a line where it does not.

        A struct with a dozen fields is constructed from a dozen arguments, and
        on one line that is a line nobody can read a diff of.
        """
        line = opening + ", ".join(arguments) + ")"
        if len("    " * self.depth + line) <= WIDTH:
            self(line)
            return
        self(opening)
        self.depth += 1
        for argument in arguments:
            self(argument + ",")
        self.depth -= 1
        self(")")


def encode(body: Body, what: Encoding, expr: str) -> None:
    """Write the value of `expr` onto `out`."""
    if what.kind == "bool":
        body(f"_write_bool({expr}, out)")
    elif what.kind == "int":
        body(f"_write_signed(Int64({expr}), out)")
    elif what.kind == "uint":
        body(f"_write_unsigned(UInt64({expr}), out)")
    elif what.kind == "float":
        body(f"_write_float(Float64({expr}), {what.bits}, out)")
    elif what.kind == "string":
        body(f"_write_string({expr}, out)")
    elif what.kind == "struct":
        body(f"_encode_{what.func}({expr}, out)")
    elif what.kind == "optional":
        body.block(f"if {expr}:")
        encode(body, what.args[0], f"{expr}.value()")
        body.close()
        body.block("else:")
        body('_ = out.write_string("null")')
        body.close()
    elif what.kind == "list":
        item = body.fresh("item")
        first = body.fresh("first")
        body("out.write_byte(_LBRACKET)")
        body(f"var {first} = True")
        body.block(f"for {item} in {expr}:")
        body.block(f"if not {first}:")
        body("out.write_byte(_COMMA)")
        body.close()
        body(f"{first} = False")
        encode(body, what.args[0], item)
        body.close()
        body("out.write_byte(_RBRACKET)")
    elif what.kind == "dict":
        keys = body.fresh("keys")
        entry = body.fresh("entry")
        key = body.fresh("key")
        first = body.fresh("first")
        body("out.write_byte(_LBRACE)")
        # Sorted, because Go sorts and because a codec whose output depends on
        # the order a hash table happens to be in cannot be compared with
        # anything, including its own output from the run before.
        body(f"var {keys} = List[String]()")
        body.block(f"for {entry} in {expr}.items():")
        body(f"{keys}.append({entry}.key)")
        body.close()
        body(f"sort({keys})")
        body(f"var {first} = True")
        body.block(f"for {key} in {keys}:")
        body.block(f"if not {first}:")
        body("out.write_byte(_COMMA)")
        body.close()
        body(f"{first} = False")
        body(f"_write_string({key}, out)")
        body("out.write_byte(_COLON)")
        encode(body, what.args[1], f"{expr}[{key}]")
        body.close()
        body("out.write_byte(_RBRACE)")


def expression(what: Encoding) -> str:
    """How to read one value, for the types that read in one expression."""
    if what.kind == "bool":
        return "sc.read_bool()"
    if what.kind == "int":
        return f"{what.spell}(sc.read_signed({what.bits}))"
    if what.kind == "uint":
        return f"{what.spell}(sc.read_unsigned({what.bits}))"
    if what.kind == "float":
        return f"{what.spell}(sc.read_float({what.bits}))"
    if what.kind == "string":
        return "sc.read_string()"
    return f"_decode_{what.func}(sc)"


def value(body: Body, what: Encoding, name: str) -> None:
    """Declare `name` and read one value of `what` into it."""
    if not what.composite:
        body(f"var {name} = {expression(what)}")
        return
    body(f"var {name} = {what.spell}()")
    fill(body, what, name)


def into(body: Body, what: Encoding, target: str) -> None:
    """Read one value of `what` into a variable that already exists.

    A collection is built in a fresh one and moved over rather than added to in
    place, so that a key the document repeats replaces what it had before
    instead of appending to it. Go takes the last of a repeated key and so does
    this.
    """
    if not what.composite:
        body(f"{target} = {expression(what)}")
        return
    held = body.fresh("held")
    value(body, what, held)
    body(f"{target} = {moved(what, held)}")


def fill(body: Body, what: Encoding, target: str) -> None:
    """Read a composite into a variable that is empty and already exists."""
    if what.kind == "optional":
        # `target` is empty already, so `null` is nothing to do. Writing None
        # into it here would be a dead store and the compiler says so.
        body.block("if not sc.accept_null():")
        held = body.fresh("held")
        value(body, what.args[0], held)
        body(f"{target} = {moved(what.args[0], held)}")
        body.close()
    elif what.kind == "list":
        item = body.fresh("item")
        body("sc.enter()")
        body("sc.expect(_LBRACKET)")
        body.block("if not sc.accept(_RBRACKET):")
        body.block("while True:")
        value(body, what.args[0], item)
        body(f"{target}.append({moved(what.args[0], item)})")
        body.block("if sc.accept(_COMMA):")
        body("continue")
        body.close()
        body("break")
        body.close()
        body("sc.expect(_RBRACKET)")
        body.close()
        body("sc.leave()")
    elif what.kind == "dict":
        key = body.fresh("key")
        held = body.fresh("held")
        body("sc.enter()")
        body("sc.expect(_LBRACE)")
        body.block("if not sc.accept(_RBRACE):")
        body.block("while True:")
        body(f"var {key} = sc.read_string()")
        body("sc.expect(_COLON)")
        value(body, what.args[1], held)
        body(f"{target}[{key}^] = {moved(what.args[1], held)}")
        body.block("if sc.accept(_COMMA):")
        body("continue")
        body.close()
        body("break")
        body.close()
        body("sc.expect(_RBRACE)")
        body.close()
        body("sc.leave()")


def empty(what: Encoding, expr: str) -> str:
    """The test `omitempty` turns into, which is Go's idea of empty."""
    if what.kind in ("string",):
        return f'{expr} != ""'
    if what.kind in ("list", "dict"):
        return f"len({expr}) != 0"
    if what.kind in ("bool", "optional"):
        return expr
    return f"{expr} != 0"


def encoder(codec: Codec) -> list[str]:
    """`marshal_json` and the function it calls."""
    body = Body()
    body.block(f"def marshal_json(value: {codec.name}) raises -> String:")
    body('"""`value` as a JSON object."""')
    body("var out = Builder()")
    body(f"_encode_{codec.func}(value, out)")
    body("return out.string()")
    body.close()
    body()
    body()

    members = codec.encoded
    body.block(f"def _encode_{codec.func}(value: {codec.name}, mut out: Builder) raises:")
    body('"""One object onto the end of `out`, for a field or for the whole value."""')
    body("out.write_byte(_LBRACE)")

    # Whether a field needs a comma in front of it is worked out here rather
    # than at run time. It is only ever a question across a field that may not
    # be written at all, and only until the first field that always is: after
    # that one, every comma is certain. So the run time flag exists only when
    # the struct opens with `omitempty` fields, which is what `wrote` is for.
    first_certain = next((i for i, m in enumerate(members) if not m.omitempty), len(members))
    if first_certain > 0 and len(members) > 1:
        body("var wrote = False")
    certain = False
    maybe = False
    for index, member in enumerate(members):
        comma = "always" if certain else ("test" if maybe else "none")
        if member.omitempty:
            body.block(f"if {empty(member.encoding, 'value.' + member.name)}:")
        if comma == "always":
            body("out.write_byte(_COMMA)")
        elif comma == "test":
            body.block("if wrote:")
            body("out.write_byte(_COMMA)")
            body.close()
        # The key and its colon are one literal, escaped now rather than on
        # every call, which is most of what a generated encoder is for.
        body(f"_ = out.write_string({literal(chr(34) + escaped(member.json) + chr(34) + ':')})")
        if member.omitempty and member.encoding.kind == "optional":
            # An `omitempty` optional is only written when it holds something,
            # so the null branch under it would be a test that has already been
            # made and an arm nothing reaches.
            encode(body, member.encoding.args[0], f"value.{member.name}.value()")
        else:
            encode(body, member.encoding, f"value.{member.name}")
        if not member.omitempty:
            certain = True
            maybe = False
            continue
        if not certain:
            if index < len(members) - 1:
                body("wrote = True")
            maybe = True
        body.close()
    body("out.write_byte(_RBRACE)")
    body.close()
    return body.lines


def decoder(codec: Codec) -> list[str]:
    """`unmarshal_json_<struct>` and the function it calls."""
    body = Body()
    body.block(
        f"def unmarshal_json_{codec.func}(out result: {codec.name}, "
        "data: Span[Byte, _]) raises:"
    )
    body(f'"""The whole of `data` as one `{codec.name}`."""')
    body("var sc = _Scanner(data)")
    body(f"result = _decode_{codec.func}(sc)")
    body("sc.end()")
    body.close()
    body()
    body()

    body.block(
        f"def _decode_{codec.func}(out result: {codec.name}, mut sc: _Scanner[_]) raises:"
    )
    body(f'"""One object out of `sc`, wherever in the document it is."""')
    members = codec.members
    for member in members:
        if member.encoding.kind in ABSENT:
            body(f"var v_{member.name} = {member.encoding.spell}()")
        else:
            body(f"var v_{member.name} = Optional[{member.encoding.spell}]()")
    body("sc.enter()")
    body("sc.expect(_LBRACE)")
    body.block("if not sc.accept(_RBRACE):")
    body.block("while True:")
    body("var key = sc.read_string()")
    body("sc.expect(_COLON)")
    opened = False
    for member in members:
        body.block(f'{"if" if not opened else "elif"} key == {literal(member.json)}:')
        opened = True
        into(body, member.encoding, f"v_{member.name}")
        body.close()
    if opened:
        body.block("else:")
        body("sc.skip_value()")
        body.close()
    else:
        body("sc.skip_value()")
    body.block("if sc.accept(_COMMA):")
    body("continue")
    body.close()
    body("break")
    body.close()
    body("sc.expect(_RBRACE)")
    body.close()
    body("sc.leave()")

    arguments = []
    for member in members:
        if member.encoding.kind in ABSENT:
            arguments.append(f"v_{member.name}^")
            continue
        body.block(f"if not v_{member.name}:")
        body(f'raise _missing({literal(codec.name)}, {literal(member.json)})')
        body.close()
        arguments.append(f"v_{member.name}.take()")
    body.call(f"result = {codec.name}(", arguments)
    body.close()
    return body.lines


def header(plan: Plan) -> list[str]:
    """The docstring at the top of the generated file."""
    names = [c.name for c in plan.codecs]
    listed = ", ".join(names[:-1]) + " and " + names[-1] if len(names) > 1 else names[0]
    lines = [
        '"""JSON for ' + listed + ", generated from the structs themselves.",
        "",
        "Written by `tools/codec` out of the fields and struct tags of the",
        f"`{plan.package}` package. Do not edit it: change the struct or its tags and",
        "run the generator again. It is checked in so that it can be read, reviewed and",
        "built without running anything, and regenerating it has to produce this file",
        "byte for byte.",
        "",
        "Each struct has two entry points:",
        "",
        "```mojo",
        f"var text = marshal_json({names[0].lower()})",
        f"var back: {names[0]} = unmarshal_json_{plan.codecs[0].func}(text.as_bytes())",
        "```",
        "",
        "The encoder is overloaded on its argument, so every struct here has one called",
        "`marshal_json`. The decoder is told apart from the others only by the type it",
        "produces, which Mojo will not overload on, so its name carries the struct.",
        "",
        "A key in the document that no field matches is skipped, the way Go skips one.",
        "A field that is not in the document is an error, because Mojo has no zero value",
        "to leave it at. `Optional` is how a field says it may be absent.",
        "",
        "The scanner below the imports is a copy rather than an import. A generated",
        "codec has to build for somebody who has this library and nothing else of ours,",
        "and `core.encoding.json` does not exist yet.",
        '"""',
    ]
    return lines


def emit(plan: Plan) -> str:
    """The whole file."""
    imports, body = runtime()
    # One line per module the file names, however many structs come from it,
    # which is what somebody would have written by hand.
    within: dict[str, list[str]] = {}
    for module, name in plan.imports:
        within.setdefault(module.split(".", 1)[1], []).append(name)
    local = [f"from .{module} import {', '.join(sorted(names))}"
             for module, names in sorted(within.items())]

    lines = header(plan) + [""]
    for line in sorted(imports):
        lines += folded(line)
    lines += [""]
    for line in local:
        lines += folded(line)
    lines += ["", ""] + body

    for codec in plan.codecs:
        lines += ["", "", RULE, f"# {codec.path}", RULE, "", ""]
        lines += encoder(codec)
        if codec.decodable:
            lines += ["", ""] + decoder(codec)
        else:
            lines += [
                "",
                "",
                f"# {codec.name} has a field tagged `-`, which the document does not carry,",
                "# so there is nothing to construct one from and it encodes only.",
            ]
    return "\n".join(lines).rstrip() + "\n"
