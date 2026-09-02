# PINS: 5. Structs cannot hold themselves, and fields cannot expose an unbound origin
# EXPECT: rejected
# ERROR: struct fields do not support trait types
# ERROR: struct fields cannot expose AnyOrigin
# WHY: Both rejections are load bearing. The first is why erasure is hand
# WHY: written, the second is why the erased box keeps its address as an
# WHY: integer and launders it back to a bound origin at the call.


trait Shape:
    def area(self) -> Int:
        ...


struct Holder:
    var shape: Shape
    var address: OpaquePointer[AnyOrigin[mut=True]]


def main():
    print(0)
