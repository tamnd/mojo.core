"""The environment, read and written through the C library.

These three go through `getenv`, `setenv` and `unsetenv` rather than reading
`environ` directly, so the process the tests run in is the one being changed.
That is the point: `core.time` asks for `TZ` at the moment it needs it, and a
copy taken at start up would answer with what was set then.

Every test here puts back what it found. A variable left set changes what a
later test in the same process sees, and `TZ` in particular changes what the
whole library thinks the local zone is.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.syscall import getenv, getpid, setenv, unsetenv


def _name(suffix: String) -> String:
    """A variable name nothing else will be using.

    The process id is in it so that two suites on one machine do not land on
    each other, the same as the scratch directories in `test_calls.mojo`.
    """
    return String("MOJO_CORE_TEST_", getpid(), "_", suffix)


def test_a_variable_that_was_never_set_is_nothing() raises:
    # Go's `Getenv` returns the empty string here and its `LookupEnv` returns
    # false. An `Optional` says both at once, and the caller that needs to tell
    # unset from empty is `core.time`: no `TZ` means the host's zone and an
    # empty `TZ` means UTC.
    assert_false(getenv(_name("never_set")))


def test_setting_then_reading_gives_the_value_back() raises:
    var name = _name("roundtrip")
    setenv(name, "a value")
    var got = getenv(name)
    assert_true(got)
    assert_equal(got.value(), "a value")
    unsetenv(name)


def test_an_empty_value_is_set_and_not_absent() raises:
    # The distinction the whole `Optional` is for. Both of these are the empty
    # string to anything that only asks for the value.
    var name = _name("empty")
    setenv(name, "")
    var got = getenv(name)
    assert_true(got)
    assert_equal(got.value(), "")
    unsetenv(name)
    assert_false(getenv(name))


def test_setting_twice_keeps_the_second() raises:
    # `setenv` is called with overwrite set, which is what Go's `Setenv` does.
    var name = _name("overwrite")
    setenv(name, "first")
    setenv(name, "second")
    assert_equal(getenv(name).value(), "second")
    unsetenv(name)


def test_unsetting_something_that_is_not_set_is_not_a_failure() raises:
    # POSIX says so, and Go's `Unsetenv` returns nil here too.
    unsetenv(_name("absent"))


def test_a_long_value_comes_back_whole() raises:
    # The reader walks to the zero byte a byte at a time, so a value longer
    # than any buffer anybody guessed at is worth one line.
    var name = _name("long")
    var value = String()
    for i in range(1000):
        value += chr(ord("a") + i % 26)
    setenv(name, value)
    var got = getenv(name).value()
    assert_equal(got.byte_length(), 1000)
    assert_equal(got, value)
    unsetenv(name)


def test_the_path_is_set_for_everybody() raises:
    # Not our variable, and the one thing that is set in every environment a
    # process can be started from. This is the test that would fail if the
    # binding read from the wrong place entirely.
    assert_true(getenv("PATH"))
