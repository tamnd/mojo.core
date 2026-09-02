# PINS: Smaller facts that change how code is written
# EXPECT: rejected
# ERROR: destroyed out of the middle of a value
# WHY: A builder that hands its contents to something else cannot be a wrapper
# WHY: around the thing it builds, because giving the inner value away is this
# WHY: error. That is why errors.Report is both the builder and the record
# WHY: rather than the two structs that would read better. If this ever
# WHY: compiles, that split becomes available again and core/errors/record.mojo
# WHY: says so in the struct docstring.

from std.testing import assert_equal


struct Inner(Movable):
    var message: String

    def __init__(out self, var message: String):
        self.message = message^


struct Outer(Movable):
    var inner: Inner

    def __init__(out self, var message: String):
        self.inner = Inner(message^)

    # Moving a plain field out of an owned self is fine. Moving a struct valued
    # one is not, and only the second is below, so the probe is about the
    # nesting rather than about ownership in general.
    def give_away(var self) -> Inner:
        return self.inner^


def main() raises:
    assert_equal(Outer("hello").give_away().message, "hello")
