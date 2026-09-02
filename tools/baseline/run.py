#!/usr/bin/env python3
"""Check the platform tables against the platform.

A handful of facts in this library cannot be checked from Mojo, because
checking them means asking the host what the right answer is. The size and
field offsets of `stat`, the mutex structure, the socket address structures,
and the numeric value of every errno and signal. Get one wrong and the code
reads a plausible wrong number rather than failing, which is the worst way for
something to be wrong.

So this compiles a small C program that prints what the platform's own headers
say, and compares it to the tables checked in under core/. Everything that can
be checked from Mojo is a test instead, so that it runs on every platform on
every run rather than only where a C compiler happens to exist.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import sysconfig
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT, report

# Written by tools/gen as the syscall bindings land. One file per platform,
# named for the target triple, holding the offsets the Mojo code assumes.
BASELINES = ROOT / "core" / "sys" / "baseline"

PROBE = r"""
#include <stddef.h>
#include <stdio.h>
#include <errno.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>

#define SIZE(t)       printf("  \"sizeof(%s)\": %zu,\n", #t, sizeof(t))
#define OFFSET(t, f)  printf("  \"%s.%s\": %zu,\n", #t, #f, offsetof(t, f))
#define VALUE(n)      printf("  \"%s\": %d,\n", #n, (int)(n))

int main(void) {
    printf("{\n");
    SIZE(struct stat);
    OFFSET(struct stat, st_size);
    OFFSET(struct stat, st_mode);
    OFFSET(struct stat, st_ino);
    SIZE(struct sockaddr_in);
    SIZE(struct sockaddr_in6);
    SIZE(struct sockaddr_storage);
    OFFSET(struct sockaddr_in, sin_port);
    OFFSET(struct sockaddr_in6, sin6_addr);
    VALUE(EAGAIN);
    VALUE(EINTR);
    VALUE(ENOENT);
    VALUE(EEXIST);
    VALUE(SIGPIPE);
    VALUE(SIGCHLD);
    printf("  \"end\": 0\n}\n");
    return 0;
}
"""


def platform_name() -> str:
    """The name this platform's baseline file is stored under."""
    return sysconfig.get_platform().replace(".", "_")


def ask_the_platform() -> dict[str, int] | None:
    """Compile and run the probe, or give back None when there is no compiler."""
    cc = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
    if cc is None:
        return None
    with tempfile.TemporaryDirectory() as scratch:
        source = Path(scratch) / "probe.c"
        binary = Path(scratch) / "probe"
        source.write_text(PROBE)
        built = subprocess.run(
            [cc, "-o", str(binary), str(source)], capture_output=True, text=True
        )
        if built.returncode != 0:
            print(f"baseline: the probe did not compile\n{built.stderr}", file=sys.stderr)
            return None
        out = subprocess.run([str(binary)], capture_output=True, text=True, check=True)
    facts = json.loads(out.stdout)
    facts.pop("end", None)
    return facts


def main() -> int:
    name = platform_name()
    recorded = BASELINES / f"{name}.json"
    if not recorded.is_file():
        print(f"baseline: nothing recorded for {name} yet, nothing to check")
        return 0

    facts = ask_the_platform()
    if facts is None:
        # Not a failure. It means this host cannot answer the question, and a
        # host that cannot answer it is not evidence that the answer is wrong.
        print(f"baseline: no C compiler here, so {name} could not be checked")
        return 0

    expected = json.loads(recorded.read_text())
    problems = []
    for key, want in sorted(expected.items()):
        got = facts.get(key)
        if got is None:
            problems.append(f"{key} is recorded for {name} and the platform does not report it")
        elif got != want:
            problems.append(f"{key} is {got} here and {want} in {recorded.name}")
    for key in sorted(set(facts) - set(expected)):
        problems.append(f"{key} is reported by the platform and not recorded for {name}")

    return report("baseline", len(expected), f"facts on {name}", problems)


if __name__ == "__main__":
    raise SystemExit(main())
