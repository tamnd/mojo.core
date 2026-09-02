# PINS: 9. Real OS threads are available through libc
# EXPECT: runs
# OUTPUT: guarded 400000
# WHY: The whole foundation for the concurrency packages, verified rather than
# WHY: assumed. Four threads, a mutex and a condition variable. If the guarded
# WHY: count comes back under four hundred thousand the mutex is not doing
# WHY: anything and sync is built on sand. The atomics that go with this are in
# WHY: the atomics probes, because they come from the language and not libc.

from std.ffi import external_call

comptime Any = AnyOrigin[mut=True]
comptime THREADS = 4
comptime ROUNDS = 100000

# pthread_mutex_t is 40 bytes on Linux and 64 on macOS, and pthread_cond_t is
# 48 on both. This is a probe rather than the real binding, so it takes a
# generous fixed buffer instead of the exact size. The exact sizes are what
# tools/baseline measures.
comptime OPAQUE = 128


struct Shared:
    var mutex: Array[UInt8, OPAQUE]
    var cond: Array[UInt8, OPAQUE]
    var guarded: Int
    var done: Int

    def __init__(out self):
        self.mutex = Array[UInt8, OPAQUE](fill=0)
        self.cond = Array[UInt8, OPAQUE](fill=0)
        self.guarded = 0
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

    print("guarded", shared.guarded)
