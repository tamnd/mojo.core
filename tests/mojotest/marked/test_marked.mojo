"""One wrong format string, so that the check for one can be shown to work.

The suite build fails when a line of it carries this library's marker, which is
what keeps a wrong format string out of `core`. A check that has never fired is
a check nobody knows works, so this is the file that fires it, and
`pixi run test --selftest` builds it and asserts the failure.

It is skipped by every other run. Nothing here is a test of `core.fmt`, which
is what tests/fmt and tests/warnings are for.
"""

from std.testing import assert_equal

from core.fmt import sprintf


def test_wrong_verb() raises:
    """`%d` cannot print a string, which is a complaint and then a marker."""
    assert_equal(sprintf["%d"](String("hi")), "%!d(string=hi)")
