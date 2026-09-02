# Design

Mojo is not Go. Ten properties of the language shape nearly every decision in this repository, and each one has a compiled probe under `tools/probe/` so that a release which changes it produces a failing test naming the section here that has to be rewritten.

Everything below was established by writing the smallest program that would settle the question and running it against Mojo 1.0.0. Where a probe result contradicted an assumption, the assumption lost.

## 1. There are no trait objects

A trait is a compile time constraint, not a value. `List[Reader]` does not exist, and a struct field cannot have a trait type.

Anywhere Go stores a heterogeneous collection behind an interface, this library builds an erased struct by hand: a type erased box holding the value, plus a table of thin function pointers, plus capability bits for the operations Go would have discovered with a type assertion. `io.Reader`, `io.Writer`, the nine `database/sql` driver interfaces and `net.Conn` are all built this way.

The box is `core.runtime.box`, a package of its own rather than forty lines inside `core.io`. It is the only thing in the erasure design that needs raw pointers, so giving it its own package confines that permission to it and leaves `core.io` safe, and it means anything wanting a heterogeneous collection does not have to depend on `core.io` to get one. It holds the value on the heap behind an atomic refcount, with the destructor kept as a thin function pointer captured at construction, which is the only thing left that remembers what the type was. Reading it back is a `ref` and not a pointer, so a caller does not have to declare itself unsafe to use one. Nothing checks that the type asked for is the type that went in, because section 8 says there is no reflection to check it with; what makes that safe is that the box and the vtable that reads it are always built by the same constructor.

The static path is kept alongside it. A function that knows its reader's concrete type takes a trait bound and gets a direct call, and only code that genuinely does not know the type pays for the indirection.

The capability bits are on the trait rather than on the erased struct, and that is not where the first design put them. Go's optional interfaces need two things that are both missing here: `src.(WriterTo)` to ask a value what it is, and, less obviously, some way for a generic function to ask whether its `R` happens to implement something. Mojo has neither, so a bit that only existed on the erased side would leave the static side unable to find a fast path at all, which is the side that should be paying the least. So `capabilities` is a trait method with a default body returning zero, the optional methods are trait methods with default bodies that raise, and both paths read the same `Int` the same way. `core/io/iface.mojo` is the worked example.

## 2. `raises` survives a function pointer

`def(Args) raises thin -> Ret` is a concrete, storable type. This is what makes the vtables in the previous section possible at all. Without it every erased call would have to encode failure in the return value and the whole error design would be different.

## 3. There are no closures that can be stored

A closure that captures can be passed down, not kept. So a comparison function is a thin function pointer plus an explicit context struct, and where the function is known at compile time it becomes a parameter instead, which monomorphizes and costs nothing.

This is also why `go f(x)` becomes `spawn[f](payload)` with an explicit struct carrying what a closure would have captured, and why template functions have one fixed signature rather than Go's arbitrary ones.

## 4. There is exactly one error type, and it is a string

Mojo's `Error` carries a message. There is no error hierarchy and nothing to type assert against.

`errors.As` becomes a lookup against a thread local record written at raise time. The record holds the fields Go would have put in a struct, so `os.PathError.of(e)` finds the path and the operation, and it holds the count that Go returns alongside an error in an `(n, err)` pair, which a raise would otherwise drop.

A record lives until the next raise on the same thread. Holding an error for longer than that takes an explicit `errors.capture(e)`, which is a deliberate cost rather than a hidden one.

Wrapping and joining make the record a tree rather than a single entry, so it is an arena of links with integer indices, which is the technique section 5 commits to for every recursive type here. `errors.wrap` copies the cause's links into the new record before the new record replaces the old one, so a chain survives any number of levels and each level keeps its own fields. `errors.matches` walks that tree and `errors.field` deliberately does not, because two links can each carry a `path` and answering with the wrong one is worse than answering nothing.

`errors.Is` compares against a value and there is no error value here to compare, so a sentinel is an integer code on the record. Nobody chooses the integer: `core/errors/codes.toml` lists every sentinel in the library and the generator numbers them, because two packages picking the same constant by hand makes `matches(e, io.EOF)` quietly true for an `os` error. The consequence is that a code is meaningless outside the process that produced it and must never be written to a file or a wire. `errors.As` and `errors.AsType` have no counterpart at all, since both are reflection and section 8 says there is none; the replacement is `errors.field`, `errors.matches`, and a per package helper such as `os.PathError.of(e)`.

`errors.Join` is where this mechanism is weaker than Go's, and only for as long as the errors stay live. Go holds several error values and all of their fields; at most one of the errors passed here still owns the thread's record, so the rest contribute their message and their place in the tree and nothing else. `errors.join` over captured errors loses nothing, because an `ErrorValue` owns its whole arena. Both halves are pinned by a test so that the code and [deviations.md](deviations.md) cannot drift apart.

`errors.capture(e)` copies an error's whole subtree out of the thread and hands back an `ErrorValue` that owns every message, field and cause it can reach. That is what lets an error be stored in a list, kept in a struct, or read by another thread, and an `ErrorValue` reads without touching any slot at all, which is what makes the last of those safe. `ErrorValue.error()` is the way back: it installs the record on whatever thread calls it, so a task's failure can be re-raised by the thread that collected it and every function in this package works on it as though it had just happened. The cross thread case has a test, because thread local storage is per thread by definition and a capture that quietly read the reading thread's own record instead would answer with somebody else's fields.

A record is matched to an error by the message it was raised with, and by nothing else. The record stores the message, the lookup compares it against the caught error's message, and a mismatch means no fields. That is what makes both silent failures safe: an error from `std`, or from any library that has never heard of this, finds a record whose message is not its own and is correctly reported as carrying nothing, and an error held past the next raise finds the newer record, sees a different message, and reports nothing rather than the newer error's fields. The known limit is that two errors with the same message text on the same thread are indistinguishable and the later one wins. Nothing is appended to the message to make this work, because a message with a token in it is a message that cannot be printed, and matching on text somebody also reads would make every wording change a breaking change to a lookup.

The record needs somewhere to live that is per thread and outlives the call that wrote it, and Mojo has no process wide mutable state at all to build that out of. So the slot is a pthread key in a small C object that `core.errors` links, reached from Mojo through `external_call`. A key rather than a `_Thread_local` pointer because a key has a destructor, so a thread that exits still holding a record frees it; the destructor is a Mojo function passed in, since a function only C calls is a function a dead code pass removes. The cost is real and worth stating plainly: every binary that uses `core.errors` links a platform specific object file, and `core.errors` is tier zero, so that is every binary. The alternative was passing an explicit context down every fallible call in the library, which would have put the mechanism in the signature of every function in it. A probe pins that pthread's own per thread storage really is per thread, because the failure mode there is one thread reading another's fields, which is a wrong answer rather than a crash.

## 5. Structs cannot hold themselves, and fields cannot expose an unbound origin

No recursive types. The JSON document, the regexp abstract syntax tree, the template parse trees and the linked list are all arenas of nodes addressed by integer index, with generation counters on the handles so that a stale handle raises instead of reading somebody else's node.

A struct field also cannot carry `AnyOrigin`. It is worth being exact about how far that goes, because the obvious conclusion from it is wrong: a field *can* hold `Pointer[T, UntrackedOrigin[mut=True]]`, and that erases just as thoroughly. Two probes pin the pair, one on each side. So the type erased box stores an integer by choice rather than by force, and the choice is that the box has forgotten its pointee type as well as its origin. A pointer field would have to name some placeholder `T` and reinterpret at every use, which is a second erasure to explain on top of the one that is actually happening. An integer has no pointee type to lie about, and `Pointer[T, AnyOrigin[mut=True]](unsafe_from_address=...)` reconstitutes it at the one place that knows the real `T`.

The same reasoning does not reach the vtable slots in `core.io`, which are function pointers rather than data pointers, and those have no origin to launder in the first place.

## 6. Pointers are non-nullable and carry an origin

The compiler refuses to build a `Pointer` from the address zero and says so, so C's null pointer is `Optional[Pointer[T, o]]()`. Every foreign function that can return null has that in its signature, which means the check cannot be forgotten.

A pointer crossing a thread boundary has to be laundered to an untracked origin through its integer address, because the borrow checker cannot follow it there. That is a rule with a real cost and it is confined to the concurrency and syscall packages.

## 7. A `for` loop swallows an error raised out of `__next__`

This is the sharpest edge in the language for a library like this one. Write an iterator that can fail, loop over it, and the failure disappears.

So nothing fallible gets an `__iter__`. Fallible iteration is an explicit `has_next()` and `next()` pair, the linter rejects a `__next__` that raises, and a probe pins the compiler behaviour so that we find out if a future release fixes it.

## 8. There is no reflection, and there is not going to be

Go's `encoding/json`, `database/sql`, `fmt` and `text/template` are all built on runtime type information. None of it exists here.

The substitute is `mojo doc`, which emits JSON containing every struct's field names, their resolved types, the traits the struct implements, and the docstring attached to each field. That is enough to generate a decoder, and it is where struct tags live: the backtick tag goes in the field docstring and `tools/codec` reads it from the same JSON.

That generator is infrastructure rather than a JSON detail. JSON, XML, gob, binary, ASN.1, SQL row scanning, `%+v` formatting, template field access and property test generators all read the same output.

The hole this leaves is real and it is not papered over. `json.Marshal(anyValue)` cannot exist, because there is no such thing as a value of unknown type at run time.

## 9. Real OS threads are available through libc

Verified rather than assumed. Thread creation and joining, mutexes and condition variables all work through foreign calls into libc, and a probe runs four threads incrementing a shared counter a hundred thousand times each behind a mutex and checks that it lands exactly on four hundred thousand.

Atomics do not come from libc, and the first attempt at this said they did. `__atomic_fetch_add_8` and `__atomic_compare_exchange_8` link on macOS and fail to link on Linux, where they live in libatomic and nothing pulls it in. They come from the language instead, which is the right answer anyway: an atomic the compiler cannot see through a function call is no use for a memory model. The standard library's `Atomic` renamed its parameter from a `DType` to a type between 1.0 and 1.1, so there is one probe for each spelling and the runner picks by the version the compiler reports.

That is the whole foundation for the concurrency packages. What is not settled is whether green threads are possible on top of it, which is the M9.4 gate in the roadmap.

## 10. A compile time fact cannot be turned into a compile error

This one cost the most and it is worth stating precisely, because the obvious assumption is wrong.

A user written `def` does fold at compile time. You can parse a format string in a `comptime` block, count the verbs, and branch on the result with `comptime if`. All of that works.

What you cannot do is fail the build on the answer. Mojo 1.0 replaced `constrained` with `where` clauses, and a `where` clause is proof carrying rather than evaluating: its solver handles compiler builtins and parameter attributes, and a call to any function that is not a builtin stops it with a note saying it cannot evaluate the call. That includes functions in Mojo's own standard library, so it is not about our code being unusual.

The only mechanism that emits a diagnostic at all is `@deprecated`, which produces a warning. So the pattern this library uses everywhere is to compute the fact at compile time, call a deprecated stub from inside a `comptime if` when the fact is bad, and have `pixi run lint` fail the build on any warning carrying our marker prefix.

That mechanism is weaker than it first looks, and the probe pins the weakness rather than the hope. The warning belongs to the line the deprecated stub is called on, not to the instantiation that reached it, and it is emitted once. Three separate bad calls produce one warning pointing at the stub, with no note naming any of them and no note naming the caller. Parameterising the stub does not help. So what a user actually gets is that a check fired somewhere in their build, which is enough to tell them to go and look and not enough to tell them where.

The honest summary, using format strings as the example: this library detects every format error at compile time and reports one warning saying so, then behaves exactly like Go at run time. Inside this repository that warning is a build failure. For somebody depending on the library it is a warning that does not name the offending call, and there is currently no way to make it more than that.

The same shape applies to codec field sets, struct tags, and SQL placeholder counts. If Mojo ever grows a static assert, all of it becomes a compile error and the change is about four lines.

## Smaller facts that change how code is written

`fn` is gone. Mojo 1.0 removed it and every function in this library is a `def`, with `raises` written out where a function can fail. A `def` does not raise unless it says so, so the effect is the same as `fn` had and only the spelling changed.

`alias` is gone the same way, replaced by `comptime`, and `@parameter if` is replaced by `comptime if`. The old spellings still compile and warn, which is exactly the kind of thing the nightly job is there to catch before it stops being a warning.

`UnsafePointer` is now spelled `Pointer`, and `bitcast` is now `unsafe_bitcast`. The linter looks for both spellings of the pointer, because a word boundary match on the short name does not find the long one.

The rename left a convention behind it: everything in the standard library that can break memory safety is now spelled with an `unsafe_` prefix, on the order of fifty names and growing. The linter matches that prefix as a family rather than keeping a list, which is what closes the case that a list of type names cannot reach. `Span.unsafe_ptr` and `Pointer.as_unsafe_any_origin` are both methods on values a safe package already holds, and calling them in sequence turns a borrowed span into one the borrow checker has stopped tracking. That is exactly what section 5 permits inside `core.runtime.box` and nowhere else, so it has to be a thing the linter can see.

There is no global mutable state. A module level `var` is refused outright, with a message telling you to move it into a function or make it a `comptime` constant, so there is nowhere in the language to put a package level counter, cache, registry or default. Go's standard library uses one in a dozen places. Every one of them here becomes either a value the caller owns and passes, or something that lives outside Mojo, which is section 4's thread local slot and the only case where the second answer was the right one.

A value is destroyed after its last use, not at the end of its scope. This is mostly invisible and occasionally sharp: taking a value's address is a use, so a local whose address is passed to a function and never mentioned again is already gone when that function reads it, and no borrow rule catches this because the address left as an integer. The two places `core.io` builds a borrowed view and hands over its address end with `_ = view^` after the call, which is the whole fix, and a probe pins that it is still needed.

A struct valued field cannot be moved out of an owned `self`. The compiler refuses with "field destroyed out of the middle of a value", so a builder that hands its contents to something else has to be the thing it builds rather than a wrapper around it. That is why `errors.Report` is both the builder and the record.

There are no zero values that mean anything, so every type has an explicit constructor and `var b bytes.Buffer` becomes `var b = Buffer()`.

There is no `defer`, so cleanup is a `with` block. This turns out better than Go's version, because the scope is visible in the indentation and it runs on a raise as well as a return.

There is no `panic` and `recover` pair. `abort` is final and cannot be caught, so nothing in this library aborts for a condition the caller could have checked. The functions that keep Go's aborting behaviour are the `must_` prefixed ones, where aborting is exactly what the caller asked for by choosing that name, and every one of them has a fallible sibling.

There are no `init` functions and no method promotion through embedding. Registration is explicit and composition is explicit.

## Where this is better than Go

Ownership and origins turn several of Go's documented hazards into things that do not compile, and that is the strongest argument for writing this rather than binding Go through a foreign function interface.

A slice returned by a buffer is invalidated by the next write to that buffer. In Go this is a documented hazard you are asked to remember. Here the origin is tracked and using it afterwards is a compile error.

A string builder copied after use panics at run time in Go through a hand rolled check. Here it is not copyable, so the mistake does not compile.

A mutex copied by value needs a separate static analysis tool to catch in Go. Here it does not compile.

A row set that is never closed leaks a database connection until a finalizer runs. Here it is not copyable and returns the connection in its destructor, and the transaction scope is a `with` block, so the rollback that Go asks you to remember to defer is structural.

The full list, including every place we deliberately differ from Go in the other direction, is in [deviations.md](deviations.md).
