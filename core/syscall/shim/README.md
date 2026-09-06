# The C that core.syscall needs

There are five C files in this library. Four of them are here, and each exists for a different reason.

[`core/errors/shim/slot.c`](../../errors/shim/README.md) is there because a piece of *state* cannot be expressed in Mojo: the language has no global mutable storage at all. `varargs.c` is here because a *calling convention* cannot be expressed in Mojo. `environ.c` is here because a C *variable* cannot be named from Mojo. `spawn.c` and `signal.c` are here because a *rule about what may be called* cannot be expressed in Mojo: the child of a fork and the body of a signal handler may both call only what POSIX calls async signal safe, allocating is not on that list, and nothing in Mojo promises not to allocate. None of the five is a general place to put C, and they have nothing to say to each other beyond being compiled by the same function in `tools/lib/native.py`. Each lives next to the package that needs it.

## varargs.c, and the problem it solves

`external_call` emits a call of fixed arity. C decides how to pass an argument from the prototype, and a variadic prototype does not pass its anonymous arguments the way a fixed one does, so a call that names every argument individually is using the wrong convention for each one past the last named parameter.

On x86-64 and on standard AArch64 the two conventions agree for integer arguments, so the obvious call works. Apple's AArch64 variant is the exception: an anonymous argument goes on the stack and a fixed arity call leaves it in a register, so the callee reads whatever the stack happened to hold.

That means this, written the obvious way:

```mojo
external_call["open", Int32](path, Int32(O_CREAT | O_WRONLY), Int32(0o644))
```

creates a file with mode 0644 on both Linux machines and mode zero on this laptop, and nothing anywhere reports a problem. It is the worst shape a portability bug can have: right on two of the three platforms, wrong on the one most of the development happens on, and silent on all three.

`tools/probe/probes/variadic_call.mojo` pins both halves of that, so it fails if Apple silicon starts working and also if a platform that works today stops. [docs/design.md](../../../docs/design.md) section 11 has the reasoning and the alternatives.

## What is here

Three functions with real prototypes that name the arguments and pass them on.

| Symbol | What it does |
| --- | --- |
| `core_syscall_open3` | `open` with a creation mode |
| `core_syscall_openat4` | `openat` with a creation mode |
| `core_syscall_fcntl` | `fcntl` with its argument |

`open` without a mode is not here, because a call with no anonymous arguments has nothing to get wrong and `core.syscall` makes it directly.

`ioctl` is not here either. It is variadic and it would need the same treatment, but nothing in this library calls it yet, and a wrapper written before it has a caller is a guess about which of the argument types the caller will want. Adding another function to a file that already exists is a one line change on the day something needs it, which is how `openat` arrived. What was worth thinking about was whether the file should exist at all.

Nothing here checks a flag, reads an errno or supplies a default. All of that is Mojo, in `core/syscall/calls.mojo`, for the same reason it is Mojo in the other shim: a decision that will change should not live in the file that has to be recompiled for each platform and cannot be reached by the test suite.

The alternatives were worse. `creat` covers `O_CREAT | O_WRONLY | O_TRUNC` with a fixed prototype and nothing else, so `O_EXCL`, `O_RDWR` and `O_APPEND` on a file being created would all be out of reach, and `core.os` needs every one of them. Opening a file and then fixing its mode with `chmod` is not the same thing, since between the two calls the file exists with the wrong permissions and any other process can open it. Doing the creation in a two step dance around `creat` gets `O_EXCL` wrong, which is the one flag whose entire purpose is to be atomic.

## environ.c, and the problem it solves

`environ` is the null terminated array of `name=value` strings that every process on a Unix system has, and libc exports it as data rather than as a call. `external_call` calls a function, so there is no spelling of a C variable in Mojo at all, and the array is reachable only through something that returns it.

macOS makes the same point a second way. `environ` there is exported to the main executable and to nothing else, so a shared library asks `_NSGetEnviron` for the address of it instead. That call is a function and could be reached from Mojo directly, but Linux would still need this file, and then `calls.mojo` would carry a platform test for a difference that is entirely about how C is linked.

| Symbol | What it does |
| --- | --- |
| `core_syscall_environ` | the live `environ` array |

Nothing is copied. The caller gets the array libc is using and has to read it before anything else in the process changes the environment, which is the rule `getenv` already comes with.

## spawn.c, and the problem it solves

A child between `fork` and `execve` has inherited every lock the parent's other threads were holding at the moment of the fork, and none of the threads that would release them. Taking one of those locks in the child is a hang, and the calls that are guaranteed not to are the POSIX async signal safe list. Allocating memory is not on it.

That is a rule about what code may do rather than about what it looks like, and no Mojo signature can carry it. A child written in Mojo would look ordinary, pass every test, and hang on the machine whose allocator happened to be mid-refill when the fork landed. Go has exactly the same problem and solves it the same way: `syscall.forkAndExecInChild` is written to that list with a comment saying so, and the reviewer's job is to check each line against the list rather than to read for style.

| Symbol | What it does |
| --- | --- |
| `core_syscall_spawn` | fork, arrange the child, exec, and report why not |

A failure between the fork and the exec has nowhere to go: the child cannot raise and the exit status cannot say which failure it was, because 127 is also what a shell returns for a command it could not find. So the child writes the errno down a close on exec pipe and the parent reads it. That is Go's mechanism too.

Nothing here decides anything. Which descriptors the child gets, what its environment is and where the executable was found are all arguments built in Mojo, in `core/syscall/spawn.mojo` and `core/os`.

## signal.c, and the problem it solves

A signal handler is a C function pointer, which Mojo has no way to produce, and it runs under the same async signal safe rule the fork child does. It also needs somewhere to put a value that outlives the call, which is the thing `slot.c` exists for one floor down.

So the handler here does one thing: it writes the signal number, one byte, to a pipe. Everything worth doing about a signal happens on an ordinary thread reading the other end, where nothing is borrowed and every call in the language is available. That is the self pipe trick, and the reason to use it rather than something newer is that a pipe is a file descriptor: the event loop in M10 waits on it alongside a socket without either being a special case.

| Symbol | What it does |
| --- | --- |
| `core_syscall_signal_pipe` | the read end, made once |
| `core_syscall_signal_catch` | send this signal to the pipe |
| `core_syscall_signal_ignore` | throw this signal away |
| `core_syscall_signal_restore` | put this signal back to what it was |
| `core_syscall_signal_is_ignored` | whether it is being thrown away now |

Which signals to catch and what the bytes mean are Mojo, in `core/os/signal`.

## What they cost

Four more object files on the link line of every binary that touches `core.syscall`, next to the one `core.errors` already puts there. `tools/lib/native.py` compiles all of them and hands back the list, and the four tools that build a Mojo binary pass the list to the linker rather than a single path.

## If the language changes

The day `external_call` learns the variadic convention, `varargs.c` goes away and the three calls in `calls.mojo` become ordinary `external_call`s. `variadic_call.mojo` is the thing that will tell us, and it is a probe that is good news the day it fails.

`environ.c` goes away the day Mojo can name a C variable, and there is no probe for that one, because a language that could do it would have no failing case to write down first.

`spawn.c` and `signal.c` do not go away. A language that could express "this function allocates nothing and calls nothing that does" could hold them, and no such promise is on the roadmap; until there is one, these two are C because the rule they are written to is checked by a reader and by nothing else.
