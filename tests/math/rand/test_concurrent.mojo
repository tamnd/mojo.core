"""Go's `TestConcurrent`, the case `pixi run race` exists for.

The top level functions keep their generator in a per thread slot, and the
whole point of that slot is that two threads drawing at the same time do not
touch the same bytes. Nothing about that shows up in a single threaded run: a
generator shared by every thread produces perfectly good values, right up to
the day two threads advance it at once and one of them reads a half written
state. So this test does what Go's does, which is to run every top level
function from several threads at once and let the thread sanitiser watch.

Go's version asserts nothing at all and exists purely for the detector. Two
things are asserted here on top of that, because a run without the sanitiser
should still be worth something. The first values the threads draw are all
different, which says the slots were seeded separately rather than from one
constant, and each thread got through its whole cycle, which says the slot
survived being created on a thread that is not the main one.

Threads come from libc directly, the way `tools/probe/probes/threads.mojo`
does. There is no concurrency package in this library yet, and when there is
one this test should move onto it.

`perm` is the one top level function the worker does not call, and the reason
is the sanitiser rather than the function. `perm` returns a `List`, the Mojo
runtime serves a `List` out of its own allocator, and the sanitiser does not
intercept that allocator, so it never learns that a block one thread freed is
the same block another thread was later given. A worker that allocates and
frees on a loop therefore reports a race on recycled memory whatever the code
in it does, and a file with nothing in it but a `List` in a thread reproduces
that. Calling `perm` here would mean a permanent false report, which is worse
than the coverage is worth, because `perm` draws through the same `_next` as
everything else below and that path is covered several times over.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true

from core.math.rand import (
    exp_float64,
    float32,
    float64,
    int,
    int32,
    int32_n,
    int64,
    int64_n,
    int_n,
    norm_float64,
    uint32,
    uint64,
)

comptime _Any = AnyOrigin[mut=True]

comptime THREADS = 8
"""How many threads draw at once. Go uses ten; eight is enough to overlap and
keeps the sanitiser build quick."""

comptime CYCLES = 50
"""How many times each thread runs through every function. Go uses ten. More
is cheap here and widens the window a racing pair has to land in."""


struct Slot(Copyable, Movable):
    """One thread's private landing place.

    Each thread is handed a pointer to its own `Slot` and no thread ever looks
    at another's, so the sanitiser has nothing to say about these and anything
    it does report comes from the generator.
    """

    var first: UInt64
    """The first value this thread drew, for the seeding check."""

    var cycles: Int
    """How many cycles it finished, for the survival check."""

    var mixed: UInt64
    """Everything else it drew, folded together so the draws are not dead
    code the optimiser can delete."""

    def __init__(out self):
        """An empty slot."""
        self.first = 0
        self.cycles = 0
        self.mixed = 0


def _worker(arg: OpaquePointer[_Any]) -> OpaquePointer[_Any]:
    """Draw from every top level function, over and over. Go's goroutine body.

    The arithmetic is nonsense on purpose. What matters is that every function
    in the package is called on a thread that is not the main one, since each
    of them reaches the per thread slot and any one of them could be the one
    that reaches it wrongly.
    """
    ref slot = arg.unsafe_bitcast[Slot]()[]
    slot.first = uint64()
    var mixed = slot.first
    for _ in range(CYCLES):
        mixed += UInt64(Int(exp_float64()))
        mixed += UInt64(Int(float32()))
        mixed += UInt64(Int(float64()))
        mixed += UInt64(Int(norm_float64()))
        mixed += UInt64(uint32())
        mixed += UInt64(uint64())
        try:
            mixed += UInt64(int_n(int()))
            mixed += UInt64(Int(int32_n(int32())))
            mixed += UInt64(Int(int64_n(int64())))
        except:
            # The bounded calls raise only on a bound that is not positive,
            # which needs a draw of exactly zero. Leaving the cycle uncounted
            # is what reports it, since the assertion below wants all of them.
            return arg
        slot.cycles += 1
    slot.mixed = mixed
    return arg


def test_concurrent() raises:
    var slots = InlineArray[Slot, THREADS](fill=Slot())
    var ids = InlineArray[UInt64, THREADS](fill=0)
    var started = 0
    for i in range(THREADS):
        var box = Pointer(to=slots[i]).unsafe_bitcast[NoneType]()
        var rc = external_call["pthread_create", Int32](
            Pointer(to=ids[i]), Int(0), _worker, box
        )
        if rc != 0:
            break
        started += 1

    for i in range(started):
        _ = external_call["pthread_join", Int32](ids[i], Int(0))

    assert_equal(started, THREADS, "not every thread started")

    for i in range(THREADS):
        assert_equal(
            slots[i].cycles, CYCLES, "thread " + String(i) + " stopped early"
        )

    # Separately seeded slots, not one constant handed to every thread. Two
    # threads landing on the same first value by chance has probability around
    # 1e-18 across the eight of them.
    for i in range(THREADS):
        for k in range(i + 1, THREADS):
            assert_false(
                slots[i].first == slots[k].first,
                "threads "
                + String(i)
                + " and "
                + String(k)
                + " started from the same value, so they share a seed",
            )
