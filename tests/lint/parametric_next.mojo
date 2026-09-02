# A fixture. This file is supposed to fail the linter, and `pixi run
# lint-selftest` fails if the linter accepts it. Nothing here is compiled or
# imported by anything.
#
# What is wrong with it is what is wrong with `fallible_next.mojo`: a `for`
# loop silently drops an error raised out of `__next__`, so this iterator
# reports a clean end of input and the caller carries on with half the data.
#
# It is a second fixture because of how it is spelled rather than what it does.
# The parameter list on `__next__` is the point. The pattern this check used to
# be written with required the parenthesis straight after the name, so it did
# not match this, and this is what an iterator that borrows its input looks
# like. Do not rewrite the signature onto one line without parameters, because
# then `fallible_next.mojo` already covers it and this file proves nothing.


struct Windows[o: Origin]:
    var data: Span[UInt8, o]
    var at: Int

    def __iter__(self) -> Self:
        return Self(self.data, self.at)

    def __next__[size: Int](mut self) raises -> Span[UInt8, o]:
        if self.at + size > len(self.data):
            raise Error("short window")
        var out = self.data[self.at : self.at + size]
        self.at += size
        return out

    def __has_next__(self) -> Bool:
        return self.at < len(self.data)
