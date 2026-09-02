# PINS: Smaller facts that change how code is written
# EXPECT: rejected
# ERROR: global variables are not supported
# WHY: There is no process wide mutable state in Mojo at all, which is why the
# WHY: thread local error record needs a slot that Mojo cannot give it and gets
# WHY: one from a C object instead. If this ever compiles, that C object stops
# WHY: being necessary and section 4 of design.md gets simpler, so this is a
# WHY: probe that is good news when it fails.

# A `comptime` constant is fine and is not what this is about. The thing that
# does not exist is a module level `var` that a function can write to.
comptime LIMIT = 7

var slot: Int = 0


def main() raises:
    slot += 1
    print("slot", slot, "limit", LIMIT)
