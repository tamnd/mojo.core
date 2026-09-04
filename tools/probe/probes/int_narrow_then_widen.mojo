# PINS: Smaller facts that change how code is written
# EXPECT: runs
# OUTPUT: inline 4294956496 named 4294956496 cast 4294956496 arithmetic -10800
# WHY: Reading a signed number out of a binary format means taking bits that
# WHY: arrived unsigned and widening them as signed, and the three obvious ways
# WHY: to write that are all wrong here: where the narrow value has no other
# WHY: use, the narrowing is dropped and the original is zero extended. It is a
# WHY: wrong answer rather than a refusal, and a literal folds to the right one,
# WHY: so it only shows up on values that came from a file. `core.time`'s TZif
# WHY: reader hit it and every zone west of Greenwich was hours out. The fourth
# WHY: line is what that reader does instead. If this probe ever prints
# WHY: -10800 four times the workaround can go.

from std.sys import argv

comptime BITS = UInt32(0xFFFFD5D0)
"""Minus three hours as four bytes, which is what a zone file holds for a good
part of the Americas."""


def main() raises:
    # Out of a list at a runtime index, because a constant folds and folding
    # gives the right answer. `len(argv())` is one here and the compiler has no
    # way to know it.
    var choices: List[UInt32] = [UInt32(0), BITS]
    var raw = choices[len(argv())]

    var inline = Int(Int32(raw))

    # A named intermediate, which is the first thing to try and does not help.
    # It has to stay unused apart from this line: printing it is a second use,
    # and then the narrowing survives and the answer is right.
    var narrow = Int32(raw)
    var named = Int(narrow)

    var cast = Int(Int32(raw).cast[DType.int64]())

    # Arithmetic instead of a conversion. Nothing here can be folded away
    # without changing the value, so this one is right whatever happens to the
    # three above.
    var arithmetic: Int
    if raw >= 0x8000_0000:
        arithmetic = Int(raw) - 0x1_0000_0000
    else:
        arithmetic = Int(raw)

    print(
        "inline",
        inline,
        "named",
        named,
        "cast",
        cast,
        "arithmetic",
        arithmetic,
    )
