"""Text to integers. Go's `atoi.go`.

`parse_uint` does the work, `parse_int` peels off a sign and calls it, and
`atoi` is base 10 into an `Int`.

Go returns a clamped value alongside `ErrRange`: the largest magnitude the bit
size can hold, with the right sign. A raise carries no value, so this raises and
the caller computes the clamp if they want it, which is `(1 << bits) - 1` for
unsigned and one less magnitude on the positive side for signed. The code on
the error is `ErrRange`, and `errors.field(e, "num")` still has the text.

The underscore rule is Go's, and it only applies when the base is zero, which
is when the text is being read as a Go literal rather than as digits. `1_000`
parses at base 0 and is a syntax error at base 10, in both libraries.
"""

from core.errors import Report
from core.errors.codes import ErrRange, ErrSyntax

from core.strconv.itoa import INT_SIZE
from core.strconv.num_error import (
    _base_error,
    _bit_size_error,
    _range_error,
    _syntax_error,
)


comptime _ZERO = UInt8(ord("0"))
comptime _NINE = UInt8(ord("9"))
comptime _LOWER_A = UInt8(ord("a"))
comptime _LOWER_Z = UInt8(ord("z"))
comptime _UNDERSCORE = UInt8(ord("_"))
comptime _PLUS = UInt8(ord("+"))
comptime _MINUS = UInt8(ord("-"))
comptime _CASE_BIT = UInt8(ord("x")) - UInt8(ord("X"))


def _lower(c: UInt8) -> UInt8:
    """`c` with the case bit set. Go's `lower`.

    A letter comes back lower case and everything else comes back as some other
    byte, which is fine because the only questions asked of it are whether it
    is a letter and which one.
    """
    return c | _CASE_BIT


def _underscore_ok[o: ImmOrigin](s: StringSlice[o]) -> Bool:
    """Whether the underscores in `s` are where a Go literal allows them.

    Go's `underscoreOK`, and the reason it is a separate pass: the digit loop
    skips underscores without looking at what is around them, so this is what
    makes `1__0` and `_1` and `10_` wrong.
    """
    var data = s.as_bytes()
    var i = 0
    # The last thing seen: `^` for the start, `0` for a digit or a base prefix,
    # `_` for an underscore, `!` for anything else.
    var saw = UInt8(ord("^"))

    if len(data) >= 1 and (data[0] == _MINUS or data[0] == _PLUS):
        i = 1

    var hex = False
    if len(data) >= i + 2 and data[i] == _ZERO:
        var c = _lower(data[i + 1])
        if c == UInt8(ord("b")) or c == UInt8(ord("o")) or c == UInt8(ord("x")):
            hex = c == UInt8(ord("x"))
            i += 2
            # A base prefix counts as a digit, so `0x_1` is allowed.
            saw = _ZERO

    while i < len(data):
        var c = data[i]
        if (_ZERO <= c and c <= _NINE) or (
            hex and _LOWER_A <= _lower(c) and _lower(c) <= UInt8(ord("f"))
        ):
            saw = _ZERO
        elif c == _UNDERSCORE:
            if saw != _ZERO:
                return False
            saw = _UNDERSCORE
        elif saw == _UNDERSCORE:
            return False
        else:
            saw = UInt8(ord("!"))
        i += 1
    return saw != _UNDERSCORE


def _parse_uint[
    o: ImmOrigin
](
    s: StringSlice[o],
    base: Int,
    bit_size: Int,
    func: StringSlice[ImmStaticOrigin],
    num: StringSlice[o],
) raises -> UInt64:
    """`parse_uint`, with the name and the text the failure should report.

    `parse_int` calls this with the sign already removed, and Go's rule is that
    the error names the whole input rather than the part that was parsed, so
    the text to blame is a separate argument.
    """
    var data = s.as_bytes()
    if len(data) == 0:
        raise _syntax_error(func, num)

    var base0 = base == 0
    var b = base
    var start = 0

    if base == 0:
        # The prefix decides, after the sign, which the caller already removed.
        b = 10
        if data[0] == _ZERO:
            if len(data) >= 3 and _lower(data[1]) == UInt8(ord("b")):
                b = 2
                start = 2
            elif len(data) >= 3 and _lower(data[1]) == UInt8(ord("o")):
                b = 8
                start = 2
            elif len(data) >= 3 and _lower(data[1]) == UInt8(ord("x")):
                b = 16
                start = 2
            else:
                b = 8
                start = 1
    elif base < 2 or base > 36:
        raise _base_error(func, num, base)

    var bits = bit_size
    if bits == 0:
        bits = INT_SIZE
    elif bits < 0 or bits > 64:
        raise _bit_size_error(func, num, bit_size)

    # The smallest value whose multiplication by the base overflows.
    var cutoff = UInt64.MAX // UInt64(b) + 1
    # `1 << bits` minus one, written as a shift down so that 64 bits does not
    # shift a 64 bit value by its own width, which has no answer.
    var max_val = UInt64.MAX >> UInt64(64 - bits)

    var underscores = False
    var n = UInt64(0)
    for i in range(start, len(data)):
        var c = data[i]
        var d: UInt8
        if c == _UNDERSCORE and base0:
            underscores = True
            continue
        elif _ZERO <= c and c <= _NINE:
            d = c - _ZERO
        elif _LOWER_A <= _lower(c) and _lower(c) <= _LOWER_Z:
            d = _lower(c) - _LOWER_A + 10
        else:
            raise _syntax_error(func, num)

        if d >= UInt8(b):
            raise _syntax_error(func, num)
        if n >= cutoff:
            raise _range_error(func, num)
        n *= UInt64(b)
        var n1 = n + UInt64(d)
        if n1 < n or n1 > max_val:
            raise _range_error(func, num)
        n = n1

    if underscores and not _underscore_ok(num):
        raise _syntax_error(func, num)
    return n


def parse_uint[
    o: ImmOrigin
](s: StringSlice[o], base: Int, bit_size: Int) raises -> UInt64:
    """`s` as an unsigned number in `base`, fitting `bit_size` bits.

    Go's `ParseUint`. A sign is not allowed, not even a plus.

    `base` is 0 or 2 through 36. At 0 the prefix decides: `0b` is binary, `0o`
    or a leading `0` is octal, `0x` is hexadecimal, anything else is decimal,
    and underscores are allowed between digits.

    `bit_size` is 0 through 64, where 0 means the width of an `Int`. Raises
    with `ErrSyntax` when the text is not digits of that base, and with
    `ErrRange` when it is but does not fit.

    ```mojo
    from core.strconv import parse_uint

    def main() raises:
        print(parse_uint("ff", 16, 8))  # 255
        print(parse_uint("0x_ff", 0, 64))  # 255
    ```
    """
    return _parse_uint(s, base, bit_size, "parse_uint", s)


def parse_int[
    o: ImmOrigin
](s: StringSlice[o], base: Int, bit_size: Int) raises -> Int64:
    """`s` as a signed number in `base`, fitting `bit_size` bits.

    Go's `ParseInt`. A leading `+` or `-` is allowed and the rest is
    `parse_uint`, so everything that says about bases, underscores and bit
    sizes applies here too.

    The negative side reaches one further than the positive side, so
    `parse_int("-128", 10, 8)` is fine and `parse_int("128", 10, 8)` raises
    with `ErrRange`.
    """
    return _parse_int_named(s, base, bit_size, "parse_int")


def atoi[o: ImmOrigin](s: StringSlice[o]) raises -> Int:
    """`s` as a base 10 `Int`. Go's `Atoi`.

    `parse_int(s, 10, 0)` with the result narrowed, which on every platform
    here is not a narrowing at all. Go's fast path for short inputs is not
    ported: it exists to skip the general loop, and the general loop is the
    same loop.

    ```mojo
    from core.strconv import atoi

    def main() raises:
        print(atoi("42") + 1)  # 43
    ```
    """
    return Int(_parse_int_named(s, 10, 0, "atoi"))


def _parse_int_named[
    o: ImmOrigin
](
    s: StringSlice[o],
    base: Int,
    bit_size: Int,
    func: StringSlice[ImmStaticOrigin],
) raises -> Int64:
    """`parse_int` under another name, so `atoi` blames `atoi`."""
    var data = s.as_bytes()
    if len(data) == 0:
        raise _syntax_error(func, s)

    var neg = False
    var body = s
    if data[0] == _PLUS:
        body = s[byte = 1 : s.byte_length()]
    elif data[0] == _MINUS:
        body = s[byte = 1 : s.byte_length()]
        neg = True

    var un = _parse_uint(body, base, bit_size, func, s)

    var bits = bit_size
    if bits == 0:
        bits = INT_SIZE

    var cutoff = UInt64(1) << UInt64(bits - 1)
    if not neg and un >= cutoff:
        raise _range_error(func, s)
    if neg and un > cutoff:
        raise _range_error(func, s)

    if neg:
        return Int64((~un + 1).cast[DType.int64]())
    return Int64(un.cast[DType.int64]())
