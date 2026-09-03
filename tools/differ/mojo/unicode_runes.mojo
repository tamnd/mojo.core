"""Our side of the `unicode-runes` differ area.

One line per code point, holding every answer this package gives about it: a
bitmask of the thirteen predicates and then the five mappings. The Go program
in `tools/differ/go/unicoderunes` prints the same line from Go's `unicode`, and
the two files have to be read together, because the whole check is that the
formatting is identical and only the answers can differ.

`--count` is how many code points to print, always starting at zero, so the
nightly run passes 1114112 and covers every code point there is. `--seed` is
accepted and ignored: there is nothing random about a character database, and
starting at zero every time is what makes the differ's case index the code
point that diverged, so a divergence names itself.
"""

from std.sys import argv

from core import unicode

comptime _CHUNK = 8192
"""How many lines to hold before writing. A print per code point on a whole
run is a million write calls and turns a two second check into a minute."""


def _flag(name: String, fallback: Int) raises -> Int:
    """One `--name value` argument, or `fallback` when it is not there."""
    var args = argv()
    for index in range(len(args)):
        if String(args[index]) == name and index + 1 < len(args):
            return Int(String(args[index + 1]))
    return fallback


def _hex(value: Int, width: Int) -> String:
    """`value` in upper case hexadecimal, zero padded to `width`, as Go's `%0*X`."""
    var digits = String(hex(value)[byte=2:]).upper()
    var out = String()
    for _ in range(width - digits.byte_length()):
        out += "0"
    out += digits
    return out


def _mask(r: Int32) -> Int:
    """The thirteen predicates as bits, alphabetically by Go's names.

    The order is the order in the Go program's `mask`, and the two are meant to
    be read side by side. A predicate added to one and not the other shifts
    every bit above it and every line diverges, which is the loud failure
    rather than the quiet one.

    Written out rather than looped over a list, because a list here is an
    allocation per code point and the whole run asks this question 1,114,112
    times.
    """
    var out = 0
    if unicode.is_control(r):
        out |= 1 << 0
    if unicode.is_digit(r):
        out |= 1 << 1
    if unicode.is_graphic(r):
        out |= 1 << 2
    if unicode.is_letter(r):
        out |= 1 << 3
    if unicode.is_lower(r):
        out |= 1 << 4
    if unicode.is_mark(r):
        out |= 1 << 5
    if unicode.is_number(r):
        out |= 1 << 6
    if unicode.is_print(r):
        out |= 1 << 7
    if unicode.is_punct(r):
        out |= 1 << 8
    if unicode.is_space(r):
        out |= 1 << 9
    if unicode.is_symbol(r):
        out |= 1 << 10
    if unicode.is_title(r):
        out |= 1 << 11
    if unicode.is_upper(r):
        out |= 1 << 12
    return out


def main() raises:
    var count = _flag("--count", 10000)
    # Built once. It owns a list of four case ranges, so building it inside the
    # loop would be a million allocations to answer a question about four code
    # points.
    var turkish = unicode.TurkishCase()

    var buffered = 0
    var out = String()
    for index in range(count):
        var r = Int32(index)
        if r > unicode.MAX_RUNE:
            break
        out += _hex(Int(r), 6)
        out += " "
        out += _hex(_mask(r), 4)
        out += " "
        out += _hex(Int(unicode.to_upper(r)), 6)
        out += " "
        out += _hex(Int(unicode.to_lower(r)), 6)
        out += " "
        out += _hex(Int(unicode.to_title(r)), 6)
        out += " "
        out += _hex(Int(unicode.simple_fold(r)), 6)
        out += " "
        out += _hex(Int(turkish.to_upper(r)), 6)
        out += " "
        out += _hex(Int(turkish.to_lower(r)), 6)
        out += "\n"
        buffered += 1
        if buffered == _CHUNK:
            print(out, end="")
            out = String()
            buffered = 0
    if buffered != 0:
        print(out, end="")
