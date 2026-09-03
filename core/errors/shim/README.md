# The thread local slot

There is one C file in this library. This is it, and this is why.

It lives under `core/errors` because that is what needed it first and because a
tier zero package is the only place every other package can reach. Two packages
use it now. The second is `core.math.rand`, which is why that package depends on
`core.errors` and has nothing else to say to it.

## The problem

Mojo has no global mutable state. A module level `var` is refused outright:

```
error: global variables are not supported; move this into a function body or
use 'comptime' to declare a constant
```

`tools/probe/probes/no_globals.mojo` pins that, and it is a probe that is good news the day it fails.

The error mechanism in [docs/design.md](../../../docs/design.md) section 4 needs somewhere to keep a record that is per thread and outlives the call that wrote it. Mojo's `Error` carries a string and nothing else, so the fields Go would have put in a struct have to be found again at the catch site, and the only place they can wait is storage the raising frame does not own. There is nowhere in the language to put that.

The top level functions of `core.math.rand` have the same shape of problem. They promise no seeding, no generator to carry and no lock, which means a generator that is per thread and outlives the call. Go keeps exactly that in its runtime, one `ChaCha8` per operating system thread. The alternative here would be one locked generator shared by everything, which is the design Go's original `math/rand` had and replaced.

## What is here

`slot.c` holds one pointer per thread per slot and nothing else. It does not know what is in a slot, when the contents are valid, or how to read a field. All of that is Mojo, in `record.mojo` and in `core/math/rand/globals.mojo`, where it can be read and changed by somebody who does not write C.

There are two slots. A third would be a conversation about whether the thing wanting one really has no owner to live in, which is the conversation the first two already had.

It is a pthread key rather than a `_Thread_local` variable for one reason: a key has a destructor, so a thread that exits still holding something frees it instead of leaking it. `tools/probe/probes/thread_local_free.mojo` pins that the destructor really does call back into Mojo as a worker thread unwinds, because the whole reason for choosing a key over a plain thread local rests on it.

The destructor is a Mojo function that arrives as an argument to the set call rather than a symbol this file declares and the linker resolves. Both spellings of that were tried and neither works. An `@export`ed Mojo function that no Mojo code calls is dead stripped out of an imported package, and `__attribute__((weak))` on a declaration gives a weak definition rather than a weak undefined symbol on macOS, so the link failed on one platform and quietly bound to nothing on the other. Passing the pointer in makes the dependency an argument, which no dead code pass can be wrong about.

Four symbols cross the boundary, all in the same direction:

| Symbol | What it does |
| --- | --- |
| `core_errors_slot_get` | The record for this thread, or null |
| `core_errors_slot_set` | Put a record in this thread's slot, and hand over the function that frees one |
| `core_rand_slot_get` | The default generator for this thread, or null |
| `core_rand_slot_set` | Put a generator in this thread's slot, and hand over the function that frees one |

## What it costs

Every binary that uses `core.errors` links a platform specific object file, and `core.errors` is tier zero, so that is every binary built on this library. Building the library needs a C compiler on the host, which the tools find as `cc`, `clang` or `gcc` in that order.

That cost was accepted with the alternatives on the table. Threading an explicit error context through every fallible call would have put the mechanism in the signature of every function in the library, and putting the fields in the message text would have made the message the API, so that changing the wording of an error breaks a lookup. The reasoning is recorded on [issue #8](https://github.com/tamnd/mojo.core/issues/8).

## If the language changes

The day Mojo grows any process wide mutable state, this directory goes away and `record.mojo` and `globals.mojo` keep their slots in Mojo. Nothing outside those two files would change, and `core.math.rand` would stop being unsafe and stop depending on `core.errors`. `no_globals.mojo` is the thing that will tell us.

## What is deliberately not here

No allocation, no record layout, no string handling, no error semantics. Every one of those is a decision that will change, and a decision that changes should not live in the one file that has to be recompiled for each platform and cannot be tested by the suite.
