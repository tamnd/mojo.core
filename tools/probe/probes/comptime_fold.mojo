# PINS: 10. A compile time fact cannot be turned into a compile error
# EXPECT: runs
# OUTPUT: folded 21 and branched on the answer
# WHY: The good half of section 10. A plain def really does run at compile
# WHY: time and comptime if really does branch on the result, which is what
# WHY: makes compile time format string checking possible at all.


def triple(x: Int) -> Int:
    return x * 3


def verbs(format: StaticString) -> Int:
    var count = 0
    var bytes = format.as_bytes()
    for i in range(format.byte_length()):
        if bytes[i] == Byte(37):
            count += 1
    return count


def main():
    comptime folded = triple(7)
    comptime found = verbs("%s owes %d")
    comptime if found == 2:
        print("folded", folded, "and branched on the answer")
    else:
        print("folded", folded, "and took the wrong branch")
