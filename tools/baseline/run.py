#!/usr/bin/env python3
"""Check the platform tables against the platform.

A handful of facts in this library cannot be checked from Mojo, because
checking them means asking the host what the right answer is. The size and
field offsets of `stat`, the pthread primitives, the socket address structures,
the open flags, and the numeric value of every errno and signal. Get one wrong
and the code reads a plausible wrong number rather than failing, which is the
worst way for something to be wrong.

So this compiles a small C program that prints what the platform's own headers
say, and compares it to the tables checked in under core/syscall/baseline.
Everything that can be checked from Mojo is a test instead, so that it runs on
every platform on every run rather than only where a C compiler happens to
exist.

A mismatch names the structure, the field, what the platform says and what we
recorded:

  baseline: the offset of st_size in struct stat is 96 here and 48 in
  linux-x86_64.json

`pixi run baseline --record` writes the table for the platform it is run on.
That is a deliberate act on a machine somebody trusts, and the diff is the
review, in the same way as every other generated file here. Recording on a
platform we support is not something to do to make a red check go green: if
these numbers move, either the platform changed or the recording was done
somewhere it should not have been.
"""

from __future__ import annotations

import argparse
import json
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.tree import ROOT, report

# Next to the bindings that will assume them, once tools/gen writes those in
# M5. Until then these tables are the only statement of the numbers, which is
# why they are checked in rather than measured fresh every run.
BASELINES = ROOT / "core" / "syscall" / "baseline"

# The three CI runs on, named the way the CI matrix names them. A platform
# outside this list can still be checked, it just does not have to be recorded
# for a build to pass.
SUPPORTED = ("macos-arm64", "linux-x86_64", "linux-arm64")

SIZEOF = re.compile(r"^sizeof\((.+)\)$")
FIELD = re.compile(r"^(.+)\.(\w+)$")

PROBE = r"""
#include <stddef.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>

#define SIZE(t)       printf("  \"sizeof(%s)\": %zu,\n", #t, sizeof(t))
#define OFFSET(t, f)  printf("  \"%s.%s\": %zu,\n", #t, #f, offsetof(t, f))
#define VALUE(n)      printf("  \"%s\": %d,\n", #n, (int)(n))

int main(void) {
    printf("{\n");

    SIZE(struct stat);
    OFFSET(struct stat, st_dev);
    OFFSET(struct stat, st_ino);
    OFFSET(struct stat, st_mode);
    OFFSET(struct stat, st_nlink);
    OFFSET(struct stat, st_uid);
    OFFSET(struct stat, st_gid);
    OFFSET(struct stat, st_size);

    SIZE(struct timespec);
    OFFSET(struct timespec, tv_sec);
    OFFSET(struct timespec, tv_nsec);

    /* The threads probe takes a generous fixed buffer for these rather than
       the exact size, and says these are the numbers that pin it down. */
    SIZE(pthread_t);
    SIZE(pthread_mutex_t);
    SIZE(pthread_cond_t);
    SIZE(pthread_rwlock_t);

    SIZE(struct sockaddr);
    SIZE(struct sockaddr_in);
    SIZE(struct sockaddr_in6);
    SIZE(struct sockaddr_un);
    SIZE(struct sockaddr_storage);
    OFFSET(struct sockaddr_in, sin_family);
    OFFSET(struct sockaddr_in, sin_port);
    OFFSET(struct sockaddr_in, sin_addr);
    OFFSET(struct sockaddr_in6, sin6_port);
    OFFSET(struct sockaddr_in6, sin6_addr);
    OFFSET(struct sockaddr_un, sun_path);

    VALUE(AF_INET);
    VALUE(AF_INET6);
    VALUE(AF_UNIX);
    VALUE(SOCK_STREAM);
    VALUE(SOCK_DGRAM);

    /* These are the ones that differ between Linux and macOS, which is why
       they are here and not assumed. */
    VALUE(O_RDONLY);
    VALUE(O_WRONLY);
    VALUE(O_RDWR);
    VALUE(O_APPEND);
    VALUE(O_CREAT);
    VALUE(O_EXCL);
    VALUE(O_TRUNC);
    VALUE(O_NONBLOCK);
    VALUE(O_CLOEXEC);

    VALUE(EAGAIN);
    VALUE(EBADF);
    VALUE(ECONNRESET);
    VALUE(EEXIST);
    VALUE(EINTR);
    VALUE(EINVAL);
    VALUE(EISDIR);
    VALUE(ENOENT);
    VALUE(ENOTDIR);
    VALUE(EPIPE);

    VALUE(SIGALRM);
    VALUE(SIGCHLD);
    VALUE(SIGINT);
    VALUE(SIGPIPE);
    VALUE(SIGSEGV);
    VALUE(SIGTERM);

    printf("  \"end\": 0\n}\n");
    return 0;
}
"""


def platform_name() -> str:
    """The name this platform's baseline file is stored under.

    Operating system and architecture and nothing else, spelled the way the CI
    matrix spells them. Not `sysconfig.get_platform()`, which puts the macOS
    release in the string, so that a runner one point release behind would look
    like a platform nobody had ever recorded and the check would pass by
    finding nothing.
    """
    system = {"Darwin": "macos", "Linux": "linux"}.get(
        platform.system(), platform.system().lower()
    )
    machine = {"aarch64": "arm64", "arm64": "arm64", "AMD64": "x86_64"}.get(
        platform.machine(), platform.machine()
    )
    return f"{system}-{machine}"


def describe(key: str) -> str:
    """One recorded fact, in English, for a message somebody has to act on."""
    size = SIZEOF.match(key)
    if size:
        return f"the size of {size.group(1)}"
    field = FIELD.match(key)
    if field:
        return f"the offset of {field.group(2)} in {field.group(1)}"
    return f"the value of {key}"


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


def record(name: str, facts: dict[str, int]) -> int:
    """Write the table for this platform."""
    BASELINES.mkdir(parents=True, exist_ok=True)
    path = BASELINES / f"{name}.json"
    path.write_text(json.dumps(dict(sorted(facts.items())), indent=2) + "\n")
    print(f"baseline: recorded {len(facts)} facts for {name} in {path.relative_to(ROOT)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--record", action="store_true", help="write the table for this platform"
    )
    args = parser.parse_args()

    name = platform_name()
    recorded = BASELINES / f"{name}.json"

    if args.record:
        facts = ask_the_platform()
        if facts is None:
            print("baseline: no C compiler here, so there is nothing to record", file=sys.stderr)
            return 1
        return record(name, facts)

    if not recorded.is_file():
        if name in SUPPORTED:
            # One of the three this library claims to work on. A missing table
            # here means the check is passing by having nothing to compare, on
            # a platform where the numbers matter.
            return report(
                "baseline",
                0,
                f"facts on {name}",
                [
                    f"{name} is a platform we support and has no recorded table. "
                    "Run `pixi run baseline --record` on it"
                ],
            )
        print(f"baseline: nothing recorded for {name}, and it is not a platform we support")
        return 0

    facts = ask_the_platform()
    if facts is None:
        # Not a failure. It means this host cannot answer the question, and a
        # host that cannot answer it is not evidence that the answer is wrong.
        print(f"baseline: no C compiler here, so the {name} table was not checked")
        return 0

    expected = json.loads(recorded.read_text())
    problems = []
    for key, want in sorted(expected.items()):
        got = facts.get(key)
        if got is None:
            problems.append(
                f"{describe(key)} is recorded as {want} for {name} and the platform "
                "does not report it at all"
            )
        elif got != want:
            problems.append(f"{describe(key)} is {got} here and {want} in {recorded.name}")
    for key in sorted(set(facts) - set(expected)):
        problems.append(
            f"{describe(key)} is {facts[key]} on this platform and is not recorded for "
            f"{name}. Run `pixi run baseline --record`"
        )

    return report("baseline", len(expected), f"facts on {name}", problems)


if __name__ == "__main__":
    raise SystemExit(main())
