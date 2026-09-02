# Changelog

Notable changes, newest first. This project follows semantic versioning from 1.0. Before then, anything can move.

## Unreleased

No library code yet. The repository holds the plan, the documentation, the build and the package tree, and the work is tracked as milestones and issues.

Added the 137 package manifests under `core/`, each recording the Go package it answers for, its tier, whether it may use unsafe operations, and exactly what it is allowed to import. The tier is derived from the graph rather than chosen, and `pixi run lint` checks that the number in the manifest is one more than the deepest dependency, that the graph has no cycle, and that the directory matches the name.

Added the language probes under `tools/probe/probes/`, one Mojo file per property in [docs/design.md](docs/design.md), each with a header saying whether it is supposed to run and print something or be refused by the compiler with a particular message. They pass on Mojo 1.0.0 and on the nightly build, on macOS arm64, Linux x86-64 and Linux arm64. Writing them corrected four things in the design: atomics come from the language and not from libc, because the compiler's atomic builtins do not link on Linux, `@deprecated` fires once per source location rather than once per instantiation and never names the offending call, `fn` and `alias` are gone in favour of `def` and `comptime`, and `UnsafePointer` is now spelled `Pointer`, which the linter had to learn about because a word boundary match on the short name does not find the long one.

Added the diagnostics check to `pixi run lint`. Every compile time check in this library is a deprecation warning carrying a `core:` prefix, because Mojo will not turn a compile time fact into an error. The linter now compiles each package that has code and fails on any warning carrying that prefix, which is what makes a bad format string a build failure here and a warning for everybody else. `tools/warnings` proves those diagnostics still fire, and this proves none of them are left in our own code.

See [docs/roadmap.md](docs/roadmap.md) for what is coming and in what order.
