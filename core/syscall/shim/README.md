# The variadic calls

There are two C files in this library. This is the second, and it exists for a completely different reason from the first.

[`core/errors/shim/slot.c`](../../errors/shim/README.md) is there because a piece of *state* cannot be expressed in Mojo: the language has no global mutable storage at all. `varargs.c` is here because a *calling convention* cannot be expressed in Mojo. Neither one is a general place to put C, and the two have nothing to say to each other beyond both being compiled by the same function in `tools/lib/native.py`. Each lives next to the package that needs it.

## The problem

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

## What it costs

Another object file on the link line of every binary that touches `core.syscall`, next to the one `core.errors` already puts there. `tools/lib/native.py` compiles both and hands back the list, and the four tools that build a Mojo binary pass the list to the linker rather than a single path.

The alternatives were worse. `creat` covers `O_CREAT | O_WRONLY | O_TRUNC` with a fixed prototype and nothing else, so `O_EXCL`, `O_RDWR` and `O_APPEND` on a file being created would all be out of reach, and `core.os` needs every one of them. Opening a file and then fixing its mode with `chmod` is not the same thing, since between the two calls the file exists with the wrong permissions and any other process can open it. Doing the creation in a two step dance around `creat` gets `O_EXCL` wrong, which is the one flag whose entire purpose is to be atomic.

## If the language changes

The day `external_call` learns the variadic convention, this directory goes away and the three calls in `calls.mojo` become ordinary `external_call`s. `variadic_call.mojo` is the thing that will tell us, and it is a probe that is good news the day it fails.
