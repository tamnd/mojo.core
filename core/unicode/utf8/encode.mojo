"""Writing runes into bytes, and the two questions you ask before doing it.

`valid_rune` and `rune_len` are the questions. `encode_rune` and `append_rune`
are the writing, and neither of them can fail on the value it was given: a rune
that is not a code point is written as `RUNE_ERROR`, which is Go's behaviour
and the reason `bufio.Writer.write_rune` has no failure path of its own.

Substitution rather than a raise is worth defending, because it is the opposite
of what the decoding half does with bad input, and the asymmetry is deliberate.
A bad byte in the input came from somewhere else and the caller needs to know;
a bad rune in an encode call came from the caller's own arithmetic, and every
sink it could go to has to be handed something. Go made the same call and every
UTF-8 encoder in wide use agrees.
"""

from .limits import (
    MAX_RUNE,
    RUNE_ERROR,
    RUNE_SELF,
    _SURROGATE_MAX,
    _SURROGATE_MIN,
)


def valid_rune(r: Int32) -> Bool:
    """Whether `r` is a code point that can be encoded. Go's `ValidRune`.

    False for a negative value, for anything above `MAX_RUNE`, and for the
    surrogate range, which UTF-16 reserves for spelling the code points above
    U+FFFF and which is therefore permanently not a character.
    """
    if r < 0 or r > MAX_RUNE:
        return False
    return r < _SURROGATE_MIN or r > _SURROGATE_MAX


def rune_len(r: Int32) -> Int:
    """How many bytes `r` encodes to, or -1. Go's `RuneLen`.

    The -1 is for a value that is not a code point, and it is why this is not
    the function to size a buffer with before calling `encode_rune`: that call
    substitutes `RUNE_ERROR` and writes three bytes where this says -1. Ask
    `valid_rune` first, or make room for `UTF_MAX` and stop thinking about it.
    """
    if not valid_rune(r):
        return -1
    if r < RUNE_SELF:
        return 1
    if r < 0x800:
        return 2
    if r < 0x10000:
        return 3
    return 4


def encode_rune[o: Origin[mut=True]](into: Span[UInt8, o], r: Int32) -> Int:
    """Write `r` at the front of `into` and return how many bytes it took.

    Go's `EncodeRune`. A value that is not a code point is written as
    `RUNE_ERROR`, three bytes, so this always writes something and always
    returns a positive count.

    The caller has to have made room. `into` shorter than the encoding is a
    bounds failure from the span rather than a short write, because there is no
    useful thing to return: half a rune in a buffer is worse than not writing.
    A span of `UTF_MAX` bytes is always enough.
    """
    var value = r
    if not valid_rune(value):
        value = RUNE_ERROR

    if value < RUNE_SELF:
        into[0] = UInt8(value)
        return 1
    if value < 0x800:
        into[0] = UInt8(0xC0 | (value >> 6))
        into[1] = UInt8(0x80 | (value & 0x3F))
        return 2
    if value < 0x10000:
        into[0] = UInt8(0xE0 | (value >> 12))
        into[1] = UInt8(0x80 | ((value >> 6) & 0x3F))
        into[2] = UInt8(0x80 | (value & 0x3F))
        return 3
    into[0] = UInt8(0xF0 | (value >> 18))
    into[1] = UInt8(0x80 | ((value >> 12) & 0x3F))
    into[2] = UInt8(0x80 | ((value >> 6) & 0x3F))
    into[3] = UInt8(0x80 | (value & 0x3F))
    return 4


def append_rune(mut dst: List[UInt8], r: Int32) -> Int:
    """Encode `r` onto the end of `dst`, and say how many bytes that took.

    Go's `AppendRune` takes a slice and returns the grown one, because that is
    what `append` does. Growing a `List` in place is the same operation without
    the return, so this takes `mut dst` and hands back the count instead, which
    is the number the caller usually wanted anyway. `deviations.md` has the
    row.

    Same substitution as `encode_rune`, so this cannot fail on its argument.
    """
    var value = r
    if not valid_rune(value):
        value = RUNE_ERROR

    if value < RUNE_SELF:
        dst.append(UInt8(value))
        return 1
    if value < 0x800:
        dst.append(UInt8(0xC0 | (value >> 6)))
        dst.append(UInt8(0x80 | (value & 0x3F)))
        return 2
    if value < 0x10000:
        dst.append(UInt8(0xE0 | (value >> 12)))
        dst.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
        dst.append(UInt8(0x80 | (value & 0x3F)))
        return 3
    dst.append(UInt8(0xF0 | (value >> 18)))
    dst.append(UInt8(0x80 | ((value >> 12) & 0x3F)))
    dst.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
    dst.append(UInt8(0x80 | (value & 0x3F)))
    return 4
