# PINS: 9. Real OS threads are available through libc
# TOOLCHAIN: Mojo 1.0
# EXPECT: runs
# OUTPUT: added 5 then swapped True leaving 9
# WHY: Atomic add and compare and swap, which sync and sync.atomic are built
# WHY: on. This is the Mojo 1.0 spelling. Mojo 1.1 renamed the parameter from a
# WHY: DType to a type, so there are two of these and the runner picks by the
# WHY: version the compiler reports.
# WHY:
# WHY: These come from the language rather than from libc, because the
# WHY: compiler's __atomic_fetch_add_8 and friends do not link on Linux
# WHY: without libatomic, and because an atomic the compiler cannot see is no
# WHY: use for a memory model anyway.

from std.atomic import Atomic


def main():
    var cell = Atomic[DType.int64](0)
    var previous = cell.fetch_add(5)
    var expected = Int64(5)
    var swapped = cell.compare_exchange(expected, 9)
    print(
        "added", previous + 5, "then swapped", swapped, "leaving", cell.load()
    )
