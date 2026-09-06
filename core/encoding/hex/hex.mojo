"""Hexadecimal, two characters to the byte. Go's `encoding/hex`.

There is no `Encoding` type here and no alphabet to choose, because hex has one
alphabet and everybody agrees on it. That makes this the shortest of the four
byte codecs and the only one whose length calculations are a multiplication and
a division rather than a rounding rule.

Encoding writes lowercase, which is what Go writes and what a checksum in a log
line or a git object name looks like. Decoding accepts either case, because a
hex string that arrived from somewhere else was written by whoever wrote it.
Those two rules together are why this is a port rather than a wrapper over
Mojo's `std.base64.b16encode`: that one writes uppercase and reads only
uppercase, and it takes a `String` rather than bytes, which rules out the
arbitrary bytes hex exists to spell.
"""

from core.errors import Report, partial
from core.errors.codes import ErrLength
from core.io import Byte

from .invalid import _invalid

comptime _HEXTABLE = "0123456789abcdef"
"""Value to character. Lowercase, the same as Go's."""

comptime _NOT_HEX = Byte(0xFF)
"""What `_unhex` answers for a character that is not a hex digit."""


def _unhex(b: Byte) -> Byte:
    """The value of one hex digit, or `_NOT_HEX` for a byte that is not one.

    Go has a 256 byte table for this and this has three comparisons. The table
    is a cache line and a half of constant data to save a branch that predicts
    perfectly on any real input, which is a trade worth making in Go, where the
    table is in the binary already, and not worth making here, where it would
    have to be built at run time or written out as a literal nobody can read.
    """
    if b >= 0x30 and b <= 0x39:  # `0` to `9`
        return b - 0x30
    if b >= 0x61 and b <= 0x66:  # `a` to `f`
        return b - 0x61 + 10
    if b >= 0x41 and b <= 0x46:  # `A` to `F`
        return b - 0x41 + 10
    return _NOT_HEX


def encoded_len(n: Int) -> Int:
    """How many characters `n` bytes encode to. Go's `EncodedLen`.

    Always `n * 2`, and it cannot fail or round, which is the one thing hex has
    over every other encoding in this directory.
    """
    return n * 2


def encode[
    do: Origin[mut=True], so: Origin
](dst: Span[Byte, do], src: Span[Byte, so]) -> Int:
    """Encode `src` into `dst` and say how many characters that took.

    The caller has to have made room, `encoded_len` says how much. Go's
    `Encode` returns the same count, which is the one place in this directory
    where Go returns a length and the port did not have to add one.
    """
    var table = _HEXTABLE.as_bytes()
    var j = 0
    for i in range(len(src)):
        var v = src[i]
        dst[j] = table[Int(v >> 4)]
        dst[j + 1] = table[Int(v & 0x0F)]
        j += 2
    return len(src) * 2


def append_encode[so: Origin](mut dst: List[Byte], src: Span[Byte, so]) -> Int:
    """Encode `src` onto the end of `dst`, and say how many bytes that took.

    Go's `AppendEncode` returns the grown slice. Growing a `List` in place is
    the same operation without the return, so this hands back the count, which
    is the rule every appending call in this library follows.
    """
    var start = len(dst)
    dst.resize(start + encoded_len(len(src)), 0)
    return encode(Span(dst)[start:], src)


def encode_to_string[so: Origin](src: Span[Byte, so]) -> String:
    """`src` as a hex string. Go's `EncodeToString`.

    Lowercase. The characters are always ASCII, so this is the one conversion
    in the package that cannot meet a byte that is not valid text.
    """
    var out = List[Byte](capacity=encoded_len(len(src)))
    _ = append_encode(out, src)
    return String(from_utf8_lossy=out)


def decoded_len(x: Int) -> Int:
    """How many bytes `x` characters decode to. Go's `DecodedLen`.

    Always `x // 2`, and an odd `x` rounds down, because the half pair at the
    end spells nothing. `decode` refuses that input rather than truncating it;
    this only says how much room the part before it needs.
    """
    return x // 2


def decode[
    do: Origin[mut=True], so: Origin
](dst: Span[Byte, do], src: Span[Byte, so]) raises -> Int:
    """Decode `src` into `dst` and say how many bytes came out.

    Either case of letter is accepted. Nothing is skipped: hex has no padding
    and no line breaks of its own, so a newline in the middle of a string is a
    character that is not a hex digit and is refused like any other.

    Go's `Decode` returns a count and an error together. Here a refusal raises,
    the count is on `errors.partial`, and the bytes counted are already in
    `dst`. Two refusals are possible and they are different codes: a character
    that is not a hex digit raises `ErrInvalidHexByte`, which
    `InvalidByteError.of` reads back, and an odd number of characters raises
    `ErrLength`. A string that is both is reported as the invalid character,
    because that problem comes first in the input.
    """
    var i = 0
    var j = 1
    while j < len(src):
        var p = src[j - 1]
        var q = src[j]
        var a = _unhex(p)
        var b = _unhex(q)
        if a == _NOT_HEX:
            raise _invalid(p, i)
        if b == _NOT_HEX:
            raise _invalid(q, i)
        dst[i] = (a << 4) | b
        i += 1
        j += 2

    if len(src) % 2 == 1:
        # The odd character is checked before the length is reported, since a
        # character that is not a hex digit is the earlier problem of the two
        # and naming the later one would send the caller to the wrong end of
        # the string.
        var last = src[len(src) - 1]
        if _unhex(last) == _NOT_HEX:
            raise _invalid(last, i)
        raise (
            Report("encoding/hex: odd length hex string")
            .with_code(ErrLength)
            .with_count(i)
            .error()
        )
    return i


def append_decode[
    so: Origin
](mut dst: List[Byte], src: Span[Byte, so]) raises -> Int:
    """Decode `src` onto the end of `dst`, and say how many bytes came out.

    Go's `AppendDecode` returns the grown slice and, on a malformed input, the
    partially decoded one alongside the error. Both halves are here: `dst` ends
    up holding exactly what was decoded either way, and the count comes back
    from a good decode and off `errors.partial` from a bad one.
    """
    var start = len(dst)
    dst.resize(start + decoded_len(len(src)), 0)
    try:
        var got = decode(Span(dst)[start:], src)
        dst.resize(start + got, 0)
        return got
    except e:
        dst.resize(start + partial(e), 0)
        raise e


def decode_string(s: StringSlice) raises -> List[Byte]:
    """The bytes `s` spells. Go's `DecodeString`.

    A malformed input raises and the partial decode is lost, which is the one
    place this package gives up something Go returns: the bytes were written
    into a list this call owns and a raise cannot hand it back. `append_decode`
    into a list of the caller's own keeps them, and the same is true of the
    base64 and base32 packages.
    """
    var out = List[Byte](length=decoded_len(s.byte_length()), fill=0)
    var n = decode(Span(out), s.as_bytes())
    out.resize(n, 0)
    return out^
