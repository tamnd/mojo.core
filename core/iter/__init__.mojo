"""Fallible iteration. Go's `iter`, which turns out to be a different problem.

Go's `iter` is four range-over-func symbols, `Seq`, `Seq2`, `Pull` and
`Pull2`, and all four need a closure that can be stored, which design.md
section 3 says does not exist here. So this package is not a port of that one.
It holds the thing this library needs instead: `Cursor`, the `has_next` and
`next` pair that every iterator which can fail has to be written as, because
a `for` loop swallows an error raised out of `__next__`.

`cursor.mojo` has the trait and the contract that goes with it. There is no
second trait for two-value iteration: Go needs `Seq2` because a
range-over-func has a fixed arity, and a `Cursor` whose `Element` is a tuple
covers it.
"""

from .cursor import Cursor
