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
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.native import compiler
from lib.tree import ROOT, report

# Next to the bindings that assume them. `tools/gen/syscall.py` reads these
# three files and writes core/syscall/generated.mojo out of them, so what is
# recorded here is not a note about the platform, it is the source the bindings
# are compiled from.
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
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <netinet/in.h>

/* macOS and Linux spell the three timespec fields of struct stat
   differently, and a binding that reads a modification time has to know
   where it is under whichever name the platform uses. The offsets are
   recorded under the POSIX names, so that everything above this reads one
   name on every platform. */
#ifdef __APPLE__
#define ST_ATIM st_atimespec
#define ST_MTIM st_mtimespec
#define ST_CTIM st_ctimespec
#else
#define ST_ATIM st_atim
#define ST_MTIM st_mtim
#define ST_CTIM st_ctim
#endif

#define SIZE(t)       printf("  \"sizeof(%s)\": %zu,\n", #t, sizeof(t))
#define OFFSET(t, f)  printf("  \"%s.%s\": %zu,\n", #t, #f, offsetof(t, f))
#define AT(t, f, n)   printf("  \"%s.%s\": %zu,\n", #t, n, offsetof(t, f))
#define VALUE(n)      printf("  \"%s\": %d,\n", #n, (int)(n))

int main(void) {
    printf("{\n");

    /* The width of every type a field is read at. A field read at the
       wrong width is the same class of bug as a field read at the wrong
       offset and is harder to see, because the low half of a number is
       usually right. */
    SIZE(mode_t);
    SIZE(dev_t);
    SIZE(ino_t);
    SIZE(nlink_t);
    SIZE(uid_t);
    SIZE(gid_t);
    SIZE(off_t);
    SIZE(blksize_t);
    SIZE(blkcnt_t);
    SIZE(time_t);
    SIZE(pid_t);
    SIZE(size_t);
    SIZE(ssize_t);
    SIZE(socklen_t);
    SIZE(clockid_t);

    SIZE(struct stat);
    OFFSET(struct stat, st_dev);
    OFFSET(struct stat, st_ino);
    OFFSET(struct stat, st_mode);
    OFFSET(struct stat, st_nlink);
    OFFSET(struct stat, st_uid);
    OFFSET(struct stat, st_gid);
    OFFSET(struct stat, st_rdev);
    OFFSET(struct stat, st_size);
    OFFSET(struct stat, st_blksize);
    OFFSET(struct stat, st_blocks);
    AT(struct stat, ST_ATIM, "st_atim");
    AT(struct stat, ST_MTIM, "st_mtim");
    AT(struct stat, ST_CTIM, "st_ctim");
#ifdef __APPLE__
    AT(struct stat, st_birthtimespec, "st_birthtim");
#endif

    SIZE(struct timespec);
    OFFSET(struct timespec, tv_sec);
    OFFSET(struct timespec, tv_nsec);

    SIZE(struct timeval);
    OFFSET(struct timeval, tv_sec);
    OFFSET(struct timeval, tv_usec);

    /* The two clocks anything here reads. One counts from an epoch and can
       be set backwards, the other counts from an unspecified start and
       cannot, and telling them apart is a number that disagrees: monotonic
       is 6 on macOS and 1 on Linux, and 6 on Linux is a CPU time clock. */
    VALUE(CLOCK_REALTIME);
    VALUE(CLOCK_MONOTONIC);

    /* A directory entry is read out of a buffer the kernel filled, so
       every one of these is a pointer into somebody else's memory. */
    SIZE(struct dirent);
    OFFSET(struct dirent, d_ino);
    OFFSET(struct dirent, d_reclen);
    OFFSET(struct dirent, d_type);
    OFFSET(struct dirent, d_name);
#ifdef __APPLE__
    OFFSET(struct dirent, d_namlen);
#endif

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
    VALUE(O_ACCMODE);
    VALUE(O_APPEND);
    VALUE(O_CREAT);
    VALUE(O_EXCL);
    VALUE(O_TRUNC);
    VALUE(O_NONBLOCK);
    VALUE(O_CLOEXEC);
    VALUE(O_DIRECTORY);
    VALUE(O_NOFOLLOW);
    VALUE(O_SYNC);

    VALUE(SEEK_SET);
    VALUE(SEEK_CUR);
    VALUE(SEEK_END);

    VALUE(AT_FDCWD);
    VALUE(AT_SYMLINK_NOFOLLOW);
    VALUE(AT_REMOVEDIR);

    /* The two magic nanosecond values utimensat takes in place of a time.
       macOS spells them -1 and -2 and Linux spells them a billion and
       change, so a caller that typed either by hand would be wrong on one
       of the two. */
    VALUE(UTIME_NOW);
    VALUE(UTIME_OMIT);

    VALUE(F_GETFD);
    VALUE(F_SETFD);
    VALUE(F_GETFL);
    VALUE(F_SETFL);
    VALUE(F_DUPFD);
    VALUE(F_DUPFD_CLOEXEC);
    VALUE(FD_CLOEXEC);

    /* The file type bits live in the high half of st_mode and the
       permission bits in the low half. Everything above this asks about a
       type through S_IFMT, so the mask matters as much as the values. */
    VALUE(S_IFMT);
    VALUE(S_IFREG);
    VALUE(S_IFDIR);
    VALUE(S_IFLNK);
    VALUE(S_IFBLK);
    VALUE(S_IFCHR);
    VALUE(S_IFIFO);
    VALUE(S_IFSOCK);
    VALUE(S_ISUID);
    VALUE(S_ISGID);
    VALUE(S_ISVTX);

    VALUE(DT_UNKNOWN);
    VALUE(DT_REG);
    VALUE(DT_DIR);
    VALUE(DT_LNK);
    VALUE(DT_BLK);
    VALUE(DT_CHR);
    VALUE(DT_FIFO);
    VALUE(DT_SOCK);

    VALUE(WNOHANG);
    VALUE(WUNTRACED);

    /* Every errno anything in this library reports on. Go's os maps these
       to its own errors by number, and a number that is right on one
       platform and wrong on another produces a correct looking error for
       the wrong reason. */
    VALUE(E2BIG);
    VALUE(EACCES);
    VALUE(EADDRINUSE);
    VALUE(EADDRNOTAVAIL);
    VALUE(EAFNOSUPPORT);
    VALUE(EAGAIN);
    VALUE(EALREADY);
    VALUE(EBADF);
    VALUE(EBUSY);
    VALUE(ECANCELED);
    VALUE(ECHILD);
    VALUE(ECONNABORTED);
    VALUE(ECONNREFUSED);
    VALUE(ECONNRESET);
    VALUE(EDEADLK);
    VALUE(EDESTADDRREQ);
    VALUE(EDOM);
    VALUE(EDQUOT);
    VALUE(EEXIST);
    VALUE(EFAULT);
    VALUE(EFBIG);
    VALUE(EHOSTDOWN);
    VALUE(EHOSTUNREACH);
    VALUE(EIDRM);
    VALUE(EILSEQ);
    VALUE(EINPROGRESS);
    VALUE(EINTR);
    VALUE(EINVAL);
    VALUE(EIO);
    VALUE(EISCONN);
    VALUE(EISDIR);
    VALUE(ELOOP);
    VALUE(EMFILE);
    VALUE(EMLINK);
    VALUE(EMSGSIZE);
    VALUE(ENAMETOOLONG);
    VALUE(ENETDOWN);
    VALUE(ENETRESET);
    VALUE(ENETUNREACH);
    VALUE(ENFILE);
    VALUE(ENOBUFS);
    VALUE(ENODEV);
    VALUE(ENOENT);
    VALUE(ENOEXEC);
    VALUE(ENOLCK);
    VALUE(ENOMEM);
    VALUE(ENOPROTOOPT);
    VALUE(ENOSPC);
    VALUE(ENOSYS);
    VALUE(ENOTCONN);
    VALUE(ENOTDIR);
    VALUE(ENOTEMPTY);
    VALUE(ENOTRECOVERABLE);
    VALUE(ENOTSOCK);
    VALUE(ENOTSUP);
    VALUE(ENOTTY);
    VALUE(ENXIO);
    VALUE(EOPNOTSUPP);
    VALUE(EOVERFLOW);
    VALUE(EOWNERDEAD);
    VALUE(EPERM);
    VALUE(EPIPE);
    VALUE(EPROTONOSUPPORT);
    VALUE(EPROTOTYPE);
    VALUE(ERANGE);
    VALUE(EROFS);
    VALUE(ESHUTDOWN);
    VALUE(ESPIPE);
    VALUE(ESRCH);
    VALUE(ETIMEDOUT);
    VALUE(ETXTBSY);
    VALUE(EWOULDBLOCK);
    VALUE(EXDEV);

    /* The signals POSIX names, plus the two each platform has that the
       other does not. A signal number is not portable even between the two
       Linux architectures for the real time range, and these are the ones
       that are fixed. */
    VALUE(SIGHUP);
    VALUE(SIGINT);
    VALUE(SIGQUIT);
    VALUE(SIGILL);
    VALUE(SIGTRAP);
    VALUE(SIGABRT);
    VALUE(SIGBUS);
    VALUE(SIGFPE);
    VALUE(SIGKILL);
    VALUE(SIGUSR1);
    VALUE(SIGSEGV);
    VALUE(SIGUSR2);
    VALUE(SIGPIPE);
    VALUE(SIGALRM);
    VALUE(SIGTERM);
    VALUE(SIGCHLD);
    VALUE(SIGCONT);
    VALUE(SIGSTOP);
    VALUE(SIGTSTP);
    VALUE(SIGTTIN);
    VALUE(SIGTTOU);
    VALUE(SIGURG);
    VALUE(SIGXCPU);
    VALUE(SIGXFSZ);
    VALUE(SIGVTALRM);
    VALUE(SIGPROF);
    VALUE(SIGWINCH);
    VALUE(SIGIO);
    VALUE(SIGSYS);
#ifdef SIGEMT
    VALUE(SIGEMT);
#endif
#ifdef SIGINFO
    VALUE(SIGINFO);
#endif
#ifdef SIGPWR
    VALUE(SIGPWR);
#endif
#ifdef SIGSTKFLT
    VALUE(SIGSTKFLT);
#endif

    VALUE(NAME_MAX);
    VALUE(PATH_MAX);

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
    cc = compiler()
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
