"""UTF-8, only as much of it as `bufio` needs, and only until issue #19.

`core.unicode.utf8` is M3. This package is M2 and three of its methods —
`read_rune`, `write_rune` and `ScanRunes` — cannot be written without a
decoder, so there is one here. It goes when #19 lands and every function in it
has a namesake there, so the replacement is an import change and a deletion.

It is private for that reason, and it is not a partial `core.unicode.utf8`:
there is no encoder for strings, no width table, no case mapping, nothing that
would tempt anybody to use this from outside and then have to be moved.

The one thing worth reading before trusting it is the invalid input rule, which
is Go's and is not the obvious one. A decoder that met a byte it did not like
could reasonably skip the whole malformed sequence. Go advances exactly one
byte and reports `RUNE_ERROR`, so a stream of rubbish produces one replacement
character per byte rather than an arbitrary resynchronisation, and a decode
loop always terminates. `read_rune` and `ScanRunes` both depend on that: a
size of zero would be an infinite loop.
"""

from core.io import Byte

comptime RUNE_ERROR = Int32(0xFFFD)
"""U+FFFD, the replacement character. Go's `utf8.RuneError`."""

comptime RUNE_SELF = 0x80
"""Below this a rune is one byte and is its own encoding. Go's `utf8.RuneSelf`."""

comptime UTF_MAX = 4
"""The most bytes one rune can take. Go's `utf8.UTFMax`."""

comptime MAX_RUNE = Int32(0x10FFFF)
"""The largest code point. Go's `utf8.MaxRune`."""


def _width(first: Byte) -> Int:
    """How many bytes a sequence starting with `first` claims to be.

    Zero means the byte cannot start one at all: either it is a continuation
    byte, or it is `0xC0`/`0xC1`, which can only ever begin an overlong two
    byte encoding of something that fits in one, or it is above `0xF4`, which
    would be past `MAX_RUNE`.
    """
    if first < 0x80:
        return 1
    if first < 0xC2:
        return 0
    if first < 0xE0:
        return 2
    if first < 0xF0:
        return 3
    if first < 0xF5:
        return 4
    return 0


def _second_range(first: Byte) -> Tuple[Byte, Byte]:
    """The bytes allowed in the second position, which depend on the first.

    Three of the four ranges are `0x80` to `0xBF`. The exceptions are the whole
    reason UTF-8 has a single encoding for each code point rather than several:
    `0xE0` and `0xF0` exclude the values that would be overlong, and `0xED`
    excludes the surrogate half, which is not a code point at all.
    """
    if first == 0xE0:
        return (Byte(0xA0), Byte(0xBF))
    if first == 0xED:
        return (Byte(0x80), Byte(0x9F))
    if first == 0xF0:
        return (Byte(0x90), Byte(0xBF))
    if first == 0xF4:
        return (Byte(0x80), Byte(0x8F))
    return (Byte(0x80), Byte(0xBF))


def _decode_rune[o: Origin](data: Span[Byte, o]) -> Tuple[Int32, Int]:
    """The first rune in `data`, and how many bytes it took. Go's `DecodeRune`.

    Empty input gives `(RUNE_ERROR, 0)`, and that zero is the only zero this
    returns. Anything malformed, truncated included, gives `(RUNE_ERROR, 1)`.
    """
    if len(data) == 0:
        return (RUNE_ERROR, 0)

    var first = data[0]
    var size = _width(first)
    if size == 0:
        return (RUNE_ERROR, 1)
    if size == 1:
        return (Int32(first), 1)
    if len(data) < size:
        return (RUNE_ERROR, 1)

    var lo: Byte
    var hi: Byte
    lo, hi = _second_range(first)
    var second = data[1]
    if second < lo or second > hi:
        return (RUNE_ERROR, 1)
    if size == 2:
        return ((Int32(first & 0x1F) << 6) | Int32(second & 0x3F), 2)

    var third = data[2]
    if third < 0x80 or third > 0xBF:
        return (RUNE_ERROR, 1)
    if size == 3:
        return (
            (Int32(first & 0x0F) << 12)
            | (Int32(second & 0x3F) << 6)
            | Int32(third & 0x3F),
            3,
        )

    var fourth = data[3]
    if fourth < 0x80 or fourth > 0xBF:
        return (RUNE_ERROR, 1)
    return (
        (Int32(first & 0x07) << 18)
        | (Int32(second & 0x3F) << 12)
        | (Int32(third & 0x3F) << 6)
        | Int32(fourth & 0x3F),
        4,
    )


def _full_rune[o: Origin](data: Span[Byte, o]) -> Bool:
    """Whether `data` starts with a complete encoding. Go's `FullRune`.

    Complete includes malformed, because a malformed sequence is decoded as one
    byte and reading more input will not repair it. Only a truncation that
    could still turn into a rune answers `False`, and that is the answer
    `read_rune` needs: it is the question "would another read help".
    """
    if len(data) == 0:
        return False

    var first = data[0]
    var size = _width(first)
    if size == 0:
        return True
    if len(data) >= size:
        return True

    # Short, so the answer turns on whether what did arrive is already wrong.
    var lo: Byte
    var hi: Byte
    lo, hi = _second_range(first)
    if len(data) >= 2 and (data[1] < lo or data[1] > hi):
        return True
    if len(data) >= 3 and (data[2] < 0x80 or data[2] > 0xBF):
        return True
    return False


def _rune_len(r: Int32) -> Int:
    """How many bytes `r` encodes to. Go's `RuneLen`, without the -1.

    Go answers -1 for a value that is not a code point. Every caller here is
    about to encode it anyway, and encoding substitutes `RUNE_ERROR`, so this
    answers with the width of what will actually be written.
    """
    if r < 0 or r > MAX_RUNE or (r >= 0xD800 and r <= 0xDFFF):
        return 3  # RUNE_ERROR
    if r < 0x80:
        return 1
    if r < 0x800:
        return 2
    if r < 0x10000:
        return 3
    return 4


def _encode_rune[o: Origin[mut=True]](into: Span[Byte, o], r: Int32) -> Int:
    """Write `r` at the start of `into` and return how many bytes it took.

    Substitutes `RUNE_ERROR` for anything that is not a code point, which is
    Go's behaviour and is what makes `write_rune` infallible once there is
    room. The caller has to have made room: `_rune_len` says how much.
    """
    var value = r
    if value < 0 or value > MAX_RUNE or (value >= 0xD800 and value <= 0xDFFF):
        value = RUNE_ERROR

    if value < 0x80:
        into[0] = Byte(value)
        return 1
    if value < 0x800:
        into[0] = Byte(0xC0 | (value >> 6))
        into[1] = Byte(0x80 | (value & 0x3F))
        return 2
    if value < 0x10000:
        into[0] = Byte(0xE0 | (value >> 12))
        into[1] = Byte(0x80 | ((value >> 6) & 0x3F))
        into[2] = Byte(0x80 | (value & 0x3F))
        return 3
    into[0] = Byte(0xF0 | (value >> 18))
    into[1] = Byte(0x80 | ((value >> 12) & 0x3F))
    into[2] = Byte(0x80 | ((value >> 6) & 0x3F))
    into[3] = Byte(0x80 | (value & 0x3F))
    return 4
