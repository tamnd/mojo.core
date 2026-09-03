"""Our side of the `strconv-floats` differ area.

One line per float: the bits it was built from, the same number written out in
fourteen ways at 64 bits and four ways at 32, and then the shortest form read
back, so that the line covers formatting and the parser's agreement with it at
once. The Go program in `tools/differ/go/strconvfloats` prints the same line
from Go's `strconv`, and the two files have to be read together, because the
whole check is that the fields line up and only the answers can differ.

The floats are made rather than drawn from a table, because a table is the
cases somebody thought of. `--seed` picks the stream and `--count` says how
many, and the two sides build the same stream from the same arithmetic: a
splitmix64 step per input, then one of four shapes chosen by two bits of it.
The shapes exist because uniformly random bits are almost all enormous
exponents, and the interesting failures are near one, near zero and on numbers
a person would type.
"""

from std.memory import bitcast
from std.sys import argv

from core.strconv import format_float, parse_float


comptime _CHUNK = 4096
"""How many lines to hold before writing. A print per line turns a check that
takes seconds into one that takes minutes."""

comptime _GAP = UInt64(2862933555777941757)
"""The stride between one input's seed and the next. Knuth's multiplier, used
here only because two adjacent seeds have to land far apart."""


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
    """`value` in upper case hexadecimal, zero padded to `width`, as Go's `%0*X`.
    """
    var digits = String(hex(value)[byte=2:]).upper()
    var out = String()
    for _ in range(width - digits.byte_length()):
        out += "0"
    out += digits
    return out


def _pow10(n: Int) -> Float64:
    """`10^n` for `n` up to 18, by multiplication, which is exact that far."""
    var scale = Float64(1)
    for _ in range(n):
        scale = scale * 10.0
    return scale


def _value(w: UInt64) -> Float64:
    """The float this word stands for. Four shapes, chosen by its low two bits.

    Shape 0 is the raw bits, so NaNs, infinities and the far ends of the
    exponent range all turn up. Shape 1 keeps the mantissa and puts the
    exponent within 32 of one, which is where the shortest form has the most
    digits to choose between. Shape 2 clears the exponent, so it is zero and
    the subnormals. Shape 3 is a ratio of two integers, which is what a number
    somebody typed looks like by the time it is a float.
    """
    var shape = w & 3
    var m = w & 0x800FFFFFFFFFFFFF
    if shape == 0:
        return bitcast[DType.float64](w)
    if shape == 1:
        var exp = 991 + ((w >> 52) & 63)
        return bitcast[DType.float64](m | (exp << 52))
    if shape == 2:
        return bitcast[DType.float64](m)
    var num = Float64(w % 1000000000000000000)
    return num / _pow10(Int((w >> 60) % 16))


def _f32(w: UInt64, value: Float64) -> Float64:
    """The float32 half of the line, held in a Float64 as the API takes it.

    Half the words give their top 32 bits straight to a float32 and half round
    the float64 above, for the same reason the shapes exist: raw bits and a
    number that came from somewhere are different populations.
    """
    if (w & 1) == 0:
        return Float64(bitcast[DType.float32](UInt32(w >> 32)))
    return Float64(Float32(value))


def main() raises:
    var count = _flag("--count", 10000)
    var seed = _flag("--seed", 1)

    # (format byte, precision) for the 64 bit half, then for the 32 bit half.
    # Every formatter in the package is on this list: shortest, fixed exponent,
    # fixed point, the shorter of the two, and hexadecimal.
    var wide: List[Tuple[String, Int]] = [
        ("b", -1),
        ("e", -1),
        ("e", 5),
        ("E", 17),
        ("f", -1),
        ("f", 0),
        ("f", 8),
        ("g", -1),
        ("g", 1),
        ("g", 3),
        ("G", 17),
        ("x", -1),
        ("x", 3),
        ("X", 13),
    ]
    var narrow: List[Tuple[String, Int]] = [
        ("g", -1),
        ("e", 9),
        ("f", -1),
        ("x", -1),
    ]

    var buffered = 0
    var out = String()
    for index in range(count):
        var w = _mix(UInt64(seed) + UInt64(index) * _GAP + 1)
        var value = _value(w)
        var half = _f32(w, value)

        out += _hex(bitcast[DType.uint64](value), 16)
        for spec in wide:
            out += " "
            out += format_float(value, UInt8(ord(spec[0])), spec[1], 64)
        for spec in narrow:
            out += " "
            out += format_float(half, UInt8(ord(spec[0])), spec[1], 32)

        # The shortest form read back. It is the one property the package
        # promises that no single formatting check can see.
        var shortest = format_float(value, UInt8(ord("g")), -1, 64)
        out += " "
        try:
            var back = parse_float(shortest, 64)
            out += _hex(bitcast[DType.uint64](back), 16)
        except:
            out += "unreadable"
        out += "\n"

        buffered += 1
        if buffered == _CHUNK:
            print(out, end="")
            out = String()
            buffered = 0
    if buffered != 0:
        print(out, end="")
