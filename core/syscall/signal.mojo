"""Catching a signal, and the pipe every caught one arrives on.

Go's `os/signal` sits on a handler the Go runtime already installed and turns a
signal into a send on a channel. There is no runtime here to install one and no
channels yet, so the handler is `core/syscall/shim/signal.c` and what it does
with a signal is write the number down a pipe. Its comment says why at length,
and the short version is that a handler runs on a borrowed thread where almost
nothing is safe to call, and `write` is one of the few things that is.

So the shape here is not Go's. `signal_pipe` gives back a descriptor, and a
signal that has been asked for arrives as one byte on it. Waiting for a signal
is waiting for a read, which is the same thing every other source of events in
this library is, and that is the property worth having: the event loop in M10
waits on this descriptor next to a socket without either of them being a
special case.

Every call here reports a failure as an errno, the same as the rest of
`core.syscall`. What is different is that the shim hands the number back rather
than leaving it in `errno`, because these are not system calls: they are a few
lines of C around `sigaction`, and a call that returns before reaching
`sigaction` has no errno to read.
"""

from std.ffi import external_call
from std.sys import CompilationTarget

from .abi import (
    SIGABRT,
    SIGALRM,
    SIGBUS,
    SIGCHLD,
    SIGCONT,
    SIGEMT,
    SIGFPE,
    SIGHUP,
    SIGILL,
    SIGINFO,
    SIGINT,
    SIGIO,
    SIGKILL,
    SIGPIPE,
    SIGPROF,
    SIGPWR,
    SIGQUIT,
    SIGSEGV,
    SIGSTKFLT,
    SIGSTOP,
    SIGSYS,
    SIGTERM,
    SIGTRAP,
    SIGTSTP,
    SIGTTIN,
    SIGTTOU,
    SIGURG,
    SIGUSR1,
    SIGUSR2,
    SIGVTALRM,
    SIGWINCH,
    SIGXCPU,
    SIGXFSZ,
)
from .calls import _fail
from .errno import Errno, errno


def signal_name(sig: Int) -> String:
    """What the platform calls `sig`. Go's `syscall.Signal.String`.

    A description rather than a constant name, so `SIGINT` reads back as
    `interrupt`, which is the wording a person recognises from a shell. A
    number with no description gives `signal 37`, and Go does the same for
    every real time signal, which is most of the ones above 31.

    The two platforms disagree about more of this than anybody expects. macOS
    calls `SIGABRT` an abort trap and Linux calls it aborted, macOS suspends
    where Linux stops, and the two spell the resource limits differently. The
    wording below is each platform's own, taken from Go's generated tables, so
    a message from this library and a message from a Go program on the same
    machine read the same.

    Go has this as a method on `syscall.Signal` and there is no such type here,
    because `core.syscall` deals in numbers; `core.os.Signal` is the type, and
    it asks this.
    """
    if sig == SIGHUP:
        return "hangup"
    if sig == SIGINT:
        return "interrupt"
    if sig == SIGQUIT:
        return "quit"
    if sig == SIGILL:
        return "illegal instruction"
    if sig == SIGTRAP:
        comptime if CompilationTarget.is_macos():
            return "trace/BPT trap"
        return "trace/breakpoint trap"
    if sig == SIGABRT:
        comptime if CompilationTarget.is_macos():
            return "abort trap"
        return "aborted"
    if sig == SIGEMT:
        return "EMT trap"
    if sig == SIGFPE:
        return "floating point exception"
    if sig == SIGKILL:
        return "killed"
    if sig == SIGBUS:
        return "bus error"
    if sig == SIGSEGV:
        return "segmentation fault"
    if sig == SIGSYS:
        return "bad system call"
    if sig == SIGPIPE:
        return "broken pipe"
    if sig == SIGALRM:
        return "alarm clock"
    if sig == SIGTERM:
        return "terminated"
    if sig == SIGURG:
        return "urgent I/O condition"
    if sig == SIGSTOP:
        comptime if CompilationTarget.is_macos():
            return "suspended (signal)"
        return "stopped (signal)"
    if sig == SIGTSTP:
        comptime if CompilationTarget.is_macos():
            return "suspended"
        return "stopped"
    if sig == SIGCONT:
        return "continued"
    if sig == SIGCHLD:
        return "child exited"
    if sig == SIGTTIN:
        return "stopped (tty input)"
    if sig == SIGTTOU:
        return "stopped (tty output)"
    if sig == SIGIO:
        return "I/O possible"
    if sig == SIGXCPU:
        comptime if CompilationTarget.is_macos():
            return "cputime limit exceeded"
        return "CPU time limit exceeded"
    if sig == SIGXFSZ:
        comptime if CompilationTarget.is_macos():
            return "filesize limit exceeded"
        return "file size limit exceeded"
    if sig == SIGVTALRM:
        return "virtual timer expired"
    if sig == SIGPROF:
        return "profiling timer expired"
    if sig == SIGWINCH:
        comptime if CompilationTarget.is_macos():
            return "window size changes"
        return "window changed"
    if sig == SIGINFO:
        return "information request"
    if sig == SIGUSR1:
        return "user defined signal 1"
    if sig == SIGUSR2:
        return "user defined signal 2"
    if sig == SIGSTKFLT:
        return "stack fault"
    if sig == SIGPWR:
        return "power failure"
    return String("signal ", sig)


def signal_pipe() raises -> Int:
    """The descriptor caught signals arrive on. Gives back the read end.

    Made the first time it is asked for and the same one every time after, so a
    program that arms two signals reads both from one place. It is close on
    exec, so a process started by `core.os.exec` does not inherit it.

    One byte per signal, holding the number. Nothing is queued and nothing is
    counted: two of the same signal arriving faster than the reader drains
    them are two bytes if the pipe had room and one if it did not, which is the
    same guarantee Go's buffered channel gives and the same one the operating
    system gives about signals in the first place.

    Never closed. A program that has stopped caring about signals calls
    `signal_restore` and leaves the pipe where it is: closing it would leave a
    handler writing to a descriptor that something else has since been given.
    """
    var fd = external_call["core_syscall_signal_pipe", Int32]()
    if fd < 0:
        _fail("signal_pipe", errno())
    return Int(fd)


def _check(operation: StaticString, failure: Int32) raises:
    """Raise when the shim gave back an errno rather than zero."""
    if failure != 0:
        _fail(operation, Errno(Int(failure)))


def signal_catch(sig: Int) raises:
    """Send `sig` to the pipe from now on. Go's `signal.Notify`, one signal.

    Interrupted calls restart rather than failing, which is `SA_RESTART` and is
    Go's choice too. A program learns about the signal by reading the pipe on a
    thread that is waiting for exactly that, rather than by having some
    unrelated read fail in a way its caller was never written to expect.

    The pipe is made first if it does not exist, so arming a signal and then
    asking where it will arrive is a working order. Doing it the other way
    round would drop every signal that landed in between, and there is no
    reason a caller should have to know that.

    `SIGKILL` and `SIGSTOP` cannot be caught by anything, so this fails with
    `EINVAL` on either, which is the platform's answer rather than one made up
    here.

    What was installed before is remembered, once, so `signal_restore` puts
    back the program's own disposition and not this file's handler.
    """
    _check(
        "signal_catch",
        external_call["core_syscall_signal_catch", Int32](Int32(sig)),
    )


def signal_ignore(sig: Int) raises:
    """Throw `sig` away as it arrives. Go's `signal.Ignore`, one signal.

    Not the same as catching it and not reading the pipe. An ignored signal is
    discarded by the operating system and is not inherited across an exec as
    ignored unless the new program leaves it alone, which is a difference that
    matters for `SIGPIPE`: a program that ignores it and then starts a child
    hands the child a signal it has to decide about for itself.
    """
    _check(
        "signal_ignore",
        external_call["core_syscall_signal_ignore", Int32](Int32(sig)),
    )


def signal_restore(sig: Int) raises:
    """Put `sig` back to what it was. Go's `signal.Reset`, one signal.

    What it was is what was installed the first time this library took the
    signal over, which for a program that has not done anything unusual is the
    platform default. A signal that was never taken over goes to the default,
    since there is nothing remembered and the default is what a program that
    has not asked has.
    """
    _check(
        "signal_restore",
        external_call["core_syscall_signal_restore", Int32](Int32(sig)),
    )


def signal_ignored(sig: Int) raises -> Bool:
    """Whether `sig` is being thrown away right now. Go's `signal.Ignored`.

    Asked of the platform rather than of anything this library remembers, so a
    signal that the program which started this one had already set to be
    ignored answers true. That is the useful reading and Go's: a program
    started with `SIGINT` ignored is very often meant to keep ignoring it.
    """
    var answer = external_call["core_syscall_signal_is_ignored", Int32](
        Int32(sig)
    )
    if answer < 0:
        _fail("signal_ignored", errno())
    return answer == 1
