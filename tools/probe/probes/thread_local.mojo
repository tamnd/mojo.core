# PINS: 4. There is exactly one error type, and it is a string
# EXPECT: runs
# OUTPUT: slots 0123 main 99
# WHY: The whole error mechanism is a record written into thread local storage
# WHY: at raise time, because Mojo's Error carries a string and nothing else.
# WHY: If thread local storage is not really per thread, every error in this
# WHY: library can hand back another thread's fields, which is a silent wrong
# WHY: answer rather than a crash. Mojo has no thread local of its own, so this
# WHY: is pthread_key_create and friends, and this probe is the only statement
# WHY: that they behave.

from std.ffi import external_call

comptime Any = AnyOrigin[mut=True]
comptime THREADS = 4
comptime OPAQUE = 128


struct Shared:
    var mutex: Array[UInt8, OPAQUE]
    var cond: Array[UInt8, OPAQUE]
    # One slot per thread. A worker only ever reaches its own slot through the
    # pointer it put into thread local storage, so a slot holding the wrong
    # number means the storage is shared rather than per thread.
    var slots: Array[Int, THREADS]
    var key: UInt64
    var arrived: Int
    var done: Int

    def __init__(out self):
        self.mutex = Array[UInt8, OPAQUE](fill=0)
        self.cond = Array[UInt8, OPAQUE](fill=0)
        self.slots = Array[Int, THREADS](fill=-1)
        self.key = 0
        self.arrived = 0
        self.done = 0


def worker(arg: OpaquePointer[Any]) -> OpaquePointer[Any]:
    ref shared = arg.unsafe_bitcast[Shared]()[]

    # Claim a slot, then hand its address to thread local storage and never
    # touch it directly again.
    _ = external_call["pthread_mutex_lock", Int32](Pointer(to=shared.mutex))
    var mine = shared.arrived
    shared.arrived += 1
    _ = external_call["pthread_mutex_unlock", Int32](Pointer(to=shared.mutex))

    _ = external_call["pthread_setspecific", Int32](
        shared.key, Pointer(to=shared.slots[mine])
    )

    # Wait until every thread has set its own value before any of them read one
    # back. Without the barrier a shared slot would still look right, because
    # each thread would set and read before the next one arrived.
    _ = external_call["pthread_mutex_lock", Int32](Pointer(to=shared.mutex))
    shared.done += 1
    _ = external_call["pthread_cond_broadcast", Int32](Pointer(to=shared.cond))
    while shared.done < THREADS:
        _ = external_call["pthread_cond_wait", Int32](
            Pointer(to=shared.cond), Pointer(to=shared.mutex)
        )
    _ = external_call["pthread_mutex_unlock", Int32](Pointer(to=shared.mutex))

    # Read the pointer back out and write through it. If the storage is really
    # per thread this lands in this thread's slot and nowhere else.
    var got = external_call["pthread_getspecific", OpaquePointer[Any]](shared.key)
    got.unsafe_bitcast[Int]()[] = mine
    return arg


def main() raises:
    var shared = Shared()
    _ = external_call["pthread_mutex_init", Int32](Pointer(to=shared.mutex), Int(0))
    _ = external_call["pthread_cond_init", Int32](Pointer(to=shared.cond), Int(0))

    # No destructor. The probe is about whether the value is per thread, and a
    # destructor would only run at thread exit, which is after the answer.
    var rc = external_call["pthread_key_create", Int32](
        Pointer(to=shared.key), Int(0)
    )
    if rc != 0:
        raise Error("pthread_key_create failed")

    # The main thread has its own value in the same key, set before any worker
    # runs and read after all of them have finished. That is the case the error
    # mechanism actually depends on: a record on one thread surviving every
    # other thread raising.
    var mine = 99
    _ = external_call["pthread_setspecific", Int32](
        shared.key, Pointer(to=mine)
    )

    var box = Pointer(to=shared).unsafe_bitcast[NoneType]()
    var ids = Array[UInt64, THREADS](fill=0)
    for i in range(THREADS):
        var started = external_call["pthread_create", Int32](
            Pointer(to=ids[i]), Int(0), worker, box
        )
        if started != 0:
            raise Error("pthread_create failed")
    for i in range(THREADS):
        _ = external_call["pthread_join", Int32](ids[i], Int(0))

    var slots = String("")
    for i in range(THREADS):
        slots += String(shared.slots[i])

    var back = external_call["pthread_getspecific", OpaquePointer[Any]](shared.key)
    print("slots", slots, "main", back.unsafe_bitcast[Int]()[])
