# tools

Everything the build runs that is not Mojo. All of it is Python with no dependencies outside the standard library, because a tool that needs its own environment installed is a tool people stop running.

Each directory is one job and each entry point prints what it checked even when it found nothing. That is deliberate. A tool that says nothing when it finds nothing looks exactly like a tool that is not running, and this repository will spend a while with very little in it.

| Directory | Task | What it is for |
| --- | --- | --- |
| `lib` | | The shared model of the tree. Packages, sources, and the reporting shape the others use. `native.py` is the two places a C compiler is needed: the baseline probe, and the thread local slot `core.errors` links. |
| `fmt` | `format-check` | Formats a copy and compares, because `mojo format` has no check mode. |
| `lint` | `lint`, `lint-selftest` | The package graph, layering, unsafe operations, the iteration rule, `must_` calls, marked compile time diagnostics, and the committed secret check. |
| `parity` | `parity` | How much of Go's exported surface exists here, read from Go's own API manifests. `goapi.txt` is the condensed index, `rules.py` turns a Go name into the Mojo one, and `waivers.toml` and `renames.toml` are the two escape hatches. |
| `pkgbuild` | `pkg` | Builds each package against only what its manifest declares. |
| `mojotest` | `test`, `test-selftest` | Generates one main that calls every test, so build time tracks the size of the library rather than the number of tests. Takes a package to run one package, and `--short` to skip the cases marked slow. |
| `warnings` | `warnings` | Files that are expected to produce compile time warnings, with the count and the text asserted. |
| `baseline` | `baseline` | Struct sizes and offsets, open flags, errno values and signal numbers, asked of the platform's own headers and compared to the tables in `core/syscall/baseline`. |
| `gen` | `gen`, `generated-check` | The code generators. Output is checked in and regenerated in CI, which fails on a diff. `codes.py` is the one that is not about volume: it numbers the library's sentinel errors so that no two packages can pick the same constant. |
| `docjson` | `docjson`, `docjson-selftest` | Reads the JSON `mojo doc` emits and answers questions about structs: fields, resolved types, conformances and the struct tags in field docstrings. This is the reflection substitute the generators are built on. The selftest compiles a fixture package in `testdata` on every run, because every fact the reader depends on is a fact about a compiler that is still changing. |
| `vendor` | `vendor-check` | The vendored corpora against their recorded digests and licences. |
| `probe` | `probe` | The language assumptions in `docs/design.md`, one Mojo file each under `probes/` with a header naming the section it pins and saying what is supposed to happen to it. |
| `differ` | `differ` | This library and an oracle against the same input, compared byte for byte. |
| `fuzz` | `fuzz` | Every parser that reads bytes it did not produce. |
| `testgen` | `testgen` | Converts Go's table driven tests into Mojo test data. Runs offline, output is checked in. |

`docjson`, `differ`, `fuzz` and `testgen` are not part of `pixi run check`. They need a second toolchain or a lot of time, and neither is something a commit should wait for. CI runs the last three nightly, and `docjson-selftest` runs on every commit, which is the part of `docjson` that can go quietly wrong.

## Adding a check

Put the reason next to the check, not in the commit message. Every check in `lint` exists because of a specific way this library can go wrong, and a reader who cannot tell which way that is will delete it the first time it is inconvenient.

If the check can be fooled by a small change to a regular expression, add a fixture under `tests/lint` that is supposed to fail and wire it into `--selftest`. A lint that has stopped matching anything reports success forever.

## Adding a generator

Drop a module in `gen` with a `generate()` that returns a mapping of repository relative path to file contents. The runner picks it up by being there. Nothing else needs editing.

A generator that needs a toolchain we do not always have should print a line saying so and return nothing, the way `goapi.py` does when Go is not installed. Then working offline stays possible and the check still runs somewhere: the jobs that run `generated-check` use the `oracle` environment, which pins Go in `pixi.lock`.

Check the version of that toolchain and not only that it is there. Two releases of Go produce two different API indexes, both correct, and a diff check cannot tell that apart from somebody hand editing the file. `goapi.py` reads the pinned version out of `pixi.lock` and skips anything else, which is why `pixi run check` passes on a GitHub runner, where a Go nobody asked for is already on PATH. Moving to a newer Go is then a lock file update followed by `pixi run -e oracle gen`, and the diff is the review.
