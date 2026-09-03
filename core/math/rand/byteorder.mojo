"""Eight bytes in and out of a `UInt64`, both ways round. Go's
`internal/byteorder`.

Go's `math/rand/v2` imports `internal/byteorder` rather than
`encoding/binary`, because the marshalled forms are fixed layouts of known
width and none of the reflection in `encoding/binary` is wanted for that. This
is the same four functions, private for the same reason, and `core.encoding.
binary` when it arrives is not a replacement for them: taking a dependency on
it would put a package this far up the tier list under the generators.

Both orders appear because both are in the marshalled forms. The counters are
big endian so that a marshalled state sorts and compares the way the number
does, and the seed words are little endian because that is the order ChaCha8
reads its key in. Go chose one each way and the bytes on the wire are the
compatibility surface, so neither can be tidied into the other.
"""


def _be_append_uint64(mut dst: List[UInt8], v: UInt64):
    """Append `v` as eight bytes, most significant first."""
    for shift in reversed(range(0, 64, 8)):
        dst.append(UInt8((v >> UInt64(shift)) & 0xFF))


def _be_uint64[o: ImmOrigin](b: Span[UInt8, o]) -> UInt64:
    """The first eight bytes of `b` as a number, most significant first.

    The caller has already checked the length. Every caller here is a decoder
    that rejected a short input before reaching this.
    """
    var v = UInt64(0)
    for i in range(8):
        v = (v << 8) | UInt64(b[i])
    return v


def _le_append_uint64(mut dst: List[UInt8], v: UInt64):
    """Append `v` as eight bytes, least significant first."""
    for shift in range(0, 64, 8):
        dst.append(UInt8((v >> UInt64(shift)) & 0xFF))


def _le_uint64[o: ImmOrigin](b: Span[UInt8, o]) -> UInt64:
    """The first eight bytes of `b` as a number, least significant first."""
    var v = UInt64(0)
    for i in reversed(range(8)):
        v = (v << 8) | UInt64(b[i])
    return v


def _append_str[o: ImmOrigin](mut dst: List[UInt8], s: StringSlice[o]):
    """Append the bytes of `s`. The tags in the marshalled forms are ASCII."""
    for c in s.as_bytes():
        dst.append(c)


def _has_prefix[
    o: ImmOrigin, p: ImmOrigin
](b: Span[UInt8, o], prefix: StringSlice[p]) -> Bool:
    """Whether `b` starts with `prefix`."""
    var want = prefix.as_bytes()
    if len(b) < len(want):
        return False
    for i in range(len(want)):
        if b[i] != want[i]:
            return False
    return True
