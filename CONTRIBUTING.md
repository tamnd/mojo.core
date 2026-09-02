# Contributing

## Getting set up

```
git clone git@github.com:tamnd/mojo.core.git
cd mojo.core
pixi run check
```

That should pass on a clean checkout. If it does not, that is a bug and worth an issue on its own.

## Picking something up

Everything planned is a milestone with issues under it. Start at [docs/roadmap.md](docs/roadmap.md) to see where a package sits and what it depends on, then take an issue from a milestone that is currently open. Say on the issue that you are taking it, so two people do not write the same decoder.

Issues labelled `good first issue` are self contained, have no dependencies that are not already built, and have a Go implementation you can read alongside. That last part makes them much easier than the description suggests.

## The rules that will get a change sent back

**A test that fails before your change and passes after it.** Not a test that passes either way. If the change is a port of a Go package, the test is usually Go's own test table run through `tools/testgen`, which is less work than writing one.

**No undeclared imports.** Every package has a `PACKAGE.toml` listing what it depends on. The linter checks both directions, so an import you did not declare fails, and a declaration you do not use also fails. If you find yourself wanting to add a dependency to a low tier package, that is a design question and belongs on an issue before it belongs in a diff.

**No `Pointer`, `external_call`, `stack_allocation` or any name starting with `unsafe_` outside a package that declares `unsafe = true`.** The prefix is matched as a family rather than listed, so `unsafe_ptr` and `as_unsafe_any_origin` are caught too. Those two are the ones to know about: they reach raw memory through a method on a perfectly safe `Span`, without the word `Pointer` appearing anywhere, and together they are the whole trick `core.runtime.box` is built out of. Seventeen packages declare it. The count is reported by the linter and it going up is a thing we want to notice. `core.errors` is the one that will surprise you: it is tier zero and it reaches libc, because the thread local slot the error record lives in cannot be written in Mojo at all.

**Fallible iteration uses `has_next` and `next`.** A `for` loop drops an error raised out of `__next__`, silently, so anything that can fail while iterating does not get an `__iter__`. The linter enforces this and there is a compiled probe pinning the compiler behaviour, so if a Mojo release fixes it we will find out.

**Public API has a docstring with a runnable example.** The docstring is also where struct tags live, so `tools/codec` reads it, which means a malformed one fails the build rather than being ignored.

## Porting a Go package

The order that works, learned the hard way:

Read Go's implementation and its tests together. The tests tell you which corner cases are real, and a surprising number of Go's functions have behaviour that only exists because of a bug report from 2013.

Check the parity manifest for what the package actually owes: `pixi run parity core.strings` lists every exported Go symbol and whether it exists here. That list is the definition of done for the package, not your reading of the docs.

Do not port a Go idiom that Mojo has a better answer for. A nullable value is `Optional[T]` and not a `NullString`. A cleanup is a `with` block and not a `defer`. A closed set of variants is a tagged union and not an interface. [docs/deviations.md](docs/deviations.md) is the list of places we already decided this, and if your port needs a new entry there, say so in the pull request and it will get looked at properly.

Everything Mojo will not let you do the Go way is already written down in [docs/design.md](docs/design.md) with a compiled probe next to it. If you hit a language wall, check there before working around it, because there is a decent chance the workaround is already chosen and used in ten other places.

## Commits and pull requests

Commit messages say what changed and why, in that order, and the why is the part that is hard to recover six months later. Keep a pull request to one thing. A pull request that ports a package and also reformats a tool is two reviews wearing one hat.

The pull request template has a checklist. It is short and all of it is enforced by CI anyway, so ticking it honestly saves you a round trip.

Everything reaches `main` through a pull request with the `ci ok` check passing and the branch up to date. Direct pushes, force pushes and deleting the branch are all refused. `ci ok` is a single job that fails if anything upstream failed, so the required check does not need changing every time the test matrix does.

Approving reviews are not required yet, and that is the one protection deliberately left off. Requiring one deadlocks a single maintainer, who cannot approve their own work. It goes on the day there is a second committer, and if you are reading this as that second committer, turning it on is your first pull request.

## Design changes

Anything that changes a trait, an error convention, the layering, or how generated code is shaped goes through an issue labelled `design` before code gets written. This is not bureaucracy. These decisions are load bearing across dozens of packages and they are expensive to reverse once things depend on them.

## Code of conduct

[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) applies everywhere in this project.
