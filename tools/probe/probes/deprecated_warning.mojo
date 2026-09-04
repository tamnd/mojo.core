# PINS: 10. A compile time fact cannot be turned into a compile error
# EXPECT: runs
# OUTPUT: every ring here is good and sums to 24
# WARNINGS: 1
# WHY: Why section 10 does not use `@deprecated`, kept so that nobody spends a
# WHY: day rediscovering it. Every instantiation below is good, the branch
# WHY: holding the stub is never taken, and the warning is emitted anyway. It
# WHY: belongs to the line the stub is written on and not to any instantiation,
# WHY: so it fires on correct code and cannot distinguish one call from the
# WHY: next. If this ever reports 0 warnings, `@deprecated` has become
# WHY: conditional, and the complaint mechanism in comptime_complaint.mojo
# WHY: could be replaced by something that carries a source location.


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
    print("every ring here is good and sums to", ring[8]() + ring[16]())
