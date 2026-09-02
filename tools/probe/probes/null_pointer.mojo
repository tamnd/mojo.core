# PINS: 6. Pointers are non-nullable and carry an origin
# EXPECT: rejected
# ERROR: Pointer is non-nullable
# WHY: A pointer that cannot be null is the reason no foreign signature in this
# WHY: library can forget the null check. The compiler refuses the address
# WHY: zero, so the Optional in the next probe is the only way to say it.


def main():
    var p = Pointer[Int, AnyOrigin[mut=True]](unsafe_from_address=0)
    print(p[])
