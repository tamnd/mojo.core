# Changelog

Notable changes, newest first. This project follows semantic versioning from 1.0. Before then, anything can move.

## Unreleased

No library code yet. The repository holds the plan, the documentation, the build and the package tree, and the work is tracked as milestones and issues.

Added the 137 package manifests under `core/`, each recording the Go package it answers for, its tier, whether it may use unsafe operations, and exactly what it is allowed to import. The tier is derived from the graph rather than chosen, and `pixi run lint` checks that the number in the manifest is one more than the deepest dependency, that the graph has no cycle, and that the directory matches the name.

Added the ten language probes under `tools/probe/probes/`, one Mojo file per property in [docs/design.md](docs/design.md), each with a header saying whether it is supposed to run and print something or be refused by the compiler with a particular message. They pass on Mojo 1.0.0 and on the nightly build. Writing them corrected three things in the design: `@deprecated` fires once per source location rather than once per instantiation and never names the offending call, `fn` and `alias` are gone in favour of `def` and `comptime`, and `UnsafePointer` is now spelled `Pointer`, which the linter had to learn about because a word boundary match on the short name does not find the long one.

See [docs/roadmap.md](docs/roadmap.md) for what is coming and in what order.
