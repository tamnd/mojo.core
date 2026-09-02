# A fixture, excluded from the real suite. This one carries the slow marker, so
# that `pixi run test-selftest` can check that --short actually drops it and
# that a full run does not.
#
# The marker is a comment on the line above the test rather than a list kept in
# the runner, because the person who writes a five minute test is the one who
# knows it is five minutes, and a list somewhere else goes stale.

from std.testing import assert_equal


# slow: stands in for the exhaustive float round trip, which takes minutes
def test_pretends_to_be_slow() raises:
    assert_equal(1 + 1, 2)
