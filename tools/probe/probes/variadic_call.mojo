# PINS: 11. A variadic C function cannot be called portably
# EXPECT: runs
# OUTPUT: the variadic arguments arrive as recorded True
# WHY: core.syscall binds libc, and open, fcntl, ioctl and the printf family
# WHY: are all variadic. external_call emits a fixed arity call, which is the
# WHY: wrong calling convention on Apple silicon and the right one everywhere
# WHY: else, so the same call is correct on two of our three platforms and
# WHY: silently wrong on the third. If this prints False, read section 11:
# WHY: either external_call learned the convention, which means the shim that
# WHY: section describes can go, or a platform we thought was safe no longer
# WHY: is.

from std.ffi import external_call
from std.sys import CompilationTarget

comptime SIZE = 64


def main():
    # Three named parameters and then the variadic ones, so this is exactly
    # the shape of `open(path, flags, mode)` rather than a printf special case.
    var out = Array[UInt8, SIZE](fill=0)
    var format = String("%d,%d,%d\0")
    var written = external_call["snprintf", Int32](
        Pointer(to=out[0]),
        Int(SIZE),
        format.as_bytes().unsafe_ptr(),
        Int32(111),
        Int32(222),
        Int32(333),
    )

    var got = String()
    for i in range(Int(written)):
        got += chr(Int(out[i]))

    # On Apple silicon an anonymous argument is passed on the stack and a fixed
    # arity call leaves it in a register, so snprintf formats whatever the
    # stack happened to hold. Anywhere else the two conventions agree for
    # integer arguments and the numbers arrive.
    var arrived = got == "111,222,333"
    print("the variadic arguments arrive as recorded", arrived != CompilationTarget.is_macos())
