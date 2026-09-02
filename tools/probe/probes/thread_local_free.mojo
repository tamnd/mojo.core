# PINS: 4. There is exactly one error type, and it is a string
# EXPECT: runs
# OUTPUT: freed 7 then joined
# WHY: The error record's slot is a pthread key rather than a plain thread
# WHY: local pointer for exactly one reason: a key has a destructor, so a
# WHY: thread that exits still holding a record frees it instead of leaking one
# WHY: per thread. That destructor is written in Mojo and called by C, which is
# WHY: a direction nothing else in this library goes, so it is pinned here
# WHY: rather than assumed. If it stops working, core.errors leaks a record for
# WHY: every thread that ever raised and nothing else would notice.

from std.ffi import external_call

comptime Any = AnyOrigin[mut=True]


struct Handover:
    """What the worker needs: the key to claim, and something to put in it."""

    var key: UInt64
    var payload: Int

    def __init__(out self):
        self.key = 0
        self.payload = 7


def dispose(value: OpaquePointer[Any]) abi("C"):
    """Called by pthread as a thread unwinds, never by any Mojo code here."""
    # No newline, so that the ordering below is one line the header can state.
    print("freed", value.unsafe_bitcast[Int]()[], end=" ")


def worker(arg: OpaquePointer[Any]) -> OpaquePointer[Any]:
    """Claim the key with a value and exit without clearing it.

    The value is a field of main's `Handover`, which outlives this thread
    because main joins. A pointer into this thread's own stack would be gone by
    the time the destructor read it, which is the mistake this comment exists
    to stop somebody making.
    """
    ref shared = arg.unsafe_bitcast[Handover]()[]
    _ = external_call["pthread_setspecific", Int32](
        shared.key, Pointer(to=shared.payload).unsafe_bitcast[NoneType]()
    )
    return arg


def main() raises:
    var shared = Handover()
    var rc = external_call["pthread_key_create", Int32](
        Pointer(to=shared.key), dispose
    )
    if rc != 0:
        raise Error("pthread_key_create failed")

    var box = Pointer(to=shared).unsafe_bitcast[NoneType]()
    var id = UInt64(0)
    var started = external_call["pthread_create", Int32](
        Pointer(to=id), Int(0), worker, box
    )
    if started != 0:
        raise Error("pthread_create failed")

    # The destructor runs as the worker unwinds, so its line comes out before
    # this one. Ordering is the whole assertion: a destructor that ran at
    # process exit instead would print after the join and leak until then.
    _ = external_call["pthread_join", Int32](id, Int(0))
    print("then joined")
