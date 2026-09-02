# PINS: 10. A compile time fact cannot be turned into a compile error
# EXPECT: runs
# OUTPUT: three bad rings and one good one sum to 30
# WARNINGS: 1
# WHY: The mechanism section 10 settles on, and its limit. Three bad
# WHY: instantiations at three separate call sites produce exactly one
# WHY: warning, because the warning belongs to the line the deprecated stub is
# WHY: called on and not to the instantiation. So this tells you a check fired
# WHY: and not which call was wrong, and the WARNINGS count above is what
# WHY: would change if that were ever fixed.


@deprecated("core: n must be a power of two")
def bad_n():
    pass


def is_power_of_two(n: Int) -> Bool:
    return n > 0 and (n & (n - 1)) == 0


def ring[n: Int]() -> Int:
    comptime if not is_power_of_two(n):
        bad_n()
    return n


def main():
    var a = ring[6]()
    var b = ring[6]()
    var c = ring[10]()
    var d = ring[8]()
    print("three bad rings and one good one sum to", a + b + c + d)
