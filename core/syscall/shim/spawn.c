/*
 * The window between fork and exec. The fourth C file in this library, and the
 * one with the strongest reason to be C.
 *
 * A child between `fork` and `execve` shares nothing with the parent's other
 * threads but has inherited every lock they held at the moment of the fork. A
 * lock held by a thread that does not exist in the child is a lock that is
 * never released, so the child hangs the first time it touches anything that
 * takes one. The list of calls that are safe in there is fixed by POSIX and it
 * is short, and allocating memory is not on it. That is the whole reason this
 * is C: nothing in Mojo promises not to allocate, so a child written in Mojo
 * would deadlock on one machine in fifty and pass every test on the rest.
 *
 * So the code below is not written the way code is usually written. Every call
 * in `child` is on the POSIX async signal safe list, nothing between the fork
 * and the exec allocates, and the only way a failure gets out is four bytes
 * down a pipe. Read it against that list rather than for style. Go's
 * `syscall.forkAndExecInChild` has the same shape and the same rule written
 * above it, and this is that function with the parts this library does not
 * offer left out.
 *
 * Everything that is a decision is in Mojo, in core/syscall/calls.mojo and in
 * core/os: which file descriptors the child gets, what its environment is,
 * where the executable was found. This file is handed an argument vector and a
 * table of descriptors and does exactly what it is told, because a decision
 * made here cannot be tested and cannot be read by somebody who does not write
 * C.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <sys/wait.h>
#include <unistd.h>

/* Kept in step with the comptimes of the same name in core/syscall/spawn.mojo.
 */
#define CORE_SPAWN_SETSID 1
#define CORE_SPAWN_SETPGID 2

/*
 * The highest signal number worth resetting. POSIX gives no portable count and
 * the two spellings of one disagree: `NSIG` is 32 on macOS and the glibc
 * headers only define it under a feature test. A number past the end costs one
 * failed call per signal that does not exist and the failure is ignored, which
 * is cheaper than a header dance that gets it wrong on a platform nobody here
 * builds on.
 */
#define CORE_SPAWN_SIGNALS 64

/*
 * Move `fd` somewhere above `floor`, close on exec. Used only to get a
 * descriptor out of the way of the slot it is about to be written into.
 *
 * `F_DUPFD_CLOEXEC` is one call where `dup` and a separate `F_SETFD` are two,
 * and two calls have a window between them. There are no other threads in this
 * child, so the window cannot be lost to one, but the single call is also the
 * simpler thing to read.
 */
static int move_above(int fd, int floor) {
    return fcntl(fd, F_DUPFD_CLOEXEC, floor);
}

/*
 * Everything the child does before it becomes the new program. Runs in the
 * forked child and never returns: either `execve` replaces it or it reports
 * why not and exits.
 *
 * `report` is the write end of a close on exec pipe. The parent is reading the
 * other end, so a successful exec closes this and the parent sees end of file,
 * and a failure writes the errno and the parent sees four bytes. That is the
 * only channel out; the exit status cannot carry it, because 127 is also what
 * a shell returns for a command it could not find and the point of this is to
 * say which failure it was.
 */
static void child(const char *path, char *const *argv, char *const *envp,
                  int *fds, int count, const char *dir, int flags, int pgid,
                  int report) {
    int i;
    int moved;
    int failure;
    sigset_t none;
    struct sigaction dfl;

    /*
     * A handler inherited from the parent runs in the child on the parent's
     * assumptions, and a signal blocked in the parent stays blocked across the
     * exec, so a program started from a thread that happened to be masking
     * SIGTERM would be unkillable for reasons nothing in it explains. Both are
     * reset here. Go does the same and calls it out as the thing that took the
     * longest to find.
     */
    dfl.sa_handler = SIG_DFL;
    dfl.sa_flags = 0;
    sigemptyset(&dfl.sa_mask);
    for (i = 1; i <= CORE_SPAWN_SIGNALS; i++) {
        sigaction(i, &dfl, NULL);
    }
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);

    if (flags & CORE_SPAWN_SETSID) {
        if (setsid() < 0) {
            goto failed;
        }
    }
    if (flags & CORE_SPAWN_SETPGID) {
        if (setpgid(0, pgid) < 0) {
            goto failed;
        }
    }
    if (dir != NULL && dir[0] != '\0') {
        if (chdir(dir) < 0) {
            goto failed;
        }
    }

    /*
     * The report pipe has to get out of the way before anything is written
     * into the slots, because a table long enough to reach it would either
     * close it or overwrite it and the failure below would then go nowhere. It
     * cannot be moved in the parent, since the number that is free here is not
     * known until the table is known, and the table is the child's business.
     */
    if (report < count) {
        moved = move_above(report, count);
        if (moved < 0) {
            goto failed;
        }
        report = moved;
    }

    /*
     * The two passes that put the descriptors where the child wants them.
     *
     * A single pass of `dup2` is wrong whenever a source descriptor is also a
     * destination slot that has not been filled yet: swapping the child's
     * standard output and standard error is the smallest case, and one pass
     * gives the child the same pipe twice. So anything sitting in the range
     * being written is moved above it first, and the second pass then writes
     * into slots nothing is reading from.
     *
     * `dup2` clears close on exec on the descriptor it makes, which is why the
     * child keeps these three and loses everything else the parent opened.
     * That is the same rule the rest of this library is written to: every
     * descriptor core.os opens is close on exec from the moment it exists, and
     * the ones that cross into a new program are exactly the ones named here.
     */
    for (i = 0; i < count; i++) {
        if (fds[i] >= 0 && fds[i] < i) {
            moved = move_above(fds[i], count);
            if (moved < 0) {
                goto failed;
            }
            fds[i] = moved;
        }
    }
    for (i = 0; i < count; i++) {
        if (fds[i] < 0) {
            close(i);
            continue;
        }
        if (fds[i] == i) {
            /* Already in place, and only close on exec stands in the way. */
            if (fcntl(i, F_SETFD, 0) < 0) {
                goto failed;
            }
            continue;
        }
        if (dup2(fds[i], i) < 0) {
            goto failed;
        }
    }

    execve(path, argv, envp);

failed:
    failure = errno;
    /*
     * One write of one int, which a pipe delivers whole. The return value is
     * looked at only to keep a compiler from warning: there is nothing useful
     * to do about a failed write here and the parent's answer for a child that
     * said nothing and exited 127 is already correct.
     */
    if (write(report, &failure, sizeof(failure)) < 0) {
        failure = 0;
    }
    _exit(127);
}

/*
 * Start `path` as a new process. Gives back its process id, or -1 with the
 * reason in `*failure`.
 *
 * `fds[i]` is the descriptor the child sees as `i`, and -1 means the child
 * gets nothing there. The array is `count` long, so a caller wanting the usual
 * three passes three, and one wanting Go's `ExtraFiles` passes more. It is not
 * const because the first pass above rewrites entries it has moved, but that
 * happens after the fork and so only ever to the child's own copy of it. The
 * caller's array comes back exactly as it went in.
 *
 * `dir` is a directory to change to before the exec. A null pointer and an
 * empty string both mean no change, and the empty string is there because Mojo
 * has no null pointer worth writing at a call site: the caller passes the
 * bytes of a string it already has, and no string it could pass is a directory
 * anybody can change to.
 *
 * `*failure` is a plain errno and covers both halves: a failure in this
 * process, such as running out of descriptors for the pipe, and a failure in
 * the child, such as the executable not existing. The caller cannot tell the
 * two apart and does not need to, because either way no program started and
 * the errno says why.
 */
int core_syscall_spawn(const char *path, char *const *argv, char *const *envp,
                       int *fds, int count, const char *dir, int flags,
                       int pgid, int *failure) {
    int report[2];
    int pid;
    int held;
    ssize_t got;

    *failure = 0;
    if (pipe(report) < 0) {
        *failure = errno;
        return -1;
    }
    /*
     * Close on exec on both ends, which is what makes the pipe the signal it
     * is: the child's copy of the write end disappears the moment `execve`
     * succeeds, and the parent's read reaches end of file with nothing in it.
     * Set separately rather than with `pipe2`, which macOS does not have.
     */
    if (fcntl(report[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(report[1], F_SETFD, FD_CLOEXEC) < 0) {
        *failure = errno;
        close(report[0]);
        close(report[1]);
        return -1;
    }

    pid = fork();
    if (pid < 0) {
        *failure = errno;
        close(report[0]);
        close(report[1]);
        return -1;
    }
    if (pid == 0) {
        close(report[0]);
        child(path, argv, envp, fds, count, dir, flags, pgid, report[1]);
        _exit(127); /* Unreachable: `child` does not return. */
    }

    close(report[1]);
    /*
     * Read until the pipe says something or ends. A signal delivered to this
     * thread while it waits is not an answer about the child, so `EINTR` goes
     * round again rather than being reported as a failed start.
     */
    for (;;) {
        got = read(report[0], &held, sizeof(held));
        if (got < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
    close(report[0]);

    if (got == sizeof(held)) {
        /*
         * The child said why it could not become the program. It is about to
         * exit 127 and reaping it here means the caller never sees a process
         * id for something that never ran.
         */
        for (;;) {
            if (waitpid(pid, NULL, 0) >= 0 || errno != EINTR) {
                break;
            }
        }
        *failure = held;
        return -1;
    }
    return pid;
}
