"""`Cursor`, and the failure it exists to stop being silent.

The point of this trait is negative: a `for` loop drops an error raised out of
`__next__`, so a reader that fails halfway looks like one that finished. A
test that only walked a cursor to the end would pass against a design with
that hole in it, so most of what is here is the failing cases, and the shared
`drain` is written the way the rule says a caller has to write it.

`Halts` is the argument in one type. It yields two elements and then fails,
and `drain` over it raises. The same struct behind a Mojo `__iter__` and a
`for` loop would return two elements and no error at all, which is what
`tools/probe/probes/for_swallows_raise.mojo` pins.
"""

from std.testing import assert_equal, assert_true

from core.iter import Cursor


struct Countdown(Cursor):
    """A cursor that cannot fail, to show the shape without the noise."""

    comptime Element = Int

    var left: Int

    var asked: Int
    """How many times `has_next` was called, so a test can see that the loop
    asks once per element plus once for the end."""

    def __init__(out self, from_: Int):
        self.left = from_
        self.asked = 0

    def has_next(mut self) raises -> Bool:
        self.asked += 1
        return self.left > 0

    def next(mut self) raises -> Int:
        if self.left == 0:
            raise Error("countdown: past the end")
        self.left -= 1
        return self.left


struct Halts(Cursor):
    """Yields `before` elements and then fails, which is the case that matters.

    The failure is in `next` rather than `has_next` because that is the
    awkward side: the loop has already been told there is another element and
    is committed to asking for it.
    """

    comptime Element = Int

    var seen: Int
    var before: Int

    def __init__(out self, before: Int):
        self.seen = 0
        self.before = before

    def has_next(mut self) raises -> Bool:
        return True

    def next(mut self) raises -> Int:
        if self.seen == self.before:
            raise Error("halts: broke at element " + String(self.seen))
        self.seen += 1
        return self.seen


struct Peeks(Cursor):
    """Fails on the other side, out of `has_next`, which a reader does.

    Answering whether there is another record can mean parsing one, so this is
    not a hypothetical arrangement. It is the csv shape, and it is why both
    methods on the trait are allowed to raise.
    """

    comptime Element = Int

    var seen: Int
    var before: Int

    def __init__(out self, before: Int):
        self.seen = 0
        self.before = before

    def has_next(mut self) raises -> Bool:
        if self.seen == self.before:
            raise Error("peeks: broke while looking ahead")
        return True

    def next(mut self) raises -> Int:
        self.seen += 1
        return self.seen


struct Owned(Deinitable, Movable):
    """An element a `Copyable` bound would have refused."""

    var n: Int

    def __init__(out self, n: Int):
        self.n = n


struct Handles(Cursor):
    """A cursor over one of those, so the bound is tested and not just read."""

    comptime Element = Owned

    var left: Int

    def __init__(out self, from_: Int):
        self.left = from_

    def has_next(mut self) raises -> Bool:
        return self.left > 0

    def next(mut self) raises -> Owned:
        if self.left == 0:
            raise Error("handles: past the end")
        self.left -= 1
        return Owned(self.left)


def drain[C: Cursor](mut cursor: C) raises -> Int:
    """The loop the rule asks for, written once and reused below."""
    var seen = 0
    while cursor.has_next():
        _ = cursor.next()
        seen += 1
    return seen


def first_of[C: Cursor](mut cursor: C) raises -> C.Element:
    """Names `C.Element` off the bound, which is the associated type working."""
    return cursor.next()


def test_a_cursor_that_cannot_fail_runs_to_the_end() raises:
    var c = Countdown(4)
    assert_equal(drain(c), 4)


def test_the_loop_asks_once_per_element_and_once_for_the_end() raises:
    var c = Countdown(4)
    _ = drain(c)
    assert_equal(c.asked, 5)


def test_next_past_the_end_raises_rather_than_returning_a_zero() raises:
    var c = Countdown(0)
    assert_equal(drain(c), 0)
    var raised = False
    try:
        _ = c.next()
    except e:
        raised = True
        assert_true("past the end" in String(e))
    assert_true(raised, "a cursor with nothing left must raise, not return 0")


def test_a_failure_in_next_reaches_the_caller() raises:
    var c = Halts(2)
    var raised = False
    try:
        _ = drain(c)
    except e:
        raised = True
        assert_true("broke at element 2" in String(e))
    assert_true(raised, "the loop must not end quietly on a failure")


def test_the_elements_before_the_failure_still_came_out() raises:
    var c = Halts(2)
    assert_equal(c.next(), 1)
    assert_equal(c.next(), 2)
    var raised = False
    try:
        _ = c.next()
    except e:
        raised = True
    assert_true(raised, "the third call is the one that fails")


def test_a_failure_in_has_next_reaches_the_caller() raises:
    var c = Peeks(3)
    var raised = False
    try:
        _ = drain(c)
    except e:
        raised = True
        assert_true("looking ahead" in String(e))
    assert_true(raised, "a cursor may fail while looking ahead")


def test_a_generic_function_can_name_the_element_type() raises:
    var c = Countdown(3)
    assert_equal(first_of(c), 2)


def test_an_element_that_is_not_copyable_is_allowed() raises:
    var c = Handles(3)
    assert_equal(drain(c), 3)


def test_an_element_that_is_not_copyable_comes_out_whole() raises:
    var c = Handles(3)
    var first = c.next()
    assert_equal(first.n, 2)
    assert_true(c.has_next())
