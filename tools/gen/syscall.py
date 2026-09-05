#!/usr/bin/env python3
"""Turn the recorded platform baselines into one Mojo table of numbers.

`core/syscall/baseline/<platform>.json` holds what that platform's own C
headers say: the size of every type and structure this library binds, the
offset of every field it reads, and the value of every constant it passes. This
reads all three files and writes `core/syscall/abi.mojo`, where each fact is a
single `comptime` binding whose value is chosen by `CompilationTarget`.

Generating it rather than typing it is the whole point of the package. A
structure offset typed by hand does not fail when it is wrong, it reads a
plausible number out of the middle of a neighbouring field, and it does that on
one platform while staying correct on the one the author was sitting at.
`struct stat.st_size` is at 96 on macOS and 48 on Linux; either constant is a
believable file size when read at the other offset.

The baselines are the source rather than the host headers, because
`generated-check` runs on one platform in CI and a generator that read the host
would emit a different file on each of the three. `pixi run baseline` is what
ties the recorded numbers back to the headers, and it runs everywhere.
"""

from __future__ import annotations

import json
import sys
import textwrap
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT

BASELINES = ROOT / "core" / "syscall" / "baseline"
TARGET = "core/syscall/abi.mojo"

# The recorded file name for each platform, and the order the ternaries test
# them in. macOS first because it is the odd one out on nearly every fact, then
# the two Linux architectures, which differ from each other only in the sizes
# of a few opaque pthread structures.
PLATFORMS = ("macos-arm64", "linux-x86_64", "linux-arm64")

# What a platform gets for a fact its headers do not have. It cannot be zero or
# minus one, because both are real values here: `DT_UNKNOWN` is 0, `struct
# stat.st_dev` is at offset 0, and a failing call returns minus one. Anything
# small is a plausible signal number. This is Int64's minimum plus one, which
# no header will ever hand out and which is unmistakable in a message.
ABSENT = -0x7FFF_FFFF_FFFF_FFFF

HEADER = '''"""The numbers this platform's C headers gave us.

Generated from `core/syscall/baseline/*.json` by `tools/gen/syscall.py`. Do not
edit: re-record a baseline with `pixi run baseline --record` and run `pixi run
gen`. `pixi run generated-check` fails on a diff.

Every binding here is a `comptime` chosen by target, so the constant folds to
one number while the program is built and nothing is decided at run time. The
three platforms are macOS arm64, Linux x86-64 and Linux arm64.

Names follow the headers. A constant keeps its own name, `sizeof(T)` becomes
`SIZEOF_T`, and the offset of a field becomes `OFFSET_<STRUCT>_<FIELD>`. The
offsets carry a prefix the headers do not have because an offset and a value
are both plain integers, and a package that reads structures out of a byte
buffer is exactly where handing one to the other goes unnoticed.

A fact a platform does not have is `ABSENT` on that platform. See its
docstring.
"""

from std.sys import CompilationTarget

comptime _MACOS = CompilationTarget.is_macos()
"""True when building for macOS. The odd one out on most of this file."""

comptime _LINUX_X86 = CompilationTarget.is_linux() and CompilationTarget.is_x86()
"""True when building for Linux x86-64.

The two Linux architectures are not interchangeable. `struct stat` is 144 bytes
on x86-64 and 128 on arm64, with `st_mode` at 24 and 16, and `O_DIRECTORY` is
65536 and 16384. A binding written on one of them and assumed to hold for
Linux is wrong on the other and does not say so.
"""

comptime _LINUX_ARM = CompilationTarget.is_linux() and not CompilationTarget.is_x86()
"""True when building for Linux arm64. The other side of `_LINUX_X86`."""

comptime ABSENT: Int = -0x7FFF_FFFF_FFFF_FFFF
"""The value of a fact the platform being built for does not have.

`SIGINFO` exists on macOS and not on Linux; `SIGPWR` is the other way round.
Rather than leave the name undefined on one platform, which would turn a
portability mistake into a spelling error somewhere unrelated, the name is
always there and holds this.

It is not zero and not minus one, because both of those are real answers in
this file. It is Int64's minimum plus one, so a caller who passes it to the
kernel gets a clear failure and a reader who sees it in a message knows at once
what it is.
"""
'''

# The constant families, in the order they appear in the generated file. Each
# is a set of prefixes and the paragraph that goes above the group. The order
# is the order somebody reading the file would want: opening a file, moving in
# it, asking about it, then the failure and signal tables, then the network.
FAMILIES: list[tuple[tuple[str, ...], str]] = [
    (
        ("O_",),
        "Flags for `open`. The access modes are the same everywhere and every "
        "other bit in this group moves: `O_CREAT` is 512 on macOS and 64 on "
        "Linux, and `O_DIRECTORY` is different on all three.",
    ),
    (
        ("SEEK_",),
        "Where an offset given to `lseek` is measured from.",
    ),
    (
        ("AT_",),
        "The `*at` family. `AT_FDCWD` is the directory descriptor standing for "
        "the process working directory, and it is negative on both platforms "
        "because a real descriptor never is.",
    ),
    (
        ("UTIME_",),
        "The two values `utimensat` takes in a nanosecond field in place of a "
        "time. `UTIME_NOW` means read the clock and `UTIME_OMIT` means leave "
        "that timestamp as it is. macOS spells them -1 and -2 and Linux spells "
        "them a billion and change, so neither is a number to type by hand.",
    ),
    (
        ("F_", "FD_"),
        "Commands for `fcntl`, and the one descriptor flag it reads and sets.",
    ),
    (
        ("S_I",),
        "The file mode bits. `S_IFMT` is the mask that selects the type out of "
        "a mode, and the rest of the `S_IF` group are the types it selects.",
    ),
    (
        ("DT_",),
        "The file type a directory entry reports, which is a different "
        "numbering from the mode bits above and cannot be substituted for it.",
    ),
    (
        ("WNOHANG", "WUNTRACED"),
        "Options for `waitpid`.",
    ),
    (
        ("CLOCK_",),
        "Which clock `clock_gettime` is being asked about. `CLOCK_MONOTONIC` "
        "is 6 on macOS and 1 on Linux, and 6 on Linux is a CPU time clock, so "
        "the wrong constant here reads a clock that answers and means "
        "something else.",
    ),
    (
        ("E",),
        "The errno table. These are the numbers a failing call leaves behind, "
        "and around half of them disagree across platforms in a way that is "
        "worse than disagreeing: `EAGAIN` is 35 on macOS and 11 on Linux, and "
        "35 on Linux is `EDEADLK`. A number compared against the wrong "
        "platform's constant does not fail to match, it matches the wrong "
        "thing, so nothing above this layer should ever see a bare number.",
    ),
    (
        ("SIG",),
        "The signal table, which disagrees across platforms in the same way "
        "the errno table does, and which is not the same length on both.",
    ),
    (
        ("AF_", "SOCK_"),
        "Socket address families and socket types.",
    ),
    (
        ("NAME_MAX", "PATH_MAX"),
        "The two length limits. `PATH_MAX` is 1024 on macOS and 4096 on Linux, "
        "so a buffer sized by the smaller one truncates paths the other "
        "platform accepts.",
    ),
]


def facts() -> dict[str, dict[str, int]]:
    """Every recorded baseline, keyed by platform then by the header's own name."""
    out = {}
    for platform in PLATFORMS:
        path = BASELINES / f"{platform}.json"
        with path.open() as fh:
            out[platform] = json.load(fh)
    return out


def mojo_name(key: str) -> str:
    """The Mojo binding name for a recorded fact.

    The three shapes a baseline key can take are `sizeof(...)`, `struct X.f`
    and a plain constant. A plain constant keeps its name so that a reader can
    search the system headers for it and find the same thing.
    """
    if key.startswith("sizeof(struct "):
        return "SIZEOF_" + key[len("sizeof(struct ") : -1].upper()
    if key.startswith("sizeof("):
        return "SIZEOF_" + key[len("sizeof(") : -1].upper()
    if key.startswith("struct "):
        struct, field = key[len("struct ") :].split(".", 1)
        return f"OFFSET_{struct.upper()}_{field.upper()}"
    return key


def value(key: str, tables: dict[str, dict[str, int]]) -> str:
    """The right hand side for one fact, folded as far as the numbers allow.

    A fact the three platforms agree on is written once rather than as a
    ternary that can only take one branch, and a fact two of them agree on gets
    one test rather than two. That is most of the file, and it is worth the
    branching in this function because a table where every line is a
    conditional hides the lines where the conditional is the point.
    """
    mac, x86, arm = (tables[p].get(key, ABSENT) for p in PLATFORMS)
    say = {ABSENT: "ABSENT"}
    m, x, a = (say.get(v, str(v)) for v in (mac, x86, arm))
    if mac == x86 == arm:
        return m
    if x86 == arm:
        return f"{m} if _MACOS else {x}"
    if mac == arm:
        return f"{x} if _LINUX_X86 else {m}"
    if mac == x86:
        return f"{a} if _LINUX_ARM else {m}"
    return f"{m} if _MACOS else ({x} if _LINUX_X86 else {a})"


def group(key: str) -> int:
    """Which section of the file a fact belongs in.

    Sizes and offsets first, because they are what the structure readers are
    built out of and what a wrong answer corrupts silently. Then the
    constants, which at worst make a call fail.
    """
    if key.startswith("sizeof("):
        return 0
    if key.startswith("struct "):
        return 1
    return 2


def constant_family(name: str) -> int:
    """The index into FAMILIES a constant sorts under.

    Longest prefix wins, so that `NAME_MAX` does not land in the errno table
    on the strength of its first letter and `SIGSYS` does not land there
    either. A constant matching nothing sorts after every family.
    """
    best = len(FAMILIES)
    longest = -1
    for i, (prefixes, _) in enumerate(FAMILIES):
        for prefix in prefixes:
            if name.startswith(prefix) and len(prefix) > longest:
                best, longest = i, len(prefix)
    return best


WIDTH = 80

def emit(lines: list[str], name: str, rhs: str) -> None:
    """One binding, wrapped the way `mojo format` would leave it.

    Written wrapped here rather than left long because generated output is
    checked in and `pixi run format-check` runs over it, so a line the
    formatter would rewrite is a failing build rather than a cosmetic
    difference, and a generated file that fails that check is a generated file
    somebody edits by hand.

    The formatter breaks a line at the last bracket that is already on it and
    otherwise puts one round the whole right hand side, so a three way choice,
    which already carries brackets round its inner two, wraps at those and a
    two way choice gets a new pair. Nothing here is long enough to need two
    levels of that.
    """
    one = f"comptime {name}: Int = {rhs}"
    if len(one) <= WIDTH:
        lines.append(one + "\n")
        return
    head, _, tail = rhs.partition("(")
    if tail:
        lines.append(f"comptime {name}: Int = {head}(\n    {tail[:-1]}\n)\n")
        return
    lines.append(f"comptime {name}: Int = (\n    {rhs}\n)\n")


def generate() -> dict[str, str]:
    """The one generated file, ready to be written or diffed."""
    tables = facts()
    keys = sorted({k for table in tables.values() for k in table})

    lines = [HEADER]

    sizes = [k for k in keys if group(k) == 0]
    lines.append(
        "\n\n"
        + wrap_comment(
            "The sizes. A buffer allocated from the wrong one of these is a "
            "structure the kernel writes past the end of, which is the worst "
            "way for any of this to be wrong."
        )
        + "\n"
    )
    for key in sizes:
        emit(lines, mojo_name(key), value(key, tables))

    offsets = [k for k in keys if group(k) == 1]
    struct = ""
    lines.append(
        "\n\n"
        + wrap_comment(
            "The offsets, grouped by the structure they are inside. A field "
            "read at the wrong one of these returns a number that looks like "
            "an answer."
        )
        + "\n"
    )
    for key in offsets:
        owner = key[len("struct ") :].split(".", 1)[0]
        if owner != struct:
            struct = owner
            lines.append(f"\n# struct {owner}\n")
        emit(lines, mojo_name(key), value(key, tables))

    constants = [k for k in keys if group(k) == 2]
    lines.append("\n")
    family = -1
    for key in sorted(constants, key=lambda k: (constant_family(k), k)):
        this = constant_family(key)
        if this != family:
            family = this
            doc = FAMILIES[this][1] if this < len(FAMILIES) else "Everything else."
            lines.append("\n" + wrap_comment(doc) + "\n")
        emit(lines, mojo_name(key), value(key, tables))

    return {TARGET: "".join(lines)}


def wrap_comment(text: str) -> str:
    """A paragraph as a Mojo comment block, wrapped to the formatter's width."""
    return "\n".join("# " + line for line in textwrap.wrap(text, width=77))
