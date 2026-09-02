# A fixture. This test is supposed to fail, and `pixi run test-selftest` fails
# if the runner reports it as a pass. It is excluded from the real suite, so a
# normal `pixi run test` never sees it.
#
# What is being proved: a runner that swallows a failing test turns the whole
# suite into theatre, and nothing else in the repository would notice. The
# selftest asserts that this failure is reported at all, and that it arrives
# with the file, the line and both values rather than only saying they differ.

from std.testing import assert_equal


def test_two_and_two() raises:
    assert_equal(2 + 2, 5)
