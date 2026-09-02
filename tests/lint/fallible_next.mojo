# A fixture. This file is supposed to fail the linter, and `pixi run
# lint-selftest` fails if the linter accepts it. Nothing here is compiled or
# imported by anything.
#
# What is wrong with it: a `for` loop silently drops an error raised out of
# `__next__`, so this iterator reports a clean end of input and the caller
# carries on with half the data. Fallible iteration is `has_next` and `next`
# instead. See docs/design.md.


struct Lines:
    var remaining: Int

    def __iter__(self) -> Self:
        return self

    def __next__(mut self) raises -> String:
        if self.remaining == 0:
            raise Error("read failed")
        self.remaining -= 1
        return String("line")

    def __has_next__(self) -> Bool:
        return self.remaining > 0
