# PINS: 12. A Mojo string is not a C string
# EXPECT: runs
# OUTPUT: the bytes of a string run past its length True
# WHY: every path core.syscall hands to libc has to be zero terminated, and a
# WHY: Mojo string carries a length instead of a terminator, so the bytes it
# WHY: gives back are the path followed by whatever else is in the allocation.
# WHY: A substring is the case that shows it every time, because what follows
# WHY: is the rest of the string it was taken from, but the same thing happens
# WHY: to a whole string sitting in a buffer that held a longer one. If this
# WHY: prints False, read section 12: the copy core.syscall makes for every
# WHY: path may be able to go.

from std.ffi import external_call

comptime _Read = AnyOrigin[mut=False]


def strlen(p: Pointer[UInt8, _Read]) -> Int:
    """How long C thinks the string at this address is."""
    return Int(external_call["strlen", Int](p))


def main():
    # A path and then something else in the same allocation, which is exactly
    # the shape of a directory name taken out of a longer path.
    var whole = String("/tmp/keep-this-name")
    var head = whole[byte=0:5]
    var bytes = head.as_bytes()
    var counted = strlen(bytes.unsafe_ptr().as_unsafe_any_origin())

    # Five bytes to Mojo and nineteen to C. Handing this to open would ask for
    # a path nobody wrote and get an errno for it.
    print("the bytes of a string run past its length", counted != len(bytes))
