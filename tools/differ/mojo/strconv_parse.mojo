"""Our side of the `strconv-parse` differ area.

One line per generated string: the string itself, then what each of the five
parsers made of it, either the exact bits of the answer or the name of the
failure. The Go program in `tools/differ/go/strconvparse` prints the same line
from Go's `strconv`, and the two files have to be read together, because the
whole check is that the fields line up and only the answers can differ.

The strings are made rather than drawn from a table, and eight shapes make them:
plain digits, a decimal with a point and an exponent, a hexadecimal float, the
words for infinity and not a number, digits with underscores in them, outright
junk, a few hundred digits at once, and a small mantissa with an exponent near
the ends of the range. The last two are the ones that reach the exact big
decimal path behind Eisel-Lemire, which is where a parser that is nearly right
goes wrong.

Where the two sides cannot agree by construction is the value beside a range
failure. Go returns the clamped infinity and the error together, and a raise
carries no value, so a failing field prints the failure and nothing else. That
is the deviation this area cannot check and `docs/deviations.md` records.
"""

from std.memory import bitcast
from std.sys import argv

from core.errors import matches
from core.errors.codes import ErrBase, ErrBitSize, ErrRange, ErrSyntax
from core.strconv import parse_float, parse_int, parse_uint


comptime _CHUNK = 4096
"""How many lines to hold before writing."""

comptime _GAP = UInt64(2862933555777941757)
"""The stride between one input's seed and the next."""

comptime _DIGITS = "0123456789"
comptime _HEX = "0123456789abcdefABCDEF"
comptime _JUNK = "0123456789abcdefxXpP+-._eE"

comptime _WORD_COUNT = 12
"""How many spellings `_word` has. A `comptime` list of `String` cannot be read
at run time, so the count is here and the list is built where it is used."""


def _flag(name: String, fallback: Int) raises -> Int:
    """One `--name value` argument, or `fallback` when it is not there."""
    var args = argv()
    for index in range(len(args)):
        if String(args[index]) == name and index + 1 < len(args):
            return Int(String(args[index + 1]))
    return fallback


def _mix(state: UInt64) -> UInt64:
    """One splitmix64 step. The same three lines are in the Go program."""
    var z = state + 0x9E3779B97F4A7C15
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    return z ^ (z >> 31)


def _hex(value: UInt64, width: Int) -> String:
    """`value` in upper case hexadecimal, zero padded to `width`."""
    var digits = String(hex(value)[byte=2:]).upper()
    var out = String()
    for _ in range(width - digits.byte_length()):
        out += "0"
    out += digits
    return out


struct _Stream(Copyable, Movable):
    """The shared source of choices.

    Every decision either program makes comes from `next()` and the two make
    them in the same written order, which is the whole reason both sides
    produce the same string. A call added to one side and not the other shifts
    every choice after it and every line diverges, which is the loud failure
    rather than the quiet one.
    """

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> UInt64:
        self.state = _mix(self.state)
        return self.state

    def below(mut self, n: Int) -> Int:
        return Int(self.next() % UInt64(n))

    def pick(mut self, alphabet: String, n: Int) -> String:
        var out = String()
        for _ in range(n):
            var at = self.below(alphabet.byte_length())
            out += alphabet[byte = at : at + 1]
        return out^

    def sign(mut self) -> String:
        var choice = self.below(3)
        if choice == 0:
            return "-"
        if choice == 1:
            return "+"
        return ""


def _word(index: Int) -> String:
    """One of the words Go's parser knows, and the spellings it refuses next to
    them. Built here rather than held as a constant, because a list of `String`
    cannot be a compile time value."""
    var words: List[String] = [
        "inf",
        "Inf",
        "INF",
        "+inf",
        "-inf",
        "infinity",
        "Infinity",
        "-INFINITY",
        "nan",
        "NaN",
        "NAN",
        "+nan",
    ]
    return words[index]


def _text(mut s: _Stream, shape: Int) -> String:
    """The string this input stands for. Eight shapes, one per line of the switch.
    """
    if shape == 0:
        var sign = s.sign()
        var n = 1 + s.below(20)
        return sign + s.pick(_DIGITS, n)
    if shape == 1:
        var sign = s.sign()
        var whole = s.pick(_DIGITS, 1 + s.below(17))
        var frac = s.pick(_DIGITS, s.below(17))
        var out = sign + whole + "." + frac
        if s.below(2) == 0:
            var mark = "e" if s.below(2) == 0 else "E"
            var esign = s.sign()
            out += mark + esign + s.pick(_DIGITS, 1 + s.below(3))
        return out^
    if shape == 2:
        var sign = s.sign()
        var whole = s.pick(_HEX, 1 + s.below(14))
        var frac = s.pick(_HEX, s.below(14))
        var mark = "p" if s.below(2) == 0 else "P"
        var esign = s.sign()
        var exp = s.pick(_DIGITS, 1 + s.below(3))
        return sign + "0x" + whole + "." + frac + mark + esign + exp
    if shape == 3:
        return _word(s.below(_WORD_COUNT))
    if shape == 4:
        # Underscores, which Go allows between digits and only there, so half
        # of these are legal and half are the mistakes next door to legal.
        var sign = s.sign()
        var body = String()
        var n = 1 + s.below(12)
        for index in range(n):
            body += s.pick(_DIGITS, 1)
            if index + 1 < n and s.below(3) == 0:
                body += "_"
        var out = sign + body
        if s.below(4) == 0:
            out = sign + "0x_" + body
        return out^
    if shape == 5:
        return s.pick(_JUNK, 1 + s.below(8))
    if shape == 6:
        var sign = s.sign()
        var body = s.pick(_DIGITS, 100 + s.below(300))
        var out = sign + body
        if s.below(2) == 0:
            var esign = s.sign()
            out += "e" + esign + s.pick(_DIGITS, 1 + s.below(3))
        return out^
    var sign = s.sign()
    var mantissa = s.pick(_DIGITS, 1 + s.below(17))
    var esign = s.sign()
    return sign + mantissa + "e" + esign + s.pick(_DIGITS, 1 + s.below(3))


def _failure(e: Error) -> String:
    """The name of a failure, which is what a raise has instead of a value."""
    if matches(e, ErrSyntax):
        return "syntax"
    if matches(e, ErrRange):
        return "range"
    if matches(e, ErrBase):
        return "base"
    if matches(e, ErrBitSize):
        return "bits"
    return "other"


def _float(text: String, bit_size: Int) -> String:
    """`parse_float` as a field: the bits, or the failure."""
    try:
        var f = parse_float(text, bit_size)
        if bit_size == 32:
            return _hex(UInt64(bitcast[DType.uint32](Float32(f))), 8)
        return _hex(bitcast[DType.uint64](f), 16)
    except e:
        return _failure(e)


def _signed(text: String, base: Int) -> String:
    """`parse_int` as a field: the bits of the answer, or the failure."""
    try:
        return _hex(bitcast[DType.uint64](parse_int(text, base, 64)), 16)
    except e:
        return _failure(e)


def _unsigned(text: String, base: Int) -> String:
    """`parse_uint` as a field: the answer, or the failure."""
    try:
        return _hex(parse_uint(text, base, 64), 16)
    except e:
        return _failure(e)


def main() raises:
    var count = _flag("--count", 10000)
    var seed = _flag("--seed", 1)

    var buffered = 0
    var out = String()
    for index in range(count):
        var w = _mix(UInt64(seed) + UInt64(index) * _GAP + 1)
        var stream = _Stream(w)
        var text = _text(stream, Int(w % 8))

        out += text
        out += " "
        out += _float(text, 64)
        out += " "
        out += _float(text, 32)
        out += " "
        out += _signed(text, 10)
        out += " "
        out += _signed(text, 0)
        out += " "
        out += _unsigned(text, 0)
        out += "\n"

        buffered += 1
        if buffered == _CHUNK:
            print(out, end="")
            out = String()
            buffered = 0
    if buffered != 0:
        print(out, end="")
