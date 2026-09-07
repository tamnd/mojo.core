#!/usr/bin/env python3
"""Lift the three constant tables out of Go's `encoding/xml` source.

Two of them decide whether a run of characters is an XML name, and Go's own
comment says where they came from: cut and pasted out of Appendix B of the XML
specification and then reformatted. The third is the HTML entity list, two
hundred and fifty two names scraped out of the HTML 4 entity page. None of the
three is derived from anything a program here could recompute, so the choice is
between copying them by hand once and reading them out of the Go tree every
time. This reads them, because a hand copy of two hundred and seventy seven
number triples is a diff nobody can review and a place for a typo to live for
years.

The ranges are packed the way `core/unicode/data.mojo` packs its own, `lo |
hi << 21 | stride << 42`, so that a reader who has seen one has seen both. XML's
tables have no ranges above U+FFFF at all, which is a fact about the 1998
specification rather than about this packing.

Needs the Go that pixi.lock pins, for the reason `goapi.py` gives at length:
two releases of Go are two correct answers and a diff check cannot tell that
apart from a mistake. Some other Go, or no Go at all, prints a line and
generates nothing, so `pixi run check` still works on a machine with its own Go
on it or with none.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# The pin check is `goapi.py`'s, imported rather than copied, because two
# copies of a version test are two chances to check different things.
from goapi import pinned, version

OUTPUT = "core/encoding/xml/tables.mojo"

# `	{0x0F3E, 0x0F3F, 1},` and `	{0x1175, 0x119E, 0x119E - 0x1175},`
RANGE = re.compile(r"^\s*\{(0x[0-9A-Fa-f]+),\s*(0x[0-9A-Fa-f]+),\s*([^}]+)\},\s*$")
# `	"nbsp": "\u00a0",`
ENTITY = re.compile(r'^\s*"([^"]+)":\s*"\\u([0-9A-Fa-f]{4})",\s*$')
# `	"basefont",`
AUTOCLOSE = re.compile(r'^\s*"([a-z]+)",\s*$')


def source() -> str | None:
    """Go's `encoding/xml/xml.go`, or None when the right Go is not here."""
    if not shutil.which("go"):
        print("gen: go is not on PATH, so the XML tables are left as they are")
        return None
    want, have = pinned(), version()
    if want and have not in want:
        print(
            f"gen: pixi.lock pins {' and '.join(sorted(want))} and the go on PATH is "
            f"{have}, so the XML tables are left as they are"
        )
        return None
    out = subprocess.run(["go", "env", "GOROOT"], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    path = Path(out.stdout.strip()) / "src" / "encoding" / "xml" / "xml.go"
    return path.read_text() if path.is_file() else None


def block(text: str, opening: str, closing: str) -> list[str]:
    """The lines between the first line that is `opening` and the next `closing`.

    Matched on whole lines rather than by counting braces, because every one of
    the three declarations wanted here opens and closes on a line of its own and
    a brace counter would have to know about the braces in the rows.
    """
    lines = text.splitlines()
    for start, line in enumerate(lines):
        if line == opening:
            break
    else:
        raise ValueError(f"no line {opening!r} in xml.go")
    for stop in range(start + 1, len(lines)):
        if lines[stop] == closing:
            return lines[start + 1 : stop]
    raise ValueError(f"no line {closing!r} after {opening!r} in xml.go")


def ranges(text: str, name: str) -> list[tuple[int, int, int]]:
    """One of Go's two `unicode.RangeTable` values, as lo, hi and stride.

    A stride is sometimes written as the subtraction that produced it, which is
    Go making the intent of a two element range visible. Both spellings arrive
    here as a number.
    """
    rows = block(text, f"var {name} = &unicode.RangeTable{{", "}")
    rows = [row for row in rows if row.strip().startswith("{")]
    out = []
    for row in rows:
        match = RANGE.match(row)
        if not match:
            raise ValueError(f"unreadable row in {name}: {row!r}")
        lo = int(match.group(1), 16)
        hi = int(match.group(2), 16)
        stride = match.group(3).strip()
        if "-" in stride:
            left, right = stride.split("-")
            step = int(left.strip(), 0) - int(right.strip(), 0)
        else:
            step = int(stride, 0)
        out.append((lo, hi, step))
    if not out:
        raise ValueError(f"{name} came out empty")
    return out


def entities(text: str) -> list[tuple[str, int]]:
    """Go's `htmlEntity`, as a name and the code point it stands for.

    Kept in the order Go writes them, which is the order the entity page had
    them in, rather than sorted. Nothing here searches the list, so the only
    thing the order changes is how a diff against Go reads.
    """
    rows = block(text, "var htmlEntity = map[string]string{", "}")
    out = []
    for row in rows:
        match = ENTITY.match(row)
        if match:
            out.append((match.group(1), int(match.group(2), 16)))
    if len(out) < 200:
        raise ValueError(f"htmlEntity came out with only {len(out)} entries")
    return out


def autoclose(text: str) -> list[str]:
    """Go's `htmlAutoClose`, the empty elements of HTML 4."""
    rows = block(text, "var htmlAutoClose = []string{", "}")
    out = [match.group(1) for row in rows if (match := AUTOCLOSE.match(row))]
    if not out:
        raise ValueError("htmlAutoClose came out empty")
    return out


def pack(row: tuple[int, int, int]) -> int:
    """One range in one word, the packing `core/unicode/data.mojo` uses."""
    lo, hi, stride = row
    return lo | (hi << 21) | (stride << 42)


HEADER = '''"""The three tables Go keeps in `encoding/xml`, and nothing else.

Generated from Go's own source by `tools/gen/xmltables.py`. Do not edit: change
the generator and run `pixi run gen`. `pixi run generated-check` fails on a
diff.

Two of these decide whether a run of characters is an XML name. They are
Appendix B of the 1998 specification, which lists the letters of the languages
that had been written down by then and has not been touched since, so a name
this refuses is a name Go refuses and a name the specification refuses. XML
1.0 fifth edition replaced the appendix with a much shorter rule that allows
far more, and neither Go nor this follows it, because a document that parses
here and not in Go would be worse than a document neither accepts.

The third is the HTML entity list. It is not used unless a caller asks for it
by assigning `html_entity()` to `Decoder.entity`, which is the second half of
the two line recipe for reading HTML that `Decoder.strict` documents.

A range is packed into one word as `lo | hi << 21 | stride << 42`, which is
what `core/unicode/data.mojo` does and is described there. XML's tables stop at
U+D7A3, so the twenty one bit fields are wider than anything in them.
"""


'''


def generate() -> dict[str, str]:
    text = source()
    if text is None:
        return {}

    first = ranges(text, "first")
    second = ranges(text, "second")
    rows = first + second

    out = [HEADER]
    out.append(f"comptime _RANGES: Array[UInt64, {len(rows)}] = [\n")
    for row in rows:
        out.append(f"    0x{pack(row):016X},\n")
    out.append("]\n")
    out.append('"""Every range in the two tables, `first` first and `second` after it."""\n')

    out.append(f"\ncomptime _SECOND_AT = {len(first)}\n")
    out.append('"""Where `second` starts, which is also how long `first` is."""\n')
    out.append(f"\ncomptime _SECOND_LEN = {len(second)}\n")
    out.append('"""How many ranges `second` has."""\n')

    out.append('''

def _in(r: Int32, at: Int, count: Int) -> Bool:
    """Whether `r` is in `count` ranges starting at `at`.

    Binary search, the same shape as `core.unicode.letter`'s, because the rows
    are sorted and there are a hundred and ninety of them in the first table. A
    stride of one is the common case and is answered without the division.
    """
    var lo = 0
    var hi = count
    while lo < hi:
        var mid = lo + (hi - lo) // 2
        var word = materialize[_RANGES]()[at + mid]
        var start = UInt32(word & 0x1FFFFF)
        var end = UInt32((word >> 21) & 0x1FFFFF)
        if UInt32(r) < start:
            hi = mid
            continue
        if UInt32(r) > end:
            lo = mid + 1
            continue
        var stride = UInt32((word >> 42) & 0x3FFFFF)
        if stride == 1:
            return True
        return (UInt32(r) - start) % stride == 0
    return False


def is_name_first(r: Int32) -> Bool:
    """Whether `r` may start an XML name. Go's `unicode.Is(first, r)`.

    That is a letter, an underscore or a colon, where letter means what
    Appendix B says it means.
    """
    return _in(r, 0, _SECOND_AT)


def is_name_rune(r: Int32) -> Bool:
    """Whether `r` may appear after the first character of an XML name.

    Go asks `unicode.Is(first, c) || unicode.Is(second, c)` and this asks the
    same two questions in the same order. `second` is the digits, the combining
    marks and the extenders, which may not start a name.
    """
    return is_name_first(r) or _in(r, _SECOND_AT, _SECOND_LEN)


def html_auto_close() -> List[String]:
    """The HTML elements that close themselves. Go's `HTMLAutoClose`.

    Go's is a package level slice a caller could sort or append to by accident
    and every other caller would then be reading a different list. This is a
    function returning a fresh one, which is what `core.encoding.base64` does
    with Go's four `Encoding` variables and for the same reason.
    """
    var out = List[String]()
''')
    for name in autoclose(text):
        out.append(f'    out.append("{name}")\n')
    out.append("    return out^\n")

    out.append('''

def html_entity() -> Dict[String, String]:
    """The HTML entity names and what they stand for. Go's `HTMLEntity`.

    Two hundred and fifty two names, each one a single code point, which is
    what the HTML 4 entity page has and is why nothing here can expand to
    anything that could be expanded again. A caller assigns this to
    `Decoder.entity` and unsets `Decoder.strict`, and those two lines are the
    whole of reading HTML with this package.

    Built fresh on every call, for the reason `html_auto_close` gives.
    """
    var out = Dict[String, String]()
''')
    for name, point in entities(text):
        out.append(f'    out["{name}"] = chr(0x{point:04X})\n')
    out.append("    return out^\n")

    return {OUTPUT: "".join(out)}


if __name__ == "__main__":
    for path, body in generate().items():
        print(f"{path}: {len(body.splitlines())} lines")
