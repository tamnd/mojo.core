"""The four constants, and the surrogate range that is not one of them.

Go keeps these at the top of `utf8.go` with everything else. They are on their
own here because both halves of the package read them and neither half should
have to import the other to do it.

Bytes are spelled `UInt8` rather than `Byte`. `core.io.Byte` is the alias the
rest of the library uses, and this package is tier 0 and depends on nothing, so
it cannot have it. They are the same type and a caller passing a
`Span[core.io.Byte, o]` here is passing exactly what these functions ask for.
"""

comptime RUNE_ERROR = Int32(0xFFFD)
"""U+FFFD, the replacement character. Go's `RuneError`.

What a decode returns for input it cannot read. It is also a perfectly ordinary
code point that can appear in valid input, which is why every caller that cares
about the difference has to look at the size as well: `RUNE_ERROR` with a size
of 3 came out of the input and `RUNE_ERROR` with a size of 1 did not.
"""

comptime RUNE_SELF = 0x80
"""Below this a rune is one byte and encodes to itself. Go's `RuneSelf`.

The reason it is worth having a name is that it is the ASCII fast path
condition, and almost every function here opens with it.
"""

comptime MAX_RUNE = Int32(0x10FFFF)
"""The largest code point. Go's `MaxRune`."""

comptime UTF_MAX = 4
"""The most bytes one rune can take. Go's `UTFMax`.

Four since 2003, when UTF-8 was cut back to what UTF-16 can represent. A
buffer of this size can always hold one encoded rune, which is what makes
`encode_rune` infallible for a caller who checked.
"""

comptime _SURROGATE_MIN = Int32(0xD800)
"""The first surrogate half. Not a code point, and not encodable."""

comptime _SURROGATE_MAX = Int32(0xDFFF)
"""The last one. UTF-16 uses this range to spell the code points above U+FFFF,
so the range itself is permanently unassigned and UTF-8 may not carry it."""
