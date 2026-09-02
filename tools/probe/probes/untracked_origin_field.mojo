# PINS: 5. Structs cannot hold themselves, and fields cannot expose an unbound origin
# EXPECT: runs
# OUTPUT: through the field 9 and the original is 9
# WHY: The other half of struct_fields, and the reason section 5's sentence is
# WHY: about AnyOrigin and not about origins in general. AnyOrigin in a field is
# WHY: rejected, UntrackedOrigin in a field is accepted, and both of them erase.
# WHY: Without this probe the erased box's integer address looks forced when it
# WHY: is chosen, and somebody would eventually rediscover this and assume the
# WHY: design predates it.


from std.memory import Pointer

comptime Untracked = UntrackedOrigin[mut=True]


struct Holder(Movable):
    # AnyOrigin here is a compile error; see the struct_fields probe. The
    # mutability has to be written out, because the bare name is a generator
    # over it rather than an origin.
    var target: Pointer[Int, Untracked]

    def __init__(out self, target: Pointer[Int, Untracked]):
        self.target = target


def main():
    var value = 7
    var holder = Holder(Pointer(to=value).unsafe_origin_cast[Untracked]())
    holder.target[] = 9
    # The second number is the point. The field really does address the
    # original, so nothing was copied and nothing is being kept alive by the
    # borrow checker.
    print("through the field", holder.target[], "and the original is", value)
