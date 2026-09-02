# A fixture. This file is supposed to fail the linter, and `pixi run
# lint-selftest` fails if the linter accepts it. Nothing here is compiled or
# imported by anything.
#
# What is wrong with it is what is wrong with `fallible_next.mojo`: a `for`
# loop silently drops an error raised out of `__next__`, so this iterator
# reports a clean end of input and the caller carries on with half the data.
#
# It is a third fixture because of what it raises. The check exempts
# `raises StopIteration`, because that is not an error and is the signature
# Mojo's `Iterator` trait requires. This one names a real error type as well,
# which is exactly the shape a too-generous exemption would wave through: end
# of input and a read failure arriving by the same route, and the loop unable
# to tell them apart. Do not simplify this to a bare `raises`, because then
# `fallible_next.mojo` already covers it and this file proves nothing.


struct Records:
    var remaining: Int

    def __iter__(self) -> Self:
        return self

    def __next__(mut self) raises StopIteration | Error -> String:
        if self.remaining == 0:
            raise StopIteration()
        if self.remaining < 0:
            raise Error("read failed")
        self.remaining -= 1
        return String("record")

    def __has_next__(self) -> Bool:
        return self.remaining > 0
