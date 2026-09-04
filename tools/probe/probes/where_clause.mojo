# PINS: 10. A compile time fact cannot be turned into a compile error
# EXPECT: rejected
# ERROR: lacking evidence to prove correctness
# ERROR: cannot evaluate call to non-builtin function
# WHY: The bad half of section 10. A where clause is proof carrying rather
# WHY: than evaluating, so it refuses this call even though 8 satisfies it.
# WHY: If this ever compiles, every compile time check in this library
# WHY: becomes a real compile error, and the complaint printed from the
# WHY: interpreter by comptime_complaint.mojo can go.


def is_power_of_two(n: Int) -> Bool:
    return n > 0 and (n & (n - 1)) == 0


def ring[n: Int]() -> Int where is_power_of_two(n):
    return n


def main():
    print(ring[8]())
