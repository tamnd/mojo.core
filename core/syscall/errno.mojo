"""The number a failing call leaves behind, and the error it becomes.

Go's `syscall.Errno` is an integer that satisfies `error`, so a caller can
compare it against `syscall.ENOENT` and also print it. This is the same idea
with the same two jobs, and it exists because Mojo's own `std.os` reports a
failed call as a string and throws the number away, which makes "the file was
not there" indistinguishable from "the directory was not searchable" to
anything trying to decide what to do next.

The number is only meaningful next to the platform's own constants, and those
are in `abi.mojo`. Nothing above this package should compare against a literal:
`EAGAIN` is 35 on macOS and 11 on Linux, and 35 on Linux is `EDEADLK`, so a
literal does not fail to match, it matches something else.
"""

from std.ffi import external_call
from std.sys import CompilationTarget

comptime _Any = AnyOrigin[mut=True]

comptime _ERRNO_LOCATION = (
    StaticString("__error") if CompilationTarget.is_macos() else StaticString(
        "__errno_location"
    )
)
"""The function giving the address of this thread's errno.

`errno` is a macro in C and not a symbol a linker can find. Both platforms
implement it as a call returning a pointer, and they disagree on the name of
that call, which is the whole of the difference.
"""

comptime _STRERROR_R = (
    StaticString(
        "strerror_r"
    ) if CompilationTarget.is_macos() else StaticString("__xpg_strerror_r")
)
"""The message lookup, in its thread safe and standard form.

There are two `strerror_r` functions in the world. The POSIX one writes into a
buffer and returns an int, and glibc's own returns a `char *` and may ignore
the buffer entirely. glibc exports the POSIX one under this name, which is why
the two platforms name different symbols for the same behaviour rather than the
same symbol for two behaviours.

Plain `strerror` would be one name on both and is not safe to call from more
than one thread, which this library cannot promise anything about.
"""

comptime _MESSAGE_MAX = 128
"""How much room the message lookup gets. The longest on either platform is
well under half of this."""


struct Errno(
    Boolable, Copyable, Equatable, ImplicitlyCopyable, Movable, Writable
):
    """The number a failing call left in this thread's errno.

    Compare it against the constants in `abi.mojo`, never against a literal.
    Zero is not a failure and no call sets it to say so, which is why
    `__bool__` reads as "something went wrong" rather than as "there is a
    number here".
    """

    var value: Int
    """The number itself, as the platform reports it."""

    def __init__(out self, value: Int):
        """Hold a number the platform gave us."""
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        """Whether these are the same failure."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether these are different failures."""
        return self.value != other.value

    def __bool__(self) -> Bool:
        """Whether this is a failure at all.

        Zero means the last call did not fail. Nothing sets errno to zero on
        success, so this is only ever asked of a value read after a call that
        already said it failed, or of one built by hand.
        """
        return self.value != 0

    def message(self) -> String:
        """What the platform calls this failure, in its own words.

        The text comes from the C library rather than from a table here, so it
        is the same wording the rest of the system uses and it follows the
        locale. Go carries its own table and its wording differs from the
        platform's in a few places; matching the platform is the more useful of
        the two when the message ends up next to one from another program.
        """
        var room = Array[UInt8, _MESSAGE_MAX](fill=0)
        var failed = external_call[_STRERROR_R, Int32](
            Int32(self.value), Pointer(to=room[0]), Int(_MESSAGE_MAX)
        )
        if failed != 0:
            # The lookup itself failed, which happens for a number no table on
            # this platform has. The number is still the answer, so say it
            # rather than saying nothing.
            return String("errno ", self.value)
        var out = String()
        for i in range(_MESSAGE_MAX):
            if room[i] == 0:
                break
            out += chr(Int(room[i]))
        return out

    def write_to[W: Writer](self, mut writer: W):
        """The platform's message, which is what Go's `Errno.Error` writes."""
        writer.write(self.message())


def errno() -> Errno:
    """The failure this thread's last failing call recorded.

    Only meaningful immediately after a call that reported failure. It is not
    cleared on success, so reading it after a call that worked gives whatever
    the last failure was, possibly from somewhere else entirely. Every call in
    this package reads it at the one moment it means something and hands back
    the result, so callers should not need this.
    """
    var slot = external_call[_ERRNO_LOCATION, Int]()
    return Errno(Int(Pointer[Int32, _Any](unsafe_from_address=slot)[]))


def set_errno(value: Errno):
    """Put a number in this thread's errno.

    Here for the calls that report failure by returning a value that is also a
    legitimate answer. `lseek` returning minus one is the case in this package:
    minus one is a valid file offset, so the only way to tell them apart is to
    clear errno first and look at it afterwards.
    """
    var slot = external_call[_ERRNO_LOCATION, Int]()
    Pointer[Int32, _Any](unsafe_from_address=slot)[] = Int32(value.value)
