# PINS: 7. A `for` loop swallows an error raised out of `__next__`
# EXPECT: runs
# OUTPUT: saw 3 of 5 with no error reported
# WHY: This is the sharpest edge in the language for a library like this one.
# WHY: Nothing fallible gets an __iter__, the linter rejects a __next__ that
# WHY: raises, and this is the probe that tells us if a release ever fixes it.


# An iterator that fails partway through. Counting down from 5, it raises on
# the third element and never gets to the last two.
@fieldwise_init
struct Fallible(ImplicitlyCopyable, Movable):
    var n: Int

    def __iter__(self) -> Self:
        return self

    def __next__(mut self) raises -> Int:
        if self.n == 2:
            raise Error("stopped early")
        self.n -= 1
        return self.n

    def __has_next__(self) -> Bool:
        return self.n > 0


def main():
    # Note that main is not declared raises, and does not need to be. The error
    # never reaches it.
    var seen = 0
    for _ in Fallible(5):
        seen += 1
    print("saw", seen, "of 5 with no error reported")
