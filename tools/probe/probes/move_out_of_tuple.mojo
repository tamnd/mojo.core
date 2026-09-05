# PINS: Smaller facts that change how code is written
# EXPECT: rejected
# ERROR: does not designate a value with an origin
# WHY: A function returning two owned values has nowhere to put them. Go's
# WHY: os.Pipe hands back two *File and the caller takes them apart, and here
# WHY: the pair comes back in a tuple and has to be used where it sits, because
# WHY: a File cannot be copied and this is the error for taking one out. Reading
# WHY: writing and closing through the tuple all work; giving one end away to
# WHY: something that owns it does not. If this ever compiles, core.os.pipe can
# WHY: be destructured and the row for it in docs/deviations.md goes.

from std.testing import assert_equal


struct Owned(Movable):
    """Move only, which is what a `File` is and why this matters."""

    var value: Int

    def __init__(out self, value: Int):
        self.value = value


def both() -> Tuple[Owned, Owned]:
    return (Owned(1), Owned(2))


def main() raises:
    var pair = both()
    # Reading a field through the tuple is fine and is what `core.os.pipe`'s
    # callers do. Taking the element out of the tuple is the line below it.
    assert_equal(pair[0].value, 1)
    var taken = pair[0]^
    assert_equal(taken.value, 1)
