# Testing

The problem this document solves is not how to write tests. It is that 8,900 symbols cannot be tested by writing tests for them one at a time. At a generous ten symbols a day that is nearly four person years, and the result would be worse than what Go already has, because Go's tests encode two decades of bugs found in production.

So the strategy is to take Go's tests rather than write our own, and to spend the effort saved on the things Go's tests cannot check.

## Harvesting Go's suites

Go's standard library ships roughly 400,000 lines of test code under a BSD licence. It is the highest value asset available to this project and it is not a substitute for thinking. It is the specification, made executable.

`tools/testgen` does the conversion and it works in three tiers depending on what the test actually is.

**Data.** A large fraction of Go's tests are table driven, which is a slice of input and expected output pairs plus a loop. The table is data, the loop is boilerplate, and the table converts mechanically. The generator parses the Go source with a Go program, using the same `go/ast` package we deliberately excluded from this library and which is exactly the right tool for this job, extracts the literal tables and emits Mojo test data plus a driver. Most of `strconv`, `strings`, `bytes`, `url`, `path`, `time`, `unicode`, `regexp`, `fmt` and the codecs is this.

**Corpora.** Directories of inputs with expected outputs, for the archive, image, compression and cryptography packages. These are copied as they are, with provenance recorded, and the test is written once per package rather than once per file.

**Logic.** Tests that are really programs, such as the connection pool behaviour in `database/sql`, the adversarial sorting inputs, and the contention tests in `sync`. These are translated by hand and they are the minority by count and the majority by value. Each one is reviewed against its Go original and the file records which Go test it came from so that a reader can compare.

The generator runs offline and its output is checked in. It is not part of the build, because a build that needs a Go toolchain present is a build that breaks, and re-running it against a new Go release is a deliberate act that produces a reviewable diff. That diff is also how we notice Go fixing a bug we have.

Provenance and licensing are enforced rather than intended. Every harvested file carries the Go copyright notice and the BSD terms, the linter fails a corpus file without a provenance entry, and the third party licence file collects them all. This is not a formality. A core library that vendors somebody else's tests without attribution is a legal problem for everyone who ships it.

## Differential testing

Go's tests check the cases Go's authors thought of. Differential testing checks the cases nobody thought of, by running two implementations against the same input and comparing.

`tools/differ` is the harness: a Mojo program and a Go program, fed identical generated input, compared byte for byte. The Go side is built once in CI and cached.

| Area | Oracle | What it finds |
| --- | --- | --- |
| Float formatting and parsing | Go | The last bit rounding cases that enumeration misses |
| Regular expressions | Go, and the four internal engines against each other | Engine selection bugs and submatch position differences |
| URL | Go, and the web platform test corpus | Normalisation differences, which are a security boundary |
| JSON | Go, and JSONTestSuite | Acceptance differences on malformed input |
| Time parsing and formatting | Go | Zone transition and daylight saving edge cases |
| Compression | The `gzip` tool, zlib and Go | Streams one implementation produces and another cannot read |
| Certificates | OpenSSL | Certificate confusion, which is the case where both parse and disagree |
| Images | Go and ImageMagick | Decoder disagreements on unusual but valid files |

The certificate row is the one that matters most. A finding there says that both implementations accepted a certificate and disagreed about who it is for, which crashes nothing and is a complete authentication bypass.

Differential testing is also the honest answer to the parity question. The parity tool checks that a symbol exists. The differ checks that it behaves. A package can be at 100% parity and wrong, so the README reports both numbers.

## Fuzzing

The fuzzing API Go added in 1.18 is implemented here over libFuzzer, which the toolchain underneath Mojo already provides.

Every parser that reads bytes it did not produce is a target, and the list is not short: JSON, XML, ASN.1, CSV, PEM, all five compression decoders, tar, zip, the three image decoders, the regexp pattern parser, URL, textproto, mail, multipart and DNS messages.

The assertion for all of them is the same and it is weaker than it looks. Any input either parses or raises. Never aborts, never allocates without bound, never loops forever. Mojo's bounds checking makes memory safety findings unlikely, which moves the value of fuzzing here to resource exhaustion and to the differential oracle, where a divergence is a finding even when neither side misbehaved.

Corpora are checked in, seeded from Go's, and grown by CI. A crash the fuzzer finds becomes a regression test with the input and a comment naming what it did.

## The properties Go's tests cannot check

Four things this library has to guarantee that Go's suites say nothing about, because Go does not have these problems.

**The iteration rule.** A `for` loop swallows an error raised out of `__next__`. The linter enforces the explicit `has_next` and `next` split, and there is a test asserting that the linter actually rejects a fallible `__next__`, using a fixture that is expected to fail. A convention defended only by memory is not defended. Separately a probe pins the compiler behaviour, so a Mojo release that fixes it makes a test fail and we revisit the whole rule.

**The error mechanism.** A foreign error must never be mistaken for one of ours, an overwritten record must fail cleanly rather than returning some other error's fields, and a captured error must survive a thread boundary with its wrapping intact. Those three are tested directly, because they are the ways that design fails silently.

**Layering.** The linter checks every import against the package's declared dependencies, in both directions, so an undeclared import fails and an unused declaration also fails. CI builds every package with only its transitive dependencies. A library that only ever builds as a whole has a dependency graph nobody has tested.

**Unsafety.** Seventeen packages declare themselves unsafe and the rest may not name a raw pointer, a foreign call or a bitcast. The linter enforces it and reports the count, because that number going up is a thing to notice.

## The compile time checks

A compile time mismatch in this library is a warning rather than an error, for the reason in [design.md](design.md). That makes the warning mechanism load bearing, and load bearing things get tested.

`tests/warnings/` holds files that are expected to produce warnings, compiled with warnings on, with the count and the message text asserted. If the underlying mechanism stops firing, which is a plausible thing for a compiler release to change, those files start compiling cleanly and the test fails. Without it, every compile time check in the library would silently stop working and nothing would say so.

`pixi run lint` builds the whole tree with warnings on and fails on any diagnostic carrying our marker prefix, which is what turns those warnings into errors inside this repository.

## Why one machine is not enough

Correctness on one machine is not correctness, and three specific things need more than one.

**Memory ordering.** A missing acquire barrier is invisible on x86-64's strong model and shows up on arm64. A concurrency suite that only ran on x86 tested nothing about ordering, which is why the arm64 runner is in the required matrix rather than being a nice extra.

**Struct layouts.** The `stat` structure, the mutex structure and the socket address structures differ per platform, and a wrong offset reads a plausible wrong number rather than failing. Those are checked against the platform's own C headers, on the platform, which is the only place the question can be asked. `pixi run baseline` does it and the recorded tables are in [core/syscall/baseline](../core/syscall/baseline/README.md). They are not a formality: `pthread_mutex_t` is 40 bytes on Linux x86-64, 48 on Linux arm64 and 64 on macOS, and `struct stat` has a different field order on the two Linux architectures rather than merely a different size.

**Real latency.** On loopback both address families win instantly, so the connection racing in the resolver is untested there. It needs two machines with a real network between them.

CI covers macOS arm64, Linux x86-64 and Linux arm64. The longer suites run on a small set of private machines that are not described here, through a runner that reads its targets from an environment file that is not checked in. The linter greps the tree for those names as a committed secret check.

## The runner

`pixi run test` finds every `def test_something() raises:` in a `test_*.mojo` file under `tests/`, generates one main that calls all of them, builds it once and runs it. One binary rather than one per test, because the build time then tracks the size of the library rather than the number of tests.

The `raises` is required and the runner says so when it is missing. A test that cannot raise cannot fail an assertion, so it passes forever and looks like coverage.

Assertions come from `std.testing`, which already reports the file, the line and both values. The runner catches the error, says which test it came out of, and rewrites the absolute path to a relative one so it can be clicked.

```
FAIL tests.strings.test_index.test_index_finds
     tests/strings/test_index.mojo:4:17: AssertionError: `left == right` comparison failed:
   left: 4
  right: 5
```

`pixi run test core.strings` runs one package. It fails rather than passing quietly when the name matches nothing, because a filter that silently matches no tests is how a suite stops running without anybody noticing.

`pixi run race` builds the same suite under the thread sanitiser. Nothing in a refcount or a lock fails an assertion when it is wrong; it corrupts something and the failure arrives later somewhere else, so a green `pixi run test` is not evidence about either. The sanitiser reports and then lets the program carry on with its exit code untouched, which means a suite with a data race in it passes with the report sitting in the log, so the runner reads the output and promotes the report itself. That was proved by making `ErasedBox`'s count non atomic and watching it report four races.

It runs on macOS and not on Linux, which is not a choice. The Mojo runtime links tcmalloc, tcmalloc assumes a 48-bit address space, and the sanitiser has taken that range for its shadow memory, so a sanitised binary dies in the allocator before it reaches main. There is no flag to build without tcmalloc. The runner recognises that message and says what happened rather than reporting a suite failure. The loss is smaller than it looks, because the macOS runner is arm64 and the weak memory model is the thing a missing barrier needs in order to show up at all; what is not covered is anything that only races under glibc.

`--short` skips the cases marked slow, which is what a local run wants and what CI does not do. A case is marked by a `# slow: why` comment on the line above it, so the decision lives with the person who wrote the five minute test rather than in a list somewhere else that goes stale.

Every suite links `core/errors/shim/slot.c`, whether or not it touches `core.errors`, so running the tests needs a C compiler on the host. It is a few hundred bytes and it makes the link line the same for every run, which is worth more than the bytes: a test that only fails when some other test happens to be in the same build is the kind of thing that costs a day to find. The object is compiled fresh into a scratch directory each time rather than cached, because deciding whether a cached copy is stale costs more than compiling fifteen lines of C, and a cache keyed on the wrong thing keeps working while linking an object from a compiler or a platform that is no longer the one in front of you.

The generated main is written to `tests/_generated_main.mojo` and is gitignored. The runner asks git whether it really is ignored and refuses to build if not, because that `.gitignore` line is one tidy up away from being deleted and generated code appearing in a commit is noticed a month later.

`pixi run test-selftest` runs the runner against fixtures under `tests/mojotest` that are supposed to fail, and checks that the failure is reported at all and that it arrives with the file, the line and both values. A runner that swallows a failing test turns the whole suite into theatre, and nothing else in the repository would notice.

## core.testing

Wraps Mojo's `std.testing`, which has assertions and little else, and adds what Go has. Subtests, benchmark iteration and allocation reporting, fuzz targets, a test main, golden files with an update flag, and a short mode, so that the five minute exhaustive float round trip is skipped locally and run in CI.

The helper packages earn their place. `iotest` supplies the half reader, the one byte reader, the error at byte n reader and the timeout reader, and most IO bugs are found by these rather than by testing the happy path. `synctest` is a fake clock and a deterministic scheduler, which is what makes a test for a five minute timeout take microseconds and a concurrency failure reproducible from a seed. `quick` is property testing, where a type supplies a generator by implementing a trait or has one generated from the same documentation JSON that produces codecs. `fstest` is an in memory filesystem, `sqltest` is the reference SQL driver, `cryptotest` is the conformance harness every hash has to pass, and `slogtest` validates a log handler.

## What CI runs

```
pixi run check   ->  format-check  lint  lint-selftest  vendor-check
                     generated-check  baseline  parity  warnings  probe
                     test-selftest  test
```

on macOS arm64, Linux x86-64 and Linux arm64, on every commit. The generated code check rebuilds the Unicode tables, the time zone data, the syscall bindings and every codec and fails on a diff. It is the single most valuable check in the list, because generated code drifting from its source is a bug that surfaces months later somewhere unrelated.

Nightly: the exhaustive float round trip, the fuzzers, the differential runs against Go, the TLS interoperability matrix, and the concurrency stress suite under the thread sanitiser.

The README carries three generated numbers once there is something to report. Parity percentage, test count, and the differential divergence count, which should be zero and which is the honest measure of whether this library behaves like the one it copies.
