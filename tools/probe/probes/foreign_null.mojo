# PINS: 6. Pointers are non-nullable and carry an origin
# EXPECT: runs
# OUTPUT: unset is none True and path is some True
# WHY: Every foreign function that can return null has Optional in its
# WHY: signature here. getenv is the smallest one that really does return null,
# WHY: so it is the one the probe uses.

from std.ffi import external_call


def lookup(name: StaticString) -> Optional[Int]:
    var address = external_call["getenv", Int](name.unsafe_ptr())
    if address == 0:
        return None
    return address


def main():
    print(
        "unset is none",
        lookup("MOJO_CORE_PROBE_NEVER_SET") is None,
        "and path is some",
        lookup("PATH") is not None,
    )
