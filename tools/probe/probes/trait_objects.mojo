# PINS: 1. There are no trait objects
# EXPECT: runs
# OUTPUT: erased call returned 4 10
# WHY: Every erased type in this library is built by hand out of a box holding
# WHY: the value and a table of thin function pointers. If Mojo grows real
# WHY: trait objects, io.Reader and the driver interfaces get a lot smaller.


# A concrete reader. Nothing here knows it is going to be erased.
struct Buf(Copyable, Movable):
    var n: Int

    def __init__(out self):
        self.n = 0

    def read(mut self, size: Int) -> Int:
        self.n += size
        return self.n


# One entry in the table. It takes the box, casts it back and makes the real
# call, which is the work a trait object would have done for us.
def buf_read[
    o: Origin[mut=True]
](this: OpaquePointer[o], size: Int) raises -> Int:
    ref buf = this.unsafe_bitcast[Buf]()[]
    return buf.read(size)


@fieldwise_init
struct AnyReader[o: Origin[mut=True]](Copyable, Movable):
    var this: OpaquePointer[Self.o]
    var read_fn: def(OpaquePointer[Self.o], Int) raises thin -> Int

    def read(self, size: Int) raises -> Int:
        return self.read_fn(self.this, size)


def main() raises:
    var buf = Buf()
    var reader = AnyReader(
        Pointer(to=buf).unsafe_bitcast[NoneType](), buf_read[origin_of(buf)]
    )
    print("erased call returned", reader.read(4), reader.read(6))
