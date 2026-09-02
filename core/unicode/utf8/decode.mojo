"""Reading runes out of bytes. Go's decoding half of `unicode/utf8`.

The rule that matters here is what happens to input that is not valid UTF-8,
because it is not the obvious rule and everything else is built on it. A
decoder that met a byte it did not like could reasonably skip the whole
malformed sequence and resynchronise. Go advances exactly one byte and reports
`RUNE_ERROR` with a size of 1, so a stream of rubbish produces one replacement
per byte rather than a guess about where the next real rune starts.

Two things depend on that and neither is optional. A decode loop always
terminates, because the size is never zero for input that is not empty.
And resynchronisation stays the caller's decision, which matters because the
right answer differs: a text editor wants to show the damage, a protocol parser
wants to reject the message, and a decoder that had already skipped ahead has
taken that choice away from both.

The validity rules are Go's `acceptRanges` written as a function. UTF-8 has
exactly one encoding for each code point, and three of the four second-byte
ranges are narrowed to keep it that way: `0xE0` and `0xF0` exclude the values
that would be a longer spelling of something that fits in fewer bytes, `0xED`
excludes the surrogate half, and `0xF4` excludes everything past `MAX_RUNE`.
An overlong encoding is not a curiosity — it is how a filter that checks for
`/` and a consumer that decodes properly are made to disagree.
"""

from .limits import RUNE_ERROR, RUNE_SELF, UTF_MAX


def _width(first: UInt8) -> Int:
    """How many bytes a sequence starting with `first` claims to be.

    Zero means the byte cannot begin one at all: either it is a continuation
    byte, or it is `0xC0` or `0xC1`, which can only ever begin an overlong two
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


def _second_range(first: UInt8) -> Tuple[UInt8, UInt8]:
    """The bytes allowed in the second position, which depend on the first.

    Go's `acceptRanges`. Three of the four are the whole continuation range;
    the exceptions are in the module docstring and they are the reason UTF-8
    has one spelling per code point.
    """
    if first == 0xE0:
        return (UInt8(0xA0), UInt8(0xBF))
    if first == 0xED:
        return (UInt8(0x80), UInt8(0x9F))
    if first == 0xF0:
        return (UInt8(0x90), UInt8(0xBF))
    if first == 0xF4:
        return (UInt8(0x80), UInt8(0x8F))
    return (UInt8(0x80), UInt8(0xBF))


def rune_start(b: UInt8) -> Bool:
    """Whether `b` could begin an encoding. Go's `RuneStart`.

    True for every byte that is not a continuation byte, including ones that
    begin nothing valid. It is a test for a boundary, not for validity, and it
    is what `decode_last_rune` scans backwards with.
    """
    return b & 0xC0 != 0x80


def decode_rune[o: Origin](data: Span[UInt8, o]) -> Tuple[Int32, Int]:
    """The first rune in `data`, and how many bytes it took. Go's `DecodeRune`.

    Empty input gives `(RUNE_ERROR, 0)`, and that zero is the only zero this
    ever returns, which is what makes a loop over it terminate. Anything
    malformed, truncated included, gives `(RUNE_ERROR, 1)`.
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

    var lo: UInt8
    var hi: UInt8
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


def decode_rune_in_string(s: String) -> Tuple[Int32, Int]:
    """`decode_rune` over the bytes of `s`. Go's `DecodeRuneInString`.

    Go has this as a separate function because converting a `string` to a
    `[]byte` copies. `String.as_bytes` borrows, so this is the same call at the
    same cost and it exists only so that the name a Go programmer reaches for
    is there. `deviations.md` has the row.
    """
    return decode_rune(s.as_bytes())


def decode_last_rune[o: Origin](data: Span[UInt8, o]) -> Tuple[Int32, Int]:
    """The last rune in `data`, and its width. Go's `DecodeLastRune`.

    Walks back at most `UTF_MAX` bytes looking for something that could begin
    an encoding, then decodes forward from there and checks that it lands
    exactly on the end. The bound is what stops a long run of continuation
    bytes turning a backwards scan over a buffer into quadratic work, and the
    landing check is what stops a truncated sequence in the middle from being
    read as the last rune.
    """
    var end = len(data)
    if end == 0:
        return (RUNE_ERROR, 0)

    var start = end - 1
    if Int(data[start]) < RUNE_SELF:
        return (Int32(data[start]), 1)

    var limit = end - UTF_MAX
    if limit < 0:
        limit = 0
    start -= 1
    while start >= limit:
        if rune_start(data[start]):
            break
        start -= 1
    if start < limit:
        start = limit

    var r: Int32
    var size: Int
    r, size = decode_rune(data[start:end])
    if start + size != end:
        return (RUNE_ERROR, 1)
    return (r, size)


def decode_last_rune_in_string(s: String) -> Tuple[Int32, Int]:
    """`decode_last_rune` over the bytes of `s`. Go's `DecodeLastRuneInString`.
    """
    return decode_last_rune(s.as_bytes())


def full_rune[o: Origin](data: Span[UInt8, o]) -> Bool:
    """Whether `data` begins with a complete encoding. Go's `FullRune`.

    Complete includes malformed, because a malformed sequence decodes as one
    byte and no amount of further input repairs it. Only a truncation that
    could still become a rune answers `False`, which makes this the question
    "would reading more help", and that is the only question a buffered reader
    ever wants to ask.
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
    var lo: UInt8
    var hi: UInt8
    lo, hi = _second_range(first)
    if len(data) >= 2 and (data[1] < lo or data[1] > hi):
        return True
    if len(data) >= 3 and (data[2] < 0x80 or data[2] > 0xBF):
        return True
    return False


def full_rune_in_string(s: String) -> Bool:
    """`full_rune` over the bytes of `s`. Go's `FullRuneInString`."""
    return full_rune(s.as_bytes())


def rune_count[o: Origin](data: Span[UInt8, o]) -> Int:
    """How many runes `data` holds. Go's `RuneCount`.

    Every byte that is not part of a valid encoding counts as one rune, for the
    same reason `decode_rune` advances one byte over it: this has to agree with
    what a decode loop would produce, or a caller that sized a list with it
    would be wrong about invalid input and only about invalid input.
    """
    var n = 0
    var i = 0
    while i < len(data):
        var size: Int
        _, size = decode_rune(data[i:])
        i += size
        n += 1
    return n


def rune_count_in_string(s: String) -> Int:
    """`rune_count` over the bytes of `s`. Go's `RuneCountInString`.

    This is what `core.strings.count_runes` will call, and it is one of the
    three answers to "how long is this string" that `deviations.md` lists in
    place of Go's single `len`.
    """
    return rune_count(s.as_bytes())


def valid[o: Origin](data: Span[UInt8, o]) -> Bool:
    """Whether `data` is entirely valid UTF-8. Go's `Valid`.

    Empty is valid. A `RUNE_ERROR` that was actually encoded in the input is
    valid, which is why this checks the size rather than the rune: the three
    byte encoding of U+FFFD decodes to the same value that a bad byte reports.
    """
    var i = 0
    while i < len(data):
        var r: Int32
        var size: Int
        r, size = decode_rune(data[i:])
        if r == RUNE_ERROR and size == 1:
            return False
        i += size
    return True


def valid_string(s: String) -> Bool:
    """Whether `s` is valid UTF-8. Go's `ValidString`.

    Almost always `True`, and that is a real difference rather than a
    tautology worth deleting. A Go `string` is arbitrary bytes and this is the
    check you run before trusting one. A Mojo `String` is validated when it is
    built, so the only way to get one that fails here is through the `unsafe_`
    constructor, where somebody asserted the encoding instead of checking it.
    Keeping the function means that assertion can still be audited.
    """
    return valid(s.as_bytes())
