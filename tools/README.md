# tools

Everything the build runs that is not Mojo. All of it is Python with no dependencies outside the standard library, because a tool that needs its own environment installed is a tool people stop running.

Each directory is one job and each entry point prints what it checked even when it found nothing. That is deliberate. A tool that says nothing when it finds nothing looks exactly like a tool that is not running, and this repository will spend a while with very little in it.

| Directory | Task | What it is for |
| --- | --- | --- |
| `lib` | | The shared model of the tree. Packages, sources, and the reporting shape the others use. |
| `fmt` | `format-check` | Formats a copy and compares, because `mojo format` has no check mode. |
| `lint` | `lint`, `lint-selftest` | Layering, unsafe operations, the iteration rule, `must_` calls, and the committed secret check. |
| `parity` | `parity` | How much of Go's exported surface exists here, read from the table in `docs/packages.md`. |
| `pkgbuild` | `pkg` | Builds each package against only what its manifest declares. |
| `mojotest` | `test` | Generates one main that calls every test, so build time tracks the size of the library rather than the number of tests. |
| `warnings` | `warnings` | Files that are expected to produce compile time warnings, with the count and the text asserted. |
| `baseline` | `baseline` | Struct offsets, errno values and signal numbers, asked of the platform's own headers. |
| `gen` | `gen`, `generated-check` | The code generators. Output is checked in and regenerated in CI, which fails on a diff. |
| `vendor` | `vendor-check` | The vendored corpora against their recorded digests and licences. |
| `probe` | `probe` | The ten language assumptions in `docs/design.md`, each a small program plus what is supposed to happen to it. |
| `differ` | `differ` | This library and an oracle against the same input, compared byte for byte. |
| `fuzz` | `fuzz` | Every parser that reads bytes it did not produce. |
| `testgen` | `testgen` | Converts Go's table driven tests into Mojo test data. Runs offline, output is checked in. |

`differ`, `fuzz` and `testgen` are not part of `pixi run check`. They need a second toolchain or a lot of time, and neither is something a commit should wait for. CI runs them nightly.

## Adding a check

Put the reason next to the check, not in the commit message. Every check in `lint` exists because of a specific way this library can go wrong, and a reader who cannot tell which way that is will delete it the first time it is inconvenient.

If the check can be fooled by a small change to a regular expression, add a fixture under `tests/lint` that is supposed to fail and wire it into `--selftest`. A lint that has stopped matching anything reports success forever.

## Adding a generator

Drop a module in `gen` with a `generate()` that returns a mapping of repository relative path to file contents. The runner picks it up by being there. Nothing else needs editing.
