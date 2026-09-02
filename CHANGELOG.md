# Changelog

Notable changes, newest first. This project follows semantic versioning from 1.0. Before then, anything can move.

## Unreleased

No library code yet. The repository holds the plan, the documentation, the build and the package tree, and the work is tracked as milestones and issues.

Added the 137 package manifests under `core/`, each recording the Go package it answers for, its tier, whether it may use unsafe operations, and exactly what it is allowed to import. The tier is derived from the graph rather than chosen, and `pixi run lint` checks that the number in the manifest is one more than the deepest dependency, that the graph has no cycle, and that the directory matches the name.

See [docs/roadmap.md](docs/roadmap.md) for what is coming and in what order.
