# PINS: Smaller facts that change how code is written
# EXPECT: runs
# OUTPUT: dead before the next statement True
# WHY: core.io builds a borrowed view of a writer, takes its address and hands
# WHY: that address to a function pointer. Taking the address is the view's
# WHY: last use, so with nothing holding it down the view is already destroyed
# WHY: by the time the call reads it, which is a use after free and not a
# WHY: compile error. `core/io/erased.mojo` consumes the view with `_ = view^`
# WHY: after the call for exactly this reason. If Mojo ever moves to end of
# WHY: scope destruction those two lines become dead weight and can go.

comptime Untracked = UntrackedOrigin[mut=True]


struct Loud(Movable):
    """Sets a flag when it dies, which is the only way to see when that is."""

    var mark: Pointer[Int, Untracked]

    def __init__(out self, mark: Pointer[Int, Untracked]):
        self.mark = mark

    def __deinit__(deinit self):
        self.mark[] = 1


def address_of[T: AnyType, o: Origin](ref [o] target: T) -> Int:
    """What `core.runtime.box.address_of` does, and the last use in question."""
    return Int(Pointer(to=target))


def main():
    var dead = 0
    var value = Loud(Pointer(to=dead).unsafe_origin_cast[Untracked]())

    # `value` is not named below this line, so this call is its last use.
    var address = address_of(value)
    _ = address

    # End of scope destruction would print False here, and the address above
    # would still be good. It prints True.
    print("dead before the next statement", dead == 1)
