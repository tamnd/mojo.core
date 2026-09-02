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
    return _through(dst, src, Span(buf), "io.copy", Int64(-1))


def copy_buffer[
    W: Writer, R: Reader, o: Origin[mut=True]
](mut dst: W, mut src: R, buf: Span[Byte, o]) raises -> Int64:
    """`copy`, through a buffer the caller owns. Go's `io.CopyBuffer`.

    For a loop that copies many times and does not want an allocation each
    time round. Everything else is `copy`, including both fast paths, which
    means a call that takes one of them never touches `buf` at all. Go says the
    same and it surprises people; it is the right behaviour, because a fast
    path that ignored a buffer it was handed is still faster than one that
    used it.

    An empty `buf` raises rather than allocating one, and Go panics. Handing
    this an empty span is a caller that thinks it has a buffer and does not,
    and silently allocating would hide exactly the allocation it came here to
    avoid.
    """
    if len(buf) == 0:
        raise Report("io.copy_buffer: the buffer is empty").error()
    if src.capabilities() & WRITER_TO != 0:
        return src.write_to(dst)
    if dst.capabilities() & READER_FROM != 0:
        return dst.read_from(src)
    return _through(dst, src, buf, "io.copy_buffer", Int64(-1))


def copy_n[
    W: Writer, R: Reader
](mut dst: W, mut src: R, n: Int64) raises -> Int64:
    """Move exactly `n` bytes from `src` into `dst`. Go's `io.CopyN`.

    Returns `n`, or raises. Ending early is `EOF`, and the count that did move
    is on `errors.partial`, which is how a caller tells a short stream from a
    broken one.

    Neither fast path is taken, and that is a deliberate difference from Go.
    Go gets one by wrapping `src` in a `LimitReader` and calling `Copy`, so a
    destination with `read_from` still gets it; the wrapper here would have to
    hold a borrowed reader in a field, which `erased.mojo` forbids for a
    reason worth more than the fast path. A caller that owns its source can
    have Go's behaviour exactly, by writing `copy(dst, limit_reader(src^, n))`.
    """
    if n <= 0:
        return 0
    var want = BUFFER
    if n < Int64(want):
        want = Int(n)
    var buf = List[Byte](capacity=want)
    for _ in range(want):
        buf.append(0)
    var moved = _through(dst, src, Span(buf), "io.copy_n", n)
    if moved < n:
        raise (
            Report("io.copy_n: input ended before the count was reached")
            .with_code(EOF)
            .with_count(Int(moved))
            .error()
        )
    return moved


def _through[
    W: Writer, R: Reader, o: Origin[mut=True]
](
    mut dst: W, mut src: R, buf: Span[Byte, o], who: String, limit: Int64
) raises -> Int64:
    """The read and write loop the three of them share.

    `limit` is how many bytes to stop after, or a negative number for no limit.
    `who` is the name that goes in front of a failure, because a message
    saying `io.copy` when the caller wrote `copy_n` sends a reader to the wrong
    function.

    Not a fast path in sight: the callers check those before they get here, so
    this is only ever the loop.
    """
    var moved = Int64(0)
    while True:
        if limit >= 0 and moved >= limit:
            return moved
        var want = len(buf)
        if limit >= 0 and limit - moved < Int64(want):
            want = Int(limit - moved)
        var n: Int
        try:
            n = src.read(buf[0:want])
        except e:
            if matches(e, EOF):
                return moved
            raise Report(who + ": reading").wrapping(e).with_count(
                Int(moved) + partial(e)
            ).error()
        if n == 0:
            # A read that moved nothing has to raise, so a zero from a buffer
            # with room in it is a reader breaking its contract. Go tolerates a
            # hundred of these before giving up; there is no reason to loop at
            # all, because the next call has no more reason to return anything
            # than this one did.
            raise (
                Report(who + ": reader returned no bytes and no error")
                .with_code(ErrNoProgress)
                .with_count(Int(moved))
                .error()
            )
        try:
            _ = dst.write(buf[0:n])
        except e:
            raise Report(who + ": writing").wrapping(e).with_count(
                Int(moved) + partial(e)
            ).error()
        moved += Int64(n)
