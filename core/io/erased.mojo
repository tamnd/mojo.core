"""Readers and writers whose concrete type is gone.

Go's `io.Reader` is one thing that does two jobs. It constrains a generic
function, and it is also a value you can put in a struct field or return from a
constructor. Mojo splits those: `iface.mojo` has the constraint, and this has
the value, built by hand out of an `ErasedBox` and a table of thin function
pointers because design.md section 1 says nothing else is available.

## Views and owners

There are two of each, and the difference is who owns the target.

A `ReaderView` borrows. It is an address and a table, no allocation, and it
does not keep anything alive. It exists because `read_from` is handed a
`mut src` it has no right to take ownership of and must still be able to call
it through a function pointer, which is the one thing a trait bound cannot do:
a vtable slot has a single concrete type, so `def (Int, mut R) thin -> Int64`
is not a type and `R` has to become an address.

An `AnyReader` owns. It boxes the value and holds a view onto what is in the
box, so it is a view plus a refcount and there is exactly one table in the
file rather than two.

**A view is an argument and never a field.** That is the whole rule that keeps
the borrowed half safe, and nothing checks it. A view outliving what it points
at is a use after free, so the two places one is constructed are both inside a
method, both hand it straight to a call, and both are done with it before they
return. If you find yourself wanting to store one, you want an `AnyReader`.

## What the tables cost

An erased call is a load and an indirect call, against a direct call for the
static path, and nothing inlines through it. That is the same trade Go makes
and the reason `iface.mojo` exists at all: code that knows its reader's type
should be generic over it and pay none of this.

Copying an `AnyReader` is an atomic increment, so it is not implicit. Copying a
`ReaderView` is free, because it owns nothing.
"""

from core.runtime.box import ErasedBox, address_of, at, launder, launder_ro

from .iface import Byte, Reader, Writer

comptime _Any = AnyOrigin[mut=True]
"""The origin a span has once it is inside a table. See `box.launder`."""

comptime _Ro = AnyOrigin[mut=False]
"""The same for a span the callee may only read."""


def _read_thunk[T: Reader](target: Int, into: Span[Byte, _Any]) raises -> Int:
    """`T.read`, materialized into something a struct field can hold.

    This is the trick the whole file rests on and it is worth naming: a
    parametric function can be turned into a thin function pointer, so
    `_read_thunk[T]` is a value even though `T.read` is not. Design.md section
    2 for why `raises` survives the crossing.
    """
    return at[T](target).read(into)


def _write_to_thunk[T: Reader](target: Int, dst: Int) raises -> Int64:
    """`T.write_to`, instantiated at `WriterView` so the slot has one type.

    `dst` is the address of a `WriterView` rather than the view itself, and
    that is not a style choice. A slot typed `def (Int, mut WriterView)` on
    `ReaderView`, with the matching one on `WriterView` naming `ReaderView`,
    is a pair of structs that mention each other. Two such structs compile on
    their own; they stop compiling once the slots are filled by thunks like
    this one, and the message is `struct has recursive reference to itself`
    pointed at whichever of the two came second, which is not where the
    problem is. Sending the address instead means neither field type names the
    other and only this function body does.

    This is not in design.md, because a claim there has to come with a probe
    and there is no small program that shows it. Several were tried: two
    traits with mutually referring views, with and without `raises`, with and
    without owner structs holding a view in a field, all compile and run.
    Putting the view types back into the two slots here still fails, so the
    shape is real; it just needs more of this file than a probe should have.
    """
    return at[T](target).write_to(at[WriterView](dst))


def _write_thunk[T: Writer](target: Int, data: Span[Byte, _Ro]) raises -> Int:
    """`T.write`, the same way."""
    return at[T](target).write(data)


def _read_from_thunk[T: Writer](target: Int, src: Int) raises -> Int64:
    """`T.read_from`, instantiated at `ReaderView`. An address, same reason."""
    return at[T](target).read_from(at[ReaderView](src))


struct ReaderView(Copyable, Movable, Reader):
    """A reader somebody else owns, callable without knowing its type.

    An argument, never a field. The module docstring says why, and nothing
    enforces it.
    """

    var target: Int
    """Where the real reader lives. An `Int` because a field cannot hold a
    pointer into memory the borrow checker is not tracking."""

    var _read: def(Int, Span[Byte, _Any]) raises thin -> Int
    var _write_to: def(Int, Int) raises thin -> Int64

    var bits: Int
    """Copied off the target at construction, not asked for again."""

    def __init__[T: Reader](out self, mut target: T):
        """Point at a reader. Borrows it and keeps nothing alive."""
        self.target = address_of(target)
        self._read = _read_thunk[T]
        self._write_to = _write_to_thunk[T]
        self.bits = target.capabilities()

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        """Through the table. `into` loses its origin on the way in."""
        return self._read(self.target, launder(into))

    def capabilities(self) -> Int:
        return self.bits

    def write_to[W: Writer](mut self, mut dst: W) raises -> Int64:
        """Through the table, with `dst` erased to a view so the slot fits.

        The stub the target inherited from the trait is what raises if it
        never implemented this, so an unset bit and a lying bit both end in a
        clear failure rather than a wrong answer.
        """
        var view = WriterView(dst)
        var moved = self._write_to(self.target, address_of(view))
        # The view is dead the moment `address_of` has read it, because Mojo
        # destroys a value after its last use rather than at the end of the
        # scope, and the only use is inside the argument list. Consuming it
        # here is what holds the stack slot down across the call.
        _ = view^
        return moved


struct WriterView(Copyable, Movable, Writer):
    """A writer somebody else owns. `ReaderView`, the other way round."""

    var target: Int
    var _write: def(Int, Span[Byte, _Ro]) raises thin -> Int
    var _read_from: def(Int, Int) raises thin -> Int64
    var bits: Int

    def __init__[T: Writer](out self, mut target: T):
        self.target = address_of(target)
        self._write = _write_thunk[T]
        self._read_from = _read_from_thunk[T]
        self.bits = target.capabilities()

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        return self._write(self.target, launder_ro(data))

    def capabilities(self) -> Int:
        return self.bits

    def read_from[R: Reader](mut self, mut src: R) raises -> Int64:
        var view = ReaderView(src)
        var moved = self._read_from(self.target, address_of(view))
        _ = view^  # `ReaderView.write_to` says why.
        return moved


struct AnyReader(Copyable, Movable, Reader):
    """A reader that owns what it wraps. Go's `io.Reader` as a value.

    This is what a function returning "some reader" returns, and what goes in a
    struct field or a list. Copying it is an atomic increment on the box, so it
    is `Reader(other, copy=...)` rather than an assignment.

    ```mojo
    from core.io import AnyReader, Reader


    def total[R: Reader](mut src: R) raises -> Int:
        var buf = List[UInt8](0, 0, 0, 0, __list_literal__=None)
        var n = 0
        while True:
            try:
                n += src.read(Span(buf))
            except:
                return n
    ```
    """

    var owner: ErasedBox
    """Keeps the value alive. The only thing that remembers its destructor."""

    var view: ReaderView
    """The table, pointed at what is inside the box.

    A view here rather than a second copy of the slots, so there is one table
    in this file. It is a field, which the module docstring says a view must
    never be, and this is the one exception: `owner` is what makes it sound,
    because the box outlives the view by construction and moves with it.
    """

    def __init__[T: Reader & Deinitable & Movable](out self, var target: T):
        """Take ownership of a reader and forget its type."""
        self.owner = ErasedBox(target^)
        self.view = ReaderView(self.owner.get[T]())

    def read[o: Origin[mut=True]](mut self, into: Span[Byte, o]) raises -> Int:
        return self.view.read(into)

    def capabilities(self) -> Int:
        return self.view.capabilities()

    def write_to[W: Writer](mut self, mut dst: W) raises -> Int64:
        return self.view.write_to(dst)

    def count(self) -> Int:
        """How many references share the boxed reader. For tests."""
        return self.owner.count()


struct AnyWriter(Copyable, Movable, Writer):
    """A writer that owns what it wraps. Go's `io.Writer` as a value."""

    var owner: ErasedBox
    var view: WriterView

    def __init__[T: Writer & Deinitable & Movable](out self, var target: T):
        self.owner = ErasedBox(target^)
        self.view = WriterView(self.owner.get[T]())

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        return self.view.write(data)

    def capabilities(self) -> Int:
        return self.view.capabilities()

    def read_from[R: Reader](mut self, mut src: R) raises -> Int64:
        return self.view.read_from(src)

    def get[T: Deinitable & Movable](self) -> ref[_Any] T:
        """The wrapped writer, for a test that wants to read a counter off it.

        `T` is not checked against what went in and cannot be, section 8. This
        is on the writer and not the reader because the counters that prove
        which path `copy` took live on writers.
        """
        return self.owner.get[T]()

    def count(self) -> Int:
        return self.owner.count()
