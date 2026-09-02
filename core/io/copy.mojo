"""`copy`, and the two fast paths it picks between.

Go's `io.Copy` is three lines of type assertion and a loop. This is the same
three decisions asked a different way, because there is nothing to assert on:
the capability bits say what the assertions would have discovered, and
`iface.mojo` explains why that is the mechanism.

The order matters and matches Go. When both sides offer a fast path the
reader's `write_to` wins, because the reader is the one that knows where its
bytes already are and can hand them over without a copy through anybody's
buffer.
"""

from core.errors import Report, matches, partial
from core.errors.codes import EOF, ErrNoProgress

from .iface import Byte, READER_FROM, Reader, WRITER_TO, Writer

comptime BUFFER = 32 * 1024
"""The slow path's buffer, in bytes. Go's `io.Copy` uses the same number.

Big enough that the per call overhead of an erased read is noise against the
work, small enough to sit on the stack of a goroutine, which is where Go's
figure comes from. Nothing here is on a goroutine, but a value with a reason
behind it beats one somebody liked the look of.
"""


def copy[W: Writer, R: Reader](mut dst: W, mut src: R) raises -> Int64:
    """Move everything from `src` into `dst`, and return how many bytes moved.

    Go's `io.Copy`. Ends at `src`'s end of input, which is a normal return and
    not an error: `EOF` is what stops the loop and it is not reraised. Any
    other failure comes out of this call with the count that moved before it on
    `errors.partial`, so a caller that cares can find out how far it got.

    ```mojo
    from core.io import copy, AnyWriter


    def send[R: Reader](mut src: R, var dst: AnyWriter) raises -> Int64:
        return copy(dst, src)
    ```

    Argument order is Go's, destination first, which reads backwards next to
    the sentence above and is worth keeping anyway: every port of a Go program
    gets this right by default, and a library that swapped it would produce a
    call that compiles and does the opposite of what it says.
    """
    # Both paths are one AND against a field. On a static type the field is a
    # constant the optimiser can see through; on an erased one it was copied
    # off the target at construction. Neither is a table lookup.
    if src.capabilities() & WRITER_TO != 0:
        return src.write_to(dst)
    if dst.capabilities() & READER_FROM != 0:
        return dst.read_from(src)

    var buf = List[Byte](capacity=BUFFER)
    for _ in range(BUFFER):
        buf.append(0)

    var moved = Int64(0)
    while True:
        var n: Int
        try:
            n = src.read(Span(buf))
        except e:
            if matches(e, EOF):
                return moved
            raise Report("io.copy: reading").wrapping(e).with_count(
                Int(moved) + partial(e)
            ).error()
        if n == 0:
            # A read that moved nothing has to raise, so a zero from a buffer
            # with room in it is a reader breaking its contract. Go tolerates a
            # hundred of these before giving up; there is no reason to loop at
            # all, because the next call has no more reason to return anything
            # than this one did.
            raise (
                Report("io.copy: reader returned no bytes and no error")
                .with_code(ErrNoProgress)
                .with_count(Int(moved))
                .error()
            )
        try:
            _ = dst.write(Span(buf)[0:n])
        except e:
            raise Report("io.copy: writing").wrapping(e).with_count(
                Int(moved) + partial(e)
            ).error()
        moved += Int64(n)
