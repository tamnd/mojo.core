# PINS: 7. A `for` loop swallows an error raised out of `__next__`
# EXPECT: runs
# OUTPUT: saw 2 and then caught looked ahead and failed
# WHY: The other half of the previous probe, and the reason the linter rule is
# WHY: written against __next__ and nothing else. The swallowing is specific to
# WHY: __next__: a raising __has_next__ makes the `for` itself a raising call,
# WHY: so the loop cannot even be written in a function that is not `raises`
# WHY: and the error comes out. If a release ever makes the two consistent,
# WHY: this is what says which way it went.


# The same iterator as `for_swallows_raise`, with the failure moved one method
# across. Nothing else about it changes.
@fieldwise_init
struct Fallible(ImplicitlyCopyable, Movable):
    var n: Int

    def __iter__(self) -> Self:
        return Self(self.n)

    def __next__(mut self) -> Int:
        self.n -= 1
        return self.n

    def __has_next__(self) raises -> Bool:
        if self.n == 3:
            raise Error("looked ahead and failed")
        return self.n > 0


def main():
    var seen = 0
    var caught = String("nothing")
    try:
        for _ in Fallible(5):
            seen += 1
    except e:
        caught = String(e)
    print("saw", seen, "and then caught", caught)
