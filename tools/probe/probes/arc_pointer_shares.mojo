# PINS: Smaller facts that change how code is written
# EXPECT: runs
# OUTPUT: shared True count 1 lists 1
# WHY: `core.time` needs a `Time` to know its location without copying the
# WHY: location's two lists on every copy of the `Time`, and the paragraph
# WHY: above says there is nowhere in Mojo to put a shared registry. An
# WHY: `ArcPointer` is the answer instead, so the two properties it is relied
# WHY: on for are pinned here: copies share one pointee, and the count is
# WHY: atomic enough that four threads copying and dropping at once end where
# WHY: they started. A non atomic count comes back as something other than one,
# WHY: or frees the pointee early and crashes this probe.

from std.ffi import external_call
from std.memory import ArcPointer

comptime Any = AnyOrigin[mut=True]
comptime THREADS = 4
comptime ROUNDS = 100000


struct Counted(Movable):
    """Records how many of these were ever built, which is the copy count."""

    var built: Int

    def __init__(out self, built: Int):
        self.built = built


struct Shared:
    var arc: ArcPointer[Counted]

    def __init__(out self, var arc: ArcPointer[Counted]):
        self.arc = arc^


def worker(arg: OpaquePointer[Any]) -> OpaquePointer[Any]:
    ref shared = arg.unsafe_bitcast[Shared]()[]
    for _ in range(ROUNDS):
        # One copy and one drop per round, with nothing guarding either, so the
        # count is the only thing keeping the pointee alive.
        var mine = shared.arc
        _ = mine^
    return arg


def main() raises:
    var shared = Shared(ArcPointer(Counted(1)))

    # Two names for one pointee, which is the property a `Time` holding a
    # location depends on: the copy is a count bump and not two lists.
    var second = shared.arc
    var same = Int(Pointer(to=shared.arc[])) == Int(Pointer(to=second[]))
    _ = second^

    var box = Pointer(to=shared).unsafe_bitcast[NoneType]()
    var ids = Array[UInt64, THREADS](fill=0)
    for i in range(THREADS):
        var rc = external_call["pthread_create", Int32](
            Pointer(to=ids[i]), Int(0), worker, box
        )
        if rc != 0:
            raise Error("pthread_create failed")
    for i in range(THREADS):
        _ = external_call["pthread_join", Int32](ids[i], Int(0))

    print(
        "shared",
        same,
        "count",
        shared.arc.count(),
        "lists",
        shared.arc[].built,
    )
