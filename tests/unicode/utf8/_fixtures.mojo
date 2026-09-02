"""The tables. Go's `utf8map`, `surrogateMap` and `testStrings`, transcribed.

Everything here is a `List[UInt8]` rather than a `String`, and that is not
tidiness. Half of these byte sequences are not valid UTF-8, so a Mojo `String`
cannot hold them at all: `String(from_utf8=...)` raises on exactly the input the
interesting half of this suite is about. Go writes them as string literals
because a Go `string` is arbitrary bytes; here the literal is the byte list and
the tests read a little worse for it.

`Case` pairs a code point with its one correct encoding. There is one correct
encoding per code point, which is the whole reason the overlong forms in
`_INVALID` are rejected rather than accepted as a spelling variant.
"""


@fieldwise_init
struct Case(Copyable, Movable):
    """A code point and the bytes it encodes to, in both directions."""

    var rune: Int32
    var encoded: List[UInt8]


def valid_cases() -> List[Case]:
    """Go's `utf8map`. Every boundary in the encoding, and both sides of it.

    The reason a table beats generated input here is that it was written by
    hand from the specification rather than from this implementation, so an
    encoder and a decoder that are wrong in the same direction still fail it.
    """
    var out = List[Case]()
    out.append(Case(0x0000, [UInt8(0x00)]))
    out.append(Case(0x0001, [UInt8(0x01)]))
    out.append(Case(0x007E, [UInt8(0x7E)]))
    out.append(Case(0x007F, [UInt8(0x7F)]))
    out.append(Case(0x0080, [UInt8(0xC2), 0x80]))
    out.append(Case(0x0081, [UInt8(0xC2), 0x81]))
    out.append(Case(0x00BF, [UInt8(0xC2), 0xBF]))
    out.append(Case(0x00C0, [UInt8(0xC3), 0x80]))
    out.append(Case(0x00C1, [UInt8(0xC3), 0x81]))
    out.append(Case(0x00C8, [UInt8(0xC3), 0x88]))
    out.append(Case(0x00D0, [UInt8(0xC3), 0x90]))
    out.append(Case(0x00E0, [UInt8(0xC3), 0xA0]))
    out.append(Case(0x00F0, [UInt8(0xC3), 0xB0]))
    out.append(Case(0x00F8, [UInt8(0xC3), 0xB8]))
    out.append(Case(0x00FF, [UInt8(0xC3), 0xBF]))
    out.append(Case(0x0100, [UInt8(0xC4), 0x80]))
    out.append(Case(0x07FF, [UInt8(0xDF), 0xBF]))
    out.append(Case(0x0400, [UInt8(0xD0), 0x80]))
    out.append(Case(0x0800, [UInt8(0xE0), 0xA0, 0x80]))
    out.append(Case(0x0801, [UInt8(0xE0), 0xA0, 0x81]))
    out.append(Case(0x1000, [UInt8(0xE1), 0x80, 0x80]))
    out.append(Case(0xD000, [UInt8(0xED), 0x80, 0x80]))
    # The last code point before the surrogate half, and the first after it.
    out.append(Case(0xD7FF, [UInt8(0xED), 0x9F, 0xBF]))
    out.append(Case(0xE000, [UInt8(0xEE), 0x80, 0x80]))
    out.append(Case(0xFFFE, [UInt8(0xEF), 0xBF, 0xBE]))
    out.append(Case(0xFFFF, [UInt8(0xEF), 0xBF, 0xBF]))
    out.append(Case(0x10000, [UInt8(0xF0), 0x90, 0x80, 0x80]))
    out.append(Case(0x10001, [UInt8(0xF0), 0x90, 0x80, 0x81]))
    out.append(Case(0x40000, [UInt8(0xF1), 0x80, 0x80, 0x80]))
    out.append(Case(0x10FFFE, [UInt8(0xF4), 0x8F, 0xBF, 0xBE]))
    out.append(Case(0x10FFFF, [UInt8(0xF4), 0x8F, 0xBF, 0xBF]))
    # U+FFFD encoded on purpose, which is the case that stops a decoder from
    # reporting failure by value alone.
    out.append(Case(0xFFFD, [UInt8(0xEF), 0xBF, 0xBD]))
    return out^


def surrogate_cases() -> List[Case]:
    """Go's `surrogateMap`: the three byte forms of the UTF-16 halves.

    These are well formed as arithmetic and forbidden as UTF-8, so a decoder
    that only checked the shape of the bytes accepts all of them. The `rune`
    field is what the bytes would have meant, not what decoding gives, which is
    `(RUNE_ERROR, 1)` for every one.
    """
    var out = List[Case]()
    out.append(Case(0xD800, [UInt8(0xED), 0xA0, 0x80]))
    out.append(Case(0xDFFF, [UInt8(0xED), 0xBF, 0xBF]))
    return out^


def invalid() -> List[List[UInt8]]:
    """Go's `TestDecodeInvalidSequence` table, minus the two valid entries.

    Four bytes each, so that a decoder is never refusing one of these for want
    of input. Every entry is wrong in the first, second, third or fourth byte,
    and the overlong forms — `C0`, `C1`, `E0 80`, `F0 80` — are the ones a
    decoder written from the arithmetic alone will happily accept.
    """
    var out = List[List[UInt8]]()
    out.append([UInt8(0x80), 0x80, 0x80, 0x80])
    out.append([UInt8(0xC0), 0x80, 0x80, 0x80])
    out.append([UInt8(0xC1), 0x80, 0x80, 0x80])
    out.append([UInt8(0xC2), 0xC0, 0x80, 0x80])
    out.append([UInt8(0xDF), 0xC0, 0x80, 0x80])
    out.append([UInt8(0xE0), 0x80, 0x80, 0x80])
    out.append([UInt8(0xE0), 0xA0, 0xC0, 0x80])
    out.append([UInt8(0xE0), 0xC0, 0x80, 0x80])
    out.append([UInt8(0xED), 0xA0, 0x80, 0x80])
    out.append([UInt8(0xF0), 0x80, 0x80, 0x80])
    out.append([UInt8(0xF0), 0x90, 0x80, 0xC0])
    out.append([UInt8(0xF0), 0x90, 0xC0, 0x80])
    out.append([UInt8(0xF0), 0xC0, 0x80, 0x80])
    out.append([UInt8(0xF4), 0x90, 0x80, 0x80])
    out.append([UInt8(0xF4), 0xC0, 0x80, 0x80])
    out.append([UInt8(0xF5), 0x80, 0x80, 0x80])
    out.append([UInt8(0xFF), 0x80, 0x80, 0x80])
    return out^


def joined(cases: List[Case]) -> List[UInt8]:
    """Every encoding in `cases` end to end, for the sequencing tests."""
    var out = List[UInt8]()
    for entry in cases:
        out.extend(entry.encoded.copy())
    return out^
