# Changelog

Notable changes, newest first. This project follows semantic versioning from 1.0. Before then, anything can move.

## Unreleased

Two language probes and the design facts they pin, ahead of `core.errors` in M1.

Mojo has no global mutable state. A module level `var` is refused outright and the message tells you to move it into a function or make it a `comptime` constant, so there is nowhere in the language to put a package level counter, cache, registry or default. Go's standard library has one in a dozen places. [docs/design.md](docs/design.md) now records that, and that every one of those becomes a value the caller owns and passes.

The one exception is the thread local error record in section 4, which has to outlive the call that wrote it and cannot be passed. It gets its slot from a small C object that `core.errors` links, described below. The cost is stated in the design rather than discovered later, and the alternative it was weighed against was threading an explicit context through every fallible call in the library, which puts the error mechanism in the signature of every function in it.

`tools/probe/probes/thread_local.mojo` pins that pthread's per thread storage really is per thread. Four threads each claim a slot, hand its address to `pthread_setspecific`, wait at a barrier until all four have written, then read the pointer back and write through it, while the main thread holds a different value in the same key across all of it. Without the barrier a shared slot would still look correct, because each thread would set and read before the next arrived. The failure this rules out is one thread reading another thread's error fields, which is a wrong answer rather than a crash.

Both probes were checked against the two ways they can fail: compiling when they should not, and still being refused for a different reason than the one recorded.

The first library code in the tree: the thread local error record, which is the mechanism every fallible function in this library will be written against.

`Report(message).with_field("path", name).error()` writes a record into this thread's slot and hands back the `Error` to raise. `field(e, "path")`, `code(e)` and `partial(e)` read it back at the catch site, so the fields Go would have put in a struct survive a raise that carries only a string, and so does the `n` from Go's `(n, err)` that a raise would otherwise drop.

A record is matched to an error by the message it was raised with and by nothing else. That is what makes the two silent failures safe. An error raised by `std`, or by anything that has never heard of this mechanism, finds a record whose message is not its own and is correctly reported as carrying nothing. An error held past the next raise on the same thread finds the newer record, sees a different message, and reports nothing rather than the newer error's fields. Both of those would otherwise run, print something plausible and be wrong, so both have a test, and both tests were watched failing with the identity check removed. Nothing is appended to the message to make this work: a message with a token in it is a message that cannot be printed, and matching on text that somebody also reads would make every wording change a breaking change to a lookup.

The slot is C, in `core/errors/shim/slot.c`, and that directory's README says why at length. It is a pthread key rather than a `_Thread_local` pointer because a key has a destructor, so a thread that exits still holding a record frees it. The destructor is a Mojo function handed to the shim rather than exported for it to find, because a function only C calls is a function a dead code pass removes, and the exported version linked on Linux and not on macOS. `core.errors` therefore declares `unsafe = true`, taking the linter's count from fifteen packages to sixteen, and running the tests now needs a C compiler on the host.

`core.errors` is tier zero, so every binary built on this library links that object. The cost is stated in [docs/design.md](docs/design.md) section 4 rather than left to be found in a link line, and the alternative it was weighed against, threading an explicit context through every fallible call, is recorded there too.

Two more language facts, each with a probe. A struct valued field cannot be moved out of an owned `self`, which is why `errors.Report` is both the builder and the record rather than the two structs that would read better. And the pthread key destructor really does call back into Mojo on a worker thread's exit, which was proved before the record depended on it.

`tools/lib/native.py` is now the one place that goes looking for a C compiler, shared by `pixi run baseline` and the test runner, and it explains why neither takes one from the lockfile.

The rest of Go's `errors` package: `wrap`, `matches`, `join`, `unwrap`, `causes` and `new`. `core.errors` is the first package in this library at full parity, five symbols present and two waived.

The record is a tree now, because wrapping and joining both make one. It is an arena of links with integer indices, which is the technique the design already committed to for every recursive type here, used for the first time. A chain survives any number of levels with each level keeping its own fields, and `wrap` copies the cause out of the thread's slot before the new record replaces it, which is the only order that works when there is one slot per thread. `field` and `code` answer about the error you hand them and not about what it wraps, because two links in a chain can each carry a `path` and the wrong one is worse than nothing. `matches` is the one that walks, and it walks every cause of a joined error rather than the first, which is the part of Go's contract that is easy to get wrong and which now fails a test when it is.

A sentinel is a code, and nobody picks the number. Go's `errors.Is(err, io.EOF)` works because `io.EOF` is a value you can hold, and there is none here, so a sentinel is an integer on the record. Integers chosen by hand collide, and a collision makes `matches(e, io.EOF)` quietly true for an `os` error, so `core/errors/codes.toml` lists every sentinel in the library and `tools/gen/codes.py` numbers them. That makes a collision impossible rather than unlikely, at the cost that the numbers move when a line is inserted, so a code is meaningless outside the process that produced it and the type says so. `Code` is a struct rather than an `Int`, which is what stops `with_code(300)` compiling where `with_count(300)` was meant.

`errors.As` and `errors.AsType` are waived. Both are reflection over a type hierarchy and this library has neither, so there is no honest partial version; the replacement is the field lookup, the sentinel comparison, and a per package helper such as `os.PathError.of(e)`. `errors.Is` is renamed to `matches`, because `is` is a Mojo keyword.

`join` is weaker than Go's and the deviations page says so rather than leaving it to be found. Go holds error values and every field with them. At most one of the errors passed here still owns the thread's record, so the others contribute their message and their place in the tree and nothing more. `capture` is what will close it.

Sixteen new tests, and the suite was checked against three ways of getting this wrong: a `matches` that does not walk the chain, a `join` that reports only its first cause, and a wrap that refers to the record instead of copying it. Each one fails the tests that name it and nothing else.

`errors.capture(e)` and `ErrorValue`, which is what makes an error a value again. It copies the error's whole subtree out of the thread and owns every message, field and cause it can reach, so a failure can go in a list, sit in a struct field, or be read by a thread that never saw it raised. `ErrorValue.error()` is the way back: it installs the record on whatever thread calls it, so a task's error can be re-raised by the thread that collected it and every function in this package then works on it as though it had just happened.

The cross thread case is the one that decides whether any of this is real, and it now has a test. The reading thread first raises an error of its own, so its slot holds something else entirely, and then reads the captured value. Routing `ErrorValue.field` through the thread's slot instead of the value makes that test fail with `left: /the wrong one`, which is the exact wrong answer it exists to rule out.

`join` over captured errors keeps every field of every cause. Over live errors it cannot, because a record is written at raise time and the next raise replaces it, so all but one arrive as a message. Both halves have a test, so the code and the deviations page cannot drift apart.

With that, the three ways design.md section 4 can fail silently are all covered: a foreign error mistaken for ours, an error held past the next raise, and a capture read on a thread whose own storage holds something else.

## v0.1.0 - 2026-09-03

M0 is complete. The tree, the manifests, the linter, the parity tool, the test runner, the platform tables, the language probes and CI on macOS arm64, Linux x86-64 and Linux arm64. There is still no library code, and that is the point of the milestone: every check that the rest of the work depends on now exists, runs everywhere, and has been shown to fail when it should.

The two checks that landed in this release were both, before it, reporting success while checking nothing. That is the failure mode this milestone exists to rule out.

`pixi run test` is a real test runner now. It finds every `def test_something() raises:` under `tests/`, generates one main that calls all of them, builds it once and runs it, so the build time tracks the size of the library rather than the number of tests. Failures come out with the file, the line and both values, because `std.testing` already reports all three and the runner rewrites the absolute path to a relative one so it can be clicked. The `raises` is required and the runner says so when it is missing, since a test that cannot raise cannot fail an assertion and passes forever while looking like coverage.

`pixi run test core.strings` runs one package and fails rather than passing quietly when the name matches nothing, which is how a suite stops running without anybody noticing. `--short` skips the cases marked slow, and a case is marked with a `# slow: why` comment on the line above it, so the decision sits with the person who wrote the five minute test.

Added `pixi run test-selftest`, which runs the runner against fixtures under `tests/mojotest` that are supposed to fail and checks the failure is reported with the file, the line and both values. A runner that swallows a failing test turns the whole suite into theatre and nothing else here would notice. Breaking the runner on purpose was tried, and the selftest catches it.

The generated main is gitignored and the runner asks git whether it really is, refusing to build if not. That `.gitignore` line is one tidy up away from being deleted, and generated code appearing in a commit is the kind of thing noticed a month later.

Also corrected the symbol count in [docs/testing.md](docs/testing.md), which still said 11,598 from before the counts were generated.

`pixi run baseline` now has tables to check against, recorded for macOS arm64, Linux x86-64 and Linux arm64 and checked in under [core/syscall/baseline](core/syscall/baseline/README.md). Before this it looked for a file that was never there, said it had nothing to compare and passed, which is a check that reports success forever. A missing table on a platform we support is now a failure rather than a skip.

The tables earn their place immediately. `pthread_mutex_t` is 40 bytes on Linux x86-64, 48 on Linux arm64 and 64 on macOS, and the threads probe had been taking a generous fixed buffer while saying these were the numbers that would pin it down. `sin_family` is at offset 0 on Linux and offset 1 on macOS, because macOS puts a length byte first. `O_CREAT` is 64 on Linux and 512 on macOS. `struct stat` has a different field order on the two Linux architectures, not merely a different size.

A mismatch now names the structure, the field, what the platform says and what was recorded, rather than printing a key and two numbers. The platform key is the operating system and the architecture and nothing else, spelled the way the CI matrix spells them. It used to come from `sysconfig.get_platform()`, which puts the macOS release in the string, so a runner one point release behind would have looked like a platform nobody had ever recorded and the check would have passed by finding nothing.

Branch protection on `main` now requires a pull request with the `ci ok` check passing and the branch up to date, on top of the force push and deletion rules that were already there. Approving reviews are the one protection deliberately left off, because requiring one deadlocks a single maintainer who cannot approve their own work. [CONTRIBUTING.md](CONTRIBUTING.md) records that, and the trigger for turning it on.

## v0.0.1 - 2026-09-02

The repository itself, and the checks everything after this depends on. There is no library code in it yet. What is here is the plan, the documentation, the build, the package tree and the tools, and the work is tracked as milestones and issues.

Added the 137 package manifests under `core/`, each recording the Go package it answers for, its tier, whether it may use unsafe operations, and exactly what it is allowed to import. The tier is derived from the graph rather than chosen, and `pixi run lint` checks that the number in the manifest is one more than the deepest dependency, that the graph has no cycle, and that the directory matches the name.

Added the language probes under `tools/probe/probes/`, one Mojo file per property in [docs/design.md](docs/design.md), each with a header saying whether it is supposed to run and print something or be refused by the compiler with a particular message. They pass on Mojo 1.0.0 and on the nightly build, on macOS arm64, Linux x86-64 and Linux arm64. Writing them corrected four things in the design: atomics come from the language and not from libc, because the compiler's atomic builtins do not link on Linux, `@deprecated` fires once per source location rather than once per instantiation and never names the offending call, `fn` and `alias` are gone in favour of `def` and `comptime`, and `UnsafePointer` is now spelled `Pointer`, which the linter had to learn about because a word boundary match on the short name does not find the long one.

Added the diagnostics check to `pixi run lint`. Every compile time check in this library is a deprecation warning carrying a `core:` prefix, because Mojo will not turn a compile time fact into an error. The linter now compiles each package that has code and fails on any warning carrying that prefix, which is what makes a bad format string a build failure here and a warning for everybody else. `tools/warnings` proves those diagnostics still fire, and this proves none of them are left in our own code.

Made `pixi run parity` read Go's own API manifests instead of the table in the documentation. `tools/gen/goapi.py` condenses the nine megabytes of `$GOROOT/api/go1*.txt` into `tools/parity/goapi.txt`, one line per symbol, which is checked in so that the tool works without Go installed and regenerated in CI so that it cannot quietly stop matching. The tool takes the Go package each `PACKAGE.toml` names, applies the naming rules in `tools/parity/rules.py`, and compares that against what `mojo doc` reports. `pixi run parity core.strings` prints one package symbol by symbol, which is the list somebody porting it is owed. The percentage and the counts now live in a generated block in the README. The generator only runs against the Go that `pixi.lock` pins and says so and stops against any other, because two releases of Go produce two different indexes, both correct, and a diff check cannot tell that apart from a mistake.

The two escape hatches are there as files, `tools/parity/waivers.toml` for symbols deliberately not ported and `tools/parity/renames.toml` for names the rules could not derive, and both are checked for lines that no longer point at anything so they cannot rot quietly.

The symbol counts in [docs/packages.md](docs/packages.md) are now generated from the same index and most of them changed, because the numbers that were there counted lines in Go's manifests rather than symbols. Go lists `time.January` twice, once for its value and once for its type, and the old counts counted it twice. The library is 8,900 symbols across 135 packages, not 11,598, and `unicode` is 309 rather than 328. Nothing about the work changed, only the honesty of the number.

Also fixed `core.testing.cryptotest`, which named `crypto/internal/cryptotest` as the Go package it answers for. The real one is `testing/cryptotest`, and the new check on package names is what found it.

See [docs/roadmap.md](docs/roadmap.md) for what is coming and in what order.
