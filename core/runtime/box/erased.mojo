"""A refcounted heap box holding a value whose type has been forgotten.

There are no trait objects in Mojo. A trait is a compile time constraint, not a
value, so `List[Reader]` does not exist and a struct field cannot have a trait
type. Design.md section 1 is the whole story: anywhere Go stores something
behind an interface, this library builds an erased struct by hand out of two
pieces, and this is the first of them. The second is a table of thin function
pointers, which is #12.

```mojo
from core.runtime.box import ErasedBox


struct File(Copyable, Movable):
    var fd: Int

    def __init__(out self, fd: Int):
        self.fd = fd


def main():
    var box = ErasedBox(File(3))
    print(box.get[File]().fd)
```

The value goes on the heap, the type goes away, and a function pointer stays
behind so that the right destructor runs when the last reference goes. Nothing
here knows what `T` was; the only thing that remembers is the `get[T]` at the
other end and the destructor captured at construction.

## Why the address is an integer

A struct field cannot carry `AnyOrigin`, so a field cannot hold a `Pointer` into
memory the borrow checker is not tracking. It could hold one with
`UntrackedOrigin`, which design.md section 5 and the `untracked_origin_field`
probe now record, so this is a choice rather than the only option: the box has
forgotten its pointee type as well as its origin, and a pointer field would have
to name a placeholder `T` and reinterpret at every use, which is a second
erasure on top of the real one. An integer has no pointee type to lie about.

Either way the laundering is confined here and is not visible above here. `get`
hands back a `ref`, so a caller reads the value without naming a pointer and
without having to declare itself unsafe. That is the entire reason this is its
own package rather than forty lines inside `core.io`.

## Why it is not implicitly copyable

Copying is an atomic increment. Go's interface copy is free and this one is
not, so the copy is spelled out at the call site rather than happening where
nobody can see it. `errors.ErrorValue` made the same call for the same reason.

## What is not checked

Nothing verifies that the `T` handed to `get` is the `T` that went in. There is
no reflection in this language, section 8, so there cannot be. What makes it
safe in practice is that the box and the vtable that reads it are built by the
same constructor, so the pairing is a local fact rather than something a caller
can get wrong from a distance.
"""

from std.atomic import Atomic
from std.ffi import external_call
from std.memory import Pointer
from std.os import abort
from std.sys import align_of, size_of

comptime _Any = AnyOrigin[mut=True]
"""The untracked origin every address here is laundered through.

Design.md sections 5 and 6. The borrow checker cannot follow a value across a
heap block it did not allocate, so the origin it gets back is unbound and
mutable, and the safety argument is the one in this module's docstring rather
than anything the compiler can check.
"""

comptime _Ro = AnyOrigin[mut=False]
"""The same, for a span a callee is only allowed to read from."""


def _offset[T: AnyType]() -> Int:
    """Where the value starts, which is also the block's alignment.

    The count is an `Int64` at offset zero and the value follows it, so the
    offset has to clear eight bytes and satisfy `T`. It floors at eight rather
    than at `align_of[Int64]()` because `posix_memalign` refuses an alignment
    that is not a multiple of `sizeof(void*)`, and a `T` wanting one or two
    byte alignment would otherwise produce one.

    Not stored on the box. `get[T]` knows `T` and recomputes it, and a caller
    who has the wrong `T` has already lost by more than an offset.
    """
    return align_of[T]() if align_of[T]() > 8 else 8


def value[T: Deinitable & Movable](address: Int) -> ref[_Any] T:
    """The value inside a block, given the block's address.

    For the vtable thunks in #12, which are handed an address rather than a
    box. Same laundering as `ErasedBox.get`, and the same unchecked `T`.
    """
    return Pointer[T, _Any](unsafe_from_address=address + _offset[T]())[]


def address_of[T: AnyType, o: Origin](ref[o] target: T) -> Int:
    """The address of something the caller already owns.

    For an erased view: a vtable that borrows rather than boxes needs the
    address of a value on somebody else's stack, and the thunk on the other end
    takes an `Int` for the reason section 5 gives. `io.copy`'s fast path is the
    case that needs it, because `read_from` is handed a `mut src` it cannot take
    ownership of and must still be able to call through a function pointer.

    Nothing keeps the value alive. A view built from this outliving what it
    points at is a use after free, and the rule that prevents it is that a view
    is an argument and never a field. See `core.io`.
    """
    return Int(Pointer(to=target))


def at[T: AnyType](address: Int) -> ref[_Any] T:
    """The value at an address, as a reference.

    The counterpart to `address_of`, and the unchecked half: nothing verifies
    that `T` is what is there. `value` is the one to use for a box, since a box
    has a count in front of its value and this does not.
    """
    return Pointer[T, _Any](unsafe_from_address=address)[]


def launder[T: AnyType, o: Origin[mut=True]](span: Span[T, o]) -> Span[T, _Any]:
    """A mutable span with its origin forgotten, for passing through a vtable.

    A vtable slot is a struct field, so it has one concrete type and cannot be
    parametric over the caller's origin: `def (Int, Span[T, o]) thin -> Int` is
    not a type that exists. The slot pins the origin to `_Any` and the erased
    struct's method laundens the caller's span into it on the way in. Without
    this the call is rejected outright, because there is no implicit rebind
    between origins:

    ```
    error: invalid indirect call: value cannot be converted from
           'Span[UInt8, o]' to 'Span[UInt8, Any]'
    ```

    What makes it safe is that the laundered span never outlives the call. It is
    an argument to the thunk, the thunk hands it to a `read` or a `write`, and
    both of those are done with it before they return. An implementation that
    stored it would be keeping a pointer into a buffer nobody is tracking any
    more, and nothing here can stop that; it is the same unchecked pairing the
    module docstring describes, in the one direction the borrow checker cannot
    follow.

    ```mojo
    from core.runtime.box import launder

    def main():
        var buf = List[UInt8](1, 2, 3, __list_literal__=None)
        print(len(launder(Span(buf))))
    ```
    """
    return Span[T, _Any](
        unsafe_ptr=span.unsafe_ptr().as_unsafe_any_origin(), length=len(span)
    )


def launder_ro[T: AnyType, o: Origin](span: Span[T, o]) -> Span[T, _Ro]:
    """The same, for a span nothing is going to write through.

    Takes an origin of either mutability and gives back an immutable one, which
    is what a `write` wants: the writer is not allowed to modify the caller's
    buffer, and a caller holding a mutable span should not have to give up that
    guarantee to call one.
    """
    return Span[T, _Ro](
        unsafe_ptr=span.unsafe_ptr().as_unsafe_any_origin(), length=len(span)
    )


def _release[T: Deinitable & Movable](address: Int):
    """Destroy the value in a block and free the block.

    One of these is materialized per erased type and stored on the box as a
    thin function pointer, which is what lets a box that has forgotten `T` still
    run `T`'s destructor. Design.md section 2 is what makes a function pointer
    a storable value at all; this is that fact used for something other than a
    vtable.
    """
    Pointer[T, _Any](
        unsafe_from_address=address + _offset[T]()
    ).unsafe_deinit_pointee()
    # A pointer rather than the integer sitting right there, because
    # `core.errors` already declares `free` taking one and two packages in the
    # same binary declaring the same foreign symbol with different argument
    # types is a link that fails. Nothing warns; it only shows up when both
    # packages end up in one build, which is every build of the test suite.
    external_call["free", NoneType](
        Pointer[Int64, _Any](unsafe_from_address=address).unsafe_bitcast[
            NoneType
        ]()
    )


struct ErasedBox(Copyable, Movable):
    """A value of a forgotten type, on the heap, with a shared count.

    Copyable, because the point of an erased value is to be stored, and a
    reader that cannot go in a list twice is not much of a reader. Not
    implicitly copyable, because the copy is an atomic increment.
    """

    var address: Int
    """The block. An `Int` for the reason the module docstring gives.

    Layout, where `offset` is `max(8, align_of[T]())`:

    ```
      0        offset                    offset + size_of[T]()
      +--------+-------------------------+
      | Int64  |            T            |
      +--------+-------------------------+
    ```

    One allocation rather than two. Erasure sits on the read path of every
    buffered reader in this library and two allocations per box is a cost that
    shows up.
    """

    var drop: def(Int) thin -> None
    """`_release[T]` for the `T` that went in, and the only trace of it left."""

    def __init__[T: Deinitable & Movable](out self, var v: T):
        """Move a value onto the heap and start its count at one."""
        var slot = Int(0)
        var size = _offset[T]() + size_of[T]()
        # posix_memalign rather than malloc, which promises sixteen bytes and
        # would be wrong for a SIMD type wanting thirty two or sixty four.
        var rc = external_call["posix_memalign", Int32](
            Pointer(to=slot), _offset[T](), size
        )
        if rc != 0 or slot == 0:
            # The allocator is out of memory or was handed a bad alignment.
            # Neither is recoverable here and neither can be reported, since a
            # constructor that raises would put a `try` around every erasure in
            # the library.
            abort("core.runtime.box: allocation of " + String(size) + " failed")
        Pointer[Int64, _Any](unsafe_from_address=slot).unsafe_write(Int64(1))
        Pointer[T, _Any](unsafe_from_address=slot + _offset[T]()).unsafe_write(
            v^
        )
        self.address = slot
        self.drop = _release[T]

    def __init__(out self, *, copy: Self):
        """Share the value and take a reference to it."""
        _ = Atomic.fetch_add(
            Pointer[Int64, _Any](unsafe_from_address=copy.address), Int64(1)
        )
        self.address = copy.address
        self.drop = copy.drop

    def __init__(out self, *, deinit move: Self):
        """Hand the reference over. The count does not change."""
        self.address = move.address
        self.drop = move.drop

    def __deinit__(deinit self):
        """Drop a reference, and destroy the value if it was the last one."""
        # fetch_add of minus one rather than fetch_sub, because the pointer
        # taking overload of fetch_sub does not exist and only the method form
        # does, and there is no Atomic struct anywhere in this design to call
        # a method on. The ordering is sequentially consistent, which is the
        # default and is stronger than this needs.
        var before = Atomic.fetch_add(
            Pointer[Int64, _Any](unsafe_from_address=self.address), Int64(-1)
        )
        if before == 1:
            self.drop(self.address)

    def get[T: Deinitable & Movable](self) -> ref[_Any] T:
        """The value, as a reference rather than a pointer.

        A `ref` so that reading an erased value does not oblige the reader to
        name `Pointer` and therefore to declare itself unsafe. `T` is not
        checked against what went in and cannot be.

        ```mojo
        from core.runtime.box import ErasedBox

        def main():
            var box = ErasedBox(Int(7))
            print(box.get[Int]())
        ```
        """
        return value[T](self.address)

    def count(self) -> Int:
        """How many references share this value. For tests and for nothing else.

        A number that another thread can change between the read and the next
        line, so it answers a question about the past. It is here because a
        refcount that is never observed is a refcount nobody can prove correct.
        """
        return Int(
            Atomic.load(Pointer[Int64, _Any](unsafe_from_address=self.address))
        )
