"""The environment, read and written through the C library.

`getenv`, `setenv` and `unsetenv` go to libc rather than to a copy of the
environment taken at start up, so the process the tests run in is the one being
changed. That is the point: `core.time` asks for `TZ` at the moment it needs it,
and a copy taken at start up would answer with what was set then.

`environ` and `clearenv` are the two that see the whole array. `environ` reads
it through the shim, and `clearenv` is written in terms of both and is the one
test here that has to put the environment back rather than one variable.

Every test here puts back what it found. A variable left set changes what a
later test in the same process sees, and `TZ` in particular changes what the
whole library thinks the local zone is.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.syscall import clearenv, environ, getenv, getpid, setenv, unsetenv


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


def _entry_for(name: String) raises -> Optional[String]:
    """The `name=value` line for a variable, out of the whole array."""
    var wanted = String(name, "=")
    for entry in environ():
        if entry.startswith(wanted):
            return Optional(entry)
    return None


def test_environ_finds_a_variable_this_test_set() raises:
    # The array and `getenv` have to be looking at the same place, and this is
    # what says so. On macOS the shim asks `_NSGetEnviron` for the address and
    # a wrong answer there would give a stale array that still had `PATH` in it,
    # so the variable being looked for is one set a moment ago.
    var name = _name("in_environ")
    setenv(name, "a value")
    var found = _entry_for(name)
    assert_true(found)
    assert_equal(found.value(), String(name, "=a value"))
    unsetenv(name)
    assert_false(_entry_for(name))


def test_environ_has_the_path_and_is_not_empty() raises:
    var all = environ()
    assert_true(len(all) > 0)
    assert_true(_entry_for("PATH"))


def test_every_entry_has_a_name_and_a_separator() raises:
    # Not a law, since a parent using `execve` can put anything in the array,
    # but it is true of every environment a test runner produces, and a walk
    # that lost its place would show up here as a line that is half of one
    # entry and half of the next.
    for entry in environ():
        assert_true(entry.find("=") > 0)


def test_a_value_with_an_equals_sign_in_it_is_one_entry() raises:
    # The name ends at the first `=` and everything after it is the value, so a
    # reader that split on the last one would report the wrong name.
    var name = _name("equals")
    setenv(name, "a=b=c")
    assert_equal(_entry_for(name).value(), String(name, "=a=b=c"))
    unsetenv(name)


def test_clearenv_empties_the_environment() raises:
    # The one destructive test in the suite. Everything is read first and put
    # back in a `finally`, because the tests that run after this one in the same
    # process need `PATH` and `TZ` to be what they were.
    var saved = environ()
    try:
        clearenv()
        assert_equal(len(environ()), 0)
        assert_false(getenv("PATH"))
        setenv(_name("after_clear"), "still works")
        assert_equal(len(environ()), 1)
    finally:
        clearenv()
        for entry in saved:
            var cut = entry.find("=")
            if cut > 0:
                setenv(
                    String(entry[byte=0:cut]), String(entry[byte = cut + 1 :])
                )
    assert_true(getenv("PATH"))
    assert_equal(len(environ()), len(saved))
