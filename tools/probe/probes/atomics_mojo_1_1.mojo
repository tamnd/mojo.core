# PINS: 9. Real OS threads are available through libc
# TOOLCHAIN: Mojo 1.1
# EXPECT: runs
# OUTPUT: added 5 then swapped True leaving 9
# WHY: The same probe as atomics_mojo_1_0, in the spelling Mojo 1.1 wants.
# WHY: Atomic takes a type now rather than a DType. When 1.1 becomes the
# WHY: pinned toolchain the 1.0 file goes and this one loses its TOOLCHAIN
# WHY: line.

from std.atomic import Atomic


def main():
    var cell = Atomic[Int64](0)
    var previous = cell.fetch_add(5)
    var expected = Int64(5)
    var swapped = cell.compare_exchange(expected, 9)
    print(
        "added", previous + 5, "then swapped", swapped, "leaving", cell.load()
    )
