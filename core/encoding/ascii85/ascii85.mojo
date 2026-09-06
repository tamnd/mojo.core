"""Four bytes to five characters, base 85. Go's `encoding/ascii85`.

Base 85 is the densest encoding that stays inside printable ASCII: 85 to the
fifth is just over 256 to the fourth, so five characters carry four bytes with
a little room to spare, where base64 needs six characters for three bytes and
base32 needs eight for five. That is why PostScript and PDF use it for embedded
binary and why the `btoa` tool used it before them.

The alphabet is every character from `!` to `u`, in value order, with one
special case: four zero bytes are written as a single `z`, because a run of
zeros is the one pattern that turns up often enough in binary to be worth a
rule of its own. The decoder skips space and control characters, so a document
wrapped at any width reads back.

Ascii85 in the wild is usually fenced with `<~` and `~>`. Neither of those is
written or read here, the same as in Go, because the fence belongs to the
format the encoding is embedded in rather than to the encoding.
"""

from core.io import Byte

from .corrupt import _corrupt

comptime _FIRST = Byte(ord("!"))
"""The first symbol, which stands for zero."""

comptime _LAST = Byte(ord("u"))
"""The last symbol, which stands for eighty four."""

comptime _ZERO = Byte(ord("z"))
"""The shorthand for four zero bytes."""

comptime _SPACE = Byte(ord(" "))
"""Everything at or below this is skipped by the decoder."""


def max_encoded_len(n: Int) -> Int:
    """The most characters `n` bytes can encode to. Go's `MaxEncodedLen`.

    The most rather than the exact number, which is what makes this the odd one
    out in this directory. Four zero bytes shorten to one character, so the
    real length depends on the data, and a caller sizing a buffer has to take
    the worst case.
    """
    return (n + 3) // 4 * 5


def encode[
    do: Origin[mut=True], so: Origin
](dst: Span[Byte, do], src: Span[Byte, so]) -> Int:
    """Encode `src` into `dst` and say how many characters that took.

    The caller has to have made room, `max_encoded_len` says how much.

    This encodes `src` as a whole document: the last group is written short if
    the input does not divide by four, so a caller feeding it one block of a
    larger stream at a time would end each block as though it were the end of
    everything. `new_encoder` is what a stream wants, and Go's documentation
    says the same in the same place.
    """
    if len(src) == 0:
        return 0

    var n = 0
    var si = 0
    while si < len(src):
        var left = len(src) - si

        # Four bytes into one number, most significant first. A short group
        # leaves the low bytes zero, which is what the padding rule wants.
        var v = UInt32(0)
        if left >= 4:
            v |= UInt32(src[si + 3])
        if left >= 3:
            v |= UInt32(src[si + 2]) << 8
        if left >= 2:
            v |= UInt32(src[si + 1]) << 16
        v |= UInt32(src[si]) << 24

        if v == 0 and left >= 4:
            dst[n] = _ZERO
            n += 1
            si += 4
            continue

        # Five digits, written from the back, since each division takes the
        # lowest one off.
        var rest = v
        for i in range(4, -1, -1):
            dst[n + i] = _FIRST + Byte(rest % 85)
            rest //= 85

        # A short group keeps one character more than it had bytes, and the
        # ones below that are dropped. Five digits were written either way,
        # which is why the caller's room is `max_encoded_len` and not less.
        var kept = 5
        if left < 4:
            kept -= 4 - left
            si = len(src)
        else:
            si += 4
        n += kept
    return n


def decode[
    do: Origin[mut=True], so: Origin
](dst: Span[Byte, do], src: Span[Byte, so], flush: Bool) raises -> Tuple[
    Int, Int
]:
    """Decode `src` into `dst`. Go's `Decode`.

    Two counts come back: how many bytes were written to `dst`, and how many
    characters of `src` were used. They are two numbers rather than one because
    a group is only decoded when all five of its characters have arrived, so a
    caller reading a stream keeps the leftover and hands it back next time.

    `flush` says that `src` is the end of the document. Without it the last
    partial group is left for later; with it the group is completed by assuming
    the largest digit for every character that never arrived, which is what
    recovers the bytes a short group carries.

    Space and control characters are skipped wherever they appear, which is
    every byte at or below `0x20`. Anything else outside `!` to `u` raises with
    `ErrCorruptAscii85` and its offset, and so does a final group of a single
    character, which carries no whole byte.
    """
    var v = UInt32(0)
    var nb = 0
    var ndst = 0
    var nsrc = 0

    for i in range(len(src)):
        if len(dst) - ndst < 4:
            return (ndst, nsrc)
        var b = src[i]
        if b <= _SPACE:
            continue
        elif b == _ZERO and nb == 0:
            nb = 5
            v = 0
        elif b >= _FIRST and b <= _LAST:
            v = v * 85 + UInt32(b - _FIRST)
            nb += 1
        else:
            raise _corrupt(i)

        if nb == 5:
            nsrc = i + 1
            dst[ndst] = Byte((v >> 24) & 0xFF)
            dst[ndst + 1] = Byte((v >> 16) & 0xFF)
            dst[ndst + 2] = Byte((v >> 8) & 0xFF)
            dst[ndst + 3] = Byte(v & 0xFF)
            ndst += 4
            nb = 0
            v = 0

    if flush:
        nsrc = len(src)
        if nb > 0:
            # A group of one carries nothing. The encoding spends one character
            # more than the bytes it spells, so one character is all overhead
            # and there is no input it could have come from.
            if nb == 1:
                raise _corrupt(len(src))
            # The missing digits are assumed to be the largest there is, which
            # is what makes the bits above them come out right. Anything
            # smaller would round the value down and lose the last byte.
            for _ in range(nb, 5):
                v = v * 85 + 84
            for _ in range(nb - 1):
                dst[ndst] = Byte((v >> 24) & 0xFF)
                v <<= 8
                ndst += 1
    return (ndst, nsrc)
