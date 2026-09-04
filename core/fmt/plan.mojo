"""A format string, taken apart.

Go reads the format string every time `Printf` runs. Here the format is usually
a `comptime` parameter, so it is read once, when the program is built, and what
comes out is this: a list of `Piece`, each one a run of literal text followed by
at most one verb. The call that used to carry a format string carries a
concatenation instead, and the string itself is not in the binary.

`vsprintf` has a format string that is not known until the program runs, and it
calls the same parser. That is why `Piece` carries an origin rather than a
`StaticString`: a piece cut out of a `String` the caller built borrows from that
`String`, and a piece cut out of a literal borrows from the binary, and neither
copies. One parser for both paths is not a tidiness argument, it is most of what
makes the two paths agree on the bytes they produce.

Everything in this file is written so that it can run in the compile time
interpreter: no raising, no allocation the interpreter cannot follow, and a hand
written decoder for the one rune it has to read, because a verb is a rune in Go
and `%☺` has to come out as `%!☺(...)` rather than as three bytes of nonsense.

The pieces are the plan. Checking them against the arguments they will consume
happens in `check.mojo`, and writing the values out happens in `write.mojo`.
"""

# The flag characters, as bits, plus the two that only `%v` has.
#
# `%#v` and `%+v` are not the sharp and plus flags applied to `v`. Go treats
# them as two more verbs that happen to be spelled with a flag, which is why it
# moves the bit across as soon as it knows the verb is `v`, and so do we.
comptime MINUS = 1
comptime PLUS = 2
comptime SHARP = 4
comptime SPACE = 8
comptime ZERO = 16
comptime SHARPV = 32
comptime PLUSV = 64

# Carried by the last piece rather than by any verb: whether the format used an
# explicit argument index. Go stops reporting unused arguments once it sees
# one, because after `%[1]d` the arguments are no longer being consumed in
# order and "you passed one too many" stops being true.
comptime REORDERED = 128

# What a piece with no ordinary verb is. The real verbs are code points, which
# are positive, so these are negative and nothing has to be told apart by a
# flag alongside.
comptime TAIL = 0
comptime PERCENT = -1
comptime NOVERB = -2
comptime BADINDEX = -3

comptime _PERCENT_BYTE = Byte(ord("%"))
comptime _RUNE_ERROR = 0xFFFD


@fieldwise_init
struct Piece[o: ImmOrigin](Copyable, ImplicitlyCopyable, Movable):
    """A run of literal text and the verb that follows it.

    The literal is a slice of the format string, so it costs nothing to carry
    around at compile time and becomes a string constant in the program.

    The last piece in a plan is the tail: its verb is `TAIL` and it holds the
    text after the final verb. It also carries two facts about the format as a
    whole, because they are known here and nowhere else: `arg` is how many
    arguments the format consumes, and `flags` holds `REORDERED`.
    """

    var literal: StringSlice[Self.o]
    """The text before the verb, written out as it stands."""

    var verb: Int
    """The verb as a code point, or one of `TAIL`, `PERCENT`, `NOVERB` and
    `BADINDEX`."""

    var flags: Int
    """The flag bits, after `%#v` and `%+v` have been moved across."""

    var width: Int
    """The width, or -1 when the format did not give one."""

    var prec: Int
    """The precision, or -1 when the format did not give one. Zero is a
    precision, and it is not the same thing as none."""

    var arg: Int
    """Which argument this verb formats, counting from zero."""

    var width_arg: Int
    """Which argument the width comes from for `%*d`, or -1."""

    var prec_arg: Int
    """Which argument the precision comes from for `%.*f`, or -1."""


def _digits(b: Span[Byte, _], start: Int) -> Tuple[Int, Int]:
    """A run of decimal digits, and where it ends.

    Gives back -1 when there are no digits at `start`, which is how the caller
    tells `%d` from `%3d` without looking at the bytes itself.
    """
    var i = start
    var value = 0
    while i < len(b) and b[i] >= Byte(ord("0")) and b[i] <= Byte(ord("9")):
        value = value * 10 + Int(b[i]) - ord("0")
        i += 1
    if i == start:
        return (-1, start)
    return (value, i)


def rune_at(b: Span[Byte, _], at: Int) -> Tuple[Int, Int]:
    """The code point at `at`, and how many bytes it took.

    Public because `write.mojo` needs the same walk over a string when a
    precision has to count runes rather than bytes, and one decoder that both
    halves agree about is worth more than two that nearly do.

    Written out here rather than taken from `core.unicode.utf8` because this
    runs in the compile time interpreter, and the fewer functions that has to
    follow the fewer ways this has to break. It is only ever asked to read a
    verb, so anything malformed is one byte of `RUNE_ERROR` and the format
    string is wrong anyway.
    """
    var first = Int(b[at])
    if first < 0x80:
        return (first, 1)
    if first < 0xC0 or first >= 0xF8:
        return (_RUNE_ERROR, 1)
    var size = 4 if first >= 0xF0 else (3 if first >= 0xE0 else 2)
    var value = first & (
        0x07 if first >= 0xF0 else (0x0F if first >= 0xE0 else 0x1F)
    )
    if at + size > len(b):
        return (_RUNE_ERROR, 1)
    for i in range(1, size):
        var next = Int(b[at + i])
        if next < 0x80 or next >= 0xC0:
            return (_RUNE_ERROR, 1)
        value = (value << 6) | (next & 0x3F)
    return (value, size)


def pieces[o: ImmOrigin](format: StringSlice[o]) -> List[Piece[o]]:
    """The format string as a plan.

    Follows Go's `doPrintf` in what it accepts and in what order it consumes
    arguments: the width argument of `%*d` comes before the precision argument
    of `%.*f`, and both come before the value. An explicit index moves the
    counter, so `%[3]d%d` reads the third argument and then the fourth.
    """
    var out = List[Piece[o]]()
    var b = format.as_bytes()
    var n = len(b)
    var start = 0
    var i = 0
    var next = 0
    var reordered = False

    while i < n:
        if b[i] != _PERCENT_BYTE:
            i += 1
            continue
        var literal = format[byte=start:i]
        i += 1

        # `%%` is a percent sign and consumes nothing.
        if i < n and b[i] == _PERCENT_BYTE:
            out.append(Piece(literal, PERCENT, 0, -1, -1, -1, -1, -1))
            i += 1
            start = i
            continue

        var flags = 0
        while i < n:
            var c = b[i]
            if c == Byte(ord("-")):
                flags |= MINUS
            elif c == Byte(ord("+")):
                flags |= PLUS
            elif c == Byte(ord("#")):
                flags |= SHARP
            elif c == Byte(ord(" ")):
                flags |= SPACE
            elif c == Byte(ord("0")):
                flags |= ZERO
            else:
                break
            i += 1

        # `%[2]d`, the explicit argument index. One based in the format and
        # zero based everywhere after it.
        var index = -1
        if i < n and b[i] == Byte(ord("[")):
            var read = _digits(b, i + 1)
            var value = read[0]
            var after = read[1]
            if value < 1 or after >= n or b[after] != Byte(ord("]")):
                out.append(Piece(literal, BADINDEX, 0, -1, -1, -1, -1, -1))
                start = after
                i = after
                continue
            index = value - 1
            reordered = True
            i = after + 1

        var width = -1
        var width_arg = -1
        if i < n and b[i] == Byte(ord("*")):
            width_arg = next
            next += 1
            i += 1
        else:
            var read = _digits(b, i)
            width = read[0]
            i = read[1]

        var prec = -1
        var prec_arg = -1
        # `i + 1 < n` rather than `i < n`, which is Go's own condition and is
        # not an off by one. A format ending in a bare `.` never starts a
        # precision at all: the dot is read as the verb, so `%.` of an `Int` is
        # `%!.(int=3)` and not a NOVERB. It is one byte of Go's behaviour and
        # it is a row of Go's own table.
        if i + 1 < n and b[i] == Byte(ord(".")):
            i += 1
            if i < n and b[i] == Byte(ord("*")):
                prec_arg = next
                next += 1
                i += 1
            else:
                var read = _digits(b, i)
                # `%.f` is a precision of zero, which is not the same as no
                # precision at all and is why this cannot be -1.
                prec = read[0] if read[0] >= 0 else 0
                i = read[1]

        # A format that ends in a flag or a width and never reaches a verb.
        if i >= n:
            out.append(Piece(literal, NOVERB, 0, -1, -1, -1, -1, -1))
            start = n
            break

        var read = rune_at(b, i)
        var verb = read[0]
        i += read[1]

        if index >= 0:
            next = index + 1
        var arg = index if index >= 0 else next
        if index < 0:
            next += 1

        # `%#v` and `%+v` are their own formats rather than flagged `%v`.
        if verb == ord("v"):
            if flags & SHARP != 0:
                flags = (flags & ~SHARP) | SHARPV
            if flags & PLUS != 0:
                flags = (flags & ~PLUS) | PLUSV

        out.append(
            Piece(literal, verb, flags, width, prec, arg, width_arg, prec_arg)
        )
        start = i

    var carried = REORDERED if reordered else 0
    out.append(Piece(format[byte=start:n], TAIL, carried, -1, -1, next, -1, -1))
    return out^
