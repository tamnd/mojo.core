#!/usr/bin/env python3
"""Struct tags, read strictly.

Go's struct tags are unchecked strings. `json:"nmae"` compiles, runs, and
produces a field called `nmae` for as long as nobody looks; `json:"name,omitEmpty"`
is a field called `name` with an option Go has never heard of and silently
ignores. The whole category is a spelling mistake that survives review and
fails in production, and every Go programmer has been caught by it at least
once.

Here a tag is read at build time by a generator, so a tag that is not right can
stop the build instead. That is the single largest thing this generator does
that Go's `encoding/json` cannot, and it is why this module refuses things Go
accepts:

- an option nobody implements, however Go spells it,
- an empty option, which is a comma somebody typed twice,
- an option twice over,
- a name with a quote or a comma in it, which Go quietly throws away,
- two fields that come out under the same JSON name, which Go encodes as
  duplicate keys and decodes into whichever it reaches last,
- and a backticked span that looks like a tag and is not one, which is the
  misspelling that produces no tag at all rather than a wrong one.

The last of those is the reason this reads the docstring itself rather than
taking `docjson`'s parsed tags and stopping there. `json: "name"` with a space
in it is not a tag by the grammar, so a reader that only collects tags sees a
field with no tag on it and encodes it under its Mojo name. The mistake is
invisible in exactly the way the ones above are.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from docjson.read import BACKTICKED, TAG_SPAN, tags

# What Go's `isValidTag` allows in a name: letters, digits, and this set of
# punctuation. A name outside it is not refused by Go, it is thrown away by Go,
# which is worse.
PUNCTUATION = set("!#$%&()*+-./:;<=>?@[]^_{|}~ ")

# A backticked span that was meant to be a tag. Anything with a known tag key
# and a colon in it that did not parse as a tag is a misspelling, because there
# is no other reason to write one in prose.
KEYS = ("json", "codec", "xml")
SUSPICIOUS = re.compile(r"\b(" + "|".join(KEYS) + r")\s*:")

# The options this generator implements. Go has one more, `string`, which
# encodes a number or a boolean as a JSON string for the benefit of JavaScript
# readers that lose precision above 2^53. It is not here yet, and a tag that
# asks for it is refused rather than ignored, which is the whole point.
OPTIONS = ("omitempty",)


@dataclass(frozen=True)
class Tag:
    """What one field's `json` tag says."""

    name: str = ""
    skip: bool = False
    omitempty: bool = False


def valid_name(name: str) -> bool:
    """Whether a JSON name is one Go would keep."""
    return bool(name) and all(c.isalnum() or c in PUNCTUATION for c in name)


def suspicious(field: str, docstring: str) -> list[str]:
    """Backticked spans that look like a tag and are not one."""
    found = []
    for span in BACKTICKED.findall(docstring):
        if TAG_SPAN.match(span) or not SUSPICIOUS.search(span):
            continue
        found.append(f"{field}: `{span}` is not a struct tag, and looks like one")
    return found


def read(field: str, docstring: str) -> tuple[Tag, list[str]]:
    """One field's tag, and everything wrong with it.

    The `json` key only. A field with no tag is encoded under its own name,
    which is Go's rule and is what makes the generator worth running on a
    struct nobody has annotated.
    """
    problems = suspicious(field, docstring)
    found = tags(docstring)
    if "json" not in found:
        return Tag(name=field), problems

    value = found["json"]
    # `json:"-"` skips the field and `json:"-,"` is a field called `-`. The
    # second is a wart of Go's and is here because a tag that means one thing
    # in Go and another here is worse than a wart.
    if value == "-":
        return Tag(skip=True), problems

    parts = value.split(",")
    name = parts[0]
    # `json:"-,"` is the one place a trailing comma means something, so it is
    # the one place an empty option is not a stray one.
    options = [] if value == "-," else parts[1:]
    seen: set[str] = set()
    for option in options:
        if not option:
            problems.append(f"{field} has an empty option in its tag, which is a stray comma")
            continue
        if option in seen:
            problems.append(f"{field} has `{option}` in its tag twice")
            continue
        seen.add(option)
        if option not in OPTIONS:
            known = ", ".join(f"`{o}`" for o in OPTIONS)
            problems.append(
                f"{field} has `{option}` in its tag, which this generator does not "
                f"implement. It knows {known}"
            )
    if name and not valid_name(name):
        problems.append(f"{field} is tagged with the name `{name}`, which Go would throw away")
    return Tag(name=name or field, omitempty="omitempty" in seen), problems


def collide(named: list[tuple[str, str]]) -> list[str]:
    """Fields that come out under the same JSON name.

    Go writes both keys and reads the last one, which is a data loss bug that
    compiles. Two fields cannot share a name here.
    """
    problems = []
    by_name: dict[str, list[str]] = {}
    for field, name in named:
        by_name.setdefault(name, []).append(field)
    for name, fields in sorted(by_name.items()):
        if len(fields) > 1:
            problems.append(f'{" and ".join(fields)} are both encoded as "{name}"')
    return problems
