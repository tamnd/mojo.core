# A fixture, excluded from the real suite. This one is supposed to pass, so
# that `pixi run test-selftest` is checking that the runner separates a failure
# from a pass rather than that it fails everything.

from std.testing import assert_equal, assert_true


def test_arithmetic() raises:
    assert_equal(2 + 2, 4)


def test_truth() raises:
    assert_true(True, "True is true")
