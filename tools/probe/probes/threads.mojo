# PINS: 9. Real OS threads are available through libc
# EXPECT: runs
# OUTPUT: guarded 400000 atomic 400000 and the cas took True
# WHY: The whole foundation for the concurrency packages, verified rather than
# WHY: assumed. Four threads, a mutex, a condition variable, an atomic add and
# WHY: a compare and swap. If the guarded count comes back under four hundred
# WHY: thousand the mutex is not doing anything and sync is built on sand.

from std.ffi import external_call

comptime Any = AnyOrigin[mut=True]
comptime THREADS = 4
comptime ROUNDS = 100000

# pthread_mutex_t is 40 bytes on Linux and 64 on macOS, and pthread_cond_t is
# 48 on both. This is a probe rather than the real binding, so it takes a
# generous fixed buffer instead of the exact size. The exact sizes are what
# tools/baseline measures.
comptime OPAQUE = 128

# __ATOMIC_SEQ_CST. The atomics go through libc rather than through the
# standard library's Atomic, because libc is what section 9 claims and because
# the standard library spelling has already changed once between releases.
comptime SEQ_CST = Int32(5)


struct Shared:
    var mutex: Array[UInt8, OPAQUE]
    var cond: Array[UInt8, OPAQUE]
    var guarded: Int
    var total: Int64
    var done: Int

    def __init__(out self):
        self.mutex = Array[UInt8, OPAQUE](fill=0)
        self.cond = Array[UInt8, OPAQUE](fill=0)
        self.guarded = 0
        self.total = 0
        self.done = 0


def worker(arg: OpaquePointer[Any]) -> OpaquePointer[Any]:
    ref shared = arg.unsafe_bitcast[Shared]()[]
    for _ in range(ROUNDS):
        # The guarded counter is a plain Int, so it only lands on the right
        # number if the mutex is real.
        _ = external_call["pthread_mutex_lock", Int32](Pointer(to=shared.mutex))
        shared.guarded += 1
        _ = external_call["pthread_mutex_unlock", Int32](
            Pointer(to=shared.mutex)
        )
        _ = external_call["__atomic_fetch_add_8", Int64](
            Pointer(to=shared.total), Int64(1), SEQ_CST
        )
    _ = external_call["pthread_mutex_lock", Int32](Pointer(to=shared.mutex))
    shared.done += 1
    _ = external_call["pthread_cond_signal", Int32](Pointer(to=shared.cond))
    _ = external_call["pthread_mutex_unlock", Int32](Pointer(to=shared.mutex))
    return arg


def main() raises:
    var shared = Shared()
    _ = external_call["pthread_mutex_init", Int32](
        Pointer(to=shared.mutex), Int(0)
    )
    _ = external_call["pthread_cond_init", Int32](
        Pointer(to=shared.cond), Int(0)
    )

    # The pointer crosses a thread boundary, which the borrow checker cannot
    # follow, so it goes over as an opaque box and comes back with a bound
    # origin inside the worker.
    var box = Pointer(to=shared).unsafe_bitcast[NoneType]()
    var ids = Array[UInt64, THREADS](fill=0)
    for i in range(THREADS):
        var rc = external_call["pthread_create", Int32](
            Pointer(to=ids[i]), Int(0), worker, box
        )
        if rc != 0:
            raise Error("pthread_create failed")

    # Wait on the condition variable rather than on the joins, so that the
    # condition variable is part of what this probe proves.
    _ = external_call["pthread_mutex_lock", Int32](Pointer(to=shared.mutex))
    while shared.done < THREADS:
        _ = external_call["pthread_cond_wait", Int32](
            Pointer(to=shared.cond), Pointer(to=shared.mutex)
        )
    _ = external_call["pthread_mutex_unlock", Int32](Pointer(to=shared.mutex))

    for i in range(THREADS):
        _ = external_call["pthread_join", Int32](ids[i], Int(0))

    var counted = shared.total
    var swapped = external_call["__atomic_compare_exchange_8", Bool](
        Pointer(to=shared.total),
        Pointer(to=counted),
        Int64(0),
        False,
        SEQ_CST,
        SEQ_CST,
    )
    print(
        "guarded",
        shared.guarded,
        "atomic",
        counted,
        "and the cas took",
        swapped,
    )
