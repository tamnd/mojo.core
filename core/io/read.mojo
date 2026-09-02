"""The reading functions. Go's `ReadAtLeast`, `ReadFull`, `ReadAll`.

Every one of these exists because a single `read` is allowed to come back
short. A reader that has one byte ready hands over one byte, and a caller that
wanted eight and treated the result as eight is the most common bug there is in
code written against this interface. So the loop that keeps asking lives here,
written once, instead of in every caller.

The interesting decision is which failure a truncated stream gets.
`read_at_least` raises `EOF` when it read nothing at all and
`ErrUnexpectedEOF` when it read something and then ran out, and that
distinction is the whole reason these are separate sentinels: a decoder reading
records in a loop wants to stop cleanly at a record boundary and complain
loudly anywhere else, and it can only tell those apart if the library does.
"""

from core.errors import Report, matches, partial
from core.errors.codes import (
    EOF,
    ErrNoProgress,
    ErrShortBuffer,
    ErrUnexpectedEOF,
)

from .iface import Byte, Reader, StringWriter, Writer

comptime _CHUNK = 512
"""How much `read_all` asks for at a time, and Go's starting capacity too."""


def read_at_least[
    R: Reader, o: Origin[mut=True]
](mut src: R, into: Span[Byte, o], least: Int) raises -> Int:
    """Read into `into` until at least `least` bytes have arrived.

    Go's `io.ReadAtLeast`. Returns the number of bytes read, which is at least
    `least` and at most `len(into)`, and raises otherwise:

    - `ErrShortBuffer` if `into` is smaller than `least`, before reading
      anything, because that is the caller's mistake and no amount of input
      would have fixed it.
    - `EOF` if the input ended before any byte arrived.
    - `ErrUnexpectedEOF` if some bytes arrived and then the input ended.

    Called `least` and not `min`, which is Go's name for it, because `min` is a
    builtin here and a parameter that shadows one reads badly at the call site.
    """
    if len(into) < least:
        raise (
            Report(
                "io.read_at_least: buffer shorter than the minimum asked for"
            )
            .with_code(ErrShortBuffer)
            .error()
        )
    var n = 0
    while n < least:
        var got: Int
        try:
            got = src.read(into[n:])
        except e:
            if matches(e, EOF):
                if n == 0:
                    raise e
                raise (
                    Report("io.read_at_least: input ended part way through")
                    .with_code(ErrUnexpectedEOF)
                    .with_count(n)
                    .error()
                )
            raise Report("io.read_at_least: reading").wrapping(e).with_count(
                n + partial(e)
            ).error()
        if got == 0:
            # The contract says a read that moved nothing raises, so this
            # cannot happen from a reader that keeps it. From one that does
            # not, the loop would never end, and a hang is the one failure
            # that tells the caller nothing at all.
            raise (
                Report(
                    "io.read_at_least: reader returned no bytes and no error"
                )
                .with_code(ErrNoProgress)
                .with_count(n)
                .error()
            )
        n += got
    return n


def read_full[
    R: Reader, o: Origin[mut=True]
](mut src: R, into: Span[Byte, o]) raises -> Int:
    """Fill `into` exactly. Go's `io.ReadFull`.

    `read_at_least` with the minimum set to the whole span, so it returns
    `len(into)` or raises. An empty span reads nothing and returns zero without
    raising, even at the end of input, which matches `read` itself.
    """
    return read_at_least(src, into, len(into))


def read_all[R: Reader](mut src: R) raises -> List[Byte]:
    """Read until the end of input and return everything. Go's `io.ReadAll`.

    `EOF` is the successful end and is not reraised, exactly as in `copy`. Any
    other failure comes out of this call, and the bytes read before it are
    lost: Go returns them alongside the error and a caller that wants that
    behaviour should use `copy` into a buffer it owns, where the partial result
    is still in its hands.

    There is no size limit here and none in Go. Reading an attacker's stream
    into memory with this is how a program runs out of it; `limit_reader` is
    the answer and the reason it is in this package.
    """
    var out = List[Byte](capacity=_CHUNK)
    var n = 0
    while True:
        while len(out) < n + _CHUNK:
            out.append(0)
        var got: Int
        try:
            got = src.read(Span(out)[n:])
        except e:
            if matches(e, EOF):
                break
            raise Report("io.read_all: reading").wrapping(e).with_count(
                n + partial(e)
            ).error()
        if got == 0:
            raise (
                Report("io.read_all: reader returned no bytes and no error")
                .with_code(ErrNoProgress)
                .with_count(n)
                .error()
            )
        n += got
    while len(out) > n:
        _ = out.pop()
    return out^


def write_string[W: Writer](mut dst: W, s: String) raises -> Int:
    """Write the bytes of `s`. Go's `io.WriteString`.

    Go's version type asserts to `io.StringWriter` first, and the only thing
    that buys is skipping the copy that `[]byte(s)` makes. There is no copy
    here: `String.as_bytes` is a borrow of the bytes the string already holds,
    so the conversion Go is avoiding does not exist and the assertion would
    have nothing to gain. The `StringWriter` trait is still declared, because a
    writer that genuinely wants the string rather than its bytes is a real
    thing and a function can ask for one by name.
    """
    return dst.write(s.as_bytes())
