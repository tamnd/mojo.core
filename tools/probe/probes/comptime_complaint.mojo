# PINS: 10. A compile time fact cannot be turned into a compile error
# EXPECT: runs
# OUTPUT: three bad rings and one good one: ring 6 ring 10 ring 6 ring 8
# WARNINGS: 2
# WHY: The mechanism section 10 settles on, and every compile time check in
# WHY: this library rests on it. A `comptime` binding whose value is read is
# WHY: folded by an interpreter that runs our code, so a print in that code
# WHY: prints while the program is built. The three bad calls below are two
# WHY: distinct instantiations and produce two complaints, one each, and the
# WHY: good one says nothing. That is the whole point: the complaint is
# WHY: conditional and `@deprecated` is not.
# WHY: The empty string is load bearing. A binding nothing reads is never
# WHY: folded and never prints, so the value has to reach the result.
# WHY: If this reports 0, every compile time check in the library has gone
# WHY: quiet at once and nothing else would have said so.


def complain(message: String) -> StaticString:
    print(message)
    return ""


def is_power_of_two(n: Int) -> Bool:
    return n > 0 and (n & (n - 1)) == 0


def ring[n: Int]() -> String:
    var out = String("ring ")
    comptime if not is_power_of_two(n):
        comptime said = complain(String("core: ", n, " is not a power of two"))
        out += said
    out += String(n)
    return out^


def main():
    print(
        "three bad rings and one good one:",
        ring[6](),
        ring[10](),
        ring[6](),
        ring[8](),
    )
