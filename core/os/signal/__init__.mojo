"""Hearing about a signal sent to this program. Go's `os/signal`.

```mojo
from core.os import INTERRUPT
from core.os.signal import ignored, notify, reset

def main() raises:
    notify(INTERRUPT)
    print(ignored(INTERRUPT))  # => False
    reset(INTERRUPT)
```

A signal arrives at a moment nothing in the program chose, on a thread nothing
in the program chose, in the middle of whatever that thread was doing. Almost
nothing is safe to call there. So the whole job of this package is to turn that
into something a program can wait for on purpose, and what it turns it into is
a byte on a pipe.

## Why this is not Go's shape

Go's `Notify` takes a channel and sends the signal on it, and a program selects
on that channel next to everything else it is waiting for. There are no
channels here yet, and a channel that only a signal handler could write to
would have to be written in C anyway, so `notify` gives back a descriptor
instead and a signal arrives as one byte holding its number.

That is not a worse shape, it is an earlier one. A descriptor is what the event
loop in M10 waits on, so a program will be able to wait for a signal beside a
socket and a timer without any of the three being a special case, and the
channel version can be built on top of this the day channels exist. Go's
runtime does the same thing internally, with a self pipe underneath the
channel.

## What a program has to know

The pipe is one descriptor for every signal, so a program reads one place and
looks at the byte to see which arrived. Nothing is queued and nothing is
counted: two of the same signal arriving faster than the reader drains them may
be one byte or two, which is the same promise Go's buffered channel makes and
the same one the operating system makes about signals in the first place.

The pipe is made once and is never closed, because a handler writing to a
descriptor that something else has since been given would be much worse than a
descriptor that stays open. `stop` and `reset` put the signal back and leave
the pipe where it is.

`SIGKILL` and `SIGSTOP` cannot be caught by any program, so `notify` on either
of them fails rather than quietly doing nothing.
"""

from core.os import Signal
from core.syscall import (
    signal_catch,
    signal_ignore,
    signal_ignored,
    signal_pipe,
    signal_restore,
)


def notify(sig: Signal) raises -> Int:
    """Start delivering `sig` to the pipe. Gives back the pipe. Go's `Notify`.

    The descriptor is the same one every time and for every signal, so a
    program that arms three signals reads one place and reads the byte to see
    which of the three it was.

    Arming a signal is what stops the platform's own default from happening, so
    a program that calls this for `INTERRUPT` and then never reads the pipe
    does not stop when somebody presses control C. That is Go's behaviour too
    and it is the point: the program has said it will handle it.

    Called twice for the same signal, this is the second call doing nothing,
    which is what a program assembling its handlers from several places wants.

    Go's takes a channel and a variadic list of signals, and its empty list
    means every signal there is. There is no such spelling here: a caller that
    wants several calls this several times, and a caller that wants every
    signal has to say which, because a loop over every number would take over
    `SIGSEGV` and `SIGBUS` as well and a program that catches those and carries
    on is a program running on a corrupt stack.
    """
    signal_catch(sig.number)
    return signal_pipe()


def stop(sig: Signal) raises:
    """Stop delivering `sig` to the pipe. Go's `Stop`.

    The signal goes back to what it was before this library took it over, which
    for a program that has not done anything unusual is the platform's default.
    A signal already in the pipe and not yet read stays there; this is about
    what happens next, not about what has already happened.

    Go's `Stop` takes the channel rather than the signal, because its bookkeeping
    is per channel. There is one pipe here and it is shared, so the signal is
    what there is to name.
    """
    signal_restore(sig.number)


def reset(sig: Signal) raises:
    """Undo the effect of `notify` for `sig`. Go's `Reset`.

    The same thing as `stop` in this library, because Go's two calls differ
    only in whether they are named by channel or by signal, and there is one
    pipe here. Both are kept because both are Go's and a reader coming from Go
    should find the name they went looking for.
    """
    signal_restore(sig.number)


def ignore(sig: Signal) raises:
    """Throw `sig` away as it arrives. Go's `Ignore`.

    Not the same as arming it and never reading the pipe. An ignored signal is
    discarded by the operating system, so nothing accumulates anywhere and the
    program is never woken for it.

    It is also not the same for a child: a signal that is ignored here is still
    ignored in a program started from here unless that program sets it, which
    is a rule about `execve` rather than about this library and is the reason
    `SIGPIPE` behaves so strangely in shell pipelines.
    """
    signal_ignore(sig.number)


def ignored(sig: Signal) raises -> Bool:
    """Whether `sig` is being thrown away right now. Go's `Ignored`.

    Asked of the platform rather than of anything this library remembers, so a
    signal that the program which started this one had already set to be
    ignored answers true. That is the useful reading and Go's: a program
    started with `SIGINT` ignored is very often meant to keep ignoring it, and
    a program that arms it anyway has overridden a decision somebody made on
    purpose.
    """
    return signal_ignored(sig.number)
