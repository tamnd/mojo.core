"""Helpers shared by the `core.slices` tests.

The cursor here is the only non-obvious one. `core.slices`'s consumers take a
`core.iter.Cursor`, and this library has no infallible cursor to hand them —
deliberately, because `core/iter/cursor.mojo` says a list iterator is not a
cursor. So the tests bring their own, and it can be told to fail at a chosen
element, which is how the "what does a half-read sequence leave behind"
questions get asked.
"""

from core.iter import Cursor


def nan() -> Float64:
    """A NaN built at run time, so the compiler cannot fold comparisons against
    it into constants and quietly test nothing."""
    var zero = Float64(0.0)
    return zero / zero


struct Ints(Cursor, Deinitable, Movable):
    """A cursor over a list of `Int` that can be told to fail part way."""

    comptime Element = Int

    var _values: List[Int]
    var _index: Int
    var _fail_at: Int

    def __init__(out self, var values: List[Int]):
        self._values = values^
        self._index = 0
        self._fail_at = -1

    def __init__(out self, var values: List[Int], *, fail_at: Int):
        self._values = values^
        self._index = 0
        self._fail_at = fail_at

    def has_next(mut self) raises -> Bool:
        return self._index < len(self._values)

    def next(mut self) raises -> Int:
        if self._index == self._fail_at:
            raise Error(String("fixture: failed at element ", self._index))
        if self._index >= len(self._values):
            raise Error("fixture: past the end")
        self._index += 1
        return self._values[self._index - 1]


def counted(n: Int) -> List[Int]:
    """`[0, 1, ..., n - 1]`."""
    var out = List[Int](capacity=n)
    for i in range(n):
        out.append(i)
    return out^
