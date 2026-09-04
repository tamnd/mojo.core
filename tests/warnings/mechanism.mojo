# EXPECT: 2
# EXPECT-TEXT: core: buffer size must be a power of two, not 6
# EXPECT-TEXT: core: buffer size must be a power of two, not 10
# EXPECT-OUTPUT: 6 10 8
#
# The mechanism itself, with no package involved. Every compile time check in
# this library is shaped like this one: compute the fact while the program is
# built, and in the branch where the fact is bad, bind a `comptime` value from
# a function that prints the complaint and gives back an empty string, then
# write that empty string into the result.
#
# Three things are being asserted and each of them has been wrong at some
# point. The complaint fires for a bad instantiation. It does not fire for a
# good one, which is why `ring[8]` is here. And the empty string has to be
# read, because a `comptime` binding nothing reads is never folded and never
# prints, which is why it is appended rather than dropped.
#
# See section 10 of docs/design.md.


def complain(message: String) -> StaticString:
    print(message)
    return ""


def is_power_of_two(n: Int) -> Bool:
    return n > 0 and (n & (n - 1)) == 0


def ring[n: Int]() -> String:
    var out = String()
    comptime if not is_power_of_two(n):
        comptime said = complain(
            String("core: buffer size must be a power of two, not ", n)
        )
        out += said
    out += String(n)
    return out^


def main():
    print(ring[6](), ring[10](), ring[8]())
