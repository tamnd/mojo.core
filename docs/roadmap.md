# Roadmap

Sequencing for the 135 packages and the symbols behind them counted in [packages.md](packages.md). The ordering is not a preference, it is the dependency graph plus one rule: anything that could invalidate the design is done early, even when it is not needed early.

Fifteen milestones in four bands. Each one is a GitHub milestone on this repository with the work under it as issues.

| Band | Milestones | What it establishes |
| --- | --- | --- |
| Foundation | M0 to M3 | The mechanisms every other package uses. If these are wrong, everything is. |
| Breadth | M4 to M8 | The bulk of the symbol count. Mostly ordinary work. |
| Risk | M9 to M11 | Concurrency, networking, cryptography. Where the project can fail. |
| Completion | M12 to M14 | The remainder, the httpx rebase, and 1.0. |

## Foundation

### M0 Repository and probes

Before any library code: the tree, `PACKAGE.toml`, the linter, the parity tool, the baseline checks, CI on all three platforms.

And `tools/probe/`, which is every claim in [design.md](design.md) as a compiled, running test. The thin function pointer vtable, `raises` across it, the field restriction on origins, the non-nullable pointer, the `for` loop swallowing an error out of `__next__`, comptime folding of a user `def`, the builtin only limit on `where` clauses, `@deprecated` firing once per source location rather than once per instantiation, and the pthread primitives.

Those probes go in before anything is built on them, so that a Mojo release which changes one produces a failing test naming the section to rewrite.

Exit: CI green on macOS arm64, Linux x86-64 and Linux arm64. Every probe passes. Parity prints zero.

### M1 core.errors

Tier zero, and everything depends on it. The thread local record, message matching, capture, wrap, join, partial, and the code registry.

This is first because it is the hardest thing to change later. The error mechanism is in the signature of every fallible function in the library.

Exit: the three hard cases pass, which are the foreign error path, the overwrite path, and the cross thread path.

### M2 core.io and the collections

The reader and writer traits, the erased structs, the type erased box, capability bits, buffered IO. The text search algorithms. Sorting, slices, maps and comparison. The iteration rule and the lint that enforces it.

Exit: `io.copy` works between four different reader and writer implementations, two static and two erased. `pixi run pkg core.io` builds with only tier zero dependencies.

### M3 Text and maths

Generated Unicode tables. Correctly rounded float conversion in both directions. Arbitrary precision integers.

`strconv` is here rather than later because JSON, `fmt`, `time`, `net` and the codecs all depend on correct float conversion, and discovering it is wrong in M6 would invalidate all of their tests.

Exit: exhaustive 32 bit float round trip passes. 64 bit passes Go's corpus and the differential run.

## Breadth

### M4 The generator, and core.fmt

The codec generator over `mojo doc` JSON, and the first thing that consumes it.

`fmt` is early on purpose. Its pattern of computing at compile time, reporting with a warning, and promoting that warning with the linter is used by `database/sql`, by the templates and by the codecs, and it needs to be proven on a real package before three more depend on it.

Exit: Go's `fmt` table passes on both the compile time and the runtime paths, identically. The warning tests assert the diagnostic actually fires.

### M5 System

The generated syscall layer, verified against C with `offsetof` on every platform. Files, processes, signals, paths. Time and the time zone database.

Exit: the layout tests pass on every platform. Go's `os` suite passes both as root and as an unprivileged user.

### M6 Encoding

JSON, XML, CSV, binary, ASN.1, PEM and the byte codecs. Gob is deferred to M13 because nothing depends on it.

Exit: JSONTestSuite passes in full. A certificate authority bundle round trips through ASN.1 byte for byte, which `x509` depends on in M11.

### M7 Compression, archives and images

Deflate first, since four packages need it.

Exit: streams from `gzip`, from zlib and from Go all decode, and streams produced here decode with all three. PngSuite passes. The path traversal suite rejects every variant.

### M8 Text processing

Regular expressions, both template packages, MIME, logging, flags and expvar.

Exit: the four regexp engines agree on the whole corpus. The HTML template escaping suite passes completely, with no exceptions.

## Risk

### M9 Concurrency

Phased inside the milestone.

| Phase | Work | Gate |
| --- | --- | --- |
| M9.1 | Atomics and the sync primitives | none |
| M9.2 | Channels and select | the select model check passes |
| M9.3 | The scheduler, spawn and context | stress suite clean under the thread sanitiser on every platform |
| M9.4 | Green threads | go or no go |

The M9.4 gate is the single largest decision in the project and it is made by a spike before any design work. Does `swapcontext` work from Mojo with a Mojo `def` as the entry point. Do destructors behave when a stack is parked mid function and resumed on a different OS thread. Is a context switch under 200 nanoseconds. Does a guard page overrun fail in a way you can diagnose.

The second question decides it. If the answer is bad then M9.4 is abandoned, the one thread per task model ships permanently, and it goes in the deviations. Nothing else in the roadmap depends on M9.4, which is the point of putting it last inside the milestone rather than between two of them.

Exit: M9.1 through M9.3 complete and stress clean. M9.4 decided either way, in writing.

### M10 core.net

Addresses first, then the event loop, then sockets, then the resolver.

Exit: the DNS attack suite passes. Happy Eyeballs is demonstrated between two real machines, which loopback cannot show.

### M11 Cryptography

Hashes and symmetric primitives written in Mojo. The asymmetric stack, TLS and certificate handling bound to OpenSSL.

Exit: Wycheproof passes. Constant time verification by disassembly passes on both architectures. The TLS interoperability matrix passes against OpenSSL and Go in both directions. The bad certificate matrix fails correctly on every case.

## Completion

### M12 core.database.sql

The pool, the driver interfaces, the three scan paths, and the reference driver.

Exit: Go's `database/sql` suite passes against the reference driver, and the pool is clean under the thread sanitiser with contention.

### M13 The remainder

Gob, structured logging, syslog, the debug and runtime packages, the containers, weak and unique references, suffix arrays, the text helpers, the newer cryptography, mail and SMTP.

Everything deferred for being low value or having no dependents. Grouped rather than sequenced because none of it blocks anything.

Exit: parity reports 100% on every row, with the waivers file accounting for the difference.

### M14 The httpx rebase, and 1.0

Migrate `mojo.httpx` onto this library. It keeps its HTTP/1.1 parser, its HTTP/2 implementation, its client and its cookie jar, and it gives up its socket layer, its DNS, its TLS binding and its address types.

The acceptance test is httpx's own suite, unchanged. Not one behavioural change, or the rebase has failed. That is a far better test of the networking and TLS packages than anything written for them in isolation, because httpx is a real protocol implementation that already works.

Exit, and the definition of 1.0:

- Parity at 100%, with the waivers reviewed
- Differential divergence count at zero
- Every CI check green on three platforms
- httpx rebased with its suite passing unchanged
- Every package has a documentation page with its section on how it differs from Go
- The deviations document complete and reviewed as a whole

After 1.0 the API does not move.

## The ordering rules

**Risk before convenience.** M9's gate could invalidate a design chapter, so it is not scheduled after the easy 400 symbols of image codecs merely because those are pleasant to write. The only reason M9 is not earlier is that it needs the errors and IO packages to exist.

**Generated before generating.** The codec generator lands in M4, before the six packages that consume it. The alternative is six hand written codecs that then get deleted.

**Depth before breadth inside a tier.** Deflate is finished before gzip starts. Addresses are finished before sockets start. A half finished dependency makes its dependents' tests meaningless.

**Nothing is done by assertion.** A package is done when parity reports its row at 100%, its tests pass, its differential run diverges nowhere, and its documentation page exists. Four checks, all machine verified, which is why every exit criterion above is phrased as a test result rather than as a description of the work.

## What would change this plan

**A Mojo release changes a probed fact.** The probes fail and name the section. If trait objects arrive, the IO design simplifies enormously and the erased structs become an implementation detail. If a static assert arrives, every compile time warning in this library becomes a compile error, which is four lines and a major version.

**M9.4 fails.** Recorded, the simpler threading model ships, and the roadmap is otherwise unaffected.

**Mojo's own standard library grows a package we planned to write.** Gaps found in `std` get raised upstream rather than forked around. A verdict moves from write to wrap, our symbol count drops, and the parity contract is unchanged because it measures Go's surface and not ours.
