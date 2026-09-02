"""Shared helpers for the `core.maps` tests.

A `Dict` iterates in some order and `core.maps` promises nothing about which,
so almost every test here sorts before it compares. `ordered` is that, and it
is a function rather than a line repeated in thirty places because a test that
sorts one side and forgets the other passes for the wrong reason.
"""

from core.iter import Cursor
from core.slices import sort


def ordered[T: Comparable & Copyable & Deinitable](var xs: List[T]) -> List[T]:
    """`xs`, sorted, so that an unordered result can be compared to a written one.
    """
    sort(Span(xs))
    return xs^


struct Pairs(Cursor, Deinitable, Movable):
    """A fallible source of key and value pairs.

    `core.maps.collect` cannot take one of these, which is the deviation
    `seq.mojo` argues for, so this exists to test the route it points at
    instead: drain it with `core.slices.collect` and hand the list over.
    """

    comptime Element = Tuple[String, Int]

    var _pairs: List[Tuple[String, Int]]
    var _index: Int
    var _fail_at: Int

    def __init__(out self, var pairs: List[Tuple[String, Int]]):
        self._pairs = pairs^
        self._index = 0
        self._fail_at = -1

    def __init__(
        out self, var pairs: List[Tuple[String, Int]], *, fail_at: Int
    ):
        self._pairs = pairs^
        self._index = 0
        self._fail_at = fail_at

    def has_next(mut self) raises -> Bool:
        return self._index < len(self._pairs)

    def next(mut self) raises -> Self.Element:
        if self._index == self._fail_at:
            raise Error("fixture: failed at pair ", self._index)
        if self._index >= len(self._pairs):
            raise Error("fixture: past the end")
        self._index += 1
        return (
            self._pairs[self._index - 1][0].copy(),
            self._pairs[self._index - 1][1],
        )


def ages() -> Dict[String, Int]:
    """Three entries, distinct keys, one repeated value.

    The repeat is deliberate: `values` does not deduplicate and a version that
    did would still pass on a dict where every value differs.
    """
    return {String("ana"): 31, String("bo"): 27, String("cy"): 31}
