"""The refcounted type erased heap box.

Three things have to be true for anything to be built on this. The right
destructor runs, it runs exactly once however many copies there were, and the
count survives two threads doing that at the same time.

Counting the destructor takes shared mutable state, which Mojo does not have,
so `Loud` carries the address of an `Int` on the caller's stack and increments
through it as it dies. That is exactly the kind of thing a package under
`core/` may not do and a test may, and it is why the counting is here rather
than in a probe.

The threads are raw pthread through `external_call`, for the reason
`tests/errors/test_value.mojo` gives: `core.sync` does not exist yet and this
cannot wait for it. `pixi run test --race` is what makes the last test mean
anything; without the sanitiser it passes against a plain, non atomic count.
"""

from std.ffi import external_call
from std.memory import Pointer
from std.sys import align_of, size_of
from std.testing import assert_equal, assert_true

from core.runtime.box import ErasedBox, value

comptime Any = AnyOrigin[mut=True]

comptime COPIES = 2000
"""Copy and drop cycles per thread in the race test.

High enough that two threads interleave inside the read modify write of the
count, low enough that the suite does not notice. A count that is not atomic
fails at this number on every run of the sanitiser tried.
"""


struct Loud(Movable):
    """Adds one to an `Int` somewhere else as it dies."""

    var tally: Int
    """The address of that `Int`. Laundered the same way the box launders."""

    def __init__(out self, tally: Int):
        self.tally = tally

    def __deinit__(deinit self):
        ref n = Pointer[Int, Any](unsafe_from_address=self.tally)[]
        n = n + 1


struct Wide(Movable):
    """Bigger than a machine word and nothing like a power of two."""

    var parts: InlineArray[UInt8, 37]

    def __init__(out self, first: UInt8):
        self.parts = InlineArray[UInt8, 37](fill=first)


def test_a_box_gives_back_what_went_in() raises:
    var box = ErasedBox(Int(7))
    assert_equal(box.get[Int](), 7)


def test_a_box_can_be_written_through() raises:
    var box = ErasedBox(Int(1))
    box.get[Int]() = 42
    assert_equal(box.get[Int](), 42)


def test_a_value_bigger_than_a_word_survives() raises:
    var box = ErasedBox(Wide(9))
    assert_equal(box.get[Wide]().parts[0], 9)
    assert_equal(box.get[Wide]().parts[36], 9)
    assert_true(size_of[Wide]() > size_of[Int]())


def _lives_at[T: Deinitable & Movable](ref box: ErasedBox) -> Int:
    """Where the value actually is, rather than where the block starts.

    The offset from one to the other is private and depends on `T`, so asking
    the box for the value and taking the address of what comes back is the only
    way a test can check the alignment of the thing that has to be aligned.
    Checking the block instead passes whatever the offset is, which is a test
    that agrees with any implementation.
    """
    return Int(Pointer(to=box.get[T]()))


def test_a_one_byte_value_is_still_aligned_for_the_count() raises:
    # align_of is one here, and the count in front of the value needs eight,
    # which is the case the offset's floor exists for.
    var box = ErasedBox(UInt8(200))
    assert_equal(align_of[UInt8](), 1)
    assert_equal(box.address % 8, 0)
    assert_equal(_lives_at[UInt8](box) - box.address, 8)
    assert_equal(box.get[UInt8](), 200)


def test_an_over_aligned_value_lands_on_its_alignment() raises:
    # Sixty four byte alignment is more than malloc promises anywhere, so this
    # is the test that says posix_memalign is doing something malloc would not.
    comptime Vector = SIMD[DType.float32, 16]
    assert_equal(align_of[Vector](), 64)

    var box = ErasedBox(Vector(1.5))
    assert_equal(_lives_at[Vector](box) % align_of[Vector](), 0)
    assert_equal(box.get[Vector]()[0], 1.5)
    assert_equal(box.get[Vector]()[15], 1.5)


def _drop[T: Deinitable & Movable](var v: T):
    """Consume a value, so that the drop happens here and not somewhere later.

    Mojo destroys at last use, so a box left in a `var` dies at a point the
    reader has to work out. Handing it to this says where.
    """
    pass


def test_the_destructor_runs_exactly_once() raises:
    var tally = Int(0)
    _drop(ErasedBox(Loud(Int(Pointer(to=tally)))))
    assert_equal(tally, 1)


def test_a_copy_holds_the_destructor_off() raises:
    var tally = Int(0)
    var box = ErasedBox(Loud(Int(Pointer(to=tally))))
    var second = box.copy()

    _drop(box^)
    # Still one reference, so nothing has been destroyed. A count that was
    # dropped rather than shared would have fired here.
    assert_equal(tally, 0)

    _drop(second^)
    assert_equal(tally, 1)


def test_many_copies_destroy_once() raises:
    var tally = Int(0)
    var held = List[ErasedBox]()
    var box = ErasedBox(Loud(Int(Pointer(to=tally))))
    for _ in range(16):
        held.append(box.copy())
    assert_equal(box.count(), 17)

    _drop(box^)
    for _ in range(16):
        _drop(held.pop())
        assert_true(tally <= 1)
    assert_equal(tally, 1)


def test_a_move_does_not_touch_the_count() raises:
    var tally = Int(0)
    var box = ErasedBox(Loud(Int(Pointer(to=tally))))
    assert_equal(box.count(), 1)

    var moved = box^
    assert_equal(moved.count(), 1)
    _drop(moved^)
    assert_equal(tally, 1)


def test_two_boxes_of_the_same_type_are_separate() raises:
    var first = ErasedBox(Int(1))
    var second = ErasedBox(Int(2))
    assert_true(first.address != second.address)
    assert_equal(first.get[Int](), 1)
    assert_equal(second.get[Int](), 2)


def test_the_free_reader_agrees_with_the_method() raises:
    # `value` is what the vtable thunks will use, since they are handed an
    # address rather than a box. It has to answer the same thing.
    var box = ErasedBox(Int(11))
    assert_equal(value[Int](box.address), 11)
    value[Int](box.address) = 12
    assert_equal(box.get[Int](), 12)


struct Shared(Movable):
    """A box two threads copy and drop at the same time."""

    var box: ErasedBox

    def __init__(out self, var box: ErasedBox):
        self.box = box^


def churn(arg: OpaquePointer[Any]) -> OpaquePointer[Any]:
    """Take a reference and drop it again, over and over."""
    ref shared = arg.unsafe_bitcast[Shared]()[]
    for _ in range(COPIES):
        _drop(shared.box.copy())
    return arg


def test_a_box_shared_between_threads_keeps_its_count() raises:
    var tally = Int(0)
    var shared = Shared(ErasedBox(Loud(Int(Pointer(to=tally)))))
    var arg = Pointer(to=shared).unsafe_bitcast[NoneType]()

    var first = UInt64(0)
    var second = UInt64(0)
    assert_equal(
        Int(
            external_call["pthread_create", Int32](
                Pointer(to=first), Int(0), churn, arg
            )
        ),
        0,
    )
    assert_equal(
        Int(
            external_call["pthread_create", Int32](
                Pointer(to=second), Int(0), churn, arg
            )
        ),
        0,
    )
    for _ in range(COPIES):
        _drop(shared.box.copy())
    _ = external_call["pthread_join", Int32](first, Int(0))
    _ = external_call["pthread_join", Int32](second, Int(0))

    # Six thousand increments and six thousand decrements against one original.
    # A non atomic count loses some of them and lands below one, which either
    # destroys the value while this test still holds it or leaks it. Under
    # `pixi run test --race` the same run reports the write itself.
    assert_equal(shared.box.count(), 1)
    assert_equal(tally, 0)

    # The whole struct rather than the field, because a struct valued field
    # cannot be moved out of one. That is design.md section 5 and there is a
    # probe for it.
    _drop(shared^)
    assert_equal(tally, 1)
