# Changelog

Notable changes, newest first. This project follows semantic versioning from 1.0. Before then, anything can move.

## Unreleased

Nothing since v0.0.1.

## v0.0.1 - 2026-09-02

The repository itself, and the checks everything after this depends on. There is no library code in it yet. What is here is the plan, the documentation, the build, the package tree and the tools, and the work is tracked as milestones and issues.

Added the 137 package manifests under `core/`, each recording the Go package it answers for, its tier, whether it may use unsafe operations, and exactly what it is allowed to import. The tier is derived from the graph rather than chosen, and `pixi run lint` checks that the number in the manifest is one more than the deepest dependency, that the graph has no cycle, and that the directory matches the name.

Added the language probes under `tools/probe/probes/`, one Mojo file per property in [docs/design.md](docs/design.md), each with a header saying whether it is supposed to run and print something or be refused by the compiler with a particular message. They pass on Mojo 1.0.0 and on the nightly build, on macOS arm64, Linux x86-64 and Linux arm64. Writing them corrected four things in the design: atomics come from the language and not from libc, because the compiler's atomic builtins do not link on Linux, `@deprecated` fires once per source location rather than once per instantiation and never names the offending call, `fn` and `alias` are gone in favour of `def` and `comptime`, and `UnsafePointer` is now spelled `Pointer`, which the linter had to learn about because a word boundary match on the short name does not find the long one.

Added the diagnostics check to `pixi run lint`. Every compile time check in this library is a deprecation warning carrying a `core:` prefix, because Mojo will not turn a compile time fact into an error. The linter now compiles each package that has code and fails on any warning carrying that prefix, which is what makes a bad format string a build failure here and a warning for everybody else. `tools/warnings` proves those diagnostics still fire, and this proves none of them are left in our own code.

Made `pixi run parity` read Go's own API manifests instead of the table in the documentation. `tools/gen/goapi.py` condenses the nine megabytes of `$GOROOT/api/go1*.txt` into `tools/parity/goapi.txt`, one line per symbol, which is checked in so that the tool works without Go installed and regenerated in CI so that it cannot quietly stop matching. The tool takes the Go package each `PACKAGE.toml` names, applies the naming rules in `tools/parity/rules.py`, and compares that against what `mojo doc` reports. `pixi run parity core.strings` prints one package symbol by symbol, which is the list somebody porting it is owed. The percentage and the counts now live in a generated block in the README.

The two escape hatches are there as files, `tools/parity/waivers.toml` for symbols deliberately not ported and `tools/parity/renames.toml` for names the rules could not derive, and both are checked for lines that no longer point at anything so they cannot rot quietly.

The symbol counts in [docs/packages.md](docs/packages.md) are now generated from the same index and most of them changed, because the numbers that were there counted lines in Go's manifests rather than symbols. Go lists `time.January` twice, once for its value and once for its type, and the old counts counted it twice. The library is 8,900 symbols across 135 packages, not 11,598, and `unicode` is 309 rather than 328. Nothing about the work changed, only the honesty of the number.

Also fixed `core.testing.cryptotest`, which named `crypto/internal/cryptotest` as the Go package it answers for. The real one is `testing/cryptotest`, and the new check on package names is what found it.

See [docs/roadmap.md](docs/roadmap.md) for what is coming and in what order.
