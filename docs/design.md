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

The pointer and the context want to be one thing, and there is a spelling that makes them one: a trait with a single method, implemented by a struct whose fields are what the closure would have captured. The receiver is the context, and it is `mut self` so a stateful one can keep count. That is not just tidier. A function type has to name concrete types in every position, origins included, so `def(Span[Byte, ?], Bool) raises -> R` has a hole in it that only an untracked origin fills, and filling it means laundering through `core.runtime.box` in a package that otherwise needs nothing unsafe. A trait method may be parametric over the origin, exactly as `io.Reader.read` is, so the hole does not exist. `core.bufio.Splitter` is the first of these — Go's `bufio.SplitFunc`, which is a closure there — and comparators, handlers and codecs take the same shape. A thin function pointer is still the right answer when nothing is captured and no argument carries an origin.

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

So nothing fallible gets an `__iter__`. Fallible iteration is an explicit `has_next()` and `next()` pair, spelled as the `core.iter.Cursor` trait, the linter rejects a `__next__` that raises, and a probe pins the compiler behaviour so that we find out if a future release fixes it.

The one exemption is `raises StopIteration`, which the `Iterator` trait requires by signature. That is not an error being swallowed, it is how the language spells end of input, and the loop catching it is the loop working. So the linter reads what comes after `raises` and insists `StopIteration` is the whole of it rather than merely its first word: a bare `raises` is still rejected and so is `raises Error` or any other named type, because in those the loop cannot tell the end of the data from a failure to read it. `tests/lint/typed_fallible_next.mojo` is the fixture for the typed case. The infallible iterators in `core.slices` are written against this exemption and are the reason it exists.

The swallowing is specific to `__next__`, and that is worth knowing rather than assuming. A raising `__has_next__` makes the `for` statement itself a raising call, so the loop cannot be written in a function that is not `raises` and the error comes out normally. A second probe pins that half, because the two behaviours being different is what makes the linter rule correct as narrowly as it is written, and because a release that made them consistent could do it in either direction.

`Cursor` is deliberately not called `Iterator`. The hazard is a reader assuming `for x in it` works, and a trait with that name invites the assumption at every use site. Its element type is an associated `comptime Element` rather than a parameter, because `trait Cursor[T]` does not compile: trait declarations do not take parameters. The bound on it is `Deinitable & Movable`, the least a caller needs to own what it is handed, so a cursor may yield a buffer or a file handle. Both methods may raise and the implementation chooses which one does the work, because a reader cannot always know whether there is a next record without parsing one.

## 8. There is no reflection, and there is not going to be

Go's `encoding/json`, `database/sql`, `fmt` and `text/template` are all built on runtime type information. None of it exists here.

The substitute is `mojo doc`, which emits JSON containing every struct's field names, their resolved types, the traits the struct implements, and the docstring attached to each field. That is enough to generate a decoder, and it is where struct tags live: the backtick tag goes in the field docstring and `tools/codec` reads it from the same JSON.

That generator is infrastructure rather than a JSON detail. JSON, XML, gob, binary, ASN.1, SQL row scanning, `%+v` formatting, template field access and property test generators all read the same output.

`tools/docjson` is the reader they share, and two things it does are worth knowing about because they are not in the JSON. A field type arrives as rendered text under the name it was declared with rather than the name the module wrote, so `from core.math.big import Int as BigInt` produces a field that says `Int`, and `mojo doc` reports no private fields at all, so a struct with one looks exactly like a struct without one. Both are answered by reading the module's source alongside the JSON: what a field was written as is a name the compiler already resolved in that module's scope, and the fields missing from the JSON are the private ones. Where the source cannot be read, a name that could be two things is reported as ambiguous and a struct that might be hiding a field is reported as incomplete, and in both cases a generator refuses rather than guesses.

Generating rather than reflecting settles two things Go decides at run time. A struct tag is read while the code is being written rather than while it is running, so a misspelled one stops the build instead of quietly producing a field under the wrong name. And a field that is not in the document is an error rather than a zero, because Mojo has no zero value to leave it at: only `Optional`, `List` and `Dict` may be absent, since those are the three that have an empty value nobody has to invent. That makes `omitempty` on anything else a refusal rather than a round trip that loses a field.

Each generated file carries its own copy of the scanner it needs rather than importing one, so a codec works for somebody who has this library and nothing else of ours. When `core.encoding.json` exists the emitter can import instead, and because the generated files are checked in, that change is a diff in every one of them.

The hole this leaves is real and it is not papered over. `json.Marshal(anyValue)` cannot exist, because there is no such thing as a value of unknown type at run time.

## 9. Real OS threads are available through libc

Verified rather than assumed. Thread creation and joining, mutexes and condition variables all work through foreign calls into libc, and a probe runs four threads incrementing a shared counter a hundred thousand times each behind a mutex and checks that it lands exactly on four hundred thousand.

Atomics do not come from libc, and the first attempt at this said they did. `__atomic_fetch_add_8` and `__atomic_compare_exchange_8` link on macOS and fail to link on Linux, where they live in libatomic and nothing pulls it in. They come from the language instead, which is the right answer anyway: an atomic the compiler cannot see through a function call is no use for a memory model. The standard library's `Atomic` renamed its parameter from a `DType` to a type between 1.0 and 1.1, so there is one probe for each spelling and the runner picks by the version the compiler reports.

That is the whole foundation for the concurrency packages. What is not settled is whether green threads are possible on top of it, which is the M9.4 gate in the roadmap.

## 10. A compile time fact cannot be turned into a compile error

This one cost the most and it is worth stating precisely, because the obvious assumption is wrong.

A user written `def` does fold at compile time. You can parse a format string in a `comptime` block, count the verbs, and branch on the result with `comptime if`. All of that works.

What you cannot do is fail the build on the answer. Mojo 1.0 replaced `constrained` with `where` clauses, and a `where` clause is proof carrying rather than evaluating: its solver handles compiler builtins and parameter attributes, and a call to any function that is not a builtin stops it with a note saying it cannot evaluate the call. That includes functions in Mojo's own standard library, so it is not about our code being unusual.

`@deprecated` is the only thing in the language that emits a diagnostic, and it does not work either. It warns wherever the deprecated name is written, whether or not the `comptime if` holding it is taken, and whether or not the function holding it is ever instantiated. A stub called from a branch that never runs still warns, so a correct program gets the diagnostic meant for a wrong one. That is not a weakness to work around, it is the mechanism being unusable: it cannot say a thing about one call and stay quiet about the next. The probe named after it pins that, so nobody spends the day rediscovering it.

What does work is the compile time interpreter itself. A `comptime` binding whose value is read is folded while the program is built, by an interpreter that runs our own code, and a `print` from that code comes out on the compiler's output. So the pattern this library uses everywhere is to compute the fact at compile time, and in the branch where the fact is bad, bind a `comptime` value from a function that prints the complaint and returns an empty string, then write that empty string into whatever the function was building. The write is what makes the fold happen; a binding nothing reads is never folded and never prints. `pixi run lint` fails the build on any line carrying our marker prefix.

That gives one line per wrong call, only for calls that are actually wrong, and the line can say as much as we like: the format string, the verb, the argument position and its type. Two limits are real. The line has no file and line number on it, because a print is not a diagnostic and carries no source location, which is why the messages name the format string instead. And the compiler caches by content, so the complaint appears on the build that first compiles the call and not on a rebuild served from cache, which is why the tools that assert on these lines compile a copy carrying a nonce.

The honest summary, using format strings as the example: this library detects every format error at compile time and prints a line naming it while the program is built, then behaves exactly like Go at run time. Inside this repository that line is a build failure. For somebody depending on the library it is a line of text during the build with no source location on it.

The same shape applies to codec field sets, struct tags, and SQL placeholder counts. If Mojo ever grows a static assert, all of it becomes a compile error and the change is about four lines.

The section heading stays as it is because it is still true. A compile time fact cannot be turned into a compile error, or into a warning. It can be turned into a message, which is a weaker thing that happens to be enough.

## Smaller facts that change how code is written

`fn` is gone. Mojo 1.0 removed it and every function in this library is a `def`, with `raises` written out where a function can fail. A `def` does not raise unless it says so, so the effect is the same as `fn` had and only the spelling changed.

`alias` is gone the same way, replaced by `comptime`, and `@parameter if` is replaced by `comptime if`. The old spellings still compile and warn, which is exactly the kind of thing the nightly job is there to catch before it stops being a warning.

`UnsafePointer` is now spelled `Pointer`, and `bitcast` is now `unsafe_bitcast`. The linter looks for both spellings of the pointer, because a word boundary match on the short name does not find the long one.

The rename left a convention behind it: everything in the standard library that can break memory safety is now spelled with an `unsafe_` prefix, on the order of fifty names and growing. The linter matches that prefix as a family rather than keeping a list, which is what closes the case that a list of type names cannot reach. `Span.unsafe_ptr` and `Pointer.as_unsafe_any_origin` are both methods on values a safe package already holds, and calling them in sequence turns a borrowed span into one the borrow checker has stopped tracking. That is exactly what section 5 permits inside `core.runtime.box` and nowhere else, so it has to be a thing the linter can see.

There is no global mutable state. A module level `var` is refused outright, with a message telling you to move it into a function or make it a `comptime` constant, so there is nowhere in the language to put a package level counter, cache, registry or default. Go's standard library uses one in a dozen places. Every one of them here becomes either a value the caller owns and passes, or something that lives outside Mojo, which is section 4's thread local slot and the only case where the second answer was the right one.

A value is destroyed after its last use, not at the end of its scope. This is mostly invisible and occasionally sharp: taking a value's address is a use, so a local whose address is passed to a function and never mentioned again is already gone when that function reads it, and no borrow rule catches this because the address left as an integer. The two places `core.io` builds a borrowed view and hands over its address end with `_ = view^` after the call, which is the whole fix, and a probe pins that it is still needed.

A struct's own parameter has to be written `Self.R` in a field declaration. `struct LimitedReader[R: Reader]` with `var r: R` is refused with "unqualified access to struct parameter", while the same bare `R` is fine in a method signature and in the return type of a free function a few lines below. Nothing in the surrounding code hints that the rule exists, and every wrapper type has a field like this, so it is worth knowing before writing the first one rather than after.

A struct valued field cannot be moved out of an owned `self`. The compiler refuses with "field destroyed out of the middle of a value", so a builder that hands its contents to something else has to be the thing it builds rather than a wrapper around it. That is why `errors.Report` is both the builder and the record.

A `where` clause narrows an associated type only where that type stands alone. `trait Cursor` declares `Element: Deinitable & Movable`, and a function taking `C: Cursor` can add `where conforms_to(C.Element, Copyable)` and then hand a `C.Element` to something wanting a `Copyable`. What it cannot do is let `T` be inferred from a `Span[C.Element, o]`: that call is checked against the trait's declared bound and refused. So a generic function over a `Cursor` that needs a narrower element type calls a helper whose type parameter is bound explicitly rather than inferred, which `core.slices.sorted` does and `probes/refined_associated_type.mojo` pins.

The stronger form fails harder. `where C.Element == Tuple[K, V]` is checked at the call site and still leaves `C.Element` opaque inside the body, so `pair[0]` on a value of that type is an error: the clause narrows nothing for the code that has to use it. That is why `core.maps.insert` and `core.maps.collect` take a span of pairs where Go takes an `iter.Seq2`, since a dict needs the key and the value separately and there is no way to get them out. `probes/pair_cursor.mojo` pins it, and it and the probe above should be looked at together, because one compiler release could plausibly fix both.

There are no zero values that mean anything, so every type has an explicit constructor and `var b bytes.Buffer` becomes `var b = Buffer()`.

There is no `defer`, so cleanup is a `with` block. This turns out better than Go's version, because the scope is visible in the indentation and it runs on a raise as well as a return.

There is no `panic` and `recover` pair. `abort` is final and cannot be caught, so nothing in this library aborts for a condition the caller could have checked. The functions that keep Go's aborting behaviour are the `must_` prefixed ones, where aborting is exactly what the caller asked for by choosing that name, and every one of them has a fallible sibling.

There are no `init` functions and no method promotion through embedding. Registration is explicit and composition is explicit.

## Where this is better than Go

Ownership and origins turn several of Go's documented hazards into things that do not compile, and that is the strongest argument for writing this rather than binding Go through a foreign function interface.

This section used to open with a claim that a slice handed out by a buffer is invalidated by the next write to that buffer, and that using it afterwards is a compile error here where Go asks you to remember. That was wrong, it had no probe, and it is the reason every claim in this file now has one. A `Span` built from a `List` stays usable across a mutation of that list, including one that reallocates and leaves the span pointing at freed memory, and nothing in the compiler says so; `probes/span_outlives_its_owner.mojo` pins it. So this library returns owned bytes wherever Go returns a view into a buffer that a later call can move — `core.bufio`'s `peek`, `read_slice`, `read_line` and scanner token are all copies, and `deviations.md` records the copy as a cost rather than a win. What origins do buy is the [`ReaderView`](../core/io/erased.mojo) rule and the thread boundary in section 5; what they do not buy is this.

A string builder copied after use panics at run time in Go through a hand rolled check. Here it is not copyable, so the mistake does not compile.

A mutex copied by value needs a separate static analysis tool to catch in Go. Here it does not compile.

A row set that is never closed leaks a database connection until a finalizer runs. Here it is not copyable and returns the connection in its destructor, and the transaction scope is a `with` block, so the rollback that Go asks you to remember to defer is structural.

The full list, including every place we deliberately differ from Go in the other direction, is in [deviations.md](deviations.md).
