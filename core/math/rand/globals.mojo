"""The top level functions, and the per thread generator behind them. Go's
"top-level convenience functions" at the bottom of `rand.go`.

```mojo
from core.math.rand import float64, int_n

print(float64() < 1.0)  # True
```

These need no seeding, no generator to carry around and no lock, and they are
safe to call from any thread at any time. Everything else in the package needs
a `Source` the caller owns and is safe for one thread at a time.

## Where the generator lives

Go puts a `ChaCha8` in the runtime, one per operating system thread, seeded
from the operating system's entropy the first time it is asked. That is the
right design and it is the one here, with the difference that Mojo has no
global mutable state at all: a module level `var` is refused by the compiler
and `tools/probe/probes/no_globals.mojo` pins that it stays refused.

So the generator lives in a pthread key, in `core/errors/shim/slot.c`, which is
the same C file the error record uses and is the reason this package depends on
`core.errors`. That file's README says what the slot is and why there is C in a
Mojo library at all. This is the second and, as it says there, expected to be
the last user of it.

The consequences are worth stating plainly.

**This package is `unsafe`.** Three things in this file have no safe spelling:
the calls into the shim, the `malloc` that gives the generator somewhere to
live, and the `getentropy` that seeds it. Nothing else in the package is
touched by that, and a program that only uses `Rand`, `PCG`, `ChaCha8` and
`Zipf` never reaches this file.

**The values differ between threads, runs and processes.** That is the point
of them, and it is also why nothing here is reproducible. A test that needs the
same numbers twice uses `new_pcg` or `new_chacha8` with a seed it chose.

**A thread that exits gives its generator back.** The pthread key destructor
frees it, except on the main thread, where pthread does not run destructors for
the thread that calls exit. One generator per process outlives the process by
a few microseconds.
"""

from std.ffi import external_call
from std.sys import size_of

from core.errors import Report
from core.errors.codes import ErrInvalidArgument

from .chacha8 import ChaCha8
from .rand import Rand
from .source import Source

comptime _Any = AnyOrigin[mut=True]


def _seeded() -> ChaCha8:
    """A `ChaCha8` seeded from the operating system.

    `getentropy` rather than reading `/dev/urandom`, because it needs no file
    descriptor, cannot fail because the process is out of them, and exists on
    macOS and on Linux with either libc. POSIX guarantees it for any buffer up
    to 256 bytes and this asks for 32, so the failure branch below is not
    reachable on any platform this library supports.

    If it is ever reached anyway, the seed comes from the address of the buffer
    stirred with a multiplier. Address space layout randomisation makes that
    different in every process, so the values still differ between runs; they
    would no longer be unpredictable to somebody who can see the address, which
    is a property this package does not promise in the first place. See the
    package docstring: this is not for anything that has to be unguessable.
    """
    var seed = InlineArray[UInt8, 32](fill=0)
    if external_call["getentropy", Int32](seed.unsafe_ptr(), 32) != 0:
        var mark = UInt64(Int(seed.unsafe_ptr()))
        for word in range(4):
            mark = mark * 0x9E3779B97F4A7C15 + 1
            for k in range(8):
                seed[word * 8 + k] = UInt8((mark >> UInt64(8 * k)) & 0xFF)
    return ChaCha8(seed)


def _free(raw: OpaquePointer[_Any]) abi("C"):
    """Release a generator when its thread exits. Called by the C shim only.

    Handed to the shim on every set rather than exported for it to find, for
    the reason `core/errors/record.mojo` gives: a function that only C calls is
    a function nothing in Mojo calls, and a dead code pass removes exactly
    that. pthread never passes a null here, so there is no null case.
    """
    var held = raw.unsafe_bitcast[ChaCha8]()
    held.unsafe_deinit_pointee()
    external_call["free", NoneType](raw)


def _next() -> UInt64:
    """One value from this thread's generator, making it if there is not one.

    The address comes back as an `Int` rather than a pointer because a
    `Pointer` is non-nullable and an empty slot is precisely the null case,
    which is design.md section 6.

    Two things can go wrong and both degrade rather than fail. `malloc` can
    return nothing, and the slot can fail to exist at all, which happens only
    if the process has run out of pthread keys. In either case the generator
    made for this call is used for this call and thrown away, which costs a
    block computation per call and is still random.
    """
    var address = external_call["core_rand_slot_get", Int]()
    if address != 0:
        return Pointer[ChaCha8, _Any](unsafe_from_address=address)[].uint64()

    var fresh = _seeded()
    var value = fresh.uint64()

    var block = external_call["malloc", Int](size_of[ChaCha8]())
    if block == 0:
        return value
    Pointer[ChaCha8, _Any](unsafe_from_address=block).unsafe_write(fresh^)
    external_call["core_rand_slot_set", NoneType](block, _free)
    if external_call["core_rand_slot_get", Int]() == 0:
        # The slot could not be created, so nothing was stored and nothing ever
        # will be. Give the block back rather than leak one on every call.
        # Through `_free` rather than a second `free` call, so that the one
        # `external_call` naming `free` in this library is the one C also uses
        # and the two cannot disagree about what a `free` takes.
        _free(OpaquePointer[_Any](unsafe_from_address=block))
    return value


struct _Global(Copyable, Movable, Source):
    """This thread's generator, as a `Source`.

    Holds nothing. It exists so that the top level functions are the `Rand`
    methods rather than a second copy of them: every function below builds one
    of these, wraps it in a `Rand`, and asks. Both structs are empty of
    anything the optimiser cannot see through, so that costs nothing at run
    time and saves nineteen reimplementations of arithmetic that has to match
    Go exactly.
    """

    def __init__(out self):
        """Nothing to set up. The generator is found on first use."""
        pass

    def uint64(mut self) -> UInt64:
        """One value from this thread's generator."""
        return _next()


def _global() -> Rand[_Global]:
    """This thread's generator, wrapped so the `Rand` methods can be used."""
    return Rand(_Global())


def uint64() -> UInt64:
    """A value uniform over the whole range of `UInt64`, from the default
    source."""
    var r = _global()
    return r.uint64()


def int64() -> Int64:
    """A non negative 63 bit value, from the default source."""
    var r = _global()
    return r.int64()


def uint32() -> UInt32:
    """A value uniform over the whole range of `UInt32`, from the default
    source."""
    var r = _global()
    return r.uint32()


def int32() -> Int32:
    """A non negative 31 bit value, from the default source."""
    var r = _global()
    return r.int32()


def int() -> Int:
    """A non negative value, from the default source."""
    var r = _global()
    return r.int()


def uint() -> UInt:
    """A value uniform over the whole range of `UInt`, from the default source.
    """
    var r = _global()
    return r.uint()


def uint64_n(n: UInt64) raises -> UInt64:
    """A value in `[0, n)`, from the default source."""
    var r = _global()
    return r.uint64_n(n)


def int64_n(n: Int64) raises -> Int64:
    """A value in `[0, n)`, from the default source."""
    var r = _global()
    return r.int64_n(n)


def uint32_n(n: UInt32) raises -> UInt32:
    """A value in `[0, n)`, from the default source."""
    var r = _global()
    return r.uint32_n(n)


def int32_n(n: Int32) raises -> Int32:
    """A value in `[0, n)`, from the default source."""
    var r = _global()
    return r.int32_n(n)


def int_n(n: Int) raises -> Int:
    """A value in `[0, n)`, from the default source."""
    var r = _global()
    return r.int_n(n)


def uint_n(n: UInt) raises -> UInt:
    """A value in `[0, n)`, from the default source."""
    var r = _global()
    return r.uint_n(n)


def float64() -> Float64:
    """A value in `[0.0, 1.0)`, from the default source."""
    var r = _global()
    return r.float64()


def float32() -> Float32:
    """A value in `[0.0, 1.0)`, from the default source."""
    var r = _global()
    return r.float32()


def norm_float64() -> Float64:
    """A standard normal value, from the default source."""
    var r = _global()
    return r.norm_float64()


def exp_float64() -> Float64:
    """An exponential value with rate 1, from the default source."""
    var r = _global()
    return r.exp_float64()


def perm(count: Int) raises -> List[Int]:
    """A random permutation of `0` through `count - 1`, from the default
    source."""
    var r = _global()
    return r.perm(count)


def shuffle[swap: def(Int, Int) capturing[_] -> None](count: Int) raises:
    """Put `count` things in a random order, using the default source."""
    var r = _global()
    r.shuffle[swap](count)


def n[dt: DType, //](limit: SIMD[dt, 1]) raises -> SIMD[dt, 1]:
    """A value in `[0, limit)` of the same integer type. Go's `rand.N`.

    ```mojo
    from core.math.rand import n

    print(n(Int32(10)) < 10)  # True
    ```

    Go's version is generic over every integer type, so that `rand.N` of a
    named integer type comes back as that type rather than as an `int`. This is
    generic over `DType` instead, which reaches the ten fixed width integer
    types. `Int` and `UInt` are not `SIMD` and get the overload below.

    Raises `ErrInvalidArgument` unless `limit` is positive, and also on a
    floating point or boolean `dt`, which Go rules out at compile time with a
    type constraint on the type parameter. There is no way to say that about a
    `DType`, so the `comptime if` below folds away for the ten types this is
    for and leaves a function that only raises for the rest.
    """

    comptime if not dt.is_integral():
        raise (
            Report("rand: n needs an integer type")
            .with_code(ErrInvalidArgument)
            .error()
        )

    if limit <= 0:
        raise (
            Report("rand: invalid argument to n")
            .with_code(ErrInvalidArgument)
            .error()
        )
    return uint64_n(limit.cast[DType.uint64]()).cast[dt]()


def n(limit: Int) raises -> Int:
    """A value in `[0, limit)`. The `Int` case of `n`."""
    return int_n(limit)


def n(limit: UInt) raises -> UInt:
    """A value in `[0, limit)`. The `UInt` case of `n`."""
    return uint_n(limit)
