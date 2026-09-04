# EXPECT: 4
# EXPECT-TEXT: in "%v" argument 1 has a type that can neither write itself nor list its fields
# EXPECT-TEXT: in "%d" argument 1 has a type that can neither write itself nor list its fields
# EXPECT-TEXT: Implement Writable on it, which is Go's Stringer
# EXPECT-TEXT: Arg was given a value of a type that can neither write itself nor list its fields
# EXPECT-OUTPUT: %!v(value)
# EXPECT-OUTPUT: %!d(value)
# EXPECT-OUTPUT: %!s(value)
# EXPECT-OUTPUT: {1 %!v(value)}
#
# The reflection hole, which is the one place this library cannot do what Go
# does. Go prints any value under %v because it can look inside anything at run
# time. There is nothing here that can, so a type that neither writes itself
# nor lists its fields has no text to give, under any verb including %v.
#
# What happens instead is both halves of this file. The call is named while the
# program is built, with the two ways out spelled in the message, and when the
# program runs it writes Go's %!v(value) marker rather than pretending. Note
# there is no `=` in that marker: Go writes the value after the equals sign and
# there is no value to write.
#
# The last complaint is the same hole seen from the runtime path, where a value
# is taken apart at the moment it goes into an Arg. It is the same message with
# a different first clause, because there is no format string to quote.
#
# The struct is here because a field can be opaque too, and one bad field is a
# marker in the middle of an otherwise ordinary walk rather than a walk that
# gives up.

from core.fmt import Arg, Fields, Spec, sprintf, vsprintf, write_field


@fieldwise_init
struct Opaque:
    var n: Int


@fieldwise_init
struct Holds(Fields):
    var n: Int
    var bad: Opaque

    def write_fields(self, mut out: String, spec: Spec) raises:
        out += "{"
        write_field(out, spec, self.n)
        out += " "
        write_field(out, spec, self.bad)
        out += "}"


def main() raises:
    print(sprintf["%v"](Opaque(1)))
    print(sprintf["%d"](Opaque(1)))
    print(sprintf["%s"](Opaque(1)))
    print(sprintf["%v"](Holds(1, Opaque(2))))
    print(vsprintf(String("%v"), [Arg(Opaque(3))]))
