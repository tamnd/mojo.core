/*
 * The self pipe every caught signal goes down. The fifth C file in this
 * library, and it is here for two of the reasons the others are: a signal
 * handler is a C function pointer and there is no Mojo spelling for one, and
 * what the handler needs between calls is global mutable state, which the
 * language does not have.
 *
 * ## Why a pipe
 *
 * A signal handler runs on a borrowed thread at a moment nothing chose. The
 * calls it is allowed to make are the async signal safe list and nothing else,
 * so it cannot take a lock, cannot allocate, and cannot call back into a
 * language runtime that does either. Almost nothing worth doing about a signal
 * fits in there.
 *
 * So the handler does one thing: it writes the signal number, one byte, to a
 * pipe. The real handling happens on an ordinary thread reading the other end,
 * where every call in the language is available and nothing is borrowed. That
 * is the self pipe trick, it is as old as signals are, and the reason to use
 * it here rather than something newer is that a pipe is a file descriptor: the
 * event loop in M10 will wait on it alongside every socket without knowing
 * that one of them is signals.
 *
 * Go does not need this because its runtime already owns the handler and turns
 * a signal into a send on a channel. This library has no runtime of its own
 * and no channels yet, so the pipe is both the mechanism and the interface,
 * and `core.os.signal` hands the read end straight to the caller.
 *
 * ## What is a decision and what is not
 *
 * Which signals to catch, what to do with the bytes and when to stop are all
 * Mojo, in core/os/signal. This file installs a handler, restores what was
 * there before, and owns one pipe. Nothing here knows what SIGINT means.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

/*
 * The highest signal this file will talk about, for the same reason
 * spawn.c has a number rather than a header constant: `NSIG` is 32 on macOS,
 * is behind a feature test in the glibc headers, and the real limit is 64 on
 * Linux. Every entry point checks against this before touching the arrays, so
 * a caller passing something out of range gets `EINVAL` rather than a write
 * past the end.
 */
#define CORE_SIGNAL_MAX 64

/*
 * The write end of the pipe, and the only thing the handler reads.
 *
 * Atomic because the handler can run on any thread at any point, including
 * while another thread is in the middle of `core_syscall_signal_pipe`. A plain
 * int would be a data race in the one place in this library where a race is
 * not a theoretical concern: the reader is a signal handler and there is no
 * lock it is allowed to take.
 *
 * -1 means there is no pipe yet, and a signal arriving then would be dropped.
 * Nothing can land in that window, and the reason is worth stating because it
 * is a property of the code rather than of the ordering: no handler is
 * installed until the pipe exists, since every entry point that installs one
 * makes the pipe first.
 */
static _Atomic int sink = -1;

/* The read end, kept so a second call gives back the same pipe. */
static int source = -1;

/*
 * What was installed before this file took a signal over, so `stop` can put it
 * back. `held[sig]` is meaningful only when `saved[sig]` is set, because the
 * disposition that was there may well have been the default and there is no
 * value of `struct sigaction` that means "nothing".
 */
static struct sigaction held[CORE_SIGNAL_MAX + 1];
static char saved[CORE_SIGNAL_MAX + 1];

/*
 * The handler. Every line of it is on the async signal safe list, and that is
 * the property to check when changing it, not whether it reads well.
 *
 * `errno` is saved and put back because this ran in the middle of somebody
 * else's call. A failed write here setting `errno` to `EAGAIN` would be read
 * by the interrupted code as the result of whatever it had just done, which is
 * a bug in a program that never mentions signals.
 *
 * A full pipe drops the byte. The pipe holds several thousand of them and a
 * reader that has not drained one in that long has stopped reading, so the
 * choice is between dropping a signal and blocking a handler forever. Go
 * drops too, and says so: `signal.Notify` asks for a buffered channel and
 * gives up rather than waiting.
 */
static void deliver(int sig) {
    int saved_errno = errno;
    int fd = atomic_load_explicit(&sink, memory_order_acquire);
    unsigned char number = (unsigned char)sig;

    if (fd >= 0) {
        while (write(fd, &number, 1) < 0 && errno == EINTR) {
        }
    }
    errno = saved_errno;
}

/*
 * The pipe, made once. Gives back the read end, or -1 with `errno` set.
 *
 * Both ends are close on exec, so a program started by core.os.exec does not
 * inherit its parent's signal plumbing. Made with `pipe` and two `fcntl`s
 * rather than `pipe2`, which macOS does not have.
 *
 * Not thread safe against itself, and does not need to be: core.os.signal
 * calls it from `notify`, which is documented as something a program does
 * while it is still setting itself up. Two threads racing here would leak a
 * pipe, not corrupt one.
 */
int core_syscall_signal_pipe(void) {
    int ends[2];

    if (source >= 0) {
        return source;
    }
    if (pipe(ends) < 0) {
        return -1;
    }
    if (fcntl(ends[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(ends[1], F_SETFD, FD_CLOEXEC) < 0) {
        int failure = errno;
        close(ends[0]);
        close(ends[1]);
        errno = failure;
        return -1;
    }
    source = ends[0];
    atomic_store_explicit(&sink, ends[1], memory_order_release);
    return source;
}

/*
 * Take `sig` over, remembering what was there. Gives 0, or an errno.
 *
 * `SA_RESTART` is set, so a slow call interrupted by this signal starts again
 * rather than failing with `EINTR`. That is Go's choice and it is the one that
 * makes the pipe worth having: a program learns about the signal by reading
 * the pipe, on a thread that is waiting for exactly that, rather than by
 * having some unrelated read fail in a way its caller has to be written to
 * expect.
 *
 * Called twice for the same signal, the second call does not overwrite what
 * was remembered the first time, so `stop` still restores the disposition the
 * program started with rather than this file's own handler.
 */
int core_syscall_signal_catch(int sig) {
    struct sigaction ours;
    struct sigaction was;

    if (sig < 1 || sig > CORE_SIGNAL_MAX) {
        return EINVAL;
    }
    /*
     * The pipe before the handler, always. A handler installed while `sink` is
     * still -1 drops every signal that arrives before somebody gets round to
     * asking for the pipe, and the caller who did that has done nothing wrong:
     * arming a signal and reading the pipe are two calls and there is no
     * reason the second should have to come first.
     */
    if (core_syscall_signal_pipe() < 0) {
        return errno;
    }
    memset(&ours, 0, sizeof(ours));
    ours.sa_handler = deliver;
    ours.sa_flags = SA_RESTART;
    sigemptyset(&ours.sa_mask);

    if (sigaction(sig, &ours, &was) < 0) {
        return errno;
    }
    if (!saved[sig]) {
        held[sig] = was;
        saved[sig] = 1;
    }
    return 0;
}

/*
 * Set `sig` to a fixed disposition, remembering what was there first.
 * `wanted` is SIG_IGN or SIG_DFL, which is the whole of what the two callers
 * below need.
 */
static int set_to(int sig, void (*wanted)(int), int remember) {
    struct sigaction ours;
    struct sigaction was;

    if (sig < 1 || sig > CORE_SIGNAL_MAX) {
        return EINVAL;
    }
    memset(&ours, 0, sizeof(ours));
    ours.sa_handler = wanted;
    ours.sa_flags = 0;
    sigemptyset(&ours.sa_mask);

    if (sigaction(sig, &ours, &was) < 0) {
        return errno;
    }
    if (remember && !saved[sig]) {
        held[sig] = was;
        saved[sig] = 1;
    }
    return 0;
}

/* Throw `sig` away as it arrives. Gives 0, or an errno. */
int core_syscall_signal_ignore(int sig) { return set_to(sig, SIG_IGN, 1); }

/*
 * Put `sig` back to whatever it was before this file touched it. Gives 0, or
 * an errno.
 *
 * A signal that was never taken over goes to the platform default, which is
 * the honest answer: there is nothing remembered to restore and the default is
 * what a program that has not asked about a signal has.
 */
int core_syscall_signal_restore(int sig) {
    struct sigaction back;

    if (sig < 1 || sig > CORE_SIGNAL_MAX) {
        return EINVAL;
    }
    if (!saved[sig]) {
        return set_to(sig, SIG_DFL, 0);
    }
    back = held[sig];
    saved[sig] = 0;
    if (sigaction(sig, &back, NULL) < 0) {
        return errno;
    }
    return 0;
}

/*
 * Whether `sig` is being thrown away right now. Gives 1, 0, or -1 with `errno`
 * set.
 *
 * Asked of the platform rather than of anything remembered here, so a signal
 * ignored by whoever started this program answers yes. That is what Go's
 * `signal.Ignored` documents and it is the question worth asking: a program
 * started with SIGINT ignored is usually meant to keep ignoring it.
 */
int core_syscall_signal_is_ignored(int sig) {
    struct sigaction now;

    if (sig < 1 || sig > CORE_SIGNAL_MAX) {
        errno = EINVAL;
        return -1;
    }
    if (sigaction(sig, NULL, &now) < 0) {
        return -1;
    }
    return now.sa_handler == SIG_IGN ? 1 : 0;
}
