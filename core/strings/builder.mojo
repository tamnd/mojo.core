"""Building a string a piece at a time. Go's `strings.Builder`.

The type exists because `s += piece` in a loop is quadratic: every `+=`
allocates a new string and copies everything written so far, so a thousand
appends of ten bytes copy five megabytes to produce ten kilobytes. A builder
keeps one growing allocation and copies each piece once.

Go's `Builder` carries a pointer to itself and panics if it finds that pointer
somewhere else, which is how it catches being copied after use: a copied
builder would share the backing array with the original and each half would
overwrite the other. That check is a run time one, it costs a comparison on
every write, and it reports the mistake to whoever is unlucky enough to run the
program rather than to whoever wrote it.

Here `Builder` is `Movable` and not `Copyable`, so the same mistake does not
compile. `var b2 = b` is refused and `var b2 = b^` moves, which is what the
caller meant. There is no self pointer, no check, and nothing to pay for it on
the writing path. This is the second time in this library that a Go run time
hazard becomes a compile error — the first is `core.bytes.Buffer` not handing
out views into its own storage — and both rows are in `deviations.md`.

`string()` raises, which Go's does not. A Go string is arbitrary bytes so
Go's builder can hand back whatever was written; a Mojo `String` promises valid
UTF-8, and `write_byte` can put down a lone 0x80 that no string may contain.
Every other way of writing into a builder produces valid text, so the raise is
only reachable through `write_byte` and `write`, and `bytes()` is the accessor
that never refuses. `bytes.Buffer.string()` draws the line in the same place.
"""

from core.errors import Report
from core.io import Byte, ByteWriter, StringWriter, Writer
from core.unicode.utf8 import append_rune


struct Builder(ByteWriter, Movable, StringWriter, Writer):
    """A string under construction. Go's `strings.Builder`.

    ```mojo
    from core.strings import Builder

    var b = Builder()
    _ = b.write_string("hello ")
    _ = b.write_string("world")
    print(b.string())  # => hello world
    ```

    The zero value is ready to use, as in Go: `Builder()` has nothing
    allocated and the first write allocates.
    """

    var _buf: List[Byte]
    """The bytes written so far."""

    def __init__(out self):
        """An empty builder with nothing allocated."""
        self._buf = List[Byte]()

    def len(self) -> Int:
        """How many bytes have been written. Go's `Builder.Len`.

        Bytes, matching Go's `len` on the string this will become, and not
        characters. `count_graphemes` on the finished string is the other
        question and it cannot be answered incrementally.
        """
        return len(self._buf)

    def cap(self) -> Int:
        """How many bytes fit before the storage grows. Go's `Builder.Cap`."""
        return Int(self._buf.capacity())

    def reset(mut self):
        """Throw everything away. Go's `Builder.Reset`.

        Go's drops the allocation as well, because its builder has to forget
        the pointer it uses for its copy check. This keeps the allocation, so
        a builder reused around a loop allocates once rather than once per
        iteration, which is what a caller resetting one is usually after.
        """
        self._buf.clear()

    def grow(mut self, n: Int) raises:
        """Make room for `n` more bytes without growing again. Go's `Grow`.

        Raises on a negative count, which Go panics on. Growing never changes
        what the builder holds, so this is only ever an optimisation, and it is
        worth doing when the final size is known: it turns a run of doubling
        reallocations into one.
        """
        if n < 0:
            raise Report("strings.Builder.grow: negative count").error()
        self._buf.reserve(len(self._buf) + n)

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        """Append `data`. Go's `Builder.Write`.

        Always takes everything and returns `len(data)`, so the short write the
        `Writer` contract talks about cannot happen; the only way to fail is to
        run out of memory. Arbitrary bytes are accepted here and it is
        `string()` that refuses to call them text.
        """
        self._buf.reserve(len(self._buf) + len(data))
        for i in range(len(data)):
            self._buf.append(data[i])
        return len(data)

    def write_string(mut self, s: String) raises -> Int:
        """Append the bytes of `s`. Go's `Builder.WriteString`.

        A `String` lends its bytes without a copy, so this is `write` under
        another name, and the name exists because `io.StringWriter` asks for it
        and because a port looks for it.
        """
        return self.write(s.as_bytes())

    def write_byte(mut self, c: Byte) raises:
        """Append one byte. Go's `Builder.WriteByte`.

        The one way to put something into a builder that is not text. A lone
        0x80 written here is accepted and comes back out of `bytes()`, and it
        is `string()` that raises on it.
        """
        self._buf.append(c)

    def write_rune(mut self, r: Int32) raises -> Int:
        """Append `r` as UTF-8 and return how many bytes that was.

        Go's `Builder.WriteRune`. A rune that is not a code point is written as
        U+FFFD, which is `utf8.append_rune`'s rule and means this cannot fail
        on a bad rune.
        """
        return append_rune(self._buf, r)

    def capabilities(self) -> Int:
        """None of the optional fast paths. A builder only takes bytes."""
        return 0

    def bytes(self) -> List[Byte]:
        """A copy of everything written. Go has no equivalent.

        The accessor that never refuses, for a builder that was fed arbitrary
        bytes through `write_byte`. It is a copy rather than a view for the
        reason `core.bytes.Buffer` gives at length: the next write can
        reallocate, and a view into storage that has moved is freed memory
        here rather than the stale memory it would be in Go.
        """
        return self._buf.copy()

    def string(self) raises -> String:
        """Everything written, as text. Go's `Builder.String`.

        Raises if what was written is not valid UTF-8, which only `write` and
        `write_byte` can arrange. Go returns it anyway, because a Go string is
        bytes; a Mojo `String` is not, and `bytes()` is the version that never
        refuses.

        A copy, so the builder can go on being written to afterwards. Go's
        `String` is a view over the builder's array and is documented as
        invalid after the next write, which is the hazard this library does not
        reproduce anywhere.
        """
        return String(from_utf8=Span(self._buf))
