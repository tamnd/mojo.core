"""Our side of the `strconv-float32` differ area.

Every float32 there is, written out and read back. One line per block of 2^20
of them, holding a hash of everything the formatter produced in the block and
the number of round trips that did not come back to the bits they started as.
4096 blocks is all 4,294,967,296 of them, which is what the nightly run does.

A hash rather than the strings themselves, because the strings are two hundred
gigabytes and the question being asked of them is only whether the two sides
agree. The block index is in the line, so a divergence names the block, and
`--count` narrows a rerun to it.

The Go program in `tools/differ/go/strconvfloat32` prints the same line from
Go's `strconv`. `--seed` is accepted and ignored: there is nothing random about
an enumeration, and starting at zero every time is what makes a divergence
reproducible from the line that reports it.
"""

from std.memory import bitcast
from std.sys import argv

from core.strconv import append_float, parse_float


comptime _BLOCK = 1 << 20
"""Floats per line. Small enough that a divergence names a narrow range and
large enough that the line count stays readable."""

comptime _BLOCKS = 1 << 12
"""Blocks in the whole enumeration. `_BLOCK * _BLOCKS` is every float32."""

comptime _FNV_OFFSET = UInt64(14695981039346656037)
comptime _FNV_PRIME = UInt64(1099511628211)


def _flag(name: String, fallback: Int) raises -> Int:
    """One `--name value` argument, or `fallback` when it is not there."""
    var args = argv()
    for index in range(len(args)):
        if String(args[index]) == name and index + 1 < len(args):
            return Int(String(args[index + 1]))
    return fallback


def _hex(value: UInt64, width: Int) -> String:
    """`value` in upper case hexadecimal, zero padded to `width`."""
    var digits = String(hex(value)[byte=2:]).upper()
    var out = String()
    for _ in range(width - digits.byte_length()):
        out += "0"
    out += digits
    return out


def main() raises:
    var count = _flag("--count", _BLOCKS)
    var g = UInt8(ord("g"))

    # Reused across the whole run. `append_float` writes into it rather than
    # building a `String` per float, which is four billion allocations saved.
    var buf = List[UInt8](capacity=32)

    var out = String()
    for block in range(count):
        if block >= _BLOCKS:
            break
        var hash = _FNV_OFFSET
        var broken = 0
        var start = UInt32(block) * UInt32(_BLOCK)
        for step in range(_BLOCK):
            var bits = start + UInt32(step)
            var f = bitcast[DType.float32](bits)
            buf.clear()
            _ = append_float(buf, Float64(f), g, -1, 32)
            var text = StringSlice(unsafe_from_utf8=Span(buf))

            # FNV-1a over the bytes of the shortest form, then one more round
            # over a zero byte, so that a boundary between two floats cannot
            # move without the hash noticing. Mixing a zero is the multiply on
            # its own, since the exclusive or with it changes nothing.
            for byte in buf:
                hash = (hash ^ UInt64(byte)) * _FNV_PRIME
            hash = hash * _FNV_PRIME

            # The round trip. A NaN comes back as some NaN rather than as the
            # same one, which is what Go promises too, so the payload is not
            # part of the question.
            var back = Float32(parse_float(text, 32))
            if f != f:
                if back == back:
                    broken += 1
            elif bitcast[DType.uint32](back) != bits:
                broken += 1

        out += _hex(UInt64(block), 4)
        out += " "
        out += _hex(hash, 16)
        out += " "
        out += String(broken)
        out += "\n"
        # One line per block is little enough to write as it is made, and a
        # block takes long enough that holding the line back would only make
        # the run look stalled.
        print(out, end="")
        out = String()
