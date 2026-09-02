## What this changes

<!-- One or two sentences. What is different after this lands. -->

## Why

<!-- The problem. This is the part that is hard to recover six months later. -->

## Checklist

- [ ] There is a test that fails before this change and passes after it
- [ ] `pixi run check` passes
- [ ] Every import is declared in the package's `PACKAGE.toml`
- [ ] New public API has a docstring with a runnable example
- [ ] Anything fallible that iterates uses `has_next` and `next` rather than `__iter__`
- [ ] Any new behaviour that differs from Go is recorded in `docs/deviations.md`

## Notes for the reviewer

<!-- Anything that is not obvious from the diff. Delete if there is nothing. -->
